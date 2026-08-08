(* ~/.config/csb/config, then the gitignored ~/.config/csb/config.local: the
   repo-selected layer between the built-in defaults and a named profile.

   The files are the profile grammar plus [SELECTOR] section headers. Every
   section whose selector matches the physical main checkout root applies, in
   DOCUMENT order -- config in full, then config.local, top to bottom -- so a
   scalar goes to the last matching section that sets it and lists union across
   all of them. --dump-config reports which sections matched, because a selector
   that matches nothing is otherwise indistinguishable from one that matches. *)

type t = {
  layer : Profile.t;
  matched : string list; (* file[selector], in application order *)
}

let empty = { layer = Profile.empty; matched = [] }

(* '*' matches any run of characters, INCLUDING '/', and is the only
   metacharacter. That one rule covers all three shapes: [*] is everything,
   [*work*] and [*/csb] are patterns, and a selector without '*' is an exact
   path. *)
let rec matches pat i s k =
  if i = String.length pat then k = String.length s
  else if pat.[i] = '*' then
    matches pat (i + 1) s k || (k < String.length s && matches pat i s (k + 1))
  else k < String.length s && pat.[i] = s.[k] && matches pat (i + 1) s (k + 1)

let selector_of line =
  let n = String.length line in
  if n >= 2 && line.[0] = '[' && line.[n - 1] = ']' then Some (String.sub line 1 (n - 2))
  else None

(* A section is one of three states, and only the third contributes: the region
   before any header holds no selector at all, and a non-matching section is
   still parsed so a typo in one repo's section cannot hide until that repo is
   the one being launched. *)
type region = Preamble | Skipped | Applied

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
        match selector_of line with
        | Some "" -> Err.die "%s: [] selects nothing (use [*] for every repo)" where
        | Some sel ->
            let pattern = Env.expand_tilde env sel in
            let hit =
              match env.Env.main_root with
              | Some root -> matches pattern 0 root 0
              | None -> false
            in
            let acc =
              if hit then { acc with matched = acc.matched @ [ label ^ "[" ^ sel ^ "]" ] }
              else acc
            in
            (acc, (if hit then Applied else Skipped), lineno)
        | None -> (
            match region with
            | Preamble ->
                Err.die "%s: KEY=VALUE outside a [SELECTOR] section: '%s'" where line
            | Skipped ->
                ignore (Profile.apply_line env ~where Profile.empty line);
                (acc, region, lineno)
            | Applied ->
                ({ acc with layer = Profile.apply_line env ~where acc.layer line },
                 region, lineno))
    in
    let acc, _, _ = List.fold_left step (acc, Preamble, 0) (Lines.of_file path) in
    acc

let load env =
  let paths = [ Env.config_file env; Env.config_local_file env ] in
  if env.Env.main_root = None && List.exists Sys.file_exists paths then
    Err.warn "warning: no git repository here, so no config section in %s applies"
      env.Env.config_dir;
  let acc = List.fold_left (fun acc path -> read env ~path acc) empty paths in
  { acc with layer = Profile.checked ~label:"config" acc.layer }
