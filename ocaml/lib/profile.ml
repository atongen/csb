(* One layer of defaults: KEY=VALUE lines, '#' comments, blanks ignored.

   The same shape serves all three layers below the CLI -- the built-in
   defaults, the repo-selected sections of ~/.config/csb/config, and a named
   profile -- so one parser and one set of merge rules cover them all.

   Scalars are last-wins within a layer and lists accumulate in the order read.
   A scalar's empty value is a RETRACTION, not a silence: see `scalar`. *)

(* A sealed layer. The two multi-key axes are ONE field each, so "which HOME" and
   "which nix target" have a single answer per layer and cannot be half-set. *)
type t = {
  home : Types.home_sel Layer.t;
  nix : Types.nix_targets Layer.t;
  agent : Types.agent Layer.t;
  shell : bool option;
  token_cmd : string Layer.t;
  token_env : string Layer.t;
  aws_profile : string Layer.t;
  latest : bool option;
  verbose : bool option;
  yolo : bool option;
  paranoid : bool option;
  pasteboard : bool option;
  sandbox : bool option;
  here : bool option;
  seed_creds : bool option;
  seed_home : string Layer.t;
  tmpdir : string Layer.t;
  accent : string Layer.t;
  args : string Layer.t;
  filter_egress : bool option;
  allow_loopback : bool option;
  keep : string list;
  setenv : (string * string) list;
  setenv_cmd : (string * string) list;
  seed_merge : (string * string) list;
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
    home = Layer.Unset; nix = Layer.Unset; agent = Layer.Unset; shell = None;
    token_cmd = Layer.Unset; token_env = Layer.Unset; aws_profile = Layer.Unset;
    latest = None; verbose = None; yolo = None; paranoid = None;
    pasteboard = None; sandbox = None; here = None; seed_creds = None;
    seed_home = Layer.Unset; tmpdir = Layer.Unset; accent = Layer.Unset;
    args = Layer.Unset;
    filter_egress = None; allow_loopback = None; keep = []; setenv = [];
    setenv_cmd = []; seed_merge = []; deny_read = [];
    allow_write = []; allow_socket = []; allow_hosts = []; allow_ports = [];
    paranoid_deny_read = []; paranoid_allow_read = [];
  }

(* What one FILE says, before the axes are folded. The six raw keys are separate
   lines in the grammar, so they must be collected separately and reconciled once
   the file is read -- `ns=foo` and `ephemeral=false` on two lines are one
   answer, not two. Nothing outside this module sees a draft. *)
type draft = {
  layer : t;
  raw_ns : string Layer.t;
  raw_ephemeral : bool option;
  raw_real_home : bool option;
  raw_nix : string Layer.t;
  raw_nix_shell : string Layer.t;
  raw_nix_agent : string Layer.t;
}

let blank =
  {
    layer = empty; raw_ns = Layer.Unset; raw_ephemeral = None;
    raw_real_home = None; raw_nix = Layer.Unset; raw_nix_shell = Layer.Unset;
    raw_nix_agent = Layer.Unset;
  }

let known_keys =
  "agent, ns, token_cmd, token_env, aws_profile, latest, verbose, yolo, paranoid, pasteboard, \
   sandbox, real_home, here, ephemeral, shell, nix_target, nix_target_shell, \
   nix_target_agent, seed_creds, seed_home, seed_merge, tmpdir, accent, args, \
   keep, setenv, setenv_cmd, deny_read, allow_write, allow_socket, \
   filter_egress, allow_loopback, allow_host, allow_port, paranoid_deny_read, \
   paranoid_allow_read"

(* An empty value RETRACTS the key, so no layer below answers either: a repo
   default in ~/.config/csb/config is cancelled by `token_cmd=` in the profile
   that runs instead of it. A key a layer never mentions stays Unset, which is
   the difference between "not this one" and "no opinion". *)
let scalar v = if v = "" then Layer.Cleared else Layer.Set v

let split_ws s =
  List.filter (fun w -> w <> "")
    (String.split_on_char ' '
       (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s))

let apply env ~where d key value =
  let p = d.layer in
  let keep_layer l = { d with layer = l } in
  let b () = Some (Validate.profile_bool ~where ~key value) in
  let path () = Validate.list_path env ~where:(where ^ ": " ^ key) value in
  let target () = scalar (Validate.nix_target ~where:(where ^ ": " ^ key) value) in
  match key with
  | "ns" -> { d with raw_ns = scalar value }
  | "real_home" -> { d with raw_real_home = b () }
  | "ephemeral" -> { d with raw_ephemeral = b () }
  | "nix_target" -> { d with raw_nix = target () }
  | "nix_target_shell" -> { d with raw_nix_shell = target () }
  | "nix_target_agent" -> { d with raw_nix_agent = target () }
  | "agent" ->
      keep_layer
        { p with
          agent =
            (if value = "" then Layer.Cleared
             else Layer.Set (Agent.of_string ~where:(where ^ ": agent") value)) }
  | "shell" -> keep_layer { p with shell = b () }
  | "token_cmd" -> keep_layer { p with token_cmd = scalar value }
  | "token_env" ->
      keep_layer
        { p with
          token_env =
            (if value = "" then Layer.Cleared
             else Layer.Set (Validate.keep_var ~msg:(where ^ ": invalid token_env name") value)) }
  | "aws_profile" ->
      keep_layer
        { p with
          aws_profile =
            (if value = "" then Layer.Cleared
             else Layer.Set (Validate.aws_profile ~where:(where ^ ": aws_profile") value)) }
  | "latest" -> keep_layer { p with latest = b () }
  | "verbose" -> keep_layer { p with verbose = b () }
  | "yolo" -> keep_layer { p with yolo = b () }
  | "paranoid" -> keep_layer { p with paranoid = b () }
  | "pasteboard" -> keep_layer { p with pasteboard = b () }
  | "sandbox" -> keep_layer { p with sandbox = b () }
  | "here" -> keep_layer { p with here = b () }
  | "seed_creds" -> keep_layer { p with seed_creds = b () }
  | "seed_home" -> keep_layer { p with seed_home = scalar (Env.expand_tilde env value) }
  | "tmpdir" -> keep_layer { p with tmpdir = scalar (Env.expand_tilde env value) }
  | "accent" -> keep_layer { p with accent = scalar value }
  | "args" -> keep_layer { p with args = scalar value }
  | "keep" -> keep_layer { p with keep = p.keep @ split_ws value }
  | "setenv" -> keep_layer { p with setenv = p.setenv @ [ Validate.setenv ~where value ] }
  | "setenv_cmd" ->
      keep_layer { p with setenv_cmd = p.setenv_cmd @ [ Validate.setenv_cmd ~where value ] }
  | "seed_merge" ->
      keep_layer { p with seed_merge = p.seed_merge @ [ Validate.seed_merge env ~where value ] }
  | "deny_read" -> keep_layer { p with deny_read = p.deny_read @ [ path () ] }
  | "allow_write" -> keep_layer { p with allow_write = p.allow_write @ [ path () ] }
  | "allow_socket" -> keep_layer { p with allow_socket = p.allow_socket @ [ path () ] }
  | "filter_egress" -> keep_layer { p with filter_egress = b () }
  | "allow_loopback" -> keep_layer { p with allow_loopback = b () }
  | "allow_host" ->
      keep_layer
        { p with
          allow_hosts =
            p.allow_hosts @ [ Validate.host ~where:(where ^ ": allow_host") value ] }
  | "allow_port" ->
      keep_layer
        { p with
          allow_ports =
            p.allow_ports @ [ Validate.port ~where:(where ^ ": allow_port") value ] }
  | "paranoid_deny_read" ->
      keep_layer { p with paranoid_deny_read = p.paranoid_deny_read @ [ path () ] }
  | "paranoid_allow_read" ->
      keep_layer { p with paranoid_allow_read = p.paranoid_allow_read @ [ path () ] }
  | _ -> Err.die "%s: unknown key '%s' (%s)" where key known_keys

(* Surrounding whitespace is not part of either half, so `paranoid = true` and
   `paranoid=true` are the same line; a value that needs a leading or trailing
   space is the price. Split and application are separate steps because the
   config file dispatches on the key before this module sees it. *)
let split_kv ~where line =
  match String.index_opt line '=' with
  | None -> Err.die "%s: expected KEY=VALUE: '%s'" where line
  | Some i ->
      ( String.trim (String.sub line 0 i),
        String.trim (String.sub line (i + 1) (String.length line - i - 1)) )

let apply_line env ~where p line =
  let key, value = split_kv ~where line in
  apply env ~where p key value

let is_blank line = line = "" || line.[0] = '#'

let parse_file env d path =
  let step (d, lineno) line =
    let line = String.trim line in
    let lineno = lineno + 1 in
    if is_blank line then (d, lineno)
    else (apply_line env ~where:(Printf.sprintf "profile %s:%d" path lineno) d line, lineno)
  in
  fst (List.fold_left step (d, 0) (Lines.of_file path))

(* Fold a draft into a layer, which is where both axes get their single answer
   and where the invariants a layer must satisfy on its own are checked.

   The two HOME rules are not the same rule, and the difference is load-bearing:
   a POSITIVE selector is `ns=`, `ephemeral=true` or `real_home=true`, and two of
   those in one layer are unresolvable rather than ranked; but merely NAMING any
   of the three -- `ephemeral=false` included -- is the layer claiming the axis,
   which retracts whatever the layers below selected. So `ns=foo` beside
   `ephemeral=false` is one answer (Shared foo), while `ephemeral=false` alone is
   a retraction. `label` names the layer in every message. *)
let seal ~label d =
  let p = d.layer in
  let positive =
    List.filter_map Fun.id
      [ (match d.raw_ns with Layer.Set n -> Some (Types.Sel_shared n) | _ -> None);
        (if d.raw_ephemeral = Some true then Some (Types.Sel_throwaway Types.Anon)
         else None);
        (if d.raw_real_home = Some true then Some Types.Sel_real_home else None) ]
  in
  (match positive with
  | _ :: _ :: _ ->
      Err.die "%s: ns, ephemeral=true, and real_home=true are mutually exclusive" label
  | _ -> ());
  let named_axis =
    Layer.named d.raw_ns || d.raw_ephemeral <> None || d.raw_real_home <> None
  in
  let home =
    match positive with
    | sel :: _ -> Layer.Set sel
    | [] -> if named_axis then Layer.Cleared else Layer.Unset
  in
  let nix =
    if
      Layer.named d.raw_nix || Layer.named d.raw_nix_shell
      || Layer.named d.raw_nix_agent
    then
      Layer.Set
        {
          Types.shared = Layer.value d.raw_nix;
          for_shell = Layer.value d.raw_nix_shell;
          for_agent = Layer.value d.raw_nix_agent;
        }
    else Layer.Unset
  in
  { p with
    home;
    nix;
    keep = List.map (Validate.keep_var ~msg:(label ^ ": invalid keep var name")) p.keep }

let file env ~name = Filename.concat (Env.profiles_dir env) name
let has_file env ~name = Sys.file_exists (file env ~name)

(* Read NAME, then the optional gitignored NAME.local overlay. *)
let load env ~name =
  let base = file env ~name in
  let overlay = base ^ ".local" in
  if not (Sys.file_exists base) then Err.die "profile not found: %s" base;
  let d = parse_file env blank base in
  let d = if Sys.file_exists overlay then parse_file env d overlay else d in
  seal ~label:("profile " ^ name) d

(* Seal an already-split body as one layer: a [profile NAME] block in the config
   file, whose lines were collected there instead of read from profiles/NAME.
   The two sources produce the same kind of layer and are stacked the same way,
   so nothing downstream needs to know which one a -p resolved to. *)
let of_body env ~label body =
  seal ~label
    (List.fold_left (fun d (where, key, value) -> apply env ~where d key value) blank body)

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

(* Stack `over` on `base`: whatever the higher layer answered wins, lists union
   with the lower layer first. The two multi-key axes need no special case any
   more -- each is one field, so `Layer.over` moving it as a unit is the same
   statement as moving any other key. *)
let overlay ~base ~over =
  let s hi lo = match hi with Some _ -> hi | None -> lo in
  {
    home = Layer.over over.home base.home;
    nix = Layer.over over.nix base.nix;
    agent = Layer.over over.agent base.agent;
    shell = s over.shell base.shell;
    token_cmd = Layer.over over.token_cmd base.token_cmd;
    token_env = Layer.over over.token_env base.token_env;
    aws_profile = Layer.over over.aws_profile base.aws_profile;
    latest = s over.latest base.latest;
    verbose = s over.verbose base.verbose;
    yolo = s over.yolo base.yolo;
    paranoid = s over.paranoid base.paranoid;
    pasteboard = s over.pasteboard base.pasteboard;
    sandbox = s over.sandbox base.sandbox;
    here = s over.here base.here;
    seed_creds = s over.seed_creds base.seed_creds;
    seed_home = Layer.over over.seed_home base.seed_home;
    tmpdir = Layer.over over.tmpdir base.tmpdir;
    accent = Layer.over over.accent base.accent;
    args = Layer.over over.args base.args;
    filter_egress = s over.filter_egress base.filter_egress;
    allow_loopback = s over.allow_loopback base.allow_loopback;
    keep = base.keep @ over.keep;
    setenv = dedupe_setenv (base.setenv @ over.setenv);
    setenv_cmd = dedupe_setenv (base.setenv_cmd @ over.setenv_cmd);
    seed_merge = base.seed_merge @ over.seed_merge;
    deny_read = base.deny_read @ over.deny_read;
    allow_write = base.allow_write @ over.allow_write;
    allow_socket = base.allow_socket @ over.allow_socket;
    allow_hosts = base.allow_hosts @ over.allow_hosts;
    allow_ports = base.allow_ports @ over.allow_ports;
    paranoid_deny_read = base.paranoid_deny_read @ over.paranoid_deny_read;
    paranoid_allow_read = base.paranoid_allow_read @ over.paranoid_allow_read;
  }
