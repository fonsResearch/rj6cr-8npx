(* The rule engine (V3, v1.1). [capture], at the end of cycle n: the events of cycle n are
   registered. [rules_step], at the start of cycle n + 1: the automaton step of cycle n on them, with
   its verdicts first in the merge of this cycle. [rule_faults], after the threads: the fail-stops
   that step found. Model: rule_inputs, rules_step, rule_faults. *)
open! Base
open Hardcaml
open Signal
open State
open W

(* P0..P7: whether an edge read now is the peer's (model: rule_inputs) *)
let peer_mask (ctx : ctx) (w : Signal.t W.t) =
  (* oe during cycle now - j: j = 0 this cycle, j >= 1 from the history *)
  let oe_at j = if j = 0 then ctx.oe0 else U.nth w.c.oe_hist (j - 1) in
  concat_lsb
    (List.init 8 ~f:(fun p ->
       let f = U.nth w.c.filt p in
       let quiet fv = U.all (List.map [ 1; 2; 3; 4 ] ~f:(fun k -> ~:(bit (oe_at (k + fv)) p))) in
       mux f [ quiet 0; quiet 1; quiet 2; quiet 3 ]))
;;

let capture (ctx : ctx) (w : Signal.t W.t) =
  { w with
    c =
      { w.c with
        ri_valid = vdd
      ; ri_pp = ctx.pv_prev
      ; ri_peer = peer_mask ctx w
      ; ri_rise = w.t.ev_rise
      ; ri_fall = w.t.ev_fall
      ; ri_lev = w.t.l_ev
      }
  }
;;

(* returns the state and, per rule, per thread, whether the step faults that thread *)
let rules_step (ctx : ctx) (w : Signal.t W.t) =
  let c = w.c in
  let on = c.ri_valid in
  let n1 = ctx.n -:. 1 in
  let wire_rise = c.pv_prev &: ~:(c.ri_pp) and wire_fall = c.ri_pp &: ~:(c.pv_prev) in
  let peer pin =
    (* pin is a 5-bit signal *)
    mux2 (pin >=:. 16) vdd (mux2 (pin >=:. 8) gnd (U.bit_at c.ri_peer (select pin 2 0)))
  in
  let tr = c.trace in
  let event (r : Signal.t Rule.t) sel =
    let ok_hi = select sel 15 10 ==:. 0 in
    let cls = select sel 9 7 and q = select sel 6 5 and idx = select sel 4 0 in
    let c01 =
      (cls ==:. 0 |: (cls ==:. 1)) &: (idx <=:. 23) &: (q <=:. 2)
      &: U.bit_at (mux2 (cls ==:. 0) wire_rise wire_fall) idx
      &: (q ==:. 0 |: ((q ==:. 1) ==: peer idx))
    in
    let c23 =
      (cls ==:. 2 |: (cls ==:. 3)) &: (idx <=:. 15) &: (q ==:. 0)
      &: U.bit_at (mux2 (cls ==:. 2) c.ri_rise c.ri_fall) idx
    in
    let c5 =
      cls ==:. 5 &: (q ==:. 0) &: (r.owner <=:. 2) &: tr.em_v &: (tr.em_t ==: r.owner)
      &: (tr.em_c ==: uresize idx 8)
    in
    let c6 = cls ==:. 6 &: (q ==:. 0) &: (idx <=:. 10) &: U.bit_at c.ri_lev idx in
    ok_hi &: (c01 |: c23 |: c5 |: c6)
  in
  let results =
    List.map c.rules ~f:(fun (r : Signal.t Rule.t) ->
      let mask = mux r.ps [ U.k 16 0; U.k 16 0xF; U.k 16 0xFF; U.k 16 0xFFF ] in
      let tick = select n1 15 0 &: mask ==: mask in
      let start_ev = event r r.sel_start and stop_ev = event r r.sel_stop and abort_ev = event r r.sel_abort in
      let a = r.active in
      let over = a &: ~:abort_ev &: (r.cnt >: r.rmax) in
      let stop = a &: ~:abort_ev &: ~:(r.cnt >: r.rmax) &: stop_ev in
      let cont = a &: ~:abort_ev &: ~:(r.cnt >: r.rmax) &: ~:stop_ev in
      let v_min = stop &: (r.cnt <: r.rmin) in
      let cnt1 = mux2 (r.cnt ==:. 0xFFFF) r.cnt (r.cnt +: uresize tick 16) in
      let active1 = a &: cont in
      let start = ~:active1 &: start_ev in
      let r' =
        { r with
          active = U.upd on r.active (r.en &: (active1 |: start))
        ; cnt = U.upd (on &: r.en) r.cnt (mux2 start (uresize tick 16) (mux2 cont cnt1 r.cnt))
        ; obs_min = U.upd (on &: r.en &: stop) r.obs_min (U.umin r.obs_min r.cnt)
        ; obs_max = U.upd (on &: r.en &: stop) r.obs_max (U.umax r.obs_max r.cnt)
        }
      in
      r', on &: r.en &: over, on &: r.en &: v_min)
  in
  let w = { w with c = { w.c with rules = List.map results ~f:(fun (r, _, _) -> r) } } in
  (* violations in rule order; the verdict carries the cycle of the events *)
  let w =
    List.foldi results ~init:w ~f:(fun k w (_, v_max, v_min) ->
      w_if (v_max |: v_min) w (fun w -> Core.record ~cycle:n1 ctx w k ~max_kind:v_max))
  in
  let faults =
    List.mapi results ~f:(fun k (_, v_max, v_min) ->
      let r = rule w k in
      List.init 3 ~f:(fun id -> (v_max |: v_min) &: (r.policy ==:. 2) &: (r.owner ==:. id)))
  in
  w, faults
;;

(* after the threads' own update: a thread that faulted or stopped on its own keeps that *)
let rule_faults faults (w : Signal.t W.t) =
  List.foldi faults ~init:w ~f:(fun k w per_thread ->
    List.foldi per_thread ~init:w ~f:(fun id w go ->
      let t = th w id in
      let go = go &: ~:(t.st ==:. 4) &: ~:(t.st ==:. 0) in
      w_if go w (fun w -> Core.enter_fault w id ~code:8 ~arg:(U.k 8 k))))
;;
