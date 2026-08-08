(* The process environment csb reads: HOME, the XDG config root, and the three
   CSB_* knobs --dump-config reports. Captured once so resolution downstream is
   a function of this record rather than of global state. *)

type t = {
  home : string;
  config_dir : string;  (* $XDG_CONFIG_HOME/csb, else ~/.config/csb *)
  latest : bool;        (* CSB_LATEST non-empty *)
  verbose : bool;       (* CSB_VERBOSE non-empty *)
  tmpdir : string option;  (* CSB_TMPDIR, as given *)
  (* CSB_MAIN_ROOT: the physical main checkout root the config sections are
     selected by. bin/csb derives it from git and passes it in, so repo identity
     has one implementation and this stays a function of its inputs. Absent
     outside a repository, where no section matches. *)
  main_root : string option;
}

let getenv_nonempty name =
  match Sys.getenv_opt name with None | Some "" -> None | Some v -> Some v

let of_process () =
  let home = Option.value (Sys.getenv_opt "HOME") ~default:"" in
  let config_dir =
    match getenv_nonempty "XDG_CONFIG_HOME" with
    | Some d -> Filename.concat d "csb"
    | None -> Filename.concat (Filename.concat home ".config") "csb"
  in
  {
    home;
    config_dir;
    latest = getenv_nonempty "CSB_LATEST" <> None;
    verbose = getenv_nonempty "CSB_VERBOSE" <> None;
    tmpdir = getenv_nonempty "CSB_TMPDIR";
    main_root = getenv_nonempty "CSB_MAIN_ROOT";
  }

let profiles_dir env = Filename.concat env.config_dir "profiles"
let allowed_hosts_file env = Filename.concat env.config_dir "allowed-hosts"
let config_file env = Filename.concat env.config_dir "config"
let config_local_file env = config_file env ^ ".local"

(* Expand a LITERAL leading ~/ against HOME; every other value passes through. *)
let expand_tilde env v =
  let n = String.length v in
  if n >= 2 && v.[0] = '~' && v.[1] = '/' then
    Filename.concat env.home (String.sub v 2 (n - 2))
  else v

(* CSB_TMPDIR becomes the launched process's TMPDIR, its ephemeral HOME base and
   a write root, so it must exist and is stored resolved. *)
let resolve_tmpdir env =
  match env.tmpdir with
  | None -> None
  | Some raw ->
      let v = expand_tilde env raw in
      if not (Sys.file_exists v && Sys.is_directory v) then
        Err.die "CSB_TMPDIR does not exist or is not a directory: '%s'" v;
      Some (Unix.realpath v)
