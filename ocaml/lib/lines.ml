(* Read a text file as its lines, with or without a trailing newline. *)

let of_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])
