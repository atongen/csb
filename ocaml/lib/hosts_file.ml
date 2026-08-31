(* $XDG_CONFIG_HOME/csb/allowed-hosts: the user-global egress allowlist. Add-only
   like the deny file -- entries accumulate with --allow-host and a profile's
   allow_host=, and a bad entry aborts the launch rather than silently launching
   with a shorter allowlist.

   Agents reach different hosts, so the resolved agent picks the file:
   allowed-hosts.<agent> when it exists, and the unsuffixed allowed-hosts
   otherwise -- one shared list until an agent needs its own, rather than a
   migration for every operator who already has one. *)

let is_space c = c = ' ' || c = '\t' || c = '\r'

let trim s =
  let n = String.length s in
  let i = ref 0 and j = ref n in
  while !i < !j && is_space s.[!i] do incr i done;
  while !j > !i && is_space s.[!j - 1] do decr j done;
  String.sub s !i (!j - !i)

let strip_comment s =
  match String.index_opt s '#' with None -> s | Some i -> String.sub s 0 i

let path env agent =
  let per_agent = Env.allowed_hosts_file env (Agent.hosts_file agent) in
  if Sys.file_exists per_agent then per_agent
  else Env.allowed_hosts_file env "allowed-hosts"

let read env agent =
  let path = path env agent in
  if not (Sys.file_exists path) then []
  else
    List.filter_map
      (fun (lineno, line) ->
        match trim (strip_comment line) with
        | "" -> None
        | host -> Some (Validate.host ~where:(Printf.sprintf "%s:%d" path lineno) host))
      (List.mapi (fun i line -> (i + 1, line)) (Lines.of_file path))
