(* The command line as one layer: what the operator explicitly asked for, with
   "untouched" distinguished from "set to the default value" so a profile knows
   whether it may supply a value.

   Two rules shape the parsing:

   - A flag and its --no- partner in one invocation is an ERROR, not last-wins.
     cmdliner cannot see the relative order of two different options, and an
     ordering that silently picks the wrong one is worse than a refusal.
   - Values are optional at the cmdliner level (~vopt) so that a missing one
     surfaces as csb's own "requires a NAME" rather than cmdliner's phrasing. *)

open Cmdliner

type t = {
  mode : Types.mode;
  dump : Types.dump;
  no_launch : bool;
  reseed : bool;
  branch : string option;
  agent_args : string list option;  (* Some _ once `--` appeared, even if empty *)
  profiles : string list;           (* every -p, in the order given *)
  shell : bool option;
  yolo : bool option;
  paranoid : bool option;
  pasteboard : bool option;
  sandbox : bool option;
  here : bool option;
  seed_creds : bool option;
  latest : bool option;
  verbose : bool option;
  filter_egress : bool option;
  allow_loopback : bool option;
  nix : Types.nix_targets Layer.t;
  home : Types.home_sel Layer.t;
  agent : Types.agent Layer.t;
  seed_home : string Layer.t;
  accent : string Layer.t;
  token_cmd : string Layer.t;
  token_env : string Layer.t;
  aws_profile : string Layer.t;
  tmpdir : string Layer.t;
  setenv : (string * string) list;
  setenv_cmd : (string * string) list;
  seed_merge : (string * string) list;
  keep : string list;
  deny_read : string list;
  allow_write : string list;
  allow_socket : string list;
  allow_hosts : string list;
  allow_ports : int list;
  paranoid_deny_read : string list;
  paranoid_allow_read : string list;
}

(* --- argv pre-pass ----------------------------------------------------------

   Two shapes cmdliner cannot express, removed before it ever sees them:

   - `--` ends csb's own options; everything after is the agent's argv. cmdliner
     would fold those tokens into the BRANCH positional.
   - `-E=NAME` / `--ephemeral=NAME` gives one flag an optional value. Declaring
     it that way (~vopt) makes `-E feature/foo` swallow the BRANCH positional,
     which is a real invocation. Extracting the =NAME form here leaves a plain
     flag behind, so BRANCH survives. *)

let value_taking =
  [ "-N"; "--ns"; "--agent"; "--nix-target"; "--nix-target-shell";
    "--nix-target-agent";
    "--seed-home"; "--accent"; "--token-cmd"; "--token-env"; "--aws"; "--tmpdir"; "--setenv";
    "--setenv-cmd"; "--seed-merge";
    "-p"; "--profile"; "-k"; "--keep"; "--deny-read";
    "--allow-write"; "--allow-socket"; "--allow-host"; "--allow-port";
    "--paranoid-deny-read"; "--paranoid-allow-read" ]

let ephemeral_named tok =
  let take prefix =
    if String.starts_with ~prefix tok then
      let n = String.length prefix in
      Some (String.sub tok n (String.length tok - n))
    else None
  in
  match take "-E=" with Some v -> Some v | None -> take "--ephemeral="

