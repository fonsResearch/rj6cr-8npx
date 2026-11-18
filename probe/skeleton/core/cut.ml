(* The structural changes of the skeleton (../README.md). SKEL_CUT (comma separated) adds
   block removals for size points of the skeleton gate: rules, line, peek, trace. *)
let cuts =
  [ "shared"; "peek1" ]
  @ (match Stdlib.Sys.getenv_opt "SKEL_CUT" with
     | None | Some "" -> []
     | Some s -> String.split_on_char ',' s)
;;

let on k = List.mem k cuts
