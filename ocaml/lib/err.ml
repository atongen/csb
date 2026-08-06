(* csb's die/warn channel. The message text is part of the contract:
   test/validation.bats asserts these strings, so they are transcribed from
   bin/csb rather than reworded. *)

exception Die of string

let prog = Filename.basename Sys.argv.(0)
let die fmt = Printf.ksprintf (fun m -> raise (Die m)) fmt
let warn fmt = Printf.ksprintf (fun m -> prerr_endline (prog ^ ": " ^ m)) fmt

(* A continuation line of a warning: unprefixed, as bin/csb writes them. *)
let note fmt = Printf.ksprintf prerr_endline fmt
