(* csb-config -- csb's config-resolution layer (docs/PLAN-008-proxy.md section 9).

   A pure function of (argv, config files, env) printing bin/csb's
   --dump-config wire format. No git, no nix, no exec, no writes. The bats
   config suite is the oracle:

     make ocaml-test    # CSB=<this binary> bats test/precedence.bats test/lists.bats *)

open Csb_config
open Cmdliner

(* bin/csb's own order: the CLI exclusions, then CSB_TMPDIR, then the profile,
   then the allowed-hosts file. Each step can die, and which message the
   operator sees depends on getting here first. *)
let run env cli =
  Cli.check_exclusive cli;
  let tmpdir = Env.resolve_tmpdir env in
  let profile = Option.map (fun name -> Profile.load env ~name) cli.Cli.profile in
  let hosts_file = Hosts_file.read env in
  Dump.print (Resolve.resolve ~env ~cli ~profile ~tmpdir ~hosts_file)

let man =
  [
    `S Manpage.s_description;
    `P "csb-config resolves csb's configuration -- CLI flags over profile keys \
        over environment defaults -- and prints the result as KEY=VALUE lines. \
        It launches nothing and touches no repository.";
    `P "A flag and its --no- partner in one invocation is an error rather than \
        last-wins.";
    `S Manpage.s_environment;
    `P "CSB_LATEST, CSB_VERBOSE: non-empty defaults the matching flag on. \
        CSB_TMPDIR: the host scratch dir. XDG_CONFIG_HOME: where profiles and \
        allowed-hosts live.";
  ]

let () =
  let info = Cmd.info "csb-config" ~doc:"Resolve and print csb's configuration" ~man in
  try
    let env = Env.of_process () in
    let pre = Cli.prepass (List.tl (Array.to_list Sys.argv)) in
    let argv = Array.of_list (Sys.argv.(0) :: pre.Cli.opts) in
    match Cli.eval ~info ~argv (Cli.term env pre) with
    | Ok (`Ok cli) -> run env cli
    | Ok (`Help | `Version) -> ()
    | Error (`Parse | `Term | `Exn) -> exit Cmd.Exit.cli_error
  with Err.Die msg ->
    prerr_endline (Err.prog ^ ": " ^ msg);
    exit 1
