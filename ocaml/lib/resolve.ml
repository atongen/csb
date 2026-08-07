(* Fold the layers into the one resolved config --dump-config prints.

   Precedence: CLI beats profile beats env default for scalars and booleans;
   lists union, CLI first, then the profile (base then .local), then the
   add-only allowed-hosts file. The order of the steps below is bin/csb's own,
   because two of them are observable: warnings reach stderr as they are
   reached, and a die stops everything after it. *)

let opt_or higher lower = match higher with Some _ -> higher | None -> lower

let bool_layer ~cli ~profile ~default =
  Option.value (opt_or cli profile) ~default

(* Literal ${HOME} and a leading ~/ are the two expansions a profile args= word
   gets; nothing else is interpreted. *)
let expand_word env w =
  let home = env.Env.home in
  let buf = Buffer.create (String.length w) in
  let sub = "${HOME}" in
  let n = String.length sub in
  let i = ref 0 in
  while !i < String.length w do
    if !i + n <= String.length w && String.sub w !i n = sub then (
      Buffer.add_string buf home;
      i := !i + n)
    else (
      Buffer.add_char buf w.[!i];
      incr i)
  done;
  Env.expand_tilde env (Buffer.contents buf)

let resolve ~(env : Env.t) ~(cli : Cli.t) ~(profile : Profile.t option) ~tmpdir ~hosts_file =
  let pf sel = match profile with None -> None | Some p -> sel p in
  let plist sel = match profile with None -> [] | Some p -> sel p in

  let shell = bool_layer ~cli:cli.shell ~profile:(pf (fun p -> p.shell)) ~default:false in

  (* The launch HOME: three selectors on one axis, each profile value suppressed
     by an explicit CLI choice anywhere on that axis. *)
  let ns_cli, ns_val =
    match cli.ns with Set n -> (true, n) | Cleared -> (true, "") | Untouched -> (false, "")
  in
  let eph_cli = cli.ephemeral <> None in
  let rh_cli = cli.real_home <> None in
  let real_home =
    match pf (fun p -> p.real_home) with
    | Some v when (not rh_cli) && ns_val = "" && not eph_cli -> v
    | _ -> cli.real_home = Some true
  in
  let ephemeral =
    match pf (fun p -> p.ephemeral) with
    | Some v when (not eph_cli) && ns_val = "" && not real_home -> v
    | _ -> cli.ephemeral = Some true
  in
  let namespace =
    match pf (fun p -> p.ns) with
    | Some n when ns_val = "" && (not ephemeral) && (not real_home) && not ns_cli -> n
    | _ -> ns_val
  in
  let ephemeral_name = if ephemeral then cli.ephemeral_name else None in

  let latest = bool_layer ~cli:cli.latest ~profile:(pf (fun p -> p.latest)) ~default:env.latest in
  let verbose =
    bool_layer ~cli:cli.verbose ~profile:(pf (fun p -> p.verbose)) ~default:env.verbose
  in
  let yolo = bool_layer ~cli:cli.yolo ~profile:(pf (fun p -> p.yolo)) ~default:false in
  let paranoid =
    bool_layer ~cli:cli.paranoid ~profile:(pf (fun p -> p.paranoid)) ~default:false
  in
  let pasteboard =
    bool_layer ~cli:cli.pasteboard ~profile:(pf (fun p -> p.pasteboard)) ~default:false
  in
  let sandbox = bool_layer ~cli:cli.sandbox ~profile:(pf (fun p -> p.sandbox)) ~default:true in
  let seed_creds =
    bool_layer ~cli:cli.seed_creds ~profile:(pf (fun p -> p.seed_creds)) ~default:false
  in
  let filter_egress =
    bool_layer ~cli:cli.filter_egress ~profile:(pf (fun p -> p.filter_egress)) ~default:false
  in

  (* One CLI target of any kind takes the profile's whole set out of play. *)
  let nix_targets =
    match cli.nix_targets with
    | Cli.Nt_cleared -> Types.no_nix_targets
    | Cli.Nt_set t -> t
    | Cli.Nt_untouched ->
        {
          Types.shared = pf (fun p -> p.nix_target);
          for_shell = pf (fun p -> p.nix_target_shell);
          for_claude = pf (fun p -> p.nix_target_claude);
        }
  in

  let here_cli = cli.here <> None in
  let p_here = pf (fun p -> p.here) in
  let here =
    match p_here with
    | Some v when not here_cli ->
        if v && cli.branch <> None then (
          Err.warn "warning: profile here=true overridden by BRANCH '%s' (worktree mode)"
            (Option.get cli.branch);
          cli.here = Some true)
        else v
    | _ -> cli.here = Some true
  in
  (* Bare `csb -p NAME` launches --here: a profile is a launch config, and plain
     `csb` still lists. *)
  let here =
    here
    || (cli.profile <> None && cli.mode = Types.Launch && cli.branch = None
        && (not here_cli) && p_here <> Some false)
  in

  let seed_home =
    match cli.seed_home with
    | Cli.Set v -> Some v
    | Cli.Cleared -> None
    | Cli.Untouched -> pf (fun p -> p.seed_home)
  in
  let accent =
    match cli.accent with
    | Cli.Set v -> Some v
    | Cli.Cleared -> None
    | Cli.Untouched -> pf (fun p -> p.accent)
  in

  let deny_read = cli.deny_read @ plist (fun p -> p.deny_read) in
  let allow_write = cli.allow_write @ plist (fun p -> p.allow_write) in
  let allow_socket = cli.allow_socket @ plist (fun p -> p.allow_socket) in
  let paranoid_deny_read = cli.paranoid_deny_read @ plist (fun p -> p.paranoid_deny_read) in
  let paranoid_allow_read = cli.paranoid_allow_read @ plist (fun p -> p.paranoid_allow_read) in

  (* Running claude with no sandbox defeats the whole tool. The condition is the
     "will actually launch claude" guard. *)
  if (not sandbox) && (not shell) && cli.mode = Types.Launch && (not cli.no_launch)
     && (cli.branch <> None || here)
  then
    Err.die
      "--no-sandbox is only allowed with -s/--shell -- claude never runs unsandboxed.\n\
      \  add -s for an unsandboxed shell, or drop --no-sandbox.";

  if not sandbox then (
    if paranoid || deny_read <> [] || allow_write <> [] || allow_socket <> []
       || paranoid_deny_read <> [] || paranoid_allow_read <> []
    then (
      Err.warn "warning: --no-sandbox drops the filesystem sandbox; --paranoid and the";
      Err.note "  deny-read / allow-write / allow-socket lists have no effect in this mode");
    if filter_egress then (
      Err.warn
        "warning: --filter-egress needs the sandbox to enforce it (the profile is what";
      Err.note
        "  leaves the proxy as the only reachable endpoint); egress is NOT filtered here"));

  if namespace <> "" then ignore (Validate.namespace namespace);
  (match ephemeral_name with Some n -> ignore (Validate.ephemeral_name n) | None -> ());
  (match accent with Some a -> ignore (Validate.accent a) | None -> ());

  let claude_args =
    match cli.claude_args with
    | Some args -> args
    | None -> (
        match pf (fun p -> p.args) with
        | None -> []
        | Some s -> List.map (expand_word env) (Profile.split_ws s))
  in
  let claude_args =
    if not yolo then claude_args
    else if shell then (
      Err.warn "warning: -y/--yolo has no effect with --shell (ignored)";
      claude_args)
    else "--dangerously-skip-permissions" :: claude_args
  in

  {
    Types.mode = cli.mode;
    dump = cli.dump;
    no_launch = cli.no_launch;
    target =
      (if here then Types.Here
       else match cli.branch with Some b -> Types.Branch b | None -> Types.List_worktrees);
    runner = (if shell then Types.Shell else Types.Claude);
    home =
      (if real_home then Types.Real_home
       else if ephemeral then
         Types.Throwaway
           (match ephemeral_name with Some n -> Types.Named n | None -> Types.Anon)
       else if namespace <> "" then Types.Shared namespace
       else Types.Per_repo);
    paranoid;
    pasteboard;
    sandbox;
    yolo;
    latest;
    verbose;
    reseed = cli.reseed;
    seed_creds;
    nix_targets;
    profile = cli.profile;
    token_cmd = pf (fun p -> p.token_cmd);
    seed_home;
    accent;
    cfg_tmpdir = tmpdir;
    claude_args;
    keep = cli.keep @ plist (fun p -> p.keep);
    setenv = plist (fun p -> p.setenv);
    deny_read;
    allow_write;
    allow_socket;
    filter_egress;
    allow_hosts = cli.allow_hosts @ plist (fun p -> p.allow_hosts) @ hosts_file;
    allow_ports = cli.allow_ports @ plist (fun p -> p.allow_ports);
    paranoid_deny_read;
    paranoid_allow_read;
  }
