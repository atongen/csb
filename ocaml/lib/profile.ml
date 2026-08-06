(* ~/.config/csb/profiles/NAME (+ an optional NAME.local overlay) parsed into one
   layer of defaults: KEY=VALUE lines, '#' comments, blanks ignored.

   Scalars are last-wins across both files -- an empty value resets the key to
   absent, which is how bin/csb's `[[ -n "$p_key" ]]` guards read. Lists
   accumulate, base first. *)

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

let parse_file env p path =
  let step (p, lineno) line =
    let lineno = lineno + 1 in
    let where = Printf.sprintf "profile %s:%d" path lineno in
    if line = "" || line.[0] = '#' then (p, lineno)
    else
      match String.index_opt line '=' with
      | None -> Err.die "%s: expected KEY=VALUE: '%s'" where line
      | Some i ->
          let key = String.sub line 0 i in
          let value = String.sub line (i + 1) (String.length line - i - 1) in
          (apply env ~where p key value, lineno)
  in
  fst (List.fold_left step (p, 0) (Lines.of_file path))

(* Read NAME, then the optional gitignored NAME.local overlay, and check the
   per-profile invariants that need the profile's name in their message. *)
let load env ~name =
  let base = Filename.concat (Env.profiles_dir env) name in
  let overlay = base ^ ".local" in
  if not (Sys.file_exists base) then Err.die "profile not found: %s" base;
  let p = parse_file env empty base in
  let p = if Sys.file_exists overlay then parse_file env p overlay else p in
  let home_sel =
    List.length
      (List.filter Fun.id
         [ p.ns <> None; p.ephemeral = Some true; p.real_home = Some true ])
  in
  if home_sel > 1 then
    Err.die "profile %s: ns, ephemeral=true, and real_home=true are mutually exclusive" name;
  let keep =
    List.map
      (Validate.keep_var ~msg:(Printf.sprintf "profile %s: invalid keep var name" name))
      p.keep
  in
  { p with keep }
