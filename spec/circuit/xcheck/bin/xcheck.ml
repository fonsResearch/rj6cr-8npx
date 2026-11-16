(* Long lockstep campaigns: xcheck.exe <scenario> <seed> <runs>
   scenario: core | rules | frames | fuzz *)
open Spec_xcheck

let () =
  let kind = Sys.argv.(1) and seed = int_of_string Sys.argv.(2) and runs = int_of_string Sys.argv.(3) in
  let o : Stim.opts =
    match kind with
    | "core" -> { rules = false; trace = false; line = false; fuzz = false; frames = false; directed = false; run = 30 }
    | "rules" -> { rules = true; trace = true; line = false; fuzz = false; frames = false; directed = false; run = 30 }
    | "frames" -> { rules = true; trace = true; line = false; fuzz = false; frames = true; directed = false; run = 40 }
    | "fuzz" -> { rules = true; trace = true; line = true; fuzz = true; frames = false; directed = false; run = 40 }
    | "directed" -> { rules = false; trace = true; line = false; fuzz = false; frames = false; directed = true; run = 20 }
    | _ -> failwith "scenario: core | rules | frames | fuzz | directed"
  in
  Campaign.scenario ~name:kind ~seed ~runs o
;;
