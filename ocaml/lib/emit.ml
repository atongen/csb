(* The adoption seam: everything bin/csb needs from resolution, written to a
   file as NUL-terminated KEY=VALUE records.

   Two things separate it from Dump, which is the operator-facing seam. It
   redacts nothing -- token_cmd carries its command, setenv its values -- so it
   goes to a file the caller reads and unlinks rather than to a terminal. And a
   list key repeats, once per element, instead of joining: NUL is the one byte a
   path, an argument or a variable's value cannot contain, so no element can
   split itself into two.

   The key set is exactly what bin/csb consumes. An unknown key on either side
   is an error there, so a field added here without a reader fails loudly. *)

open Types

let dump_name = function
  | No_dump -> ""
  | Dump_config -> "config"
  | Dump_sandbox -> "sandbox"

let records c =
  let b v = [ string_of_bool v ] in
  let s v = [ v ] in
  let setenv_words = List.map (fun (k, v) -> k ^ "=" ^ v) c.setenv in
  List.concat_map
    (fun (k, vs) -> List.map (fun v -> (k, v)) vs)
    [
      ("dump", s (dump_name c.dump));
      ("mode", s (Dump.mode_name c.mode));
      ("no_launch", b c.no_launch);
      ("here", b (Dump.is_here c.target));
      ("shell", b (Dump.is_shell c.runner));
      ("paranoid", b c.paranoid);
      ("pasteboard", b c.pasteboard);
      ("nix_target_effective", s (effective_nix_target c));
      ("sandbox", b c.sandbox);
      ("real_home", b (Dump.is_real_home c.home));
      ("yolo", b c.yolo);
      ("latest", b c.latest);
      ("verbose", b c.verbose);
      ("namespace", s (Dump.namespace_name c.home));
      ("branch", s (Dump.branch_name c.target));
      ("ephemeral", b (Dump.is_throwaway c.home));
      ("ephemeral_name", s (Dump.throwaway_name c.home));
      ("profile", s (Dump.opt c.profile));
      ("seed_creds", b c.seed_creds);
      ("seed_home", s (Dump.opt c.seed_home));
      ("reseed", b c.reseed);
      ("accent", s (Dump.opt c.accent));
      ("cfg_tmpdir", s (Dump.opt c.cfg_tmpdir));
      ("token_cmd", s (Dump.opt c.token_cmd));
      ("filter_egress", b c.filter_egress);
      ("claude_args", c.claude_args);
      ("keep", c.keep);
      ("setenv", setenv_words);
      ("deny_read", c.deny_read);
      ("allow_write", c.allow_write);
      ("allow_socket", c.allow_socket);
      ("allow_host", c.allow_hosts);
      ("allow_port", List.map string_of_int c.allow_ports);
      ("paranoid_deny_read", c.paranoid_deny_read);
      ("paranoid_allow_read", c.paranoid_allow_read);
    ]

(* The file carries token_cmd, so it is created private and the caller unlinks
   it once read. *)
let to_file path c =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> List.iter (fun (k, v) -> Printf.fprintf oc "%s=%s\000" k v) (records c))
