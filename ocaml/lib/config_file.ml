(* ~/.config/csb/config, then the gitignored ~/.config/csb/config.local: the
   repo-selected layer between the built-in defaults and a named profile.

   The files are the profile grammar plus [SELECTOR] section headers. Every
   section whose selector matches the physical main checkout root applies, in
   DOCUMENT order -- config in full, then config.local, top to bottom -- so a
   scalar goes to the last matching section that sets it and lists union across
   all of them. --dump-config reports which sections matched, because a selector
   that matches nothing is otherwise indistinguishable from one that matches.

   A [group NAME] header is a named bundle rather than a selector: it matches no
   repository, and `use = NAME` splices its lines into the section naming it, at
   that point in document order. Path and concept are different grouping axes --
   a selector can only collect repos that share a path shape.

   A [profile NAME] header is a third kind again: it matches no repository and no
   use= can name it, and it applies only when `-p NAME` asks for it -- one layer
   ABOVE every section here. Keeping it distinct from [group] is what stops a
   bundle meant for splicing from being launchable, and a launch config from
   being spliced into every repo that says use=. A block in config.local EXTENDS
   the one config defined, exactly as profiles/NAME.local extends profiles/NAME;
   twice in one file is a typo and refused. *)

(* A selector header: comma-separated terms, `!` excluding. The first positive
   pattern is its own field, so a header of exclusions alone -- which would
   select nothing while reading as if it selected something -- cannot be
   built. *)
type term_set = {
  first : string;
  more : string list;
  excluded : string list;
}

(* A named bundle, in definition order. `label` is the file that defined it, so
   a use from config.local still reports where the lines came from. The same
   shape serves a [profile NAME] block: both are bodies of lines held until
   something names them, and `uses` records the groups already spliced in so the
   provenance a profile block reports is the whole of what it carried. *)
type group = {
  name : string;
  label : string;
  body : (string * string * string) list; (* where, key, value *)
  uses : string list;                     (* label[group NAME], in splice order *)
}

type header = Group_def of string | Profile_def of string | Select of term_set

(* Accumulating across both files, then the one sealed layer they amount to. *)
type acc = {
  draft : Profile.draft;
  seen : string list; (* file[selector], in application order *)
  groups : group list;
  profiles : group list;
}

type t = {
  layer : Profile.t;
  matched : string list;
  (* The [profile NAME] blocks, for a -p to resolve against. *)
  blocks : group list;
}

let empty = { draft = Profile.blank; seen = []; groups = []; profiles = [] }

(* '*' matches any run of characters, INCLUDING '/', and is the only
   metacharacter. That one rule covers all three shapes: [*] is everything,
   [*work*] and [*/csb] are patterns, and a term without '*' is an exact
   path. *)
let rec matches pat i s k =
  if i = String.length pat then k = String.length s
  else if pat.[i] = '*' then
    matches pat (i + 1) s k || (k < String.length s && matches pat i s (k + 1))
  else k < String.length s && pat.[i] = s.[k] && matches pat (i + 1) s (k + 1)

(* Some positive term names the repo and no exclusion takes it back. The
   exclusion is the only way to withhold a broad section from one repo, since a
   list value has no retraction at any layer. *)
let selects sel root =
  let hit pat = matches pat 0 root 0 in
  List.exists hit (sel.first :: sel.more) && not (List.exists hit sel.excluded)

let header_of line =
  let n = String.length line in
  if n >= 2 && line.[0] = '[' && line.[n - 1] = ']' then Some (String.sub line 1 (n - 2))
  else None

let group_keyword = "group"
let profile_keyword = "profile"

(* [group NAME] and [profile NAME] can never collide with a selector: a selector
   is matched against an absolute path, which no leading keyword can begin. *)
let keyword_arg_of keyword s =
  let n = String.length keyword in
  if s = keyword then Some ""
  else if
    String.length s > n
    && String.sub s 0 n = keyword
    && (s.[n] = ' ' || s.[n] = '\t')
  then Some (String.trim (String.sub s n (String.length s - n)))
  else None

let parse_terms env ~where raw =
  let step (pos, neg) t =
    let t = String.trim t in
    if t = "" then Err.die "%s: empty term in [%s]" where raw
    else if t.[0] = '!' then
      let p = String.trim (String.sub t 1 (String.length t - 1)) in
      if p = "" then Err.die "%s: '!' with no pattern in [%s]" where raw
      else (pos, Env.expand_tilde env p :: neg)
    else (Env.expand_tilde env t :: pos, neg)
  in
  let pos, neg = List.fold_left step ([], []) (String.split_on_char ',' raw) in
  match List.rev pos with
  | [] ->
      Err.die "%s: [%s] only excludes (add a positive term, e.g. '*, %s')" where raw raw
  | first :: more -> { first; more; excluded = List.rev neg }

let parse_header env ~where raw =
  let s = String.trim raw in
  if s = "" then Err.die "%s: [] selects nothing (use [*] for every repo)" where
  else
    match (keyword_arg_of group_keyword s, keyword_arg_of profile_keyword s) with
    | Some "", _ -> Err.die "%s: [group] needs a name" where
    | Some name, _ -> Group_def (Validate.group_name ~where name)
    | _, Some "" -> Err.die "%s: [profile] needs a name" where
    | _, Some name -> Profile_def (Validate.profile_name ~where name)
    | None, None -> Select (parse_terms env ~where s)

let extend_group groups name entry =
  List.map
    (fun g -> if g.name = name then { g with body = g.body @ [ entry ] } else g)
    groups

