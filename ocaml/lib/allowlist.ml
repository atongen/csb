(* Host allowlist for the egress proxy: exact names and *.suffix wildcards.
   Matching is case-insensitive and ignores a trailing dot. *)

type entry =
  | Exact of string
  | Suffix of string (* "*.example.com" is stored as "example.com" *)

type t = entry list

let normalize h =
  let h = String.lowercase_ascii (String.trim h) in
  let n = String.length h in
  if n > 0 && h.[n - 1] = '.' then String.sub h 0 (n - 1) else h

let entry_of_line line =
  let line = String.trim line in
  if line = "" || line.[0] = '#' then None
  else
    let h = normalize line in
    if String.length h > 2 && String.sub h 0 2 = "*." then
      Some (Suffix (String.sub h 2 (String.length h - 2)))
    else Some (Exact h)

let of_lines lines = List.filter_map entry_of_line lines

let of_file path =
  let ic = open_in path in
  let rec read acc =
    match input_line ic with
    | line -> read (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = read [] in
  close_in ic;
  of_lines lines

(* "*.example.com" covers foo.example.com but not example.com itself; list both
   when both are wanted. *)
let under_suffix host suffix =
  let hl = String.length host and sl = String.length suffix in
  hl > sl + 1
  && String.sub host (hl - sl) sl = suffix
  && host.[hl - sl - 1] = '.'

let matches t host =
  let host = normalize host in
  List.exists
    (function Exact h -> h = host | Suffix s -> under_suffix host s)
    t

(* An IP literal bypasses a name-based allowlist, so the proxy refuses one unless
   the literal itself is listed. *)
let is_ip_literal h =
  h <> ""
  && (String.contains h ':'
     || String.for_all (fun c -> (c >= '0' && c <= '9') || c = '.') h)
