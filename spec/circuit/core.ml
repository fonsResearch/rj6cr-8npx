(* Threads, their timing hardware, the commit path and verdict recording: spec/model.ml from
   owned_mask to timing, in the same order. *)
open! Base
open Hardcaml
open Signal
open State
open W

let owned_mask (w : Signal.t W.t) id = concat_lsb (List.map w.c.owner ~f:(fun o -> o ==:. id))

(* record: rule k (static) has a violation of the given kind in this cycle *)
let record (ctx : ctx) (w : Signal.t W.t) k ~max_kind =
  let r = rule w k in
  let r = { r with v_max = r.v_max |: max_kind; v_min = r.v_min |: ~:max_kind } in
  let w = set_rule w k r in
  let c = w.c in
  let v = { Verdict.valid = vdd; rule = U.k 2 k; max_kind; cycle = ctx.n } in
  let set_fail = r.guarantee &: ~:(c.fail.valid) in
  let set_blame = ~:(r.guarantee) &: ~:(c.blame.valid) in
  { w with
    c =
      { c with
        fail = Verdict.map2 c.fail v ~f:(U.upd set_fail)
      ; blame_before_fail = U.upd set_fail c.blame_before_fail c.blame.valid
      ; blame = Verdict.map2 c.blame v ~f:(U.upd set_blame)
      }
  }
;;

let enter_fault (w : Signal.t W.t) id ~code ~arg =
  let own = owned_mask w id in
  map_th w id (fun t ->
    { t with
      st = U.k 3 4
    ; fcode = U.k 4 code
    ; farg = uresize arg 8
    ; fl_valid = gnd
    ; sm = own
    ; sv = w.c.safe_val &: own
    ; em = select own 7 0
    ; ev = w.c.safe_dir &: select own 7 0
    ; armed = vdd
    ; due = vdd
    ; deadline = gnd
    ; adv = gnd
    })
;;

(* edges the pending commit of a thread would put on the pad value registers *)
let proposed (w : Signal.t W.t) id =
  let t = th w id in
  let m = t.sm &: owned_mask w id in
  m &: t.sv &: ~:(w.c.value), m &: ~:(t.sv) &: w.c.value
;;

