(* The file layers under the command line, and the axis folds that both a launch
   and a completion read from them.

   One -p resolves from whichever source defines it. A name defined BOTH as a
   file under profiles/ and as a [profile NAME] block is refused rather than
   ranked: two launch configs answering to one name is a mistake in the
   configuration, and picking one silently is how the wrong sandbox gets
   built. *)

let one_profile env config name =
  match (Config_file.block env config ~name, Profile.has_file env ~name) with
  | Some _, true ->
      Err.die
        "profile '%s' is defined twice: %s and a [profile %s] block in the config file"
        name (Profile.file env ~name) name
  | Some (layer, seen), false -> (layer, seen)
  | None, true -> (Profile.load env ~name, [])
  | None, false ->
      Err.die "profile not found: %s (nor a [profile %s] block in the config file)"
        (Profile.file env ~name) name

(* Every -p in turn, each its own layer folded onto the ones before it. *)
let profiles env config names =
  List.fold_left
    (fun (layer, seen) name ->
      let over, from_config = one_profile env config name in
      (Profile.overlay ~base:layer ~over, seen @ from_config))
    (Profile.empty, []) names

(* Config below the profiles: the two file layers as one. *)
let stack (config : Config_file.t) profile =
  Profile.overlay ~base:config.Config_file.layer ~over:profile

let opt_or higher lower = match higher with Some _ -> higher | None -> lower

let bool_layer ~cli ~profile ~default = Option.value (opt_or cli profile) ~default

let shell ~cli (layers : Profile.t) = bool_layer ~cli ~profile:layers.shell ~default:false

let agent ~cli (layers : Profile.t) =
  Option.value (Layer.value (Layer.over cli layers.agent)) ~default:Types.Claude
