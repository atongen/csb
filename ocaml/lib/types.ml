(* Resolved csb configuration.

   The variants exist so combinations bin/csb rejects at runtime cannot be built
   at all: one target, one runner, one HOME. Dump projects them back onto the
   flat keys bin/csb prints. *)

type mode =
  | Launch
  | Delete
  | List_ns
  | Reap

(* Neither BRANCH nor --here is a real third state -- the worktree listing. bash
   spells it as two empty variables. *)
type target =
  | List_worktrees
  | Here
  | Branch of string

type runner =
  | Agent
  | Shell

(* Which agent CLI a launch runs. One variant per adapter row in Agent; every
   place csb has to know the answer reads that table, so nothing else branches. *)
type agent =
  | Claude

(* One seed step, deferred to bin/csb because it needs facts csb-config does not
   have: the resolved worktree path, the launch HOME, the macOS keychain. `arg`
   is the source -- a host path, a keychain service name, or file content --
   and `dest` is relative to the launch HOME. Content carries ${CSB_WORKTREE}
   and ${CSB_HOME} placeholders bin/csb substitutes. *)
type seed_verb =
  | Copy        (* host file -> dest, 0600 *)
  | Keychain    (* macOS `security -w <service>` -> dest, 0600 *)
  | File        (* content -> dest, write-if-absent (--reseed overwrites) *)
  | Json_merge  (* content deep-merged into dest, the content winning *)

type seed = {
  verb : seed_verb;
  arg : string;
  dest : string;
}

type throwaway =
  | Anon            (* bare -E *)
  | Named of string (* -E=NAME *)

(* -N / -E / --real-home are the three mutually exclusive answers to "which HOME";
   Per_repo is the default fourth. *)
type home =
  | Per_repo
  | Shared of string (* --ns NAME, verbatim: @-normalization happens later *)
  | Throwaway of throwaway
  | Real_home

(* What a layer may SELECT, which is the same set minus the default: Per_repo is
   what remains when no layer selected anything, so a layer that "chose Per_repo"
   is not a state worth being able to write down. *)
type home_sel =
  | Sel_shared of string
  | Sel_throwaway of throwaway
  | Sel_real_home

let home_of_sel = function
  | Sel_shared n -> Shared n
  | Sel_throwaway t -> Throwaway t
  | Sel_real_home -> Real_home

(* The two read-only seams. Config is answered by csb-config itself; sandbox
   needs the profile generator, which lives in bin/csb, so it travels onward. *)
type dump =
  | No_dump
  | Dump_config
  | Dump_sandbox

type nix_targets = {
  shared : string option;     (* --nix-target *)
  for_shell : string option;  (* --nix-target-shell *)
  for_agent : string option;  (* --nix-target-agent *)
}

type t = {
  mode : mode;
  dump : dump;
  no_launch : bool;
  target : target;
  runner : runner;
  agent : agent;
  home : home;
  paranoid : bool;
  pasteboard : bool;
  sandbox : bool;
  yolo : bool;
  latest : bool;
  verbose : bool;
  reseed : bool;
  seed_creds : bool;
  nix_targets : nix_targets;
  profile : string option;
  token_cmd : string option;
  (* The variable token_cmd's output is exported into, and which joins the
     scrub's keep list. Always answered: the agent's default when no layer
     names one. *)
  token_env : string;
  seed_home : string option;
  accent : string option;
  cfg_tmpdir : string option;
  tmp_base : string;  (* the resolved base every launch temp path sits under *)
  agent_args : string list;
  keep : string list;
  setenv : (string * string) list;
  deny_read : string list;
  allow_write : string list;
  allow_socket : string list;
  filter_egress : bool;
  allow_loopback : bool;
  allow_hosts : string list;
  allow_ports : int list;
  paranoid_deny_read : string list;
  paranoid_allow_read : string list;
  (* The launch HOME's onboarding seed, then the --seed-creds sources: two
     lists because bin/csb gates them differently -- onboarding runs on every
     redirected-HOME launch, credentials only in the --seed-creds arm. *)
  seed : seed list;
  cred_seed : seed list;
  (* Which config sections were selected, in application order: provenance for
     the layer above, reported by --dump-config and by nothing else. *)
  config_sections : string list;
}

let no_nix_targets = { shared = None; for_shell = None; for_agent = None }

(* --nix-target-{shell,agent} beat --nix-target for whichever mode runs; the
   flake's own `default` is the floor. Mirrors effective_nix_target in bin/csb. *)
let effective_nix_target c =
  let per_mode =
    match c.runner with
    | Shell -> c.nix_targets.for_shell
    | Agent -> c.nix_targets.for_agent
  in
  match per_mode with
  | Some s -> s
  | None -> ( match c.nix_targets.shared with Some s -> s | None -> "default")

