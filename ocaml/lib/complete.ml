(* Shell-completion candidates, attached to the converters in Cli. cmdliner
   does not prefix-filter value items, so every function here does; and it
   calls them outside its exception guard on half-typed lines, so every one of
   them is total. *)

open Cmdliner

module C = Arg.Completion

(* What the completion context reads off the command line. *)
type ctx = {
  shell : bool option;
  agent : Types.agent Layer.t;
  profiles : string list;
  delete : bool;
}

let total f = try f () with Err.Die _ | Sys_error _ | Unix.Unix_error _ -> []

let matching ~token = List.filter (String.starts_with ~prefix:token)

let strings ~token xs = List.map C.string (matching ~token xs)

let plain f = C.make (fun (_ : unit option) ~token -> Ok (total (fun () -> f ~token)))

let entries dir = List.sort compare (Array.to_list (Sys.readdir dir))

let is_dir path = Sys.file_exists path && Sys.is_directory path

(* --- value positions ---------------------------------------------------------- *)

let agents : string C.t = plain (fun ~token -> strings ~token Agent.names)

let accents : string C.t = plain (fun ~token -> strings ~token Validate.accent_names)

let valid_profile name =
  (not (Filename.check_suffix name ".local"))
  && (try ignore (Validate.profile_name ~where:"" name); true with Err.Die _ -> false)

let profile_names env =
  let dir = Env.profiles_dir env in
  let files =
    total (fun () ->
        List.filter
          (fun n -> valid_profile n && not (is_dir (Filename.concat dir n)))
          (entries dir))
  in
  let blocks =
    total (fun () ->
        List.map (fun g -> g.Config_file.name) (Config_file.load env).Config_file.blocks)
  in
  List.sort_uniq compare (files @ blocks)

let profiles env = plain (fun ~token -> strings ~token (profile_names env))

(* A shared namespace is an @NAME dir; -N takes NAME or @NAME, so the candidate
   is spelled the way the token already is. *)
let namespaces env =
  plain (fun ~token ->
      let root = Env.ns_root env in
      let shared =
        List.filter
          (fun n -> String.starts_with ~prefix:"@" n && is_dir (Filename.concat root n))
          (entries root)
      in
      let spell n =
        if String.starts_with ~prefix:"@" token then n
        else String.sub n 1 (String.length n - 1)
      in
      strings ~token (List.map spell shared))

let var_names : string C.t =
  plain (fun ~token ->
      let name kv =
        match String.index_opt kv '=' with Some i -> String.sub kv 0 i | None -> kv
      in
      strings ~token
        (List.sort_uniq compare (List.map name (Array.to_list (Unix.environment ())))))

(* Validate.list_path refuses a relative path, so no relative one is offered. *)
let list_paths : string C.t =
  plain (fun ~token ->
      if String.starts_with ~prefix:"/" token || String.starts_with ~prefix:"~" token then
        [ C.files ]
      else [ C.message "PATH must be absolute or start with ~/" ])

(* --- BRANCH, and the arguments after -- ------------------------------------------ *)

(* Protocol v1 by hand: a value group is always named "Values", which zsh
   glues onto a -- prefix (--mo becomes --mo=--model), so the agent's own flags
   need a group of their own. *)
let raw_group ~name ~files items =
  let item (flag, doc) = [ "item"; flag; doc; "item-end" ] in
  let lines =
    ("1" :: (if items = [] then [] else "group" :: name :: List.concat_map item items))
    @ if files then [ "files" ] else []
  in
  String.concat "\n" lines ^ "\n"

type runner = Shell | Agent of Types.agent

(* The same folds a launch uses. A layer that does not resolve -- a missing
   profile, a config that does not parse -- leaves the command line alone to
   answer. *)
let runner_of env (c : ctx) =
  let layers =
    try
      let config = Config_file.load env in
      Layers.stack config (fst (Layers.profiles env config c.profiles))
    with Err.Die _ | Sys_error _ | Unix.Unix_error _ -> Profile.empty
  in
  if Layers.shell ~cli:c.shell layers then Shell else Agent (Layers.agent ~cli:c.agent layers)

let agent_args agent ~token =
  let flags =
    List.filter (fun (f, _) -> String.starts_with ~prefix:token f) (Agent.argv_flags agent)
  in
  let files = not (String.starts_with ~prefix:"-" token) in
  [ C.raw (raw_group ~name:(Agent.to_string agent ^ " options") ~files flags) ]

let branch env ~after_dashdash context =
  C.make ~context (fun ctx ~token ->
      Ok
        (total (fun () ->
             match (after_dashdash, ctx) with
             | true, None -> agent_args Types.Claude ~token
             | true, Some c -> (
                 match runner_of env c with
                 | Shell -> [ C.restart ]
                 | Agent a -> agent_args a ~token)
             | false, Some { delete = true; _ } -> strings ~token env.Env.complete_worktrees
             | false, _ -> strings ~token env.Env.complete_branches)))
