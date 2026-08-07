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

(* A valued option that --no-<opt> also resets. *)
type 'a setting = Untouched | Cleared | Set of 'a

(* The three nix-target keys share one --no-nix-target, so they resolve against
   a profile as a set rather than individually. *)
type nix_targets = Nt_untouched | Nt_cleared | Nt_set of Types.nix_targets

type t = {
  mode : Types.mode;
  dump : Types.dump;
  no_launch : bool;
  reseed : bool;
  branch : string option;
  claude_args : string list option;  (* Some _ once `--` appeared, even if empty *)
  profile : string option;
  shell : bool option;
  yolo : bool option;
  paranoid : bool option;
  pasteboard : bool option;
  sandbox : bool option;
  real_home : bool option;
  here : bool option;
  ephemeral : bool option;
  ephemeral_name : string option;
  seed_creds : bool option;
  latest : bool option;
  verbose : bool option;
  filter_egress : bool option;
  nix_targets : nix_targets;
  ns : string setting;
  seed_home : string setting;
  accent : string setting;
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

   - `--` ends csb's own options; everything after is claude's argv. cmdliner
     would fold those tokens into the BRANCH positional.
   - `-E=NAME` / `--ephemeral=NAME` gives one flag an optional value. Declaring
     it that way (~vopt) makes `-E feature/foo` swallow the BRANCH positional,
     which is a real invocation. Extracting the =NAME form here leaves a plain
     flag behind, so BRANCH survives. *)

