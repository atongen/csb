(* The --dump-config wire format: the exact keys, order and value spellings of
   bin/csb's dump block. Never prints a secret -- token_cmd reports
   present/absent and setenv reports VAR names only. *)

open Types

let opt = function Some v -> v | None -> ""
let joined xs = String.concat "|" xs

let mode_name = function
  | Launch -> "launch"
  | Delete -> "delete"
  | List_ns -> "list_ns"

let is_here = function Here -> true | List_worktrees | Branch _ -> false
let branch_name = function Branch b -> b | Here | List_worktrees -> ""
let is_shell = function Shell -> true | Claude -> false

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
    ("paranoid", string_of_bool c.paranoid);
    ("pasteboard", string_of_bool c.pasteboard);
    ("nix_target", opt c.nix_targets.shared);
    ("nix_target_shell", opt c.nix_targets.for_shell);
    ("nix_target_claude", opt c.nix_targets.for_claude);
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
    ("profile", opt c.profile);
    ("seed_creds", string_of_bool c.seed_creds);
    ("seed_home", opt c.seed_home);
    ("reseed", string_of_bool c.reseed);
    ("accent", opt c.accent);
    ("cfg_tmpdir", opt c.cfg_tmpdir);
    ("token_cmd", (match c.token_cmd with Some _ -> "present" | None -> "absent"));
    ("claude_args", joined c.claude_args);
    ("keep", joined c.keep);
    ("setenv", joined (List.map fst c.setenv));
    ("deny_read", joined c.deny_read);
    ("allow_write", joined c.allow_write);
    ("allow_socket", joined c.allow_socket);
    ("paranoid_deny_read", joined c.paranoid_deny_read);
    ("paranoid_allow_read", joined c.paranoid_allow_read);
  ]

let print c =
  List.iter (fun (k, v) -> Printf.printf "%s=%s\n" k v) (to_lines c)
