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
let opt_str names ~docv ~doc =
  Arg.(value & opt ~vopt:(Some None) (some (some string)) None
       & info names ~docv ~doc)

let opt_str_all names ~docv ~doc =
  Arg.(value & opt_all ~vopt:None (some string) [] & info names ~docv ~doc)

let flag names ~doc = Arg.(value & flag_all & info names ~doc)

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

(* --- the term --------------------------------------------------------------- *)

let term env pre =
  let open Term.Syntax in
  let path_all ~flag_name vs =
    List.map
      (Validate.list_path env ~where:flag_name)
      (need_all ~msg:(flag_name ^ " requires a PATH") vs)
  in
  let+ delete = flag [ "d"; "delete" ] ~doc:"Delete the worktree and namespace for BRANCH."
  and+ list_ns = flag [ "list-ns" ] ~doc:"List the namespaces under ~/.csb/claudes."
  and+ no_launch = flag [ "n"; "no-launch" ] ~doc:"Prepare the worktree and HOME, then stop."
  and+ reseed = flag [ "reseed" ] ~doc:"Overwrite existing files when seeding the launch HOME."
  and+ _dump = flag [ "dump-config" ] ~doc:"Print the resolved config. csb-config does nothing else."
  and+ yolo = flag [ "y"; "yolo" ] ~doc:"Pass --dangerously-skip-permissions to claude."
  and+ no_yolo = flag [ "no-yolo"; "yodo" ] ~doc:"Cancel a profile yolo=true."
  and+ paranoid = flag [ "paranoid" ] ~doc:"Deny reads outside the worktree and the launch HOME."
  and+ no_paranoid = flag [ "no-paranoid" ] ~doc:"Cancel a profile paranoid=true."
  and+ pasteboard = flag [ "pasteboard" ] ~doc:"Re-allow pbcopy/pbpaste (macOS)."
  and+ no_pasteboard = flag [ "no-pasteboard" ] ~doc:"Cancel a profile pasteboard=true."
  and+ sandbox = flag [ "sandbox" ] ~doc:"Keep the filesystem sandbox (the default)."
  and+ no_sandbox = flag [ "no-sandbox" ] ~doc:"Drop the filesystem sandbox. Shell only."
  and+ real_home = flag [ "real-home" ] ~doc:"Launch with the real HOME, unredirected."
  and+ no_real_home = flag [ "no-real-home" ] ~doc:"Cancel a profile real_home=true."
  and+ here = flag [ "here" ] ~doc:"Run in the current checkout instead of a worktree."
  and+ no_here = flag [ "no-here" ] ~doc:"Cancel a profile here=true and the bare -p implication."
  and+ shell = flag [ "s"; "shell" ] ~doc:"Run a shell instead of claude."
  and+ no_shell = flag [ "no-shell" ] ~doc:"Cancel a profile shell=true."
  and+ ephemeral =
    flag [ "E"; "ephemeral" ] ~doc:"Use a throwaway HOME under the temp dir. -E=NAME reuses one."
  and+ no_ephemeral = flag [ "no-ephemeral" ] ~doc:"Cancel a profile ephemeral=true."
  and+ latest = flag [ "L"; "latest" ] ~doc:"Build claude from its latest upstream rev."
  and+ no_latest = flag [ "no-latest" ] ~doc:"Cancel a profile latest=true or CSB_LATEST."
  and+ verbose = flag [ "v"; "verbose" ] ~doc:"Report what csb is doing."
  and+ no_verbose = flag [ "no-verbose" ] ~doc:"Cancel a profile verbose=true or CSB_VERBOSE."
  and+ seed_creds = flag [ "seed-creds" ] ~doc:"Seed the host claude session credential."
  and+ no_seed_creds = flag [ "no-seed-creds" ] ~doc:"Cancel a profile seed_creds=true."
  and+ filter_egress =
    flag [ "filter-egress" ] ~doc:"Route egress through csb-proxy and allow only --allow-host."
  and+ no_filter_egress = flag [ "no-filter-egress" ] ~doc:"Cancel a profile filter_egress=true."
  and+ no_nix_target = flag [ "no-nix-target" ] ~doc:"Cancel every profile nix_target key."
  and+ no_ns = flag [ "no-ns" ] ~doc:"Cancel a profile ns= and use the branch default."
  and+ no_seed_home = flag [ "no-seed-home" ] ~doc:"Cancel a profile seed_home= and use the template."
  and+ no_accent = flag [ "no-accent" ] ~doc:"Cancel a profile accent=."
  and+ nix_target =
    opt_str [ "nix-target" ] ~docv:"NAME" ~doc:"devShells.<system>.NAME to run under."
  and+ nix_target_shell =
    opt_str [ "nix-target-shell" ] ~docv:"NAME" ~doc:"As --nix-target, for -s/--shell runs only."
  and+ nix_target_claude =
    opt_str [ "nix-target-claude" ] ~docv:"NAME" ~doc:"As --nix-target, for claude runs only."
  and+ ns = opt_str [ "N"; "ns" ] ~docv:"NAME" ~doc:"Share the HOME namespace @NAME across repos."
  and+ seed_home = opt_str [ "seed-home" ] ~docv:"DIR" ~doc:"Seed the launch HOME from DIR."
  and+ accent = opt_str [ "accent" ] ~docv:"COLOR" ~doc:"Tint the statusline."
  and+ profile = opt_str [ "p"; "profile" ] ~docv:"NAME" ~doc:"Apply profile NAME as defaults."
  and+ keep = opt_str_all [ "k"; "keep" ] ~docv:"VAR" ~doc:"Keep VAR through the env scrub."
  and+ deny_read = opt_str_all [ "deny-read" ] ~docv:"PATH" ~doc:"Deny reads under PATH."
  and+ allow_write = opt_str_all [ "allow-write" ] ~docv:"PATH" ~doc:"Allow writes under PATH."
  and+ allow_socket =
    opt_str_all [ "allow-socket" ] ~docv:"PATH" ~doc:"Allow connecting to the unix socket PATH."
  and+ allow_host =
    opt_str_all [ "allow-host" ] ~docv:"HOST" ~doc:"Allow egress to HOST or *.SUFFIX."
  and+ allow_port =
    opt_str_all [ "allow-port" ] ~docv:"PORT" ~doc:"Allow egress to the host-local TCP PORT."
  and+ paranoid_deny_read =
    opt_str_all [ "paranoid-deny-read" ] ~docv:"PATH" ~doc:"Extra --paranoid read deny."
  and+ paranoid_allow_read =
    opt_str_all [ "paranoid-allow-read" ] ~docv:"PATH" ~doc:"Re-allow PATH under --paranoid."
  and+ positional = Arg.(value & pos_all string [] & info [] ~docv:"BRANCH") in
  let ephemeral =
    pair ~pos:"-E/--ephemeral" ~neg:"--no-ephemeral"
      (given ephemeral || pre.eph_name <> None)
      (given no_ephemeral)
  in
  {
    mode = mode ~delete:(given delete) ~list_ns:(given list_ns);
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
