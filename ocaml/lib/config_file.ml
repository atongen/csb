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
   a selector can only collect repos that share a path shape. *)

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
   a use from config.local still reports where the lines came from. *)
type group = {
  name : string;
  label : string;
  body : (string * string * string) list; (* where, key, value *)
}

type header = Group_def of string | Select of term_set

(* Accumulating across both files, then the one sealed layer they amount to. *)
type acc = {
  draft : Profile.draft;
  seen : string list; (* file[selector], in application order *)
  groups : group list;
}

type t = {
  layer : Profile.t;
  matched : string list;
}

let empty = { draft = Profile.blank; seen = []; groups = [] }

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

(* [group NAME] can never collide with a selector: a selector is matched against
   an absolute path, which no leading keyword can begin. *)
let group_name_of s =
  let n = String.length group_keyword in
  if s = group_keyword then Some ""
  else if
    String.length s > n
    && String.sub s 0 n = group_keyword
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
    match group_name_of s with
    | Some "" -> Err.die "%s: [group] needs a name" where
    | Some name -> Group_def (Validate.group_name ~where name)
    | None -> Select (parse_terms env ~where s)

let extend_group groups name entry =
  List.map
    (fun g -> if g.name = name then { g with body = g.body @ [ entry ] } else g)
    groups

(* A forward reference and a typo are the same mistake here -- the group has to
   be defined above the line that uses it -- so they share one message. *)
let find_group acc ~where name =
  if name = "" then Err.die "%s: use= needs a group name" where;
  match List.find_opt (fun g -> g.name = name) acc.groups with
  | Some g -> g
  | None -> Err.die "%s: no [group %s] defined above this line" where name

let use_key = "use"

(* A section is one of four states, and only two of them keep anything: the
   region before any header holds no selector at all, and a non-matching section
   is still parsed so a typo in one repo's section cannot hide until that repo is
   the one being launched. *)
type region = Preamble | Skipped | Applied | Defining of string

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
                ( { acc with groups = acc.groups @ [ { name; label; body = [] } ] },
                  Defining name,
                  lineno )
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
  { layer = Profile.seal ~label:"config" acc.draft; matched = acc.seen }