let extend_group_uses groups name (body, used) =
  List.map
    (fun g ->
      if g.name = name then { g with body = g.body @ body; uses = g.uses @ [ used ] } else g)
    groups

(* A forward reference and a typo are the same mistake here -- the group has to
   be defined above the line that uses it -- so they share one message. *)
let find_group acc ~where name =
  if name = "" then Err.die "%s: use= needs a group name" where;
  match List.find_opt (fun g -> g.name = name) acc.groups with
  | Some g -> g
  | None -> Err.die "%s: no [group %s] defined above this line" where name

let use_key = "use"

(* A section is one of five states, and only three of them keep anything: the
   region before any header holds no selector at all, and a non-matching section
   is still parsed so a typo in one repo's section cannot hide until that repo is
   the one being launched. *)
type region =
  | Preamble
  | Skipped
  | Applied
  | Defining of string
  | Defining_profile of string

let read env ~path acc =
  if not (Sys.file_exists path) then acc
  else
    let label = Filename.basename path in
    let step (acc, region, lineno) line =
      let line = String.trim line in
      let lineno = lineno + 1 in
      let where = Printf.sprintf "config %s:%d" path lineno in
      if Profile.is_blank line then (acc, region, lineno)
      else
        match header_of line with
        | Some raw -> (
            match parse_header env ~where raw with
            | Group_def name ->
                if List.exists (fun g -> g.name = name) acc.groups then
                  Err.die "%s: group '%s' is already defined" where name;
                ( { acc with groups = acc.groups @ [ { name; label; body = []; uses = [] } ] },
                  Defining name,
                  lineno )
            | Profile_def name ->
                (* An existing block is EXTENDED, the way profiles/NAME.local
                   extends profiles/NAME -- but only from the other file. Twice
                   in one file has no such reading and is refused. *)
                (match List.find_opt (fun g -> g.name = name) acc.profiles with
                | Some g when g.label = label ->
                    Err.die "%s: profile '%s' is already defined in %s" where name label
                | Some _ -> ()
                | None -> ());
                let acc =
                  if List.exists (fun g -> g.name = name) acc.profiles then acc
                  else
                    { acc with profiles = acc.profiles @ [ { name; label; body = []; uses = [] } ] }
                in
                (acc, Defining_profile name, lineno)
            | Select sel ->
                let hit =
                  match env.Env.main_root with
                  | Some root -> selects sel root
                  | None -> false
                in
                let acc =
                  if hit then
                    { acc with seen = acc.seen @ [ label ^ "[" ^ String.trim raw ^ "]" ] }
                  else acc
                in
                (acc, (if hit then Applied else Skipped), lineno))
        | None -> (
            let key, value = Profile.split_kv ~where line in
            match region with
            | Preamble ->
                Err.die "%s: KEY=VALUE outside a [SELECTOR] section: '%s'" where line
            | Defining name ->
                if key = use_key then
                  Err.die "%s: [group %s]: use= cannot name another group" where name;
                ignore (Profile.apply env ~where Profile.blank key value);
                ( { acc with groups = extend_group acc.groups name (where, key, value) },
                  region,
                  lineno )
            | Defining_profile name ->
                (* use= composes here, unlike inside a [group]: a group is the
                   shared fragment and a profile is what assembles fragments,
                   so the composition has one direction and cannot cycle. The
                   lines are spliced at this point in document order, which is
                   what keeps a scalar set after the use= winning. *)
                if key = use_key then
                  let g = find_group acc ~where value in
                  ( { acc with
                      profiles =
                        extend_group_uses acc.profiles name
                          (g.body, g.label ^ "[group " ^ g.name ^ "]") },
                    region,
                    lineno )
                else (
                  ignore (Profile.apply env ~where Profile.blank key value);
                  ( { acc with profiles = extend_group acc.profiles name (where, key, value) },
                    region,
                    lineno ))
            | Skipped ->
                if key = use_key then ignore (find_group acc ~where value)
                else ignore (Profile.apply env ~where Profile.blank key value);
                (acc, region, lineno)
            | Applied ->
                if key = use_key then (
                  let g = find_group acc ~where value in
                  ( { acc with
                      draft =
                        List.fold_left
                          (fun d (w, k, v) -> Profile.apply env ~where:w d k v)
                          acc.draft g.body;
                      seen = acc.seen @ [ g.label ^ "[group " ^ g.name ^ "]" ] },
                    region,
                    lineno ))
                else
                  ( { acc with draft = Profile.apply env ~where acc.draft key value },
                    region,
                    lineno ))
    in
    let acc, _, _ = List.fold_left step (acc, Preamble, 0) (Lines.of_file path) in
    acc

let load env =
  let paths = [ Env.config_file env; Env.config_local_file env ] in
  if env.Env.main_root = None && List.exists Sys.file_exists paths then
    Err.warn "warning: no git repository here, so no config section in %s applies"
      env.Env.config_dir;
  let acc = List.fold_left (fun acc path -> read env ~path acc) empty paths in
  { layer = Profile.seal ~label:"config" acc.draft;
    matched = acc.seen;
    blocks = acc.profiles }

(* The layer a `-p NAME` resolves to when the config file defines it, plus the
   provenance it contributes: the block itself, then every group it spliced. *)
let block env cfg ~name =
  match List.find_opt (fun g -> g.name = name) cfg.blocks with
  | None -> None
  | Some g ->
      Some
        ( Profile.of_body env ~label:("profile " ^ name) g.body,
          (g.label ^ "[profile " ^ name ^ "]") :: g.uses )
