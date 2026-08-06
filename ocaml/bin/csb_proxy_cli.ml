(* csb-proxy -- the egress allowlist proxy (docs/PLAN-007-agent-sandbox-again.md
   section 2).

     csb-proxy ALLOWLIST_FILE [--allow-port N]...

   Prints the bound loopback port on stdout, then serves until killed. The
   launcher reads that port and pins the sandbox profile to it, so nothing else
   is reachable. Allow/deny decisions go to stderr. *)

open Csb_config

let usage () =
  prerr_endline "usage: csb-proxy ALLOWLIST_FILE [--allow-port N]...";
  exit 2

let parse argv =
  let file = ref None and ports = ref [] in
  let rec go = function
    | [] -> ()
    | "--allow-port" :: n :: rest -> (
      match int_of_string_opt n with
      | Some p when p > 0 && p <= 65535 ->
        ports := p :: !ports;
        go rest
      | _ ->
        prerr_endline "csb-proxy: --allow-port needs a port from 1 to 65535";
        exit 2)
    | "--allow-port" :: [] ->
      prerr_endline "csb-proxy: --allow-port requires a PORT";
      exit 2
    | a :: rest when !file = None && String.length a > 0 && a.[0] <> '-' ->
      file := Some a;
      go rest
    | _ -> usage ()
  in
  go (List.tl (Array.to_list argv));
  match !file with
  | None -> usage ()
  | Some f -> (f, if !ports = [] then [ 443 ] else List.rev !ports)

let () =
  let file, allowed_ports = parse Sys.argv in
  let allow =
    try Allowlist.of_file file
    with Sys_error msg ->
      Printf.eprintf "csb-proxy: %s\n" msg;
      exit 1
  in
  Proxy.serve ~allow ~allowed_ports ~announce:(fun p -> Printf.printf "%d\n%!" p)