type pre = {
  opts : string list;              (* what cmdliner parses *)
  rest : string list option;       (* the agent's argv, once `--` appeared *)
  eph_name : string option;
}

let prepass argv =
  let rec loop acc name = function
    | [] -> { opts = List.rev acc; rest = None; eph_name = name }
    | "--" :: rest -> { opts = List.rev acc; rest = Some rest; eph_name = name }
    (* An option's own value is never inspected: `--accent --` sets the accent. *)
    | tok :: value :: rest when List.mem tok value_taking ->
        loop (value :: tok :: acc) name rest
    | tok :: rest when ephemeral_named tok <> None ->
        let v = Option.get (ephemeral_named tok) in
        if v = "" then
          Err.die "-E=/--ephemeral= requires a NAME (use bare -E for a random throwaway)";
        loop acc (Some v) rest
    | tok :: rest -> loop (tok :: acc) name rest
  in
  loop [] None argv

(* --- option values ---------------------------------------------------------- *)

(* string option option: None when absent, Some None when named with no value. *)
let opt_str ?docs names ~docv ~doc =
  Arg.(value & opt ~vopt:(Some None) (some (some string)) None
       & info names ?docs ~docv ~doc)

let opt_str_all ?docs names ~docv ~doc =
  Arg.(value & opt_all ~vopt:None (some string) [] & info names ?docs ~docv ~doc)

let flag ?docs names ~doc = Arg.(value & flag_all & info names ?docs ~doc)

(* csb requires a non-empty value wherever it requires a value at all. *)
let need ~msg = function
  | None -> None
  | Some (Some v) when v <> "" -> Some v
  | Some None | Some (Some _) -> Err.die "%s" msg

let need_all ~msg vs =
  List.map (function Some v when v <> "" -> v | _ -> Err.die "%s" msg) vs

(* --keep accepts an empty value only to refuse it as a variable name. *)
let need_all_named ~msg vs =
  List.map (function Some v -> v | None -> Err.die "%s" msg) vs

let given occurrences = occurrences <> []

let pair ~pos ~neg pos_given neg_given =
  if pos_given && neg_given then Err.die "%s and %s are mutually exclusive" pos neg;
  if pos_given then Some true else if neg_given then Some false else None

let setting ~pos ~neg ~cleared value =
  match (value, cleared) with
  | Some v, false -> Layer.Set v
  | None, true -> Layer.Cleared
  | None, false -> Layer.Unset
  | Some _, true -> Err.die "%s and %s are mutually exclusive" pos neg

let mode ~delete ~list_ns ~list_wt ~reap =
  match List.filter (fun (g, _) -> g) [ (delete, Types.Delete); (list_ns, Types.List_ns);
                                        (list_wt, Types.List_wt); (reap, Types.Reap) ] with
  | [] -> Types.Launch
  | [ (_, m) ] -> m
  | _ ->
      Err.die "-d/--delete, -l/--list, --list-ns and --reap are mutually exclusive"

let dump ~config ~sandbox =
  match (config, sandbox) with
  | true, true -> Err.die "--dump-config and --dump-sandbox are mutually exclusive"
  | true, false -> Types.Dump_config
  | false, true -> Types.Dump_sandbox
  | false, false -> Types.No_dump

let branch_of = function
  | [] -> None
  | [ b ] -> Some b
  | _ :: extra :: _ -> Err.die "unexpected argument: %s" extra

(* The launch HOME is ONE axis with four answers, so the command line gives one
   field: three positive selectors, and --per-repo retracting whatever a lower
   layer chose. Two positives in one invocation is unresolvable rather than
   ranked -- the same rule Profile.seal applies to a file layer, stated once
   here instead of a second time in check_exclusive. *)
let home_of ~ns ~ephemeral ~eph_name ~real_home ~per_repo =
  if ns <> None && ephemeral then Err.die "--ns and -E/--ephemeral are mutually exclusive";
  if real_home && ns <> None then
    Err.die "--real-home and --ns are mutually exclusive (each selects the launch HOME)";
  if real_home && ephemeral then
    Err.die
      "--real-home and -E/--ephemeral are mutually exclusive (each selects the launch HOME)";
  let positive =
    match (ns, ephemeral, real_home) with
    | Some n, _, _ -> Some (Types.Sel_shared n)
    | _, true, _ ->
        Some
          (Types.Sel_throwaway
             (match eph_name with Some n -> Types.Named n | None -> Types.Anon))
    | _, _, true -> Some Types.Sel_real_home
    | _ -> None
  in
  match (positive, per_repo) with
  | Some _, true ->
      Err.die "--per-repo and an explicit HOME selector are mutually exclusive"
  | Some sel, false -> Layer.Set sel
  | None, true -> Layer.Cleared
  | None, false -> Layer.Unset

let nix_targets_of ~shared ~for_shell ~for_agent ~cleared =
  let any = shared <> None || for_shell <> None || for_agent <> None in
  if any && cleared then
    Err.die "--nix-target and --no-nix-target are mutually exclusive";
  if cleared then Layer.Cleared
  else if any then Layer.Set { Types.shared; for_shell; for_agent }
  else Layer.Unset

(* --- the term ---------------------------------------------------------------

   The options are grouped into their own manpage sections: cmdliner otherwise
   renders one alphabetical list, and csb's surface is large enough that the
   read/write knobs, the egress knobs and the HOME selectors read as unrelated
   flags rather than as three policies. *)

let s_home = "HOME SELECTION"
let s_policy = "SANDBOX POLICY"
let s_egress = "EGRESS FILTERING"
let s_seed = "SEEDING THE LAUNCH HOME"
let s_negate = "NEGATIONS"
let s_seams = "READ-ONLY SEAMS"

let term env pre =
  let open Term.Syntax in
  let path_all ~flag_name vs =
    List.map
      (Validate.list_path env ~where:flag_name)
      (need_all ~msg:(flag_name ^ " requires a PATH") vs)
  in
  let+ delete =
    flag [ "d"; "delete" ]
      ~doc:
        "Delete mode: run .worktreesetup.sh's sandboxed 'down' teardown, if any, \
         then remove BRANCH's worktree, keeping the branch. Only worktrees csb \
         created, under .worktrees/, are ever torn down or removed. The launch \
         HOME is NOT removed: it is per-repo, or a shared @-namespace, and not \
         tied to one branch. Retire a namespace deliberately with rm -rf."
  and+ list_wt =
    flag [ "l"; "list" ]
      ~doc:
        "List the worktrees csb created under .worktrees/, then exit. Works from \
         anywhere in the repository, linked worktrees included. Note the case: \
         -L is --latest, which launches."
  and+ list_ns =
    flag [ "list-ns" ]
      ~doc:
        "List the namespace configs under ~/.csb/agents: the per-repo-per-agent \
         defaults, repo-<key>-<agent>, and the shared @ ones. Flags any leftover \
         directories from the pre-0.3 per-branch layout."
  and+ reap =
    flag [ "reap" ]
      ~doc:
        "Reclaim what dead sessions left behind: kill orphaned egress proxies \
         (removing the allowlist file each was reading) and delete random \
         ephemeral HOMEs whose owning session is gone. A running session's \
         proxy and HOME are never matched, nor is a proxy kept in a terminal \
         by 'make proxy-run'; a HOME dir without an owner stamp is reported \
         but left alone. HOMEs are sought under the configured tmpdir (else \
         TMPDIR). Every launch runs the same pass quietly; this form reports."
  and+ no_launch =
    flag [ "n"; "no-launch" ]
      ~doc:
        "Prepare or reuse the worktree, including .worktreeinclude and \
         .worktreesetup.sh's sandboxed 'up', then exit printing the worktree path."
  and+ reseed =
    flag [ "reseed" ] ~docs:s_seed
      ~doc:
        "When seeding the launch HOME from the template, overwrite existing \
         files instead of keeping them."
  and+ dump_config =
    flag [ "dump-config" ] ~docs:s_seams
      ~doc:
        "Resolve flags, config sections, profile (and .local) and environment, \
         print the final KEY=VALUE knobs, and exit: no launch, no worktree \
         lookup, no token_cmd. config_sections reports which config sections \
         the repository selected. Never prints a secret -- token_cmd shows \
         present or absent, and setenv shows variable names only."
  and+ dump_sandbox =
    flag [ "dump-sandbox" ] ~docs:s_seams
      ~doc:
        "Resolve far enough to build the sandbox artifact, print it -- the \
         seatbelt profile text on macOS, the bubblewrap argv one token per line \
         on Linux -- and exit before any launch, seeding or token_cmd. Drive it \
         with --here in a git repository."
  and+ yolo =
    flag [ "y"; "yolo" ]
      ~doc:
        "Pass the agent's skip-every-prompt flag, allowing every tool call. \
         Which flag that is belongs to the agent (claude: \
         --dangerously-skip-permissions)."
  and+ no_yolo = flag [ "no-yolo"; "yodo" ] ~docs:s_negate ~doc:"Cancel a profile yolo=true."
  and+ paranoid =
    flag [ "paranoid" ] ~docs:s_policy
      ~doc:
        "Tighten reads: instead of allow-minus-deny-list, make the real HOME \
         read-DENY except the write-allow roots -- worktree, git dir, namespace \
         HOME, temp dir. The redirected HOME keeps tool caches working. \
         Re-expose read-only paths with --paranoid-allow-read; deny extra trees \
         with --paranoid-deny-read."
  and+ no_paranoid =
    flag [ "no-paranoid" ] ~docs:s_negate ~doc:"Cancel a profile paranoid=true."
  and+ pasteboard =
    flag [ "pasteboard" ] ~docs:s_policy
      ~doc:
        "macOS: re-allow pbcopy and pbpaste inside the sandbox. OFF by default, \
         because the pasteboard is a read channel around the whole file \
         deny-list: a secret copied from a password manager while an agent runs \
         is readable by it. A no-op on Linux and under --no-sandbox."
  and+ no_pasteboard =
    flag [ "no-pasteboard" ] ~docs:s_negate ~doc:"Cancel a profile pasteboard=true."
  and+ sandbox =
    flag [ "sandbox" ] ~docs:s_policy ~doc:"Keep the filesystem sandbox. This is the default."
  and+ no_sandbox =
    flag [ "no-sandbox" ] ~docs:s_policy
      ~doc:
        "Drop the filesystem sandbox -- the seatbelt or bubblewrap wrapper -- for \
         the launched process. SHELL ONLY: csb refuses to run an agent \
         unsandboxed. The environment scrub, devShell, HOME policy and --keep \
         still apply; only the read/write lockdown is gone, so the shell has \
         full host filesystem access. With it, --paranoid and the deny/allow \
         lists are inert."
  and+ real_home =
    flag [ "real-home" ] ~docs:s_home
      ~doc:
        "Use the operator's REAL HOME instead of a redirected one: no namespace, \
         no seeding, and the real HOME is NOT made writable. Pair it with \
         --no-sandbox for a shell whose ~/.ssh, ~/.kube and ~/.aws resolve, for \
         example a deployment."
  and+ per_repo =
    flag [ "per-repo" ] ~docs:s_home
      ~doc:
        "Select the default per-repo-per-agent HOME \
         ~/.csb/agents/repo-<key>-<agent>, retracting an ns=, ephemeral= or \
         real_home= chosen by any lower layer. The one negation for the whole \
         HOME axis, since the axis has one answer."
  and+ here =
    flag [ "here" ]
      ~doc:
        "No worktree: run in the current directory, for quick operations. \
         Mutually exclusive with BRANCH."
  and+ no_here =
    flag [ "no-here" ] ~docs:s_negate
      ~doc:"Cancel a profile here=true and the bare -p implication."
  and+ shell =
    flag [ "s"; "shell" ]
      ~doc:
        "Drop into an interactive bash -- or run the arguments after -- as a \
         command -- instead of the agent, in the exact environment the agent \
         would get: same worktree, devShell, environment scrub, HOME redirection \
         and deny-list."
  and+ no_shell = flag [ "no-shell" ] ~docs:s_negate ~doc:"Cancel a profile shell=true."
  and+ ephemeral =
    flag [ "E"; "ephemeral" ] ~docs:s_home
      ~doc:
        "Throwaway config and HOME, no namespace, not persisted. Bare, it is a \
         random throwaway HOME. As -E=NAME or --ephemeral=NAME it is a \
         deterministic throwaway HOME under the temp dir, csb-home-NAME, so a \
         sibling 'csb -s -E=NAME' in another pane attaches to the exact same \
         environment. Still ephemeral -- temp, OS-reaped, untracked by \
         --list-ns -- and not a namespace."
  and+ latest =
    flag [ "L"; "latest" ]
      ~doc:
        "Get the very latest claude: re-lock the claude-code flake input to its \
         upstream HEAD, bypassing the committed flake.lock. The upstream rev is \
         checked at most once per CSB_LATEST_TTL seconds, daily by default, and \
         cached, then pinned so the rest of the day is fully cached. Trades \
         reproducibility for always-newest. Specific to the claude-code flake; \
         every other agent tracks csb's own nixpkgs input."
  and+ no_latest =
    flag [ "no-latest" ] ~docs:s_negate ~doc:"Cancel a profile latest=true or CSB_LATEST."
  and+ verbose =
    flag [ "v"; "verbose" ]
      ~doc:
        "Restore csb's routine status narration and nix's own build output. \
         Launches are quiet by default; warnings and errors always print."
  and+ no_verbose =
    flag [ "no-verbose" ] ~docs:s_negate ~doc:"Cancel a profile verbose=true or CSB_VERBOSE."
  and+ seed_creds =
    flag [ "seed-creds" ] ~docs:s_seed
      ~doc:
        "Seed the HOST's native session credential for the agent -- the macOS \
         keychain, or the agent's own state dir elsewhere -- into the launch \
         HOME, so the sandbox presents your live subscription session instead of \
         a long-lived token. It shares the refresh-token family with the host \
         install."
  and+ no_seed_creds =
    flag [ "no-seed-creds" ] ~docs:s_negate ~doc:"Cancel a profile seed_creds=true."
  and+ filter_egress =
    flag [ "filter-egress" ] ~docs:s_egress
      ~doc:
        "Route the sandbox's HTTPS egress through csb-proxy and allow ONLY the \
         hosts named by --allow-host, a profile's allow_host=, or the \
         allowed-hosts config file. On macOS the sandbox profile enforces it: \
         the proxy's loopback port becomes the only reachable IP endpoint. On \
         Linux a pasta network namespace plus an nftables default-drop ruleset \
         does the same job, since bwrap itself has no socket filter. Either \
         way, a client that ignores HTTPS_PROXY reaches nothing. OFF by \
         default: filtering breaks WebFetch for any host not on the list."
  and+ no_filter_egress =
    flag [ "no-filter-egress" ] ~docs:s_negate ~doc:"Cancel a profile filter_egress=true."
  and+ allow_loopback =
    flag [ "allow-loopback" ] ~docs:s_egress
      ~doc:
        "Under --filter-egress, allow loopback TCP to ANY port instead of only \
         the proxy's and --allow-port's. A test runner that talks to a helper \
         process over 127.0.0.1 on a kernel-assigned port -- flutter test, a \
         dart VM service, a browser driver -- cannot name its port in advance, \
         and hangs without this. It also re-exposes every service listening on \
         the HOST's loopback, on both platforms, so prefer --allow-port when the \
         port is known."
  and+ no_allow_loopback =
    flag [ "no-allow-loopback" ] ~docs:s_negate ~doc:"Cancel a profile allow_loopback=true."
  and+ no_nix_target =
    flag [ "no-nix-target" ] ~docs:s_negate ~doc:"Cancel all three profile nix_target keys."
  and+ no_token_cmd =
    flag [ "no-token-cmd" ] ~docs:s_negate
      ~doc:"Cancel a configured token_cmd= and authenticate some other way."
  and+ no_token_env =
    flag [ "no-token-env" ] ~docs:s_negate
      ~doc:"Cancel a configured token_env= and use the agent's own variable."
  and+ no_agent =
    flag [ "no-agent" ] ~docs:s_negate
      ~doc:"Cancel a configured agent= and use the default, claude."
  and+ no_aws =
    flag [ "no-aws" ] ~docs:s_negate
      ~doc:"Cancel a configured aws_profile= and launch with no AWS credentials."
  and+ no_tmpdir =
    flag [ "no-tmpdir" ] ~docs:s_negate
      ~doc:"Cancel a configured tmpdir= and fall back to CSB_TMPDIR."
  and+ no_seed_home =
    flag [ "no-seed-home" ] ~docs:s_negate
      ~doc:"Cancel a profile seed_home= and use the default template."
  and+ no_accent = flag [ "no-accent" ] ~docs:s_negate ~doc:"Cancel a profile accent=, untinting."
  and+ nix_target =
    opt_str [ "nix-target" ] ~docv:"NAME"
      ~doc:
        "Which nix target to run under: devShells.<system>.NAME from the repo's \
         own flake, instead of the default one -- a leaner ci or release \
         closure, say. If the repo's flake has no such target the launch FAILS \
         rather than silently falling back: the generic fallback devShell only \
         ever provides default."
  and+ nix_target_shell =
    opt_str [ "nix-target-shell" ] ~docv:"NAME"
      ~doc:
        "As --nix-target, for -s/--shell runs only; it beats --nix-target when a \
         shell is the mode running. Whichever target wins also applies to \
         .worktreesetup.sh, which runs in the same devShell."
  and+ nix_target_agent =
    opt_str [ "nix-target-agent" ] ~docv:"NAME"
      ~doc:"As --nix-target, for agent runs only; it beats --nix-target for those runs."
  and+ agent =
    opt_str [ "agent" ] ~docv:"NAME"
      ~doc:
        "Which agent CLI to launch. csb supplies its binary from its own flake, \
         and the agent decides the credential variable, the yolo flag, the \
         onboarding seed and the egress allowlist file. Only 'claude' for now, \
         which is the default."
  and+ ns =
    opt_str [ "N"; "ns" ] ~docv:"NAME" ~docs:s_home
      ~doc:
        "Use a shared, cross-repo HOME at ~/.csb/agents/@NAME instead of the \
         per-repo-per-agent default. NAME and @NAME are equivalent; the @ is \
         added if you omit it. A shared namespace is NOT agent-suffixed -- \
         naming one is already a sharing decision, and '-N work-codex' is how \
         you keep them apart. Persistent, and never auto-removed by -d."
  and+ seed_home =
    opt_str [ "seed-home" ] ~docv:"DIR" ~docs:s_seed
      ~doc:
        "Seed the launch HOME, without overwriting, from template DIR: the \
         user-level files -- an agent's instructions file, settings, rules/ -- \
         that the in-sandbox agent should otherwise miss, since its real state \
         dir is denied and HOME is redirected. Defaults to ~/.config/csb/home."
  and+ token_cmd =
    opt_str [ "token-cmd" ] ~docv:"CMD"
      ~doc:
        "Run CMD on the host, outside the sandbox, and pass its first line into          the launch as the agent's credential variable (see --token-env) -- a          secrets-manager read such as 'op read op://vault/claude/token'. The          command is the configuration, never the token, so it is safe in a          config file; note that a value given here reaches ps(1) and the shell          history, which a config or profile key does not."
  and+ token_env =
    opt_str [ "token-env" ] ~docv:"VAR"
      ~doc:
        "The variable --token-cmd's output is exported into, and which the env \
         scrub keeps. Defaults to the agent's own (claude: \
         CLAUDE_CODE_OAUTH_TOKEN); name another to authenticate an agent through \
         a provider key instead."
  and+ aws =
    opt_str [ "aws" ] ~docv:"PROFILE" ~docs:s_seed
      ~doc:
        "Fetch SHORT-LIVED credentials for aws profile PROFILE on the host -- \
         'aws configure export-credentials', with an sso device-code login \
         fallback -- and inject them into the launched environment, in both \
         agent and shell modes. Credentials that do not expire are REFUSED: a \
         profile must resolve to a session (sso, assume-role, \
         credential_process), never to long-lived IAM user keys. The real \
         ~/.aws stays denied inside the sandbox, so the injected session is the \
         only AWS access the launch has, and it does NOT refresh -- re-launch \
         when it expires."
  and+ tmpdir =
    opt_str [ "tmpdir" ] ~docv:"DIR"
      ~doc:
        "Use DIR as the launch's TMPDIR, the base for an -E throwaway HOME, and a          write root. Must already exist. Overrides CSB_TMPDIR."
  and+ setenv =
    opt_str_all [ "setenv" ] ~docv:"VAR=VALUE" ~docs:s_seed
      ~doc:
        "Export VAR=VALUE in the launched environment, after the scrub, so it          survives regardless of --keep. Repeatable; the last layer to name a VAR          wins, and this is the highest layer."
  and+ setenv_cmd =
    opt_str_all [ "setenv-cmd" ] ~docv:"VAR=CMD" ~docs:s_seed
      ~doc:
        "Run CMD on the HOST, outside the sandbox, and export its output as VAR \
         in the launched environment -- --token-cmd generalized to any variable, \
         for a secrets-manager read such as 'op read op://vault/rag/token'. The \
         command is the configuration, never the value, so it is safe in a \
         config file. Failure or empty output aborts the launch before any \
         worktree or namespace side effect. Repeatable; a VAR may not also be \
         named by --setenv or --token-env."
  and+ seed_merge =
    opt_str_all [ "seed-merge" ] ~docv:"DEST=FILE" ~docs:s_seed
      ~doc:
        "Deep-merge the JSON in host FILE into DEST, relative to the launch \
         HOME, on EVERY launch -- so one edited file reaches every sandbox \
         without --reseed and without overwriting what the HOME accumulated. \
         The merged keys win. FILE may carry \\${CSB_WORKTREE} and \\${CSB_HOME}, \
         substituted per launch. Repeatable; applied after the agent's own \
         seed, so it can override that too."
  and+ accent =
    opt_str [ "accent" ] ~docv:"COLOR"
      ~doc:
        "Tint the statusline repo name so profiles are tellable at a glance, \
         personal versus work say. COLOR is a name -- black, red, green, yellow, \
         blue, magenta, cyan, white, gray/grey, or a bright-* variant -- or raw \
         ANSI SGR parameters such as 38;5;208."
  and+ profile =
    opt_str_all [ "p"; "profile" ] ~docv:"NAME"
      ~doc:
        "Load launch defaults from ~/.config/csb/profiles/NAME, or from a \
         [profile NAME] block in the config file -- one or the other, never \
         both. A gitignored NAME.local is layered on top for host-specific \
         values, and its values win; explicit CLI flags beat both, and both beat \
         the config sections. Repeatable: each -p is its own layer, folded left \
         to right, so the last one to answer a scalar wins and their lists \
         union. Like any launch naming no BRANCH, 'csb -p NAME' runs --here. See \
         the CONFIGURATION section for the keys."
  and+ keep =
    opt_str_all [ "k"; "keep" ] ~docv:"VAR"
      ~doc:"Also keep environment variable VAR across the scrub. Repeatable."
  and+ deny_read =
    opt_str_all [ "deny-read" ] ~docv:"PATH" ~docs:s_policy
      ~doc:
        "Also read-DENY PATH, in both modes, adding to the built-in floor. \
         Repeatable."
  and+ allow_write =
    opt_str_all [ "allow-write" ] ~docv:"PATH" ~docs:s_policy
      ~doc:
        "Also make PATH writable, and thus readable under --paranoid, in both \
         modes. Repeatable."
  and+ allow_socket =
    opt_str_all [ "allow-socket" ] ~docv:"PATH" ~docs:s_policy
      ~doc:
        "Also allow connecting to the unix socket at PATH; a directory allows \
         the sockets under it. For a dev service the sandbox must reach over a \
         socket rather than TCP, for example /tmp/.s.PGSQL.5432 for postgres. \
         macOS only -- a no-op on Linux, where such sockets are already \
         reachable. Refused for the IPC broker paths csb closes, and for a whole \
         shared write root like /tmp. Repeatable."
  and+ allow_host =
    opt_str_all [ "allow-host" ] ~docv:"HOST" ~docs:s_egress
      ~doc:
        "Under --filter-egress, allow egress to HOST. A leading '*.' matches \
         subdomains only, so list a bare parent domain separately when you want \
         both. Repeatable; accumulates with the config file and a profile's \
         allow_host=."
  and+ allow_port =
    opt_str_all [ "allow-port" ] ~docv:"PORT" ~docs:s_egress
      ~doc:
        "Under --filter-egress, also allow host-local TCP to localhost:PORT -- a \
         dev server, or postgres over TCP -- traffic the CONNECT proxy cannot \
         carry. Repeatable."
  and+ paranoid_deny_read =
    opt_str_all [ "paranoid-deny-read" ] ~docv:"PATH" ~docs:s_policy
      ~doc:
        "Under --paranoid only, additionally read-deny PATH, for example a tree \
         outside HOME like /Volumes. Repeatable."
  and+ paranoid_allow_read =
    opt_str_all [ "paranoid-allow-read" ] ~docv:"PATH" ~docs:s_policy
      ~doc:
        "Under --paranoid only, re-expose PATH read-only WITHOUT granting write. \
         Rejected if it overlaps a deny. Repeatable."
  and+ positional = Arg.(value & pos_all string [] & info [] ~docv:"BRANCH") in
  {
    mode =
      mode ~delete:(given delete) ~list_ns:(given list_ns) ~list_wt:(given list_wt)
        ~reap:(given reap);
    dump = dump ~config:(given dump_config) ~sandbox:(given dump_sandbox);
    no_launch = given no_launch;
    reseed = given reseed;
    branch = branch_of positional;
    agent_args = pre.rest;
    profiles =
      List.map
        (Validate.profile_name ~where:"--profile")
        (need_all ~msg:"--profile requires a non-empty NAME" profile);
    shell = pair ~pos:"-s/--shell" ~neg:"--no-shell" (given shell) (given no_shell);
    yolo = pair ~pos:"-y/--yolo" ~neg:"--no-yolo" (given yolo) (given no_yolo);
    paranoid =
      pair ~pos:"--paranoid" ~neg:"--no-paranoid" (given paranoid) (given no_paranoid);
    pasteboard =
      pair ~pos:"--pasteboard" ~neg:"--no-pasteboard" (given pasteboard)
        (given no_pasteboard);
    sandbox = pair ~pos:"--sandbox" ~neg:"--no-sandbox" (given sandbox) (given no_sandbox);
    here = pair ~pos:"--here" ~neg:"--no-here" (given here) (given no_here);
    seed_creds =
      pair ~pos:"--seed-creds" ~neg:"--no-seed-creds" (given seed_creds)
        (given no_seed_creds);
    latest = pair ~pos:"-L/--latest" ~neg:"--no-latest" (given latest) (given no_latest);
    verbose = pair ~pos:"-v/--verbose" ~neg:"--no-verbose" (given verbose) (given no_verbose);
    filter_egress =
      pair ~pos:"--filter-egress" ~neg:"--no-filter-egress" (given filter_egress)
        (given no_filter_egress);
    allow_loopback =
      pair ~pos:"--allow-loopback" ~neg:"--no-allow-loopback" (given allow_loopback)
        (given no_allow_loopback);
    nix =
      nix_targets_of
        ~shared:
          (Option.map (Validate.nix_target ~where:"--nix-target")
             (need ~msg:"--nix-target requires a NAME" nix_target))
        ~for_shell:
          (Option.map (Validate.nix_target ~where:"--nix-target-shell")
             (need ~msg:"--nix-target-shell requires a NAME" nix_target_shell))
        ~for_agent:
          (Option.map (Validate.nix_target ~where:"--nix-target-agent")
             (need ~msg:"--nix-target-agent requires a NAME" nix_target_agent))
        ~cleared:(given no_nix_target);
    agent =
      Layer.map
        (Agent.of_string ~where:"--agent")
        (setting ~pos:"--agent" ~neg:"--no-agent" ~cleared:(given no_agent)
           (need ~msg:"--agent requires a NAME (--no-agent resets to claude)" agent));
    home =
      home_of
        ~ns:
          (need ~msg:"--ns requires a non-empty NAME (--per-repo resets to the default)" ns)
        ~ephemeral:(given ephemeral || pre.eph_name <> None) ~eph_name:pre.eph_name
        ~real_home:(given real_home)
        ~per_repo:(given per_repo);
    seed_home =
      setting ~pos:"--seed-home" ~neg:"--no-seed-home" ~cleared:(given no_seed_home)
        (need
           ~msg:
             "--seed-home requires a non-empty DIR (--no-seed-home resets to the \
              default template)"
           seed_home);
    accent =
      setting ~pos:"--accent" ~neg:"--no-accent" ~cleared:(given no_accent)
        (need ~msg:"--accent requires a COLOR (--no-accent untints)" accent);
    token_cmd =
      setting ~pos:"--token-cmd" ~neg:"--no-token-cmd" ~cleared:(given no_token_cmd)
        (need
           ~msg:"--token-cmd requires a CMD (--no-token-cmd cancels a configured one)"
           token_cmd);
    token_env =
      Layer.map
        (Validate.keep_var ~msg:"invalid env var name for --token-env")
        (setting ~pos:"--token-env" ~neg:"--no-token-env" ~cleared:(given no_token_env)
           (need
              ~msg:"--token-env requires a VAR (--no-token-env uses the agent's own)"
              token_env));
    aws_profile =
      Layer.map
        (Validate.aws_profile ~where:"--aws")
        (setting ~pos:"--aws" ~neg:"--no-aws" ~cleared:(given no_aws)
           (need ~msg:"--aws requires a PROFILE (--no-aws cancels a configured one)" aws));
    tmpdir =
      setting ~pos:"--tmpdir" ~neg:"--no-tmpdir" ~cleared:(given no_tmpdir)
        (need ~msg:"--tmpdir requires a DIR (--no-tmpdir falls back to CSB_TMPDIR)"
           tmpdir);
    setenv =
      List.map (Validate.setenv ~where:"--setenv")
        (need_all ~msg:"--setenv requires VAR=VALUE" setenv);
    setenv_cmd =
      List.map (Validate.setenv_cmd ~where:"--setenv-cmd")
        (need_all ~msg:"--setenv-cmd requires VAR=CMD" setenv_cmd);
    seed_merge =
      List.map (Validate.seed_merge env ~where:"--seed-merge")
        (need_all ~msg:"--seed-merge requires DEST=FILE" seed_merge);
    keep =
      List.map
        (Validate.keep_var ~msg:"invalid env var name for --keep")
        (need_all_named ~msg:"--keep requires a VAR name" keep);
    deny_read = path_all ~flag_name:"--deny-read" deny_read;
    allow_write = path_all ~flag_name:"--allow-write" allow_write;
    allow_socket = path_all ~flag_name:"--allow-socket" allow_socket;
    allow_hosts =
      List.map (Validate.host ~where:"--allow-host")
        (need_all ~msg:"--allow-host requires a HOST" allow_host);
    allow_ports =
      List.map (Validate.port ~where:"--allow-port")
        (need_all ~msg:"--allow-port requires a PORT" allow_port);
    paranoid_deny_read = path_all ~flag_name:"--paranoid-deny-read" paranoid_deny_read;
    paranoid_allow_read = path_all ~flag_name:"--paranoid-allow-read" paranoid_allow_read;
  }

(* --- evaluation -------------------------------------------------------------

   cmdliner renders its own diagnostics with SGR escapes and a UTF-8 ellipsis,
   and decides that at module initialization from NO_COLOR/TERM -- before this
   program runs, so the environment cannot be corrected from here. A non-tty
   stderr gets the plain-text form instead: callers match on the message. *)

let plain s =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '\x1b' && !i + 1 < n && s.[!i + 1] = '[' then (
      i := !i + 2;
      while !i < n && s.[!i] <> 'm' do incr i done;
      incr i)
    else if !i + 2 < n && String.sub s !i 3 = "\xe2\x80\xa6" then (
      Buffer.add_string buf "...";
      i := !i + 3)
    else (
      Buffer.add_char buf s.[!i];
      incr i)
  done;
  Buffer.contents buf

let eval ~info ~argv term =
  let buf = Buffer.create 256 in
  let err = Format.formatter_of_buffer buf in
  let result = Cmd.eval_value ~err ~catch:false ~argv (Cmd.v info term) in
  Format.pp_print_flush err ();
  let msg = Buffer.contents buf in
  if msg <> "" then
    prerr_string (if Unix.isatty Unix.stderr then msg else plain msg);
  result

(* csb's CLI-level exclusions, checked in bin/csb's order: all four fire before
   any profile is read. *)
let check_exclusive c =
  if c.here = Some true && c.branch <> None then
    Err.die
      "--here and BRANCH are mutually exclusive (either provision a worktree for \
       BRANCH, or run --here)";
  if c.mode = Types.List_wt && c.branch <> None then
    Err.die "-l/--list takes no BRANCH argument";
  if c.mode = Types.List_wt && c.here = Some true then
    Err.die "-l/--list and --here are mutually exclusive (one lists, one launches)";
  ()
