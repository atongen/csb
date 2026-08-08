(* One layer of defaults: KEY=VALUE lines, '#' comments, blanks ignored.

   The same shape serves all three layers below the CLI -- the built-in
   defaults, the repo-selected sections of ~/.config/csb/config, and a named
   profile -- so one parser and one set of merge rules cover them all.

   Scalars are last-wins within a layer -- an empty value resets the key to
   absent, which is how bin/csb's `[[ -n "$p_key" ]]` guards read. Lists
   accumulate in the order read. *)

type t = {
  ns : string option;
  shell : bool option;
  token_cmd : string option;
  latest : bool option;
  verbose : bool option;
  yolo : bool option;
  paranoid : bool option;
  pasteboard : bool option;
  nix_target : string option;
  nix_target_shell : string option;
  nix_target_claude : string option;
  sandbox : bool option;
  real_home : bool option;
  here : bool option;
  ephemeral : bool option;
  seed_creds : bool option;
  seed_home : string option;
  accent : string option;
  args : string option;
  filter_egress : bool option;
  keep : string list;
  setenv : (string * string) list;
  deny_read : string list;
  allow_write : string list;
  allow_socket : string list;
  allow_hosts : string list;
  allow_ports : int list;
  paranoid_deny_read : string list;
  paranoid_allow_read : string list;
}

let empty =
  {
    ns = None; shell = None; token_cmd = None; latest = None; verbose = None;
    yolo = None; paranoid = None; pasteboard = None; nix_target = None;
    nix_target_shell = None; nix_target_claude = None; sandbox = None;
    real_home = None; here = None; ephemeral = None; seed_creds = None;
    seed_home = None; accent = None; args = None; filter_egress = None;
    keep = []; setenv = []; deny_read = []; allow_write = []; allow_socket = [];
    allow_hosts = []; allow_ports = []; paranoid_deny_read = [];
    paranoid_allow_read = [];
  }

