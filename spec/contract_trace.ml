(* Per-cycle record of one deadline commit, without and with a hold-to-minimum rule, for the
   timing-contract figure (doc/spec/fig/timing_contract.png). Every column is the value a
   register has during cycle n, read before the cycle is stepped; "stage" is what thread 0
   does in cycle n: F fetch, D decode, M data-memory access, X execute, W execute cycle of an
   instruction that has to wait and is fetched again (in this program only HALT, which waits
   for the armed commit). *)
open Spec

let lines = [| "TNOW 8"; "PINV 1, 9 @at"; "TADDI 6"; "PINV 0, 9 @at"; "HALT" |]
let src = String.concat "\n" (Array.to_list lines)

let scenario name ~rule =
  let chip = Model.create () in
  let words = Asm.assemble src in
  Model.set_window chip 0 ~pbase:0 ~psize:(Array.length words) ~dbase:0 ~dsize:256;
  assert (Model.load_thread chip 0 words);
  Model.set_owner chip 9 0;
  if rule
  then Model.set_rule chip 0 ~policy:1 ~min:12 ~start:(Model.sel 2 9) ~stop:(Model.sel 3 9) ();
  Model.start chip 0 ~pc:0;
  let th = chip.th.(0) in
  for _ = 1 to 30 do
    let n = chip.now in
    let pc = th.pc in
    let before = th.flight in
    let armed = th.armed and due = th.due and t_int = th.t_int in
    let pad = (Model.uo_out chip lsr 1) land 1 in
    (* the rule state the commit check of this cycle uses: the registers after the automaton's
       step of the previous cycle (V3, v1.1) *)
    let fw = Model.copy_chip chip in
    Model.rules_step fw;
    let active = fw.rules.(0).active and cnt = fw.rules.(0).cnt in
    let state =
      match th.state with
      | Idle -> "idle"
      | Run -> "run"
      | Wait_ev -> "wait"
      | Halted -> "halted"
      | Faulted _ -> "fault"
    in
    Model.step chip ~pad:0;
    let stage =
      match before, th.flight with
      | Some (c, _), _ when n - c = 3 -> if th.pc = pc && th.state = Run then "W" else "X"
      | Some (c, _), _ when n - c = 2 -> "M"
      | Some (c, _), _ when n - c = 1 -> "D"
      | None, Some (c, _) when c = n -> "F"
      | _ -> "-"
    in
    let instr = if stage = "-" then "" else lines.(pc) in
    Printf.printf "%s,%d,%d,%s,\"%s\",%d,%d,%d,%d,%d,%d,%s\n" name n (n land 3) stage instr (Bool.to_int armed)
      (Bool.to_int due) t_int pad (Bool.to_int active) cnt state
  done
;;

let () =
  print_endline "scenario,cycle,slot,stage,instruction,armed,due,t,pad,rule_active,rule_count,state";
  scenario "free" ~rule:false;
  scenario "hold" ~rule:true
;;
