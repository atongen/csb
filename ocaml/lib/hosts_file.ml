(* $XDG_CONFIG_HOME/csb/allowed-hosts: the user-global egress allowlist. Add-only
   like the deny file -- entries accumulate with --allow-host and a profile's
   allow_host=, and a bad entry aborts the launch rather than silently launching
   with a shorter allowlist. *)

let is_space c = c = ' ' || c = '\t' || c = '\r'

let trim s =
  let n = String.length s in
  let i = ref 0 and j = ref n in
  while !i < !j && is_space s.[!i] do incr i done;
  while !j > !i && is_space s.[!j - 1] do decr j done;
  String.sub s !i (!j - !i)

let strip_comment s =
  match String.index_opt s '#' with None -> s | Some i -> String.sub s 0 i

let read env =
  let path = Env.allowed_hosts_file env in
  if not (Sys.file_exists path) then []
  else
    List.filter_map
      (fun (lineno, line) ->
        match trim (strip_comment line) with
        | "" -> None
        | host -> Some (Validate.host ~where:(Printf.sprintf "%s:%d" path lineno) host))
      (List.mapi (fun i line -> (i + 1, line)) (Lines.of_file path))
