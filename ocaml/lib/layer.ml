(* One layer's answer for one key: silent, retracted, or given.

   `over` is the whole precedence rule -- associative with Unset as its identity,
   so any number of layers fold in one direction and no key needs its own
   ranking. Booleans deliberately do NOT use this type: for a bool, Cleared and
   Set false are the same state, and `bool option` cannot express the difference
   that does not exist. *)

type 'a t =
  | Unset
  | Cleared
  | Set of 'a

let over hi lo = match hi with Unset -> lo | Cleared | Set _ -> hi
let value = function Set v -> Some v | Unset | Cleared -> None
let named = function Unset -> false | Cleared | Set _ -> true
