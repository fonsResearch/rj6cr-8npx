(* The rule engine at the end of the cycle (model: rules_update). *)
open! Base
open Hardcaml
open Signal
open State
open W

let rules_update (ctx : ctx) (w : Signal.t W.t) =
  let pv = ctx.pv and pp = ctx.pv_prev in
  let wire_rise = pv &: ~:pp and wire_fall = pp &: ~:pv in
  (* oe during cycle now - j: j = 0 this cycle, j >= 1 from the history *)
  let oe_at j = if j = 0 then ctx.oe0 else U.nth w.c.oe_hist (j - 1) in
  let peer pin =
    (* pin is a 5-bit signal *)
    let for_low =
      List.init 8 ~f:(fun p ->
        let f = U.nth w.c.filt p in
        let quiet fv = U.all (List.map [ 1; 2; 3; 4 ] ~f:(fun k -> ~:(bit (oe_at (k + fv)) p))) in
        mux f [ quiet 0; quiet 1; quiet 2; quiet 3 ])
    in
    mux2 (pin >=:. 16) vdd (mux2 (pin >=:. 8) gnd (U.get_at for_low (select pin 2 0) ~default:gnd))
  in
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
      &: U.bit_at (mux2 (cls ==:. 2) w.t.ev_rise w.t.ev_fall) idx
    in
    let c5 =
      cls ==:. 5 &: (q ==:. 0) &: (r.owner <=:. 2) &: w.t.em_v &: (w.t.em_t ==: r.owner)
      &: (w.t.em_c ==: uresize idx 8)
    in
    let c6 = cls ==:. 6 &: (q ==:. 0) &: (idx <=:. 10) &: U.bit_at w.t.l_ev idx in
    ok_hi &: (c01 |: c23 |: c5 |: c6)
  in
  let results =
    List.map w.c.rules ~f:(fun (r : Signal.t Rule.t) ->
      let mask = mux r.ps [ U.k 16 0; U.k 16 0xF; U.k 16 0xFF; U.k 16 0xFFF ] in
      let tick = select ctx.n 15 0 &: mask ==: mask in
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
          active = r.en &: (active1 |: start)
        ; cnt = U.upd r.en r.cnt (mux2 start (uresize tick 16) (mux2 cont cnt1 r.cnt))
        ; obs_min = U.upd (r.en &: stop) r.obs_min (U.umin r.obs_min r.cnt)
        ; obs_max = U.upd (r.en &: stop) r.obs_max (U.umax r.obs_max r.cnt)
        }
      in
      r', r.en &: over, r.en &: v_min)
  in
  let w = { w with c = { w.c with rules = List.map results ~f:(fun (r, _, _) -> r) } } in
  (* violations in rule order: verdict, then fail-stop of the owner *)
  List.foldi results ~init:w ~f:(fun k w (_, v_max, v_min) ->
    let v = v_max |: v_min in
    w_if v w (fun w ->
      let w = Core.record ctx w k ~max_kind:v_max in
      let r = rule w k in
      List.fold (List.range 0 3) ~init:w ~f:(fun w id ->
        let t = th w id in
        let go = r.policy ==:. 2 &: (r.owner ==:. id) &: ~:(t.st ==:. 4) &: ~:(t.st ==:. 0) in
        w_if go w (fun w -> Core.enter_fault w id ~code:8 ~arg:(U.k 8 k)))))
;;
