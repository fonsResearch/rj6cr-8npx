(* Cycle c+3 of an instruction fetched in cycle c: the model's execute. Every effect is
   computed first and applied only if the instruction neither waits nor faults. *)
open! Base
open Hardcaml
open Signal
open State
open W
module I = Spec.Isa

let alu fn a b =
  mux fn
    [ a +: b; a -: b; a &: b; a |: b; a ^: b; a &: ~:b; uresize (a <: b) 16; uresize (a <+ b) 16; b; b; b; b; b; b; b; b ]
;;

let shift kind a n =
  mux kind [ log_shift sll a n; log_shift srl a n; log_shift sra a n; log_shift rotl a n; log_shift rotr a n; a; a; a ]
;;

let cond c a b = mux c [ a ==: b; a <>: b; a <: b; a >=: b; a <+ b; a >=+ b; gnd; gnd ]

let crc_step ~refl ~byte crc data poly =
  let one = U.crc_bit ~refl crc poly (lsb data) in
  let eight =
    List.fold (List.range 0 8) ~init:crc ~f:(fun c k ->
      let d = mux2 refl (bit data k) (bit data (7 - k)) in
      U.crc_bit ~refl c poly d)
  in
  mux2 byte eight one
;;

(* staging of pin values / output enables: (mask, values) accumulated in program order *)
type stg =
  { sm : Signal.t
  ; sv : Signal.t
  ; em : Signal.t
  ; ev : Signal.t
  ; bad : Signal.t (* a staged pin is not owned *)
  }

