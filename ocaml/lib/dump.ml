(* The --dump-config wire format: the exact keys, order and value spellings of
   bin/csb's dump block. Never prints a secret -- token_cmd reports
   present/absent, and setenv and setenv_cmd report VAR names only. *)

open Types

let opt = function Some v -> v | None -> ""
let joined xs = String.concat "|" xs

let mode_name = function
  | Launch -> "launch"
  | Delete -> "delete"
  | List_ns -> "list_ns"
  | List_wt -> "list_wt"
  | Reap -> "reap"

let is_here = function Here -> true | List_worktrees | Branch _ -> false
let branch_name = function Branch b -> b | Here | List_worktrees -> ""
let is_shell = function Shell -> true | Agent -> false

let seed_verb_name = function
  | Copy -> "copy"
  | Keychain -> "keychain"
  | File -> "file"
  | Json_merge -> "json_merge"

(* Seed instructions report their SHAPE, verb and destination: the content is
   multi-line template data, so a line-oriented dump can only mislead about it. *)
let seed_shapes xs = List.map (fun s -> seed_verb_name s.verb ^ ":" ^ s.dest) xs

let namespace_name = function
  | Shared n -> n
  | Per_repo | Throwaway _ | Real_home -> ""

let is_throwaway = function
  | Throwaway _ -> true
  | Per_repo | Shared _ | Real_home -> false

let throwaway_name = function
  | Throwaway (Named n) -> n
  | Throwaway Anon | Per_repo | Shared _ | Real_home -> ""

let is_real_home = function
  | Real_home -> true
  | Per_repo | Shared _ | Throwaway _ -> false

let to_lines c =
  [
    ("mode", mode_name c.mode);
    ("no_launch", string_of_bool c.no_launch);
    ("here", string_of_bool (is_here c.target));
    ("shell", string_of_bool (is_shell c.runner));
    ("agent", Agent.to_string c.agent);
    ("agent_bin_attr", Agent.bin_attr c.agent);
    ("paranoid", string_of_bool c.paranoid);
    ("pasteboard", string_of_bool c.pasteboard);
    ("nix_target", opt c.nix_targets.shared);
    ("nix_target_shell", opt c.nix_targets.for_shell);
    ("nix_target_agent", opt c.nix_targets.for_agent);
    ("nix_target_effective", effective_nix_target c);
    ("sandbox", string_of_bool c.sandbox);
    ("real_home", string_of_bool (is_real_home c.home));
    ("yolo", string_of_bool c.yolo);
    ("latest", string_of_bool c.latest);
    ("verbose", string_of_bool c.verbose);
    ("namespace", namespace_name c.home);
    ("branch", branch_name c.target);
    ("ephemeral", string_of_bool (is_throwaway c.home));
    ("ephemeral_name", throwaway_name c.home);
    ("profile", joined c.profiles);
    ("seed_creds", string_of_bool c.seed_creds);
    ("seed_home", opt c.seed_home);
    ("reseed", string_of_bool c.reseed);
    ("accent", opt c.accent);
    ("cfg_tmpdir", opt c.cfg_tmpdir);
    ("tmp_base", c.tmp_base);
    ("token_cmd", (match c.token_cmd with Some _ -> "present" | None -> "absent"));
    ("token_env", c.token_env);
    ("seed", joined (seed_shapes c.seed));
    ("cred_seed", joined (seed_shapes c.cred_seed));
    (* dest=source, which `seed` cannot show: there it is one more json_merge
       shape among the adapter's own. *)
    ("seed_merge", joined (List.map (fun (d, s) -> d ^ "=" ^ s) c.seed_merge));
    ("agent_args", joined c.agent_args);
    ("keep", joined c.keep);
    ("setenv", joined (List.map fst c.setenv));
    (* Names only, like setenv: the command is the configuration, but it can name
       a vault path, and the dump is the seam an operator pastes into a report. *)
    ("setenv_cmd", joined (List.map fst c.setenv_cmd));
    ("deny_read", joined c.deny_read);
    ("allow_write", joined c.allow_write);
    ("allow_socket", joined c.allow_socket);
    ("filter_egress", string_of_bool c.filter_egress);
    ("allow_loopback", string_of_bool c.allow_loopback);
    ("allow_host", joined c.allow_hosts);
    ("allow_port", joined (List.map string_of_int c.allow_ports));
    ("paranoid_deny_read", joined c.paranoid_deny_read);
    ("paranoid_allow_read", joined c.paranoid_allow_read);
    ("config_sections", joined c.config_sections);
  ]

let print c =
  List.iter (fun (k, v) -> Printf.printf "%s=%s\n" k v) (to_lines c)