(* the model's decode_sel restricted to commit selectors: (is class 2, is class 3, pin) *)
let stop_edge sel ~rise ~fall =
  let ok = select sel 15 10 ==:. 0 &: (select sel 6 5 ==:. 0) &: (select sel 4 0 <=:. 15) in
  let cls = select sel 9 7 and idx = select sel 3 0 in
  ok &: ((cls ==:. 2 &: U.bit_at rise idx) |: (cls ==:. 3 &: U.bit_at fall idx))
;;

let blocking (w : Signal.t W.t) ~rise ~fall =
  List.map w.c.rules ~f:(fun (r : Signal.t Rule.t) ->
    r.en &: r.guarantee &: (r.policy ==:. 1 |: (r.policy ==:. 2)) &: r.active &: (r.cnt <: r.rmin)
    &: stop_edge r.sel_stop ~rise ~fall)
;;

(* first index whose condition holds, as a list of exclusive conditions *)
let first_of l =
  let _, out =
    List.fold l ~init:(gnd, []) ~f:(fun (seen, acc) c -> seen |: c, (c &: ~:seen) :: acc)
  in
  List.rev out
;;

(* may_fire, evaluated only where [cond] holds (its side effects too); returns the new state
   and whether the commit may fire *)
let may_fire ctx (w : Signal.t W.t) id ~cond =
  let rise, fall = proposed w id in
  let bs = blocking w ~rise ~fall in
  let anyb = U.any bs in
  let faulted = (th w id).st ==:. 4 in
  let p2 = List.map2_exn bs w.c.rules ~f:(fun b r -> b &: (r.policy ==:. 2)) in
  let first_p2 = first_of p2 in
  let fault_path = cond &: anyb &: U.any p2 &: ~:faulted in
  let repair_path = cond &: anyb &: ~:fault_path in
  let w =
    List.foldi first_p2 ~init:w ~f:(fun k w fk ->
      w_if (fault_path &: fk) w (fun w ->
        let w = record ctx w k ~max_kind:gnd in
        enter_fault w id ~code:8 ~arg:(U.k 8 k)))
  in
  let w =
    List.foldi bs ~init:w ~f:(fun k w b ->
      let r = rule w k in
      set_rule w k { r with repaired = r.repaired |: (repair_path &: b &: (r.policy ==:. 1)) })
  in
  w, ~:anyb
;;

(* the commit of a thread fires; its edges are events of this cycle *)
let fire (ctx : ctx) (w : Signal.t W.t) id ~staged =
  let rise, fall = proposed w id in
  let w =
    w_if staged w (fun w ->
      let t = th w id in
      let own = owned_mask w id in
      let m = t.sm &: own in
      let me = t.em &: select own 7 0 in
      let w =
        tmp w (fun x ->
          { x with
            ev_rise = x.ev_rise |: rise
          ; ev_fall = x.ev_fall |: fall
          ; value_n = x.value_n &: ~:m |: (t.sv &: m)
          ; dir_n = x.dir_n &: ~:me |: (t.ev &: me)
          })
      in
      map_th w id (fun t -> { t with sm = zero 16; em = zero 8; sv = zero 16; ev = zero 8 }))
  in
  map_th w id (fun t -> { t with cap = ctx.pv })
;;

let add_p (t : Signal.t Thread.t) =
  let total = (t.t_int @: t.t_frac) +: uresize t.p 40 in
  { t with t_int = select total 39 8; t_frac = select total 7 0 }
;;

let status (ctx : ctx) (w : Signal.t W.t) id =
  let t = th w id in
  let base =
    concat_lsb
      [ t.evf; t.in_v; ~:(t.out_v); t.late; w.c.fail.valid; w.c.blame.valid
      ; U.any (List.map w.c.rules ~f:(fun r -> r.repaired)) ]
  in
  let st = Lregs.line_status ctx.snap in
  let b i = bit st i in
  let line =
    concat_lsb [ b 0; b 2; b 4; b 3; select st 10 6 <>:. 0; b 12; b 13 ]
    &: repeat (w.c.line.owner ==:. id) 7
  in
  concat_lsb [ base; line; zero 2 ]
;;

(* timing hardware of one thread in this cycle *)
let timing (ctx : ctx) (w : Signal.t W.t) id =
  let t0 = th w id in
  let reach = t0.t_int ==: ctx.e in
  (* the armed commit *)
  let due1 = t0.due |: (t0.deadline &: reach) in
  let w = map_th w id (fun t -> { t with due = U.upd t0.armed t.due due1 }) in
  let cond = t0.armed &: due1 in
  let w, ok = may_fire ctx w id ~cond in
  let go = cond &: ok in
  let w =
    w_if go w (fun w ->
      let w = fire ctx w id ~staged:vdd in
      map_th w id (fun t ->
        let t = { t with armed = gnd; due = gnd } in
        let t' = { t with t_int = ctx.e } in
        let t'' = Thread.map2 t' (add_p t') ~f:(U.upd t.adv) in
        Thread.map2 t t'' ~f:(U.upd t.deadline)))
  in
  (* the event wait *)
  let t1 = th w id in
  let waiting = t1.st ==:. 2 in
  let cur = U.bit_at ctx.pv t1.w_idx and prev = U.bit_at ctx.pv_prev t1.w_idx in
  let pin_hit =
    mux t1.w_cond [ ~:cur; cur; ~:prev &: cur; prev &: ~:cur ]
  in
  let st_hit = U.bit_at (status ctx w id) (select t1.w_idx 3 0) ==: lsb t1.w_cond in
  let hit = mux2 t1.w_pin pin_hit st_hit in
  let wd_new = mux2 hit (U.k 2 1) (mux2 (t1.w_to &: reach) (U.k 2 2) (U.k 2 0)) in
  let wd = mux2 (t1.w_due ==:. 0) wd_new t1.w_due in
  let w = map_th w id (fun t -> { t with w_due = U.upd waiting t.w_due wd }) in
  let pending = waiting &: (wd <>:. 0) in
  let with_commit = wd ==:. 2 |: t1.w_cm in
  let w, ok = may_fire ctx w id ~cond:(pending &: with_commit) in
  let go = pending &: (~:with_commit |: ok) in
  w_if go w (fun w ->
    let w = fire ctx w id ~staged:with_commit in
    map_th w id (fun t ->
      let ev_seen = wd ==:. 1 in
      let t_ev = { t with evf = vdd } in
      let t_ev = Thread.map2 t_ev { t_ev with t_int = ctx.e; t_frac = zero 8 } ~f:(U.upd t.w_re) in
      let t_to = { t with evf = gnd; t_int = ctx.e } in
      let t = Thread.map2 t_to t_ev ~f:(U.upd ev_seen) in
      let t = Thread.map2 t (add_p t) ~f:(U.upd t1.w_adv) in
      { t with st = U.k 3 1 }))
;;