let execute (ctx : ctx) (w : Signal.t W.t) id =
  let t = th w id in
  let word = t.fl_word in
  let w = map_th w id (fun t -> { t with fl_valid = gnd }) in
  let d = Dec.decode word in
  let is = d.is and f = d.f in
  let r = t.r in
  let rr idx = mux idx r in
  let own16 = Core.owned_mask w id in
  let st = Core.status ctx w id in
  let pin_src op = mux2 (f op "src") (uresize t.cap 24) ctx.pv in
  (* --- pins --- *)
  let stage s ~en p v =
    let m = U.onehot 16 p &: repeat en 16 in
    { s with sm = s.sm |: m; sv = s.sv &: ~:m |: (repeat v 16 &: m); bad = s.bad |: (en &: ~:(U.bit_at own16 p)) }
  in
  let stage_dir s ~en p v =
    let m = U.onehot 8 p &: repeat en 8 in
    { s with em = s.em |: m; ev = s.ev &: ~:m |: (repeat v 8 &: m); bad = s.bad |: (en &: ~:(U.bit_at own16 p)) }
  in
  let stage_mask s ~en mask v =
    let m = mask &: repeat en 16 in
    { s with sm = s.sm |: m; sv = s.sv &: ~:m |: (v &: m); bad = s.bad |: (m &: ~:own16 <>:. 0) }
  in
  let stage_dir_mask s ~en mask v =
    let m = mask &: repeat en 8 in
    { s with em = s.em |: m; ev = s.ev &: ~:m |: (v &: m); bad = s.bad |: (m &: ~:(select own16 7 0) <>:. 0) }
  in
  let s0 = { sm = t.sm; sv = t.sv; em = t.em; ev = t.ev; bad = gnd } in
  let s = s0 in
  let s = stage s ~en:(is Pinv) (f Pinv "p") (f Pinv "v") in
  let s = stage_dir s ~en:(is Pdir) (f Pdir "p") (f Pdir "d") in
  let s = stage s ~en:(is Pinr) (f Pinr "p") (U.bit_at (rr (f Pinr "ra")) (f Pinr "bit")) in
  let s = stage_mask s ~en:(is Pinm) (f Pinm "mask") (rr (f Pinm "ra")) in
  let s = stage_dir_mask s ~en:(is Pdrm) (f Pdrm "mask") (select (rr (f Pdrm "ra")) 7 0) in
  let pini_m = mux2 (f Pini "grp") (f Pini "mask" @: zero 8) (uresize (f Pini "mask") 16) in
  let pini_v = mux2 (f Pini "grp") (f Pini "val" @: zero 8) (uresize (f Pini "val") 16) in
  let s = stage_mask s ~en:(is Pini) pini_m pini_v in
  let s = stage_dir_mask s ~en:(is Pdri) (f Pdri "mask") (f Pdri "val") in
  let outs_bit op =
    let v = rr (f op "rd") in
    mux2 (f op "dir") (msb v) (lsb v)
  in
  let s = stage s ~en:(is Outs) (f Outs "p") (outs_bit Outs) in
  let s = stage s ~en:(is Outsc) (f Outsc "p") (outs_bit Outsc) in
  let s = stage s ~en:(is Outsc) (f Outsc "cp") (f Outsc "cv") in
  let s = stage s ~en:(is Insc) (f Insc "cp") (f Insc "cv") in
  (* --- data memory --- *)
  let ea_ld = uresize (f Ld "addr") 16 and ea_st = uresize (f St "addr") 16 in
  let ea_ldx = rr (f Ldx "ra") +: uresize (f Ldx "off") 16 in
  let ea_stx = rr (f Stx "ra") +: uresize (f Stx "off") 16 in
  let mem_op = is Ld |: is Ldx |: is St |: is Stx in
  let ea = U.oh_mux ~width:16 [ is Ld, ea_ld; is Ldx, ea_ldx; is St, ea_st; is Stx, ea_stx ] in
  let in_win = uresize ea 17 <: uresize t.dsize 17 in
  (* --- register write --- *)
  let shift_val op amt = shift (f op "kind") (rr (f op "ra")) amt in
  let outs_shifted op =
    let v = rr (f op "rd") in
    mux2 (f op "dir") (sll v 1) (srl v 1)
  in
  let ins_val op =
    let b = U.bit_at (pin_src op) (f op "pin") in
    let v = rr (f op "rd") in
    mux2 (f op "dir") (select v 14 0 @: b) (b @: select v 15 1)
  in
  let pinrd = mux2 (f Pinrd "grp") (uresize (select (pin_src Pinrd) 23 16) 16) (select (pin_src Pinrd) 15 0) in
  let djnz_v = rr (f Djnz "rd") -:. 1 in
  let tget =
    mux (f Tget "sel")
      [ select ctx.e 15 0; select ctx.e 31 16; select t.t_int 15 0; select t.t_int 31 16; t.slack_min; select t.p 15 0
      ; select t.p 31 16; zero 16 ]
  in
  let ior_addr = f Ior "addr" in
  let ior_rule = select ior_addr 7 4 ==:. 2 in
  let ior_rule_val =
    let k = select ior_addr 3 2 in
    let words =
      List.map w.c.rules ~f:(fun (r : Signal.t Rule.t) ->
        mux (select ior_addr 1 0)
          [ uresize (concat_lsb [ r.active; r.v_min; r.v_max; r.repaired ]) 16; r.obs_min; r.obs_max; r.cnt ])
    in
    mux k words
  in
  let line_ok_r, line_j_r = Lregs.line_io_index ior_addr in
  let line_mine = w.c.line.owner ==:. id in
  let ior_line = line_ok_r &: line_mine in
  let ior_val =
    U.oh_mux ~width:16
      [ ior_addr ==:. 0, st
      ; ior_rule, ior_rule_val
      ; ~:(ior_addr ==:. 0) &: ~:ior_rule &: ior_line, Lregs.line_peek ~snap:ctx.snap w.c.line line_j_r ]
  in
  let ior_bad = ~:(ior_addr ==:. 0) &: ~:ior_rule &: ~:ior_line in
  let regw =
    [ is Alu, f Alu "rd", alu (f Alu "fn") (rr (f Alu "ra")) (rr (f Alu "rb"))
    ; is Alui, f Alui "rd", alu (f Alui "fn") (rr (f Alui "rd")) (f Alui "imm")
    ; is Shi, f Shi "rd", shift_val Shi (f Shi "amt")
    ; is Shv, f Shv "rd", shift_val Shv (select (rr (f Shv "rb")) 3 0)
    ; ( is Crc
      , f Crc "rd"
      , crc_step ~refl:(f Crc "refl") ~byte:(f Crc "byte") (rr (f Crc "rd")) (rr (f Crc "ra")) (rr (f Crc "rb")) )
    ; is Ld, f Ld "rd", ctx.data_dout
    ; is Ldx, f Ldx "rd", ctx.data_dout
    ; is Jal, f Jal "rd", uresize (t.pc +:. 1) 16
    ; is Djnz, f Djnz "rd", djnz_v
    ; is Outs, f Outs "rd", outs_shifted Outs
    ; is Outsc, f Outsc "rd", outs_shifted Outsc
    ; is Ins, f Ins "rd", ins_val Ins
    ; is Insc, f Insc "rd", ins_val Insc
    ; is Pinrd, f Pinrd "rd", pinrd
    ; is Tget, f Tget "rd", tget
    ; is Pull, f Pull "rd", t.in_d
    ; is Ior, f Ior "rd", ior_val
    ]
  in
  let regw_en = U.any (List.map regw ~f:(fun (c, _, _) -> c)) in
  let regw_rd = U.oh_mux ~width:3 (List.map regw ~f:(fun (c, rd, _) -> c, rd)) in
  let regw_v = U.oh_mux ~width:16 (List.map regw ~f:(fun (c, _, v) -> c, v)) in
  (* --- control flow --- *)
  let tgt op = uresize (f op "tgt") 10 in
  let br op c = c, tgt op in
  let jumps =
    [ is Jmp, tgt Jmp
    ; is Jal, tgt Jal
    ; is Jr, select (rr (f Jr "ra")) 9 0
    ; br Br (is Br &: cond (f Br "cond") (rr (f Br "ra")) (rr (f Br "rb")))
    ; br Bri (is Bri &: cond (f Bri "cond") (rr (f Bri "ra")) (uresize (f Bri "imm") 16))
    ; br Djnz (is Djnz &: (djnz_v <>:. 0))
    ; br Bbit (is Bbit &: (U.bit_at (rr (f Bbit "ra")) (f Bbit "bit") ==: f Bbit "sense"))
    ; br Bpin (is Bpin &: (U.bit_at (pin_src Bpin) (f Bpin "pin") ==: f Bpin "sense"))
    ; br Bst (is Bst &: (U.bit_at st (f Bst "bit") ==: f Bst "sense"))
    ]
  in
  let jump = U.any (List.map jumps ~f:fst) in
  let next_pc = mux2 jump (U.oh_mux ~width:10 jumps) (t.pc +:. 1) in
  let jr_bad = is Jr &: (uresize (rr (f Jr "ra")) 16 >=: uresize t.psize 16) in
  (* --- time --- *)
  let t_int' =
    U.oh_mux ~width:32
      [ is Tnow, ctx.e +: uresize (f Tnow "imm") 32
      ; is Taddi, t.t_int +: uresize (f Taddi "imm") 32
      ; is Taddr, t.t_int +: uresize (rr (f Taddr "ra")) 32
      ; is Tset, rr (f Tset "ra") @: rr (f Tset "rb")
      ]
  in
  let t_int_ch = is Tnow |: is Taddi |: is Taddr |: is Tset in
  let t_int_n = mux2 t_int_ch t_int' t.t_int in
  let t_frac_n = mux2 (is Tnow |: is Tset) (zero 8) t.t_frac in
  let per_v = mux2 (is Tperi) (f Tperi "imm") (rr (f Tperr "ra")) in
  let per_half = mux2 (is Tperi) (f Tperi "half") (f Tperr "half") in
  let p_n =
    mux2 (is Tperi |: is Tperr)
      (mux2 per_half (per_v @: select t.p 15 0) (select t.p 31 16 @: per_v))
      t.p
  in
  (* --- waits --- *)
  let is_wait = is Waitp |: is Waits in
  let w_to = mux2 (is Waitp) (f Waitp "to") (f Waits "to") in
  let uses_deadline = select d.tm 1 1 |: (is_wait &: w_to) in
  let slack = t_int_n -: ctx.e in
  let is_late = uses_deadline &: (slack <+. 1) in
  let slack16 = mux2 (slack <+. -32768) (U.k 16 0x8000) (mux2 (slack >+. 32767) (U.k 16 0x7FFF) (select slack 15 0)) in
  (* --- outcome --- *)
  let pcb = t.fl_pcb in
  let illegal = ~:pcb &: ~:(d.legal) in
  let sync_block = ~:pcb &: d.legal &: Dec.is_sync d &: t.armed in
  let pre = ~:pcb &: d.legal &: ~:sync_block in
  let iow_addr = mux2 (is Iow) (f Iow "addr") (f Iowi "addr") in
  let iow_v = mux2 (is Iow) (rr (f Iow "ra")) (f Iowi "imm") in
  let iow = is Iow |: is Iowi in
  let line_ok_w, line_j_w = Lregs.line_io_index iow_addr in
  let iow_line = iow &: ~:(iow_addr ==:. 0) &: line_ok_w &: line_mine in
  let iow_bad = iow &: ~:(iow_addr ==:. 0) &: ~:(line_ok_w &: line_mine) in
  let op_faults =
    (* code, arg, condition; at most one holds for a legal word *)
    [ 2, zero 8, jr_bad
    ; 3, zero 8, mem_op &: ~:in_win
    ; 4, zero 8, s.bad
    ; 6, zero 8, (is Ior &: ior_bad) |: iow_bad
    ; 7, f Trap "code", is Trap
    ]
  in
  let op_fault = U.any (List.map op_faults ~f:(fun (_, _, c) -> c)) in
  let op_blocked =
    (is Pull &: (f Pull "ch" <>:. 0 |: ~:(t.in_v))) |: (is Push &: (f Push "ch" <>:. 0 |: t.out_v))
  in
  let op_ok = pre &: ~:op_fault &: ~:op_blocked in
  let late_fault = op_ok &: is_late &: t.strict in
  let apply = op_ok &: ~:late_fault in
  (* slack minimum: updated whenever the operation itself completed, also before a LATE fault *)
  let w =
    map_th w id (fun t ->
      { t with slack_min = U.upd (op_ok &: uses_deadline) t.slack_min (mux2 (slack16 <+ t.slack_min) slack16 t.slack_min) })
  in
  (* faults *)
  let w = Core.enter_fault |> fun ef ->
    let w = w_if (pcb) w (fun w -> ef w id ~code:2 ~arg:(zero 8)) in
    let w = w_if illegal w (fun w -> ef w id ~code:1 ~arg:(zero 8)) in
    let w =
      List.fold op_faults ~init:w ~f:(fun w (code, arg, c) -> w_if (pre &: c) w (fun w -> ef w id ~code ~arg))
    in
    w_if late_fault w (fun w -> ef w id ~code:5 ~arg:(zero 8))
  in
  (* apply *)
  w_if apply w (fun w ->
    let w =
      map_th w id (fun t ->
        let r = List.mapi t.r ~f:(fun i x -> U.upd (regw_en &: (regw_rd ==:. i)) x regw_v) in
        let wt_pin = is Waitp in
        let t =
          { t with
            r
          ; pc = next_pc
          ; sv = s.sv
          ; sm = s.sm
          ; ev = s.ev
          ; em = s.em
          ; t_int = t_int_n
          ; t_frac = t_frac_n
          ; p = p_n
          ; evf = t.evf &: ~:(mux2 (is Iow |: is Iowi) (lsb iow_v &: (iow_addr ==:. 0)) gnd)
          ; late = (t.late &: ~:(iow &: (iow_addr ==:. 0) &: bit iow_v 3)) |: is_late
          ; in_v = t.in_v &: ~:(is Pull)
          ; out_v = t.out_v |: is Push
          ; out_d = mux2 (is Push) (rr (f Push "ra")) t.out_d
          }
        in
        let tm = d.tm in
        let t =
          { t with
            armed = t.armed |: (tm <>:. 0)
          ; due = mux2 (tm ==:. 1) vdd (mux2 (tm >=:. 2) is_late t.due)
          ; deadline = mux2 (tm ==:. 1) gnd (mux2 (tm >=:. 2) vdd t.deadline)
          ; adv = mux2 (tm ==:. 0) t.adv (tm ==:. 3)
          }
        in
        let t =
          Thread.map2 t
            { t with
              st = U.k 3 2
            ; w_pin = wt_pin
            ; w_idx = mux2 wt_pin (f Waitp "pin") (uresize (f Waits "bit") 5)
            ; w_cond = mux2 wt_pin (f Waitp "cond") (uresize (f Waits "sense") 2)
            ; w_to
            ; w_cm = mux2 wt_pin (f Waitp "cm") (f Waits "cm")
            ; w_re = mux2 wt_pin (f Waitp "re") (f Waits "re")
            ; w_adv = mux2 wt_pin (f Waitp "adv") (f Waits "adv")
            ; w_due = mux2 is_late (U.k 2 2) (U.k 2 0)
            }
            ~f:(U.upd is_wait)
        in
        { t with st = U.upd (is Halt) t.st (U.k 3 3) })
    in
    let w =
      tmp w (fun x ->
        { x with em_v = U.upd (is Emit) x.em_v vdd; em_t = U.upd (is Emit) x.em_t (U.k 2 id); em_c = U.upd (is Emit) x.em_c (f Emit "code") })
    in
    { w with c = { w.c with line = Lregs.line_poke w.c.line ~en:iow_line line_j_w iow_v } })
;;
