(* One clock cycle of the chip (model: step), in the model's order. *)
open! Base
open Hardcaml
open Signal
open State
open W

let trace_cycle (ctx : ctx) (w : Signal.t W.t) ~slot_free =
  let tr = w.c.trace in
  let on = tr.en &: (tr.size >:. 0) in
  let wr = on &: (tr.widx <:. 4) &: (select ctx.n 1 0 ==:. 1) &: slot_free in
  let addr = tr.base +: uresize (sll (uresize tr.ptr 10) 2) 10 +: uresize tr.widx 10 in
  let w = data_req w ~en:wr ~wen:vdd ~addr ~din:(U.get_at tr.rec_ (select tr.widx 1 0) ~default:(zero 16)) in
  let widx1 = tr.widx +:. 1 in
  let done_ = wr &: (widx1 ==:. 4) in
  let ptr1 = uresize tr.ptr 9 +:. 1 in
  let wrapq = ptr1 >=: tr.size in
  let tr =
    { tr with
      widx = U.upd wr tr.widx widx1
    ; ptr = U.upd done_ tr.ptr (mux2 wrapq (zero 8) (select ptr1 7 0))
    ; wrapped = tr.wrapped |: (done_ &: wrapq)
    ; left = U.upd (done_ &: tr.trig &: (tr.left >:. 0)) tr.left (tr.left -:. 1)
    }
  in
  let trig_set = on &: tr.freeze &: (w.c.fail.valid |: w.c.blame.valid) &: ~:(tr.trig) in
  let tr = { tr with trig = tr.trig |: trig_set; left = U.upd trig_set tr.left tr.post } in
  let tr = { tr with frozen = tr.frozen |: (on &: tr.trig &: (tr.left ==:. 0) &: (tr.widx ==:. 4)) } in
  let rec_on = on &: ~:(tr.frozen) in
  let changed = (ctx.pv ^: ctx.pv_prev) &: tr.mask <>:. 0 in
  let em = w.t.em_v in
  let busy = tr.widx <:. 4 in
  let lost_busy = rec_on &: busy &: (changed |: em) in
  let new_rec = rec_on &: ~:busy &: (changed |: em |: tr.lost) in
  let pin_record = changed |: ~:em in
  let lost' = tr.lost |: (changed &: em) in
  let w3 =
    concat_msb
      [ lost'
      ; mux2 pin_record (zero 7 @: select ctx.pv 23 16)
          (concat_msb [ vdd; w.t.em_t; zero 4; w.t.em_c ])
      ]
  in
  let tr =
    { tr with
      lost = U.upd new_rec (tr.lost |: lost_busy) gnd
    ; rec_ =
        List.map2_exn tr.rec_ [ select ctx.n 15 0; select ctx.n 31 16; select ctx.pv 15 0; w3 ] ~f:(U.upd new_rec)
    ; widx = U.upd new_rec tr.widx (zero 3)
    }
  in
  { w with c = { w.c with trace = tr } }
;;

(* the registers as the model holds them after the previous cycle: read data of the
   synchronous memories enters where the model has it already *)
let effective (s : Signal.t Chip.t) ~prog_dout ~data_dout =
  let slot = select s.now 1 0 in
  let th =
    List.mapi s.th ~f:(fun id t ->
      let got = t.fl_valid &: ~:(t.fl_pcb) &: (slot ==:. (id + 1) land 3) in
      { t with fl_word = U.upd got t.fl_word prog_dout })
  in
  let h = s.host in
  let rbuf = mux2 h.rd_p prog_dout (mux2 h.rd_d (uresize data_dout 32) h.rbuf) in
  let l = s.line in
  let t_next = mux2 l.t_rd data_dout l.t_next in
  { s with th; host = { h with rbuf; rd_p = gnd; rd_d = gnd }; line = { l with t_next; t_rd = gnd } }
;;

let step (s : Signal.t Chip.t) ~pad ~prog_dout ~data_dout =
  let c = effective s ~prog_dout ~data_dout in
  let n = c.now in
  let slot = select n 1 0 in
  (* synchroniser and glitch filter: s(n) from x(n-1) *)
  let in_pin q = q < 8 || q >= 16 in
  let fl =
    List.init 24 ~f:(fun q ->
      if not (in_pin q)
      then gnd, U.nth c.fcnt q
      else (
        let xb = bit c.x q and sb = bit c.s q in
        let f1 = uresize (U.nth c.fcnt q) 3 +:. 1 in
        let toggle = (xb <>: sb) &: (f1 >: uresize (U.nth c.filt q) 3) in
        let fc = mux2 (xb ==: sb) (zero 2) (mux2 toggle (zero 2) (select f1 1 0)) in
        toggle, fc))
  in
  let s_new = c.s ^: concat_lsb (List.map fl ~f:fst) in
  let in_mask = U.k 24 0xFF00FF in
  let s_new = s_new &: in_mask in
  let c = { c with s = s_new; x = pad &: in_mask; fcnt = List.map fl ~f:snd } in
  let pv = s_new |: (uresize (select c.value 15 8) 24 |> fun x -> sll x 8) in
  let oe0 = c.dir &: ~:(c.od &: select c.value 7 0) in
  let ctx = { n; e = n +:. 1; pv; pv_prev = c.pv_prev; oe0; snap = c.line; prog_dout; data_dout } in
  let t0 = Tmp.map Tmp.port_names_and_widths ~f:(fun (_, wd) -> zero wd) in
  let t0 = { t0 with value_n = c.value; dir_n = c.dir } in
  let w = { W.c; t = t0 } in
  let w = Linep.line_cycle ctx w in
  let w =
    List.fold (List.range 0 3) ~init:w ~f:(fun w id ->
      (* fetch, on the state the thread has during this cycle *)
      let t = th w id in
      let fetch = t.st ==:. 1 &: (slot ==:. id) &: ~:(t.fl_valid) in
      let pcb = t.pc >=: t.psize in
      let w = map_th w id (fun t -> { t with fl_valid = t.fl_valid |: fetch; fl_pcb = U.upd fetch t.fl_pcb pcb }) in
      let w = prog_req w ~en:(fetch &: ~:pcb) ~wen:gnd ~addr:(select (uresize t.pbase 10 +: t.pc) 8 0) ~din:(zero 32) in
      (* cycle c+2: the data memory access *)
      let t = th w id in
      let at_mem = t.fl_valid &: ~:(t.fl_pcb) &: (slot ==:. (id + 2) land 3) in
      let d = Dec.decode t.fl_word in
      let rr i = mux i t.r in
      let module I = Spec.Isa in
      let ea =
        U.oh_mux ~width:16
          [ d.is I.Ld, uresize (d.f I.Ld "addr") 16
          ; d.is I.St, uresize (d.f I.St "addr") 16
          ; d.is I.Ldx, rr (d.f I.Ldx "ra") +: uresize (d.f I.Ldx "off") 16
          ; d.is I.Stx, rr (d.f I.Stx "ra") +: uresize (d.f I.Stx "off") 16
          ]
      in
      let is_ld = d.is I.Ld |: d.is I.Ldx and is_st = d.is I.St |: d.is I.Stx in
      let inwin = uresize ea 17 <: uresize t.dsize 17 in
      let go = at_mem &: (is_ld |: is_st) &: inwin in
      let rs = mux2 (d.is I.St) (d.f I.St "rs") (d.f I.Stx "rs") in
      let w = data_req w ~en:go ~wen:is_st ~addr:(t.dbase +: select ea 9 0) ~din:(rr rs) in
      (* timing events first; an instruction in its execute cycle sees their result *)
      let w = Core.timing ctx w id in
      let ex = (th w id).fl_valid &: (slot ==:. (id + 3) land 3) in
      w_if ex w (fun w -> Exec.execute ctx w id))
  in
  (* while the line unit transmits, its pins follow it and not the commits of a thread *)
  let w =
    tmp w (fun x ->
      let m = x.l_mask and v = x.l_val in
      let m8 = select m 7 0 in
      { x with
        ev_rise = x.ev_rise &: ~:m |: (m &: v &: ~:(w.c.value))
      ; ev_fall = x.ev_fall &: ~:m |: (m &: ~:v &: w.c.value)
      ; value_n = x.value_n &: ~:m |: v
      ; dir_n = x.dir_n &: ~:m8 |: (x.l_dir &: m8)
      })
  in
  let w = Rules.rules_update ctx w in
  let h = w.c.host in
  let host_uses = h.rq_v &: ~:(h.rq_prog) &: (slot ==:. 1) &: ~:(w.t.l_slot) in
  let w = Hostp.host_cycle ctx w ~slot_free:~:(w.t.l_slot) in
  let w = trace_cycle ctx w ~slot_free:~:(host_uses |: w.t.l_slot) in
  let c = w.c in
  let oe_hist = ctx.oe0 :: List.take c.oe_hist 6 in
  (* pins without a thread as owner hold the safe pattern *)
  let u = concat_lsb (List.mapi c.owner ~f:(fun q o -> if q = 8 then gnd else o >:. 2)) in
  let value = w.t.value_n &: ~:u |: (c.safe_val &: u) in
  let value = select value 15 9 @: c.host.miso @: select value 7 0 in
  let u8 = select u 7 0 in
  let dir = w.t.dir_n &: ~:u8 |: (c.safe_dir &: u8) in
  let next = { c with value; dir; oe_hist; pv_prev = pv; now = n +:. 1 } in
  next, w.t, c
;;
