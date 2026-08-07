(* csb-config -- csb's config-resolution layer (docs/PLAN-008-proxy.md section 9).

   A pure function of (argv, config files, env): no git, no nix, no exec, and no
   writes beyond the emit file. It answers --dump-config, --help and --version
   itself; bin/csb sets CSB_EMIT_TO for everything else and keeps git, nix and
   exec in bash.

     make ocaml-test    # the bats config suite, with this binary as CSB

   The emit target arrives in the environment rather than as a flag so that it
   cannot collide with the operator's own argv, and so every cmdliner outcome --
   including the ones that never reach the term -- can see it.

   bin/csb invokes this through `exec -a`, so argv[0] -- and therefore the
   message prefix, the usage line and the version string -- names whichever
   program the operator actually typed. *)

open Csb_config
open Cmdliner

(* The contract with bin/csb. Exit 0 means the emit file holds a resolution;
   exit 2 means csb-config already answered the operator and resolved nothing,
   so the caller stops without launching. Anything else is a failure whose
   message is already on stderr. Without an emit target there is no caller to
   signal, so answering the operator is an ordinary success. *)
let exit_answered = 2

(* bin/csb's own order: the CLI exclusions, then CSB_TMPDIR, then the profile,
   then the allowed-hosts file. Each step can die, and which message the
   operator sees depends on getting here first. *)
let run env cli emit ~answered =
  Cli.check_exclusive cli;
  let tmpdir = Env.resolve_tmpdir env in
  let profile = Option.map (fun name -> Profile.load env ~name) cli.Cli.profile in
  let hosts_file = Hosts_file.read env in
  let cfg = Resolve.resolve ~env ~cli ~profile ~tmpdir ~hosts_file in
  match (cfg.Types.dump, emit) with
  | Types.Dump_config, _ | _, None ->
      Dump.print cfg;
      answered
  | (Types.No_dump | Types.Dump_sandbox), Some path ->
      Emit.to_file path cfg;
      0

(* cmdliner picks its help renderer from TERM rather than from whether anyone is
   watching, so a piped --help arrives overstruck for a pager that is not there.
   A non-tty stdout gets the plain form instead. The sibling of the unstyling
   Cli.eval does for diagnostics on stderr. *)
let plain_help_when_piped opts =
  if Unix.isatty Unix.stdout then opts
  else List.map (function "-h" | "--help" -> "--help=plain" | a -> a) opts

let doc = "Run Claude Code, or a shell, in a sandboxed per-branch git worktree"

