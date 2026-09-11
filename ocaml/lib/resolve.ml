(* Fold the layers into the one resolved config --dump-config prints.

   `layers` arrives already stacked -- built-in defaults, then the matched
   config sections, then the profile -- so precedence here is only CLI beats
   layers beats env default for scalars and booleans; lists union, CLI first,
   then the layers bottom-up, then the add-only allowed-hosts file. The order of
   the steps below is bin/csb's own, because two of them are observable:
   warnings reach stderr as they are reached, and a die stops everything after
   it. *)

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

(* A seed_merge= source, read host-side at resolution time so a launch carries
   the content rather than a path the sandbox would have to reach. NUL is what
   separates the records bin/csb reads back, so a file holding one could split
   itself into two instructions. *)
let read_seed_source ~where path =
  if not (Sys.file_exists path) then Err.die "%s: source not found: %s" where path;
  if Sys.is_directory path then Err.die "%s: source is a directory: %s" where path;
  let content = String.concat "\n" (Lines.of_file path) in
  if content = "" then Err.die "%s: source is empty: %s" where path;
  if String.contains content '\000' then
    Err.die "%s: source contains a NUL byte: %s" where path;
  content

(* One name may be answered by setenv, setenv_cmd or token_env, never by two:
   all three land in the same `env` invocation, where the last argument silently
   wins. Refusing is what keeps that from being a rule anyone has to know. *)
let refuse_env_collisions ~setenv ~setenv_cmd ~token_env ~token_cmd =
  List.iter
    (fun (var, _) ->
      if List.mem_assoc var setenv then
        Err.die "setenv and setenv_cmd both name %s (a variable has one source)" var;
      if var = token_env && token_cmd <> None then
        Err.die
          "setenv_cmd and token_cmd both name %s (use one; --token-env names another variable)"
          var)
    setenv_cmd