let value_taking =
  [ "-N"; "--ns"; "--nix-target"; "--nix-target-shell"; "--nix-target-claude";
    "--seed-home"; "--accent"; "-p"; "--profile"; "-k"; "--keep"; "--deny-read";
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
  rest : string list option;       (* claude's argv, once `--` appeared *)
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
  | Some v, false -> Set v
  | None, true -> Cleared
  | None, false -> Untouched
  | Some _, true -> Err.die "%s and %s are mutually exclusive" pos neg

let mode ~delete ~list_ns =
  match (delete, list_ns) with
  | true, true -> Err.die "-d/--delete and --list-ns are mutually exclusive"
  | true, false -> Types.Delete
  | false, true -> Types.List_ns
  | false, false -> Types.Launch

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

let nix_targets_of ~shared ~for_shell ~for_claude ~cleared =
  let any = shared <> None || for_shell <> None || for_claude <> None in
  if any && cleared then
    Err.die "--nix-target and --no-nix-target are mutually exclusive";
  if cleared then Nt_cleared
  else if any then Nt_set { Types.shared; for_shell; for_claude }
  else Nt_untouched

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
  and+ list_ns =
    flag [ "list-ns" ]
      ~doc:
        "List the namespace configs under ~/.csb/claudes: the per-repo default, \
         repo-<key>, and the shared @ ones. Flags any leftover directories from \
         the pre-0.3 per-branch layout."
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
        "Resolve flags, profile (and .local) and environment, print the final \
         KEY=VALUE knobs, and exit: no launch, no repository lookup, no \
         token_cmd. Never prints a secret -- token_cmd shows present or absent, \
         and setenv shows variable names only."
  and+ dump_sandbox =
    flag [ "dump-sandbox" ] ~docs:s_seams
      ~doc:
        "Resolve far enough to build the sandbox artifact, print it -- the \
         seatbelt profile text on macOS, the bubblewrap argv one token per line \
         on Linux -- and exit before any launch, seeding or token_cmd. Drive it \
         with --here in a git repository."
  and+ yolo =
    flag [ "y"; "yolo" ]
      ~doc:"Pass --dangerously-skip-permissions to claude, allowing every tool call."
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
         the launched process. SHELL ONLY: csb refuses to run claude \
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
  and+ no_real_home =
    flag [ "no-real-home" ] ~docs:s_negate ~doc:"Cancel a profile real_home=true."
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
         command -- instead of claude, in the exact environment claude would \
         get: same worktree, devShell, environment scrub, HOME redirection and \
         deny-list."
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
  and+ no_ephemeral =
    flag [ "no-ephemeral" ] ~docs:s_negate ~doc:"Cancel a profile ephemeral=true."
  and+ latest =
    flag [ "L"; "latest" ]
      ~doc:
        "Get the very latest claude: re-lock the claude-code flake input to its \
         upstream HEAD, bypassing the committed flake.lock. The upstream rev is \
         checked at most once per CSB_LATEST_TTL seconds, daily by default, and \
         cached, then pinned so the rest of the day is fully cached. Trades \
         reproducibility for always-newest."
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
        "Seed the HOST's native claude session credential -- macOS keychain, or \
         ~/.claude on Linux -- into the launch config, so the sandbox presents \
         your live subscription session instead of a long-lived token. It shares \
         the refresh-token family with native claude."
  and+ no_seed_creds =
    flag [ "no-seed-creds" ] ~docs:s_negate ~doc:"Cancel a profile seed_creds=true."
  and+ filter_egress =
    flag [ "filter-egress" ] ~docs:s_egress
      ~doc:
        "Route the sandbox's HTTPS egress through csb-proxy and allow ONLY the \
         hosts named by --allow-host, a profile's allow_host=, or the \
         allowed-hosts config file. The sandbox profile is what enforces it: the \
         proxy's loopback port becomes the only reachable IP endpoint, so a \
         client that ignores HTTPS_PROXY reaches nothing. macOS only for now -- \
         a warning and no filtering on Linux, which needs a network namespace. \
         OFF by default: filtering breaks WebFetch for any host not on the list."
  and+ no_filter_egress =
    flag [ "no-filter-egress" ] ~docs:s_negate ~doc:"Cancel a profile filter_egress=true."
  and+ no_nix_target =
    flag [ "no-nix-target" ] ~docs:s_negate ~doc:"Cancel all three profile nix_target keys."
  and+ no_ns =
    flag [ "no-ns" ] ~docs:s_negate ~doc:"Cancel a profile ns= and use the branch default."
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
  and+ nix_target_claude =
    opt_str [ "nix-target-claude" ] ~docv:"NAME"
      ~doc:"As --nix-target, for claude runs only; it beats --nix-target for those runs."
  and+ ns =
    opt_str [ "N"; "ns" ] ~docv:"NAME" ~docs:s_home
      ~doc:
        "Use a shared, cross-repo HOME at ~/.csb/claudes/@NAME instead of the \
         per-repo default. NAME and @NAME are equivalent; the @ is added if you \
         omit it. Persistent, and never auto-removed by -d."
  and+ seed_home =
    opt_str [ "seed-home" ] ~docv:"DIR" ~docs:s_seed
      ~doc:
        "Seed the launch HOME, without overwriting, from template DIR: the \
         user-level files -- CLAUDE.md, settings.json, rules/ -- that \
         in-sandbox claude should otherwise miss, since the real ~/.claude is \
         denied and HOME is redirected. Defaults to ~/.config/csb/home."
  and+ accent =
    opt_str [ "accent" ] ~docv:"COLOR"
      ~doc:
        "Tint the statusline repo name so profiles are tellable at a glance, \
         personal versus work say. COLOR is a name -- black, red, green, yellow, \
         blue, magenta, cyan, white, gray/grey, or a bright-* variant -- or raw \
         ANSI SGR parameters such as 38;5;208."
  and+ profile =
    opt_str [ "p"; "profile" ] ~docv:"NAME"
      ~doc:
        "Load launch defaults from ~/.config/csb/profiles/NAME. A gitignored \
         NAME.local is layered on top for host-specific values, and its values \
         win; explicit CLI flags beat both. Bare 'csb -p NAME' with no BRANCH \
         launches --here, while plain 'csb' still lists worktrees. See the \
         PROFILES section for the keys."
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
  let ephemeral =
    pair ~pos:"-E/--ephemeral" ~neg:"--no-ephemeral"
      (given ephemeral || pre.eph_name <> None)
      (given no_ephemeral)
  in
  {
    mode = mode ~delete:(given delete) ~list_ns:(given list_ns);
    dump = dump ~config:(given dump_config) ~sandbox:(given dump_sandbox);
    no_launch = given no_launch;
    reseed = given reseed;
    branch = branch_of positional;
    claude_args = pre.rest;
    profile = need ~msg:"--profile requires a non-empty NAME" profile;
    shell = pair ~pos:"-s/--shell" ~neg:"--no-shell" (given shell) (given no_shell);
    yolo = pair ~pos:"-y/--yolo" ~neg:"--no-yolo" (given yolo) (given no_yolo);
    paranoid =
      pair ~pos:"--paranoid" ~neg:"--no-paranoid" (given paranoid) (given no_paranoid);
    pasteboard =
      pair ~pos:"--pasteboard" ~neg:"--no-pasteboard" (given pasteboard)
        (given no_pasteboard);
    sandbox = pair ~pos:"--sandbox" ~neg:"--no-sandbox" (given sandbox) (given no_sandbox);
    real_home =
      pair ~pos:"--real-home" ~neg:"--no-real-home" (given real_home) (given no_real_home);
    here = pair ~pos:"--here" ~neg:"--no-here" (given here) (given no_here);
    ephemeral;
    ephemeral_name = (if ephemeral = Some true then pre.eph_name else None);
    seed_creds =
      pair ~pos:"--seed-creds" ~neg:"--no-seed-creds" (given seed_creds)
        (given no_seed_creds);
    latest = pair ~pos:"-L/--latest" ~neg:"--no-latest" (given latest) (given no_latest);
    verbose = pair ~pos:"-v/--verbose" ~neg:"--no-verbose" (given verbose) (given no_verbose);
    filter_egress =
      pair ~pos:"--filter-egress" ~neg:"--no-filter-egress" (given filter_egress)
        (given no_filter_egress);
    nix_targets =
      nix_targets_of
        ~shared:
          (Option.map (Validate.nix_target ~where:"--nix-target")
             (need ~msg:"--nix-target requires a NAME" nix_target))
        ~for_shell:
          (Option.map (Validate.nix_target ~where:"--nix-target-shell")
             (need ~msg:"--nix-target-shell requires a NAME" nix_target_shell))
        ~for_claude:
          (Option.map (Validate.nix_target ~where:"--nix-target-claude")
             (need ~msg:"--nix-target-claude requires a NAME" nix_target_claude))
        ~cleared:(given no_nix_target);
    ns =
      setting ~pos:"-N/--ns" ~neg:"--no-ns" ~cleared:(given no_ns)
        (need
           ~msg:"--ns requires a non-empty NAME (--no-ns resets to the branch default)"
           ns);
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
  let ns_set = match c.ns with Set _ -> true | Untouched | Cleared -> false in
  if ns_set && c.ephemeral = Some true then
    Err.die "--ns and -E/--ephemeral are mutually exclusive";
  if c.real_home = Some true && ns_set then
    Err.die "--real-home and --ns are mutually exclusive (each selects the launch HOME)";
  if c.real_home = Some true && c.ephemeral = Some true then
    Err.die "--real-home and -E/--ephemeral are mutually exclusive (each selects the launch HOME)"
