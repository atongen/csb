(* CONNECT-only egress proxy. The sandbox can reach nothing but this port, so the
   allowlist here IS the egress policy. TLS is tunnelled, never terminated:
   destination control needs the CONNECT target, not the payload. *)

let log fmt = Printf.eprintf ("[csb-proxy] " ^^ fmt ^^ "\n%!")

type decision =
  | Allow of string * int
  | Deny of string

let write_all fd bytes len =
  let rec go off =
    if off < len then go (off + Unix.write fd bytes off (len - off))
  in
  go 0

let write_str fd s = write_all fd (Bytes.of_string s) (String.length s)

(* Read the request head up to CRLFCRLF, one byte at a time so no tunnel payload
   is consumed. Safe for CONNECT: the client waits for the 200 before sending. *)
let read_head fd limit =
  let buf = Buffer.create 256 in
  let one = Bytes.create 1 in
  let rec go () =
    if Buffer.length buf >= limit then None
    else
      match Unix.read fd one 0 1 with
      | 0 -> None
      | _ ->
        Buffer.add_char buf (Bytes.get one 0);
        let s = Buffer.contents buf in
        let n = String.length s in
        if n >= 4 && String.sub s (n - 4) 4 = "\r\n\r\n" then Some s else go ()
      | exception Unix.Unix_error _ -> None
  in
  go ()

let split_target target =
  match String.rindex_opt target ':' with
  | None -> None
  | Some i ->
    let host = String.sub target 0 i in
    let port = String.sub target (i + 1) (String.length target - i - 1) in
    (match int_of_string_opt port with
    | Some p when p > 0 && p <= 65535 && host <> "" -> Some (host, p)
    | _ -> None)

let request_line head =
  match String.index_opt head '\r' with
  | Some i -> String.sub head 0 i
  | None -> head

let classify allow allowed_ports head =
  match String.split_on_char ' ' (request_line head) with
  | [] | [ "" ] -> Deny "empty request"
  | "CONNECT" :: target :: _ -> (
    match split_target target with
    | None -> Deny (Printf.sprintf "malformed CONNECT target: %s" target)
    | Some (host, port) ->
      let listed = Allowlist.matches allow host in
      if Allowlist.is_ip_literal host && not listed then
        Deny (Printf.sprintf "IP literal not allowed: %s" host)
      else if not (List.mem port allowed_ports) then
        Deny (Printf.sprintf "port not allowed: %s:%d" host port)
      else if not listed then Deny (Printf.sprintf "host not allowed: %s" host)
      else Allow (host, port))
  | meth :: _ -> Deny (Printf.sprintf "only CONNECT is proxied (got %s)" meth)

let connect_to host port =
  match
    Unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  with
  | [] -> None
  | ai :: _ -> (
    let fd = Unix.socket ai.Unix.ai_family ai.Unix.ai_socktype 0 in
    try
      Unix.connect fd ai.Unix.ai_addr;
      Some fd
    with Unix.Unix_error _ ->
      (try Unix.close fd with Unix.Unix_error _ -> ());
      None)
  | exception _ -> None

let shutdown_send fd =
  try Unix.shutdown fd Unix.SHUTDOWN_SEND with Unix.Unix_error _ -> ()

let close fd = try Unix.close fd with Unix.Unix_error _ -> ()

let pump src dst =
  let buf = Bytes.create 65536 in
  let rec go () =
    match Unix.read src buf 0 (Bytes.length buf) with
    | 0 -> ()
    | n -> (
      match write_all dst buf n with () -> go () | exception _ -> ())
    | exception _ -> ()
  in
  go ();
  shutdown_send dst

let handle allow allowed_ports client =
  (match read_head client 8192 with
  | None -> ()
  | Some head -> (
    match classify allow allowed_ports head with
    | Deny why ->
      log "DENY %s" why;
      (try write_str client "HTTP/1.1 403 Forbidden\r\n\r\n"
       with Unix.Unix_error _ -> ())
    | Allow (host, port) -> (
      match connect_to host port with
      | None ->
        log "FAIL upstream unreachable %s:%d" host port;
        (try write_str client "HTTP/1.1 502 Bad Gateway\r\n\r\n"
         with Unix.Unix_error _ -> ())
      | Some upstream ->
        log "ALLOW %s:%d" host port;
        write_str client "HTTP/1.1 200 Connection Established\r\n\r\n";
        let up = Thread.create (fun () -> pump client upstream) () in
        pump upstream client;
        Thread.join up;
        close upstream)));
  close client

(* announce receives the bound port: the launcher pins the sandbox profile to it,
   so it must be read before the sandbox starts. *)
let serve ~allow ~allowed_ports ~announce =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 64;
  (match Unix.getsockname sock with
  | Unix.ADDR_INET (_, p) -> announce p
  | _ -> failwith "expected an inet socket");
  let rec loop () =
    let client, _ = Unix.accept sock in
    ignore (Thread.create (fun () -> handle allow allowed_ports client) ());
    loop ()
  in
  loop ()