(* Layer 1. Two variables that cost nothing and remove noise a tight egress
   allowlist otherwise produces: claude is pinned by nix, so an auto-update can
   only target a read-only store path, and the non-essential traffic is
   telemetry. Overridable like any other layer's setenv. *)
let builtin =
  {
    empty with
    setenv =
      [ ("DISABLE_AUTOUPDATER", "1");
        ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1") ];
  }

let known_keys =
  "ns, token_cmd, latest, verbose, yolo, paranoid, pasteboard, sandbox, \
   real_home, here, ephemeral, shell, nix_target, nix_target_shell, \
   nix_target_claude, seed_creds, seed_home, accent, args, keep, setenv, \
   deny_read, allow_write, allow_socket, filter_egress, allow_host, \
   allow_port, paranoid_deny_read, paranoid_allow_read"

let scalar v = if v = "" then None else Some v

let split_ws s =
  List.filter (fun w -> w <> "")
    (String.split_on_char ' '
       (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s))

let apply env ~where p key value =
  let b () = Some (Validate.profile_bool ~where ~key value) in
  let path () = Validate.list_path env ~where:(where ^ ": " ^ key) value in
  let target () = scalar (Validate.nix_target ~where:(where ^ ": " ^ key) value) in
  match key with
  | "ns" -> { p with ns = scalar value }
  | "shell" -> { p with shell = b () }
  | "token_cmd" -> { p with token_cmd = scalar value }
  | "latest" -> { p with latest = b () }
  | "verbose" -> { p with verbose = b () }
  | "yolo" -> { p with yolo = b () }
  | "paranoid" -> { p with paranoid = b () }
  | "pasteboard" -> { p with pasteboard = b () }
  | "nix_target" -> { p with nix_target = target () }
  | "nix_target_shell" -> { p with nix_target_shell = target () }
  | "nix_target_claude" -> { p with nix_target_claude = target () }
  | "sandbox" -> { p with sandbox = b () }
  | "real_home" -> { p with real_home = b () }
  | "here" -> { p with here = b () }
  | "ephemeral" -> { p with ephemeral = b () }
  | "seed_creds" -> { p with seed_creds = b () }
  | "seed_home" -> { p with seed_home = scalar (Env.expand_tilde env value) }
  | "accent" -> { p with accent = scalar value }
  | "args" -> { p with args = scalar value }
  | "keep" -> { p with keep = p.keep @ split_ws value }
  | "setenv" -> { p with setenv = p.setenv @ [ Validate.setenv ~where value ] }
  | "deny_read" -> { p with deny_read = p.deny_read @ [ path () ] }
  | "allow_write" -> { p with allow_write = p.allow_write @ [ path () ] }
  | "allow_socket" -> { p with allow_socket = p.allow_socket @ [ path () ] }
  | "filter_egress" -> { p with filter_egress = b () }
  | "allow_host" ->
      { p with
        allow_hosts =
          p.allow_hosts @ [ Validate.host ~where:(where ^ ": allow_host") value ] }
  | "allow_port" ->
      { p with
        allow_ports =
          p.allow_ports @ [ Validate.port ~where:(where ^ ": allow_port") value ] }
  | "paranoid_deny_read" ->
      { p with paranoid_deny_read = p.paranoid_deny_read @ [ path () ] }
  | "paranoid_allow_read" ->
      { p with paranoid_allow_read = p.paranoid_allow_read @ [ path () ] }
  | _ -> Err.die "%s: unknown key '%s' (%s)" where key known_keys

(* A KEY=VALUE line, applied to p. Surrounding whitespace is not part of either
   half, so `paranoid = true` and `paranoid=true` are the same line; a value
   that needs a leading or trailing space is the price. *)
let apply_line env ~where p line =
  match String.index_opt line '=' with
  | None -> Err.die "%s: expected KEY=VALUE: '%s'" where line
  | Some i ->
      let key = String.trim (String.sub line 0 i) in
      let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
      apply env ~where p key value

let is_blank line = line = "" || line.[0] = '#'

let parse_file env p path =
  let step (p, lineno) line =
    let line = String.trim line in
    let lineno = lineno + 1 in
    if is_blank line then (p, lineno)
    else (apply_line env ~where:(Printf.sprintf "profile %s:%d" path lineno) p line, lineno)
  in
  fst (List.fold_left step (p, 0) (Lines.of_file path))

(* The invariants a layer must satisfy on its own. The three HOME selectors are
   one axis, so a single layer naming two of them is unresolvable rather than
   ranked; `label` names the layer in both messages. *)
let checked ~label p =
  let home_sel =
    List.length
      (List.filter Fun.id
         [ p.ns <> None; p.ephemeral = Some true; p.real_home = Some true ])
  in
  if home_sel > 1 then
    Err.die "%s: ns, ephemeral=true, and real_home=true are mutually exclusive" label;
  { p with
    keep = List.map (Validate.keep_var ~msg:(label ^ ": invalid keep var name")) p.keep }

(* Read NAME, then the optional gitignored NAME.local overlay. *)
let load env ~name =
  let base = Filename.concat (Env.profiles_dir env) name in
  let overlay = base ^ ".local" in
  if not (Sys.file_exists base) then Err.die "profile not found: %s" base;
  let p = parse_file env empty base in
  let p = if Sys.file_exists overlay then parse_file env p overlay else p in
  checked ~label:("profile " ^ name) p

(* One VAR per name, keeping the last -- and so the highest layer -- to set it.
   The launch exports these in order and a later `env` argument wins, which a
   surviving duplicate would decide silently. *)
let dedupe_setenv kvs =
  let rec keep_first seen = function
    | [] -> []
    | (k, v) :: tl ->
        if List.mem k seen then keep_first seen tl else (k, v) :: keep_first (k :: seen) tl
  in
  List.rev (keep_first [] (List.rev kvs))

(* Stack `over` on `base`: a scalar the higher layer sets wins, lists union with
   the lower layer first, and the two multi-key axes move as a unit -- a layer
   that names any one of the HOME selectors, or any one of the nix targets,
   takes the whole axis below it out of play rather than leaving two layers to
   answer one question between them. *)
let overlay ~base ~over =
  let s hi lo = match hi with Some _ -> hi | None -> lo in
  let home_over = over.ns <> None || over.ephemeral <> None || over.real_home <> None in
  let nt_over =
    over.nix_target <> None || over.nix_target_shell <> None
    || over.nix_target_claude <> None
  in
  let axis on hi lo = if on then hi else lo in
  {
    ns = axis home_over over.ns base.ns;
    ephemeral = axis home_over over.ephemeral base.ephemeral;
    real_home = axis home_over over.real_home base.real_home;
    nix_target = axis nt_over over.nix_target base.nix_target;
    nix_target_shell = axis nt_over over.nix_target_shell base.nix_target_shell;
    nix_target_claude = axis nt_over over.nix_target_claude base.nix_target_claude;
    shell = s over.shell base.shell;
    token_cmd = s over.token_cmd base.token_cmd;
    latest = s over.latest base.latest;
    verbose = s over.verbose base.verbose;
    yolo = s over.yolo base.yolo;
    paranoid = s over.paranoid base.paranoid;
    pasteboard = s over.pasteboard base.pasteboard;
    sandbox = s over.sandbox base.sandbox;
    here = s over.here base.here;
    seed_creds = s over.seed_creds base.seed_creds;
    seed_home = s over.seed_home base.seed_home;
    accent = s over.accent base.accent;
    args = s over.args base.args;
    filter_egress = s over.filter_egress base.filter_egress;
    keep = base.keep @ over.keep;
    setenv = dedupe_setenv (base.setenv @ over.setenv);
    deny_read = base.deny_read @ over.deny_read;
    allow_write = base.allow_write @ over.allow_write;
    allow_socket = base.allow_socket @ over.allow_socket;
    allow_hosts = base.allow_hosts @ over.allow_hosts;
    allow_ports = base.allow_ports @ over.allow_ports;
    paranoid_deny_read = base.paranoid_deny_read @ over.paranoid_deny_read;
    paranoid_allow_read = base.paranoid_allow_read @ over.paranoid_allow_read;
  }
