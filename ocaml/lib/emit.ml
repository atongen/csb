(* The adoption seam: everything bin/csb needs from resolution, written to a
   file as NUL-terminated KEY=VALUE records.

   Two things separate it from Dump, which is the operator-facing seam. It
   redacts nothing -- token_cmd and setenv_cmd carry their commands, setenv its
   values -- so it goes to a file the caller reads and unlinks rather than to a
   terminal. And a list key repeats, once per element, instead of joining: NUL is
   the one byte a path, an argument or a variable's value cannot contain, so no
   element can split itself into two.

   The key set is exactly what bin/csb consumes. An unknown key on either side
   is an error there, so a field added here without a reader fails loudly. *)

open Types

let dump_name = function
  | No_dump -> ""
  | Dump_config -> "config"
  | Dump_sandbox -> "sandbox"

(* A seed instruction is three fields, so it rides as three PARALLEL list keys
   in one interleaved run: verb, then arg, then dest, per instruction. That
   needs no escape for a field separator -- the arg holds file content, which
   can contain any byte but NUL -- and bin/csb reads the three back into three
   arrays whose lengths it checks. *)
let seed_records prefix xs =
  List.concat_map
    (fun s ->
      [ (prefix ^ "_verb", Dump.seed_verb_name s.verb);
        (prefix ^ "_arg", s.arg);
        (prefix ^ "_dest", s.dest) ])
    xs

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
      ("agent", s (Agent.to_string c.agent));
      ("agent_bin_attr", s (Agent.bin_attr c.agent));
      ("agent_bin_name", s (Agent.bin_name c.agent));
      ("agent_config_dir", s (Agent.config_dir c.agent));
      ("agent_config_env", s (Agent.config_env c.agent));
      ("token_env", s c.token_env);
      ("token_hint", s (Agent.token_hint c.agent));
      ("cred_check", s (Agent.cred_check c.agent));
      ("cred_usable_expr", s (Agent.cred_usable_expr c.agent));
      ("cred_clear_expr", s (Agent.cred_clear_expr c.agent));
      ("ns_migrate", b (Agent.ns_migrate c.agent));
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
      ("profile", c.profiles);
      ("seed_creds", b c.seed_creds);
      ("seed_home", s (Dump.opt c.seed_home));
      ("reseed", b c.reseed);
      ("accent", s (Dump.opt c.accent));
      ("cfg_tmpdir", s (Dump.opt c.cfg_tmpdir));
      ("tmp_base", s c.tmp_base);
      ("token_cmd", s (Dump.opt c.token_cmd));
      ("filter_egress", b c.filter_egress);
      ("allow_loopback", b c.allow_loopback);
      ("agent_args", c.agent_args);
      ("keep", c.keep);
      ("setenv", setenv_words);
      ("setenv_cmd", List.map (fun (k, v) -> k ^ "=" ^ v) c.setenv_cmd);
      ("deny_read", c.deny_read);
      ("allow_write", c.allow_write);
      ("allow_socket", c.allow_socket);
      ("allow_host", c.allow_hosts);
      ("allow_port", List.map string_of_int c.allow_ports);
      ("paranoid_deny_read", c.paranoid_deny_read);
      ("paranoid_allow_read", c.paranoid_allow_read);
    ]
  @ seed_records "seed" c.seed
  @ seed_records "cred" c.cred_seed

(* The file carries token_cmd, so it is created private and the caller unlinks
   it once read. *)
let to_file path c =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> List.iter (fun (k, v) -> Printf.fprintf oc "%s=%s\000" k v) (records c))