let man =
  [
    `S Manpage.s_synopsis;
    `P "$(mname) [$(i,OPTION)]... $(i,BRANCH) [-- $(i,ARG)...]";
    `Noblank;
    `P "$(mname) [$(i,OPTION)]... --here [-- $(i,ARG)...]";
    `Noblank;
    `P "$(mname) -n $(i,BRANCH)";
    `Noblank;
    `P "$(mname) -d $(i,BRANCH)";
    `Noblank;
    `P "$(mname) --list-ns";
    `Noblank;
    `P "$(mname)";
    `S Manpage.s_description;
    `P
      "The first form provisions a git worktree for $(i,BRANCH) and launches \
       claude in it; --here launches in the current checkout instead. -n \
       prepares a worktree without launching, -d removes one, --list-ns lists \
       the namespace configs, and a bare $(mname) lists the worktrees.";
    `P
      "Claude, or the -s shell, runs inside the repo's own nix devShell with a \
       scrubbed environment, a private HOME (per-repo by default), a read \
       deny-list (~/.ssh, ~/.aws, the real ~/.claude and more -- extend it with \
       --deny-read), and a write allow-list (the worktree, the git dir, the \
       launch HOME and the temp dir -- extend it with --allow-write).";
    `P
      "Network egress stays open by default, so local services over TCP stay \
       reachable; --filter-egress narrows it to an allowlist. Host IPC does not \
       stay open -- mach and XPC and every host unix socket on macOS, the \
       session and system buses and the nix daemon socket on Linux -- so a host \
       service cannot act outside the sandbox on the sandbox's behalf. Unix \
       sockets inside the sandbox's own trees still work, and a host socket can \
       be named with --allow-socket.";
    `P "See the README for the design and the threat model, and 'Known gaps' for what is still open.";
    `S Cli.s_home;
    `P
      "-N, -E and --real-home are three MUTUALLY EXCLUSIVE answers to one \
       question: which HOME the sandboxed process gets. Each one, potentially \
       creating it, sets HOME inside the sandbox; they differ in persistence and \
       in whether that HOME is WRITABLE there.";
    `P
      "Naming none of them gives the fourth answer, and the default: the \
       per-repo HOME ~/.csb/claudes/repo-<key>, persistent and writable, shared \
       by all the repo's branches and worktrees.";
    `S Cli.s_policy;
    `S Cli.s_egress;
    `S Cli.s_seed;
    `S Cli.s_seams;
    `S Cli.s_negate;
    `P
      "Each negation overrides a profile default -- or, for latest and verbose, \
       the CSB_LATEST and CSB_VERBOSE environment defaults -- for one run. A \
       flag and its --no- partner in the same invocation is an error rather than \
       last-wins.";
    `S "PROFILES";
    `P
      "-p NAME reads ~/.config/csb/profiles/NAME, then the optional gitignored \
       NAME.local overlay, as KEY=VALUE lines with '#' comments. The keys are: \
       ns, token_cmd, latest, verbose, yolo, paranoid, pasteboard, sandbox, \
       real_home, here, ephemeral, shell, nix_target, nix_target_shell, \
       nix_target_claude, seed_creds, seed_home, accent, args, keep, setenv, \
       deny_read, allow_write, allow_socket, filter_egress, allow_host, \
       allow_port, paranoid_deny_read, paranoid_allow_read.";
    `P
      "Scalars and booleans are last-wins across the two files and are beaten by \
       an explicit CLI flag; lists accumulate across every source.";
    `S Manpage.s_environment;
    `I
      ( "CSB_SELF",
        "The flake ref csb pulls the claude binary from. Default: the private \
         remote. Override with a path: ref for local development." );
    `I ("CSB_LATEST", "Non-empty defaults -L/--latest on.");
    `I
      ( "CSB_LATEST_TTL",
        "Seconds to reuse a cached upstream claude-code rev under -L/--latest \
         before re-checking. Default 86400, daily; 0 checks every run." );
    `I ("CSB_VERBOSE", "Non-empty defaults -v/--verbose on.");
    `I ("CSB_TMPDIR", "The host scratch directory: the launched process's TMPDIR, the base for an ephemeral HOME, and a write root.");
    `I ("XDG_CONFIG_HOME", "Where the profiles and the allowed-hosts file live. Default ~/.config.");
    `I ("CSB_CONFIG_BIN", "Use this csb-config binary verbatim instead of searching for one.");
    `I ("CSB_PROXY_BIN", "Use this csb-proxy binary verbatim instead of resolving it from CSB_SELF.");
    `I ("CSB_BWRAP_BIN", "Linux: use this bubblewrap binary verbatim instead of building it via nix.");
    `S Manpage.s_files;
    `I ("~/.config/csb/profiles/NAME", "A named profile, plus its optional NAME.local overlay.");
    `I ("~/.config/csb/allowed-hosts", "The user-global egress allowlist, add-only, one host or *.suffix per line.");
    `I ("~/.config/csb/home", "The default template --seed-home copies into a fresh launch HOME.");
    `I ("~/.csb/claudes", "The persistent launch HOMEs: repo-<key> per repo, @NAME per namespace.");
  ]

let () =
  let prog = Err.prog in
  let emit = match Sys.getenv_opt "CSB_EMIT_TO" with Some "" | None -> None | p -> p in
  let answered = match emit with None -> 0 | Some _ -> exit_answered in
  let info = Cmd.info prog ~version:(prog ^ " " ^ Version.csb) ~doc ~man in
  try
    let env = Env.of_process () in
    let pre = Cli.prepass (List.tl (Array.to_list Sys.argv)) in
    let argv = Array.of_list (Sys.argv.(0) :: plain_help_when_piped pre.Cli.opts) in
    match Cli.eval ~info ~argv (Cli.term env pre) with
    | Ok (`Ok cli) -> exit (run env cli emit ~answered)
    (* cmdliner printed the page itself, so nothing was resolved. *)
    | Ok (`Help | `Version) -> exit answered
    | Error (`Parse | `Term | `Exn) -> exit Cmd.Exit.cli_error
  with Err.Die msg ->
    prerr_endline (Err.prog ^ ": " ^ msg);
    exit 1
