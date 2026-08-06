(* csb-config -- csb's config-resolution layer (docs/PLAN-007-agent-sandbox-again.md
   section 9).

   Milestone 1 (this file): emit the resolved DEFAULT config in bin/csb's
   --dump-config wire format, so the two implementations can be diffed for the
   no-args case. Flag, profile and .local parsing land next, driven by the
   existing bats oracle:

     make ocaml-test    # CSB=<this binary> bats test/precedence.bats test/lists.bats *)

open Csb_config

let env_flag name =
  match Sys.getenv_opt name with None | Some "" -> false | Some _ -> true

let env_str name =
  match Sys.getenv_opt name with None | Some "" -> None | Some v -> Some v

let () =
  let cfg =
    {
      Types.default with
      Types.latest = env_flag "CSB_LATEST";
      verbose = env_flag "CSB_VERBOSE";
      cfg_tmpdir = env_str "CSB_TMPDIR";
    }
  in
  Dump.print cfg
