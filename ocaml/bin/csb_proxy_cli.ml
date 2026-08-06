(* csb-proxy -- the egress allowlist proxy (docs/PLAN-007-agent-sandbox-again.md
   section 2).

     csb-proxy ALLOWLIST_FILE [--allow-port N]... [--log-file PATH]

   Prints the bound loopback port on stdout -- and only that, since the launcher
   reads it to pin the sandbox profile -- then serves until killed.

   Allow/deny decisions always go to stderr, and additionally to --log-file when
   given. Point that at a path the sandbox can read: a denied CONNECT reaches the
   agent as an opaque transport error, so a readable log is the only way it can
   tell policy from packet loss. *)

open Csb_config

let usage () =
  prerr_endline
    "usage: csb-proxy ALLOWLIST_FILE [--allow-port N]... [--log-file PATH]";
  exit 2

let die msg =
  prerr_endline ("csb-proxy: " ^ msg);
  exit 2

let parse argv =
  let file = ref None and ports = ref [] and log_file = ref None in
  let rec go = function
    | [] -> ()
    | "--allow-port" :: n :: rest -> (
      match int_of_string_opt n with
      | Some p when p > 0 && p <= 65535 ->
        ports := p :: !ports;
        go rest
      | _ -> die "--allow-port needs a port from 1 to 65535")
    | [ "--allow-port" ] -> die "--allow-port requires a PORT"
    | "--log-file" :: p :: rest ->
      log_file := Some p;
      go rest
    | [ "--log-file" ] -> die "--log-file requires a PATH"
    | a :: rest when !file = None && String.length a > 0 && a.[0] <> '-' ->
      file := Some a;
      go rest
    | _ -> usage ()
  in
  go (List.tl (Array.to_list argv));
  match !file with
  | None -> usage ()
  | Some f -> (f, (if !ports = [] then [ 443 ] else List.rev !ports), !log_file)

let () =
  let file, allowed_ports, log_file = parse Sys.argv in
  let allow =
    try Allowlist.of_file file
    with Sys_error msg ->
      Printf.eprintf "csb-proxy: %s\n" msg;
      exit 1
  in
  (match log_file with
  | None -> ()
  | Some p -> (
    try
      Proxy.add_log_sink
        (open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 p)
    with Sys_error msg ->
      Printf.eprintf "csb-proxy: %s\n" msg;
      exit 1));
  Proxy.serve ~allow ~allowed_ports ~announce:(fun p -> Printf.printf "%d\n%!" p)
