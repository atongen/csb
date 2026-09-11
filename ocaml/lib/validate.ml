(* Value validators shared by the CLI flags and the profile keys. Each takes the
   source label bin/csb passes as its `where` argument, so one message serves
   both ("--allow-host: ..." and "profile p:3: allow_host: ..."). *)

let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let is_alnum c = is_alpha c || is_digit c
let for_all p s = String.for_all p s
let starts_with ~prefix s = String.starts_with ~prefix s

(* Expand a LITERAL leading ~/ and require an absolute or ~/ path. *)
let list_path env ~where v =
  if starts_with ~prefix:"~/" v then Env.expand_tilde env v
  else if starts_with ~prefix:"/" v then v
  else Err.die "%s: not an absolute or ~/ path: '%s'" where v

(* A hostname, or a leading '*.' pattern matching subdomains only. The charset
   is what a DNS name needs and nothing else: the value reaches the proxy
   through a file, so no quote or whitespace can smuggle a second entry. *)
let host ~where v =
  let body = if starts_with ~prefix:"*." v then String.sub v 2 (String.length v - 2) else v in
  let ok =
    body <> ""
    && is_alnum body.[0]
    && is_alnum body.[String.length body - 1]
    && for_all (fun c -> is_alnum c || c = '.' || c = '-') body
  in
  if ok then v else Err.die "%s: not a hostname or *.suffix pattern: '%s'" where v

let port ~where v =
  match int_of_string_opt v with
  | Some n when v <> "" && for_all is_digit v && n >= 1 && n <= 65535 -> n
  | _ -> Err.die "%s: not a port from 1 to 65535: '%s'" where v

(* Interpolated into a flake ref, so no '#', quote or whitespace may reach the
   nix command line. *)
let nix_target ~where v =
  if v <> "" && is_alnum v.[0]
     && for_all (fun c -> is_alnum c || c = '.' || c = '_' || c = '-') v
  then v
  else Err.die "%s: invalid nix target '%s' (use letters, digits, . _ -)" where v

(* A namespace becomes a directory ~/.csb/agents/@NAME; the leading @ is
   optional here (it is added at resolve time). *)
let namespace v =
  let body = if starts_with ~prefix:"@" v then String.sub v 1 (String.length v - 1) else v in
  let ok =
    body <> ""
    && for_all (fun c -> is_alnum c || c = '.' || c = '_' || c = '-') body
    && v <> "." && v <> ".."
  in
  if ok then v
  else Err.die "invalid namespace '%s' (use letters, digits, . _ -; optional leading @)" v

(* NAME becomes one path component (csb-home-<NAME>), so no @ and no . / .. *)
let ephemeral_name v =
  let ok =
    v <> ""
    && for_all (fun c -> is_alnum c || c = '.' || c = '_' || c = '-') v
    && v <> "." && v <> ".."
  in
  if ok then v else Err.die "invalid ephemeral name '%s' (use letters, digits, . _ -)" v

(* The NAME in a [group NAME] header. Only ever an assoc key, but held to a
   plain word so a stray comma or bracket reads as a mistake rather than as part
   of the name. A use= names a group by string equality, so a name it could
   never match is refused where it is written. *)
let group_name ~where v =
  if v <> "" && for_all (fun c -> is_alnum c || c = '.' || c = '_' || c = '-') v then v
  else Err.die "%s: invalid group name '%s' (use letters, digits, . _ -)" where v

let accent_names =
  [ "black"; "red"; "green"; "yellow"; "blue"; "magenta"; "cyan"; "white";
    "gray"; "grey"; "bright-red"; "bright-green"; "bright-yellow";
    "bright-blue"; "bright-magenta"; "bright-cyan"; "bright-white" ]

(* A known color name or a raw ANSI SGR parameter string, so no arbitrary bytes
   reach the escape sequence the statusline builds. *)
let accent v =
  let sgr =
    List.for_all
      (fun p -> p <> "" && for_all is_digit p)
      (String.split_on_char ';' v)
  in
  if List.mem v accent_names || sgr then v
  else Err.die "invalid --accent '%s' (a color name like magenta, or ANSI SGR params like 38;5;208)" v

let is_var_name v =
  v <> "" && (is_alpha v.[0] || v.[0] = '_')
  && for_all (fun c -> is_alnum c || c = '_') v

(* --keep and profile keep= word the same refusal differently; the caller
   supplies its own lead-in. *)
let keep_var ~msg v =
  if is_var_name v then v else Err.die "%s: '%s'" msg v

(* A profile setenv= value: VAR=value, split on the first '='. *)
let setenv ~where v =
  match String.index_opt v '=' with
  | Some i when is_var_name (String.sub v 0 i) ->
      (String.sub v 0 i, String.sub v (i + 1) (String.length v - i - 1))
  | _ -> Err.die "%s: setenv needs VAR=value: '%s'" where v

(* A setenv_cmd= value: VAR=command. The command is what gets configured and its
   stdout is what reaches the sandbox, so an empty one has nothing to inject. *)
let setenv_cmd ~where v =
  match String.index_opt v '=' with
  | Some i when is_var_name (String.sub v 0 i) ->
      let cmd = String.sub v (i + 1) (String.length v - i - 1) in
      if cmd = "" then Err.die "%s: setenv_cmd needs a command: '%s'" where v
      else (String.sub v 0 i, cmd)
  | _ -> Err.die "%s: setenv_cmd needs VAR=command: '%s'" where v

(* A seed destination is joined onto the launch HOME and onto nothing else, so an
   absolute path or a '..' component would place the write outside it. *)
let seed_dest ~where v =
  let ok =
    v <> "" && v.[0] <> '/'
    && List.for_all
         (fun p -> p <> "" && p <> "." && p <> "..")
         (String.split_on_char '/' v)
  in
  if ok then v
  else
    Err.die "%s: seed_merge needs a relative destination under the launch HOME, no '..': '%s'"
      where v

(* A seed_merge= value: DEST=FILE, the launch-HOME destination first so it reads
   like setenv's target=source. FILE is a host path read at resolution time. *)
let seed_merge env ~where v =
  match String.index_opt v '=' with
  | None -> Err.die "%s: seed_merge needs DEST=FILE: '%s'" where v
  | Some i ->
      let dest = String.sub v 0 i in
      let src = String.sub v (i + 1) (String.length v - i - 1) in
      if src = "" then Err.die "%s: seed_merge needs a source FILE: '%s'" where v
      else (seed_dest ~where dest, list_path env ~where src)

(* The NAME in a [profile NAME] header, and in the -p that names one. Held to the
   same word shape as a group: it is also a file name under profiles/, so a
   separator or a leading dot would name something else entirely. *)
let profile_name ~where v =
  if v <> "" && v <> "." && v <> ".."
     && for_all (fun c -> is_alnum c || c = '.' || c = '_' || c = '-') v
  then v
  else Err.die "%s: invalid profile name '%s' (use letters, digits, . _ -)" where v

let profile_bool ~where ~key v =
  match v with
  | "true" -> true
  | "false" -> false
  | _ -> Err.die "%s: %s needs true or false: '%s'" where key v