let resolve ~(env : Env.t) ~(cli : Cli.t) ~(layers : Profile.t) ~config_sections ~tmpdir
    ~read_hosts =
  let pf sel = sel layers in
  let plist sel = sel layers in

  let shell = bool_layer ~cli:cli.shell ~profile:(pf (fun p -> p.shell)) ~default:false in

  (* Which agent runs. One axis, one field, claude when no layer answers -- and
     the key every adapter lookup below is made through, so nothing else in csb
     needs to know the answer. It is resolved early because the egress
     allowlist file and the built-in setenv layer are both keyed by it. *)
  let agent =
    Option.value (Layer.value (Layer.over cli.agent (pf (fun p -> p.agent))))
      ~default:Types.Claude
  in

  (* The launch HOME: one axis, one field, every layer answering the same way.
     Per_repo is what Cleared and Unset both resolve to -- the difference between
     them is only whether a lower layer still gets to speak. *)
  let home =
    Option.fold ~none:Types.Per_repo ~some:Types.home_of_sel
      (Layer.value (Layer.over cli.home (pf (fun p -> p.home))))
  in
  let namespace = match home with Types.Shared n -> n | _ -> "" in
  let ephemeral_name =
    match home with Types.Throwaway (Types.Named n) -> Some n | _ -> None
  in

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
  let allow_loopback =
    bool_layer ~cli:cli.allow_loopback ~profile:(pf (fun p -> p.allow_loopback)) ~default:false
  in

  (* One CLI target of any kind takes the layers' whole set out of play, which is
     now just the axis being one field. *)
  let nix_targets =
    Option.value
      (Layer.value (Layer.over cli.nix (pf (fun p -> p.nix))))
      ~default:Types.no_nix_targets
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
  (* A launch that names no BRANCH is a launch HERE. csb is a launcher, so the
     absence of a target is an answer rather than a question -- and --here works
     from any checkout, a linked worktree included, which is what makes one rule
     enough: there is no "cd to the main checkout and spell the branch" case left
     for it to have to handle. `-l/--list` is the listing, and --here=false (from
     --no-here or a profile) still declines, which Resolve then refuses below
     rather than reinterpreting. *)
  let here =
    here
    || (cli.mode = Types.Launch && cli.branch = None && (not here_cli)
        && p_here <> Some false)
  in

  let seed_home = Layer.value (Layer.over cli.seed_home (pf (fun p -> p.seed_home))) in
  let token_cmd = Layer.value (Layer.over cli.token_cmd (pf (fun p -> p.token_cmd))) in
  let token_env =
    Option.value
      (Layer.value (Layer.over cli.token_env (pf (fun p -> p.token_env))))
      ~default:(Agent.token_env agent)
  in
  (* CSB_TMPDIR is the floor, as it is for latest and verbose: a layer that names
     tmpdir answers instead of it, and --no-tmpdir hands the question back. *)
  let cfg_tmpdir =
    match Layer.over cli.tmpdir (pf (fun p -> p.tmpdir)) with
    | Layer.Set v -> Some (Env.checked_tmpdir env ~where:"tmpdir" v)
    | Layer.Cleared -> None
    | Layer.Unset -> tmpdir
  in
  (* The one directory every temp path a launch writes sits under, resolved here
     so bin/csb consumes an answer rather than recomputing the fallback. Its
     whole job is to be stable: a launch execs through `nix develop`, which
     rewrites TMPDIR, so a base read at use time would move mid-launch. *)
  let tmp_base =
    match cfg_tmpdir with
    | Some d -> d
    | None -> ( match env.Env.system_tmpdir with Some d -> d | None -> "/tmp")
  in
  let accent = Layer.value (Layer.over cli.accent (pf (fun p -> p.accent))) in

  (* CLI first here, and LAST for setenv_cmd/seed_merge below. A path list is a
     set of rules whose order the sandbox builder does not read; those two are
     applied in sequence, so the higher layer has to be the later one to win. *)
  let deny_read = cli.deny_read @ plist (fun p -> p.deny_read) in
  let allow_write = cli.allow_write @ plist (fun p -> p.allow_write) in
  let allow_socket = cli.allow_socket @ plist (fun p -> p.allow_socket) in
  let paranoid_deny_read = cli.paranoid_deny_read @ plist (fun p -> p.paranoid_deny_read) in
  let paranoid_allow_read = cli.paranoid_allow_read @ plist (fun p -> p.paranoid_allow_read) in

  (* Running an agent with no sandbox defeats the whole tool. The condition is
     the "will actually launch the agent" guard. *)
  if (not sandbox) && (not shell) && cli.mode = Types.Launch && (not cli.no_launch)
     && (cli.branch <> None || here)
  then
    Err.die
      "--no-sandbox is only allowed with -s/--shell -- an agent never runs \
       unsandboxed.\n\
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

  let agent_args =
    match cli.agent_args with
    | Some args -> args
    | None -> (
        match Layer.value (pf (fun p -> p.args)) with
        | None -> []
        | Some s -> List.map (expand_word env) (Profile.split_ws s))
  in
  let agent_args =
    if not yolo then agent_args
    else if shell then (
      Err.warn "warning: -y/--yolo has no effect with --shell (ignored)";
      agent_args)
    else Agent.yolo_flag agent :: agent_args
  in

  let setenv =
    Profile.dedupe_setenv (Agent.setenv agent @ plist (fun p -> p.setenv) @ cli.setenv)
  in
  (* CLI last for the same reason setenv puts it last: dedupe keeps the final
     mention of a name, which is the highest layer to have made one. *)
  let setenv_cmd =
    Profile.dedupe_setenv (plist (fun p -> p.setenv_cmd) @ cli.setenv_cmd)
  in
  refuse_env_collisions ~setenv ~setenv_cmd ~token_env ~token_cmd;

  (* seed_merge= reads its sources here, so a missing or unreadable one fails
     before the launch has provisioned anything. The instructions go AFTER the
     adapter's, which is what makes an operator key win the deep merge. *)
  let seed_merge = plist (fun p -> p.seed_merge) @ cli.seed_merge in
  (* --real-home is never seeded -- csb does not write the operator's own HOME --
     so a seed_merge there would resolve, read its source, and then do nothing.
     Say so rather than leaving the operator to notice the merge never landed. *)
  if seed_merge <> [] && home = Types.Real_home then (
    Err.warn "warning: --real-home is never seeded, so seed_merge= has no effect";
    Err.note "  (the real HOME already holds the agent's own config)");
  let seed =
    Agent.seed agent
    @ List.map
        (fun (dest, src) ->
          { Types.verb = Types.Json_merge;
            arg = read_seed_source ~where:"seed_merge" src;
            dest })
        seed_merge
  in

  let target =
    if here then Types.Here
    else match cli.branch with Some b -> Types.Branch b | None -> Types.List_worktrees
  in
  (* The one launch with no target: here was turned OFF explicitly, and no BRANCH
     was named. Nothing to run, and nothing to guess -- say which flag answers
     it rather than falling back to a listing the operator did not ask for. *)
  if cli.mode = Types.Launch && target = Types.List_worktrees then
    Err.die
      "nothing to launch: no BRANCH, and here is off.\n\
      \  name a BRANCH, drop --no-here / here=false, or use -l/--list to list \
       the worktrees.";

  {
    Types.mode = cli.mode;
    dump = cli.dump;
    no_launch = cli.no_launch;
    target;
    runner = (if shell then Types.Shell else Types.Agent);
    agent;
    home;
    paranoid;
    pasteboard;
    sandbox;
    yolo;
    latest;
    verbose;
    reseed = cli.reseed;
    seed_creds;
    nix_targets;
    profiles = cli.profiles;
    token_cmd;
    token_env;
    seed_home;
    accent;
    cfg_tmpdir;
    tmp_base;
    agent_args;
    keep = cli.keep @ plist (fun p -> p.keep);
    (* The agent's quiet knobs are the lowest setenv layer: they cannot live in
       a static built-in layer any more, because which ones they are is exactly
       what the layers above decide. *)
    setenv;
    setenv_cmd;
    deny_read;
    allow_write;
    allow_socket;
    filter_egress;
    allow_loopback;
    allow_hosts = cli.allow_hosts @ plist (fun p -> p.allow_hosts) @ read_hosts agent;
    allow_ports = cli.allow_ports @ plist (fun p -> p.allow_ports);
    paranoid_deny_read;
    paranoid_allow_read;
    seed;
    cred_seed = Agent.cred_seed ~env ~darwin:(Env.is_darwin env) agent;
    seed_merge;
    config_sections;
  }
