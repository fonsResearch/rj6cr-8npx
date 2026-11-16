(* A campaign: many lockstep sessions of one kind. *)
open Lockstep

(* [runs] sessions; prints totals, the coverage summed over them and any mismatch *)
let scenario ~name ~seed ~runs (o : Stim.opts) =
  let total = create () in
  let cycles = ref 0 and bad = ref 0 and conflicts = ref 0 and mem = ref 0 in
  for r = 1 to runs do
    Random.init ((seed * 1000) + r);
    let t = create () in
    Stim.run t ~loopback:(o.frames || o.directed) ~usb:o.directed (Stim.session o);
    let pd, dd = memories_equal t in
    cycles := !cycles + t.cycles;
    bad := !bad + List.length t.mismatches;
    conflicts := !conflicts + t.port_conflicts;
    mem := !mem + pd + dd;
    if t.mismatches <> [] || pd + dd > 0 || t.port_conflicts > 0
    then (
      Printf.printf "%s run %d: " name r;
      report t);
    Hashtbl.iter (fun k v -> Hashtbl.replace total.cov k (v + Option.value ~default:0 (Hashtbl.find_opt total.cov k))) t.cov
  done;
  Printf.printf "%s: %d runs, %d cycles, %d mismatches, %d port conflicts, %d memory words differ\n" name runs !cycles
    !bad !conflicts !mem;
  coverage ~ops:true total
;;

