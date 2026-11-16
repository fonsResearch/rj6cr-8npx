(* The line unit in one cycle (model: line_cycle), statement by statement. *)
open! Base
open Hardcaml
open Signal
open W

let setl (w : Signal.t W.t) f = { w with c = { w.c with line = f w.c.line } }
let ev (w : Signal.t W.t) ~en k = tmp w (fun x -> { x with l_ev = x.l_ev |: (U.onehot 11 (U.k 4 k) &: repeat en 11) })
let lc (w : Signal.t W.t) j = U.nth w.c.line.lc (j - 1)
let sat_inc x = mux2 (x ==: ones (width x)) x (x +:. 1)

(* configuration decoded once per cycle *)
type cfg =
  { ctl : Signal.t
  ; per : Signal.t
  ; inv : Signal.t
  ; idle : Signal.t
  ; code : Signal.t
  ; ext : Signal.t
  ; ones_ : Signal.t
  ; stuff_n : Signal.t
  ; wd : Signal.t
  ; crc_init : Signal.t
  ; tx_skip : Signal.t
  ; rx_skip : Signal.t
  ; poly : Signal.t
  ; owner_ok : Signal.t
  }

let c_ (g : cfg) b = bit g.ctl b

let cfg (w : Signal.t W.t) =
  let ctl = lc w 1 in
  let per = mux2 (lc w 2 <:. 16) (U.k 16 16) (lc w 2) in
  let sn = select ctl 10 8 in
  let w5 = select (lc w 5) 4 0 in
  let wd = mux2 (w5 >:. 16) (U.k 5 16) w5 in
  let init_tab = List.init 32 ~f:(fun i -> U.k 16 (if i >= 16 then 0xFFFF else (0xFFFF lsl (16 - i)) land 0xFFFF)) in
  let crc_init = mux2 (bit (lc w 5) 5) (mux wd init_tab) (zero 16) in
  let owner = w.c.line.owner in
  let owner_ok =
    owner <=:. 2 &: ~:(U.get_at (List.map w.c.th ~f:(fun t -> t.st ==:. 4)) owner ~default:vdd)
  in
  { ctl; per; inv = bit ctl 4; idle = bit ctl 5; code = select ctl 3 2; ext = bit ctl 13; ones_ = bit ctl 11
  ; stuff_n = mux2 (sn ==:. 0) (U.k 4 8) (uresize sn 4); wd; crc_init
  ; tx_skip = select (lc w 17) 7 0; rx_skip = select (lc w 17) 15 8; poly = lc w 4; owner_ok }
;;

let bitp v q = mux2 (q <=:. 23) (U.bit_at v q) gnd

(* run of equal bits / of ones, saturating *)
let track ~ones_ ~run ~last b =
  let run_ones = mux2 b (sat_inc run) (zero 4) in
  let run_eq = mux2 (b ==: last) (sat_inc run) (U.k 4 1) in
  mux2 ones_ run_ones run_eq, mux2 ones_ last b
;;

let push_word (g : cfg) (w : Signal.t W.t) ~en idx d =
  let l = w.c.line in
  let dsize = U.get_at (List.map w.c.th ~f:(fun t -> t.dsize)) l.owner ~default:(zero 11) in
  let idx = uresize idx 10 in
  let ok =
    g.owner_ok &: (uresize idx 11 <: select (lc w 11) 10 0)
    &: (uresize (select (lc w 10) 9 0) 12 +: uresize idx 12 <: uresize dsize 12)
    &: ~:(l.r_wv)
  in
  setl w (fun l ->
    { l with
      r_wv = U.upd (en &: ok) l.r_wv vdd
    ; r_widx = U.upd (en &: ok) l.r_widx idx
    ; r_wd = U.upd (en &: ok) l.r_wd d
    ; r_err = U.upd (en &: ~:ok) l.r_err (l.r_err |:. 2)
    })
;;

let resp_check (_ : cfg) (w : Signal.t W.t) ~en ~at_end =
  List.fold [ 0; 1 ] ~init:w ~f:(fun w k ->
    let l = w.c.line in
    let q = U.nth l.resp k in
    let ctl = q.ctl in
    let pos_ok = mux (select ctl 3 2) [ vdd; l.r_cnt ==: q.pos; l.r_cnt >=: q.pos; vdd ] in
    let crc_ok = ~:(bit ctl 4) |: (l.r_crc ==: lc w 6) in
    let ml = select ctl 9 6 in
    let ml = mux2 (ml >:. 8) (U.k 4 8) ml in
    let lowmask = mux ml (List.init 16 ~f:(fun i -> U.k 8 ((1 lsl Int.min i 8) - 1))) in
    let m = select q.mtch 15 8 &: lowmask in
    let match_ = (select l.r_hist 7 0 ^: select q.mtch 7 0) &: m ==:. 0 in
    let fire =
      en &: lsb ctl &: (bit ctl 5 ==: (if at_end then vdd else gnd)) &: ~:(l.q_pv) &: pos_ok &: crc_ok &: match_
    in
    let w = ev w ~en:fire (9 + k) in
    setl w (fun l ->
      { l with
        q_pv = U.upd fire l.q_pv vdd
      ; q_pk = U.upd fire l.q_pk (if k = 0 then gnd else vdd)
      ; resp =
          U.set l.resp k
            { q with fired = U.upd fire q.fired vdd; ctl = U.upd (fire &: bit ctl 1) ctl (ctl &: ~:(U.k 14 1)) }
      }))
;;

let frame_end (g : cfg) (w : Signal.t W.t) ~en =
  let l = w.c.line in
  let w = push_word g w ~en:(en &: (select l.r_cnt 3 0 <>:. 0)) (srl l.r_cnt 4) l.r_sh in
  let crcok = l.r_crc ==: lc w 6 in
  let w = setl w (fun l -> { l with r_done = U.upd en l.r_done vdd; r_crcok = U.upd en l.r_crcok crcok }) in
  let w = ev w ~en 2 in
  let w = ev w ~en:(en &: crcok) 3 in
  let w = ev w ~en:(en &: ~:crcok) 4 in
  let w = resp_check g w ~en ~at_end:true in
  setl w (fun l ->
    { l with
      r_st = U.upd en l.r_st (mux2 (c_ g 0) (U.k 2 1) (U.k 2 0))
    ; r_idle_seen = U.upd en l.r_idle_seen gnd
    })
;;

let finish g (w : Signal.t W.t) ~en =
  let in_frame = w.c.line.r_st ==:. 3 in
  let w = frame_end g w ~en:(en &: in_frame) in
  setl w (fun l ->
    { l with
      r_st = U.upd (en &: ~:in_frame) l.r_st (U.k 2 1)
    ; r_idle_seen = U.upd (en &: ~:in_frame) l.r_idle_seen gnd
    })
;;

(* the receiver; returns the state and the receive-clock bit boundary of this cycle *)
let receiver (ctx : ctx) (g : cfg) (w : Signal.t W.t) ~cmd =
  let pv = ctx.pv and pp = ctx.pv_prev in
  let lc3 = lc w 3 in
  let rxp = select lc3 8 4 in
  let dp = bitp pv rxp and dm = bitp pv (rxp +:. 1) in
  let se0 = c_ g 1 &: ~:dp &: ~:dm in
  let lv = dp ^: g.inv in
  let clkp = select lc3 13 9 in
  let ck = bitp pv clkp and ckp = bitp pp clkp in
  let sample_edge = g.ext &: mux2 (c_ g 14) (ckp &: ~:ck) (~:ckp &: ck) in
  let shift_edge = g.ext &: mux2 (c_ g 14) (~:ckp &: ck) (ckp &: ~:ck) in
  let edge = lv <>: w.c.line.r_lv in
  let w = setl w (fun l -> { l with r_lv = lv }) in
  let w = setl w (fun l -> { l with r_st = U.upd (bit cmd 3) l.r_st (zero 2) }) in
  let arm = bit cmd 1 &: g.owner_ok in
  let w = setl w (fun l -> { l with r_st = U.upd arm l.r_st (U.k 2 1); r_idle_seen = U.upd arm l.r_idle_seen gnd }) in
  let sync_len = select (lc w 12) 11 8 in
  let sync_len = mux2 (sync_len >:. 8) (U.k 4 8) sync_len in
  let l = w.c.line in
  let armed = l.r_st ==:. 1 in
  let starts = armed &: (g.ext |: (l.r_idle_seen &: (lv <>: g.idle) &: ~:se0)) in
  let w =
    w_if starts w (fun w ->
      let w =
        setl w (fun l ->
          { l with
            r_ph = mux2 (g.code ==:. 2) (srl g.per 1) (zero 16)
          ; r_prev = g.idle
          ; r_hcnt = zero 4
          ; r_cnt = zero 14
          ; r_sh = zero 16
          ; r_hist = zero 16
          ; r_crc = g.crc_init
          ; r_run = zero 4
          ; r_last = g.idle
          ; r_quiet = zero 9
          ; r_st = mux2 (sync_len ==:. 0) (U.k 2 3) (U.k 2 2)
          })
      in
      ev w ~en:(sync_len ==:. 0) 1)
  in
  let w = setl w (fun l -> { l with r_idle_seen = U.upd (armed &: ~:starts &: (lv ==: g.idle) &: ~:se0) l.r_idle_seen vdd }) in
  (* bit clock *)
  let per = g.per in
  let p17 = uresize per 17 in
  let l = w.c.line in
  let sp = uresize (srl per 1) 17 +: uresize (uresize (srl per 3) 15 *: select (lc w 15) 9 8) 17 in
  let sjw = select (lc w 15) 7 0 in
  let sjw16 = uresize sjw 12 |> fun x -> uresize (sll (uresize x 17) 4) 17 in
  let ph = uresize l.r_ph 17 in
  let corr = ~:(g.ext) &: (l.r_st >=:. 2) &: edge &: ~:starts in
  let man = g.code ==:. 2 in
  let man_mid = ph >=: uresize (srl per 2) 17 &: (ph <: p17 -: uresize (srl per 2) 17) in
  let sjw_all = sjw ==:. 0xFF in
  let early = ph <: sp in
  let late_close = sjw_all |: (sresize (uresize p17 18 -: uresize ph 18) 18 <=+ uresize sjw16 18) in
  let ph_corr =
    mux2 man
      (mux2 man_mid (uresize (srl per 1) 17) ph)
      (mux2 early
         (mux2 sjw_all (zero 17) (ph -: U.umin ph sjw16))
         (mux2 late_close (zero 17) (ph +: sjw16)))
  in
  let bnd_corr = corr &: ~:man &: ~:early &: late_close in
  let ph1 = mux2 corr ph_corr ph in
  let w = setl w (fun l -> { l with r_quiet = U.upd (corr &: man &: man_mid) l.r_quiet (zero 9) }) in
  let strobe_int = ph1 <: sp &: (ph1 +:. 16 >=: sp) in
  let ph2 = ph1 +:. 16 in
  let wrap = ph2 >=: p17 in
  let ph3 = mux2 wrap (ph2 -: p17) ph2 in
  let w = setl w (fun l -> { l with r_ph = U.upd (~:(g.ext)) l.r_ph (select ph3 15 0) }) in
  let boundary = mux2 g.ext shift_edge (bnd_corr |: wrap) in
  let strobe = mux2 g.ext sample_edge strobe_int in
  let w = setl w (fun l -> { l with r_quiet = U.upd (l.r_st >=:. 2 &: edge &: ~:man) l.r_quiet (zero 9) }) in
  (* a sampled bit *)
  let l = w.c.line in
  let go = l.r_st >=:. 2 &: strobe in
  let w =
    w_if go w (fun w ->
      let w = setl w (fun l -> { l with r_quiet = sat_inc l.r_quiet }) in
      let l = w.c.line in
      let endc = lc w 13 in
      let end_se0 = bit endc 0 &: se0 in
      let end_quiet = ~:end_se0 &: bit endc 2 &: (uresize l.r_quiet 16 >: U.umax (U.k 16 1) (srl endc 8)) in
      let w = finish g w ~en:(end_se0 |: end_quiet) in
      let data = ~:end_se0 &: ~:end_quiet in
      let l = w.c.line in
      let b = mux2 (g.code ==:. 1) (lv ==: l.r_prev) lv in
      let w = setl w (fun l -> { l with r_prev = U.upd data l.r_prev lv }) in
      let send = select (lc w 16) 13 0 in
      let prot = send ==:. 0 |: (l.r_st ==:. 2) |: (l.r_cnt <: send) in
      let due = c_ g 7 &: prot &: (l.r_run >=: g.stuff_n) in
      let stuff_bit = mux2 g.ones_ gnd ~:(l.r_last) in
      let dropped = data &: due &: (b ==: stuff_bit) in
      let run1, last1 = track ~ones_:g.ones_ ~run:l.r_run ~last:l.r_last b in
      let w = setl w (fun l -> { l with r_run = U.upd dropped l.r_run run1; r_last = U.upd dropped l.r_last last1 }) in
      let kept = data &: ~:dropped in
      let viol = kept &: due in
      let w = setl w (fun l -> { l with r_err = U.upd viol l.r_err (l.r_err |:. 1) }) in
      let w = ev w ~en:viol 5 in
      let w = finish g w ~en:(viol &: bit endc 1) in
      let stored = kept &: ~:(due &: bit endc 1) in
      w_if stored w (fun w ->
        let l = w.c.line in
        let run1, last1 = track ~ones_:g.ones_ ~run:l.r_run ~last:l.r_last b in
        let hist = select l.r_hist 14 0 @: b in
        let w = setl w (fun l -> { l with r_run = run1; r_last = last1; r_hist = hist }) in
        let hunting = l.r_st ==:. 2 in
        let hc = mux2 (l.r_hcnt >=:. 8) (U.k 4 8) (l.r_hcnt +:. 1) in
        let m = mux sync_len (List.init 16 ~f:(fun i -> U.k 8 ((1 lsl Int.min i 8) - 1))) in
        let found = hunting &: (hc >=: sync_len) &: ((select hist 7 0 &: m) ==: (select (lc w 12) 7 0 &: m)) in
        let w = setl w (fun l -> { l with r_hcnt = U.upd hunting l.r_hcnt hc; r_st = U.upd found l.r_st (U.k 2 3) }) in
        let w = ev w ~en:found 1 in
        w_if ~:hunting w (fun w ->
          let l = w.c.line in
          let crc_en = l.r_cnt >=: uresize g.rx_skip 14 &: prot in
          let pos = select l.r_cnt 3 0 in
          let bpos = mux2 (c_ g 6) pos (U.k 4 15 -: pos) in
          let cnt1 = l.r_cnt +:. 1 in
          let sh1 = l.r_sh |: (U.onehot 16 bpos &: repeat b 16) in
          let full = select cnt1 3 0 ==:. 0 in
          let w =
            setl w (fun l ->
              { l with r_crc = U.upd crc_en l.r_crc (U.crc_bit_msb l.r_crc g.poly b); r_sh = sh1; r_cnt = cnt1 })
          in
          let w = push_word g w ~en:full (srl cnt1 4 -:. 1) sh1 in
          let w = setl w (fun l -> { l with r_sh = U.upd full l.r_sh (zero 16) }) in
          let w = ev w ~en:vdd 0 in
          let w = resp_check g w ~en:vdd ~at_end:false in
          let limit = cnt1 ==:. 0x3FF0 in
          let w = setl w (fun l -> { l with r_err = U.upd limit l.r_err (l.r_err |:. 2) }) in
          let len_end = ~:limit &: bit endc 3 &: (cnt1 ==: select (lc w 14) 13 0) in
          frame_end g w ~en:(limit |: len_end))))
  in
  w, boundary, shift_edge
;;

let line_out (g : cfg) lvl =
  let o = lvl ^: g.inv in
  ~:o @: o
;;

let idle_out g (w : Signal.t W.t) ~en = setl w (fun l -> { l with t_out = U.upd en l.t_out (line_out g g.idle) })

let finish_tx g (w : Signal.t W.t) ~en =
  let w = setl w (fun l -> { l with t_st = U.upd en l.t_st (zero 3); t_done = U.upd en l.t_done vdd }) in
  let w = ev w ~en 8 in
  let rel = c_ g 15 in
  let w = setl w (fun l -> { l with t_rel = U.upd en l.t_rel rel }) in
  idle_out g w ~en:(en &: ~:rel), en
;;

let send_logical g (w : Signal.t W.t) ~en b =
  let l = w.c.line in
  let run1, last1 = track ~ones_:g.ones_ ~run:l.t_run ~last:l.t_last b in
  let line = mux g.code [ b; mux2 b l.t_line ~:(l.t_line); ~:b; b ] in
  let w =
    setl w (fun l ->
      { l with
        t_run = U.upd en l.t_run run1
      ; t_last = U.upd en l.t_last last1
      ; t_line = U.upd en l.t_line line
      ; t_bit = U.upd en l.t_bit b
      ; t_half = U.upd en l.t_half gnd
      ; t_out = U.upd en l.t_out (line_out g line)
      ; t_rel = U.upd en l.t_rel gnd
      })
  in
  ev w ~en 6
;;

(* returns the state and whether finish_tx ran (the unit wrote its pins) *)
let tail_or_finish g (w : Signal.t W.t) ~en =
  let l = w.c.line in
  let ntail = select (lc w 9) 2 0 in
  let ntail = mux2 (ntail >:. 4) (U.k 3 4) ntail in
  let more = l.t_tail <: ntail in
  let sym = mux (select l.t_tail 1 0) [ select (lc w 9) 9 8; select (lc w 9) 11 10; select (lc w 9) 13 12; select (lc w 9) 15 14 ] in
  let e1 = en &: more in
  let w =
    setl w (fun l ->
      { l with
        t_out = U.upd e1 l.t_out sym
      ; t_rel = U.upd e1 l.t_rel gnd
      ; t_tail = U.upd e1 l.t_tail (l.t_tail +:. 1)
      ; t_half = U.upd e1 l.t_half vdd
      })
  in
  finish_tx g w ~en:(en &: ~:more)
;;

let coder_reset g (w : Signal.t W.t) ~en =
  setl w (fun l ->
    { l with
      t_run = U.upd en l.t_run (zero 4)
    ; t_last = U.upd en l.t_last g.idle
    ; t_line = U.upd en l.t_line g.idle
    ; t_acc = U.upd en l.t_acc (zero 16)
    ; t_half = U.upd en l.t_half gnd
    })
;;

let boundary_tx g (w : Signal.t W.t) ~en =
  let l = w.c.line in
  let st0 = l.t_st in
  let tlen = select (lc w 8) 13 0 in
  (* state 2: a frame *)
  let s2 = en &: (st0 ==:. 2) in
  let more = l.t_sent <: tlen |: (l.t_crcleft >:. 0) in
  let stuff = s2 &: c_ g 7 &: (l.t_run >=: g.stuff_n) &: (more |: c_ g 12) in
  let w = send_logical g w ~en:stuff (mux2 g.ones_ gnd ~:(l.t_last)) in
  let data = s2 &: ~:stuff &: (l.t_sent <: tlen) in
  let pos = select l.t_sent 3 0 in
  let new_word = data &: (pos ==:. 0) &: (l.t_sent >:. 0) in
  let w =
    setl w (fun l ->
      let req = new_word &: (uresize l.t_sent 15 +:. 16 <: uresize tlen 15) in
      { l with
        t_err = U.upd (new_word &: ~:(l.t_nvalid)) l.t_err (l.t_err |:. 1)
      ; t_word = U.upd new_word l.t_word (mux2 l.t_nvalid l.t_next (zero 16))
      ; t_nvalid = U.upd new_word l.t_nvalid gnd
      ; t_req_v = U.upd req l.t_req_v vdd
      ; t_req = U.upd req l.t_req (uresize (srl l.t_sent 4) 11 +:. 1)
      })
  in
  let l = w.c.line in
  let b = U.bit_at l.t_word (mux2 (c_ g 6) pos (U.k 4 15 -: pos)) in
  let sent1 = l.t_sent +:. 1 in
  let w =
    setl w (fun l ->
      { l with
        t_crc = U.upd (data &: (l.t_sent >=: uresize g.tx_skip 14)) l.t_crc (U.crc_bit_msb l.t_crc g.poly b)
      ; t_sent = U.upd data l.t_sent sent1
      ; t_crcleft = U.upd (data &: (sent1 ==: tlen)) l.t_crcleft g.wd
      })
  in
  let w = send_logical g w ~en:data b in
  let l = w.c.line in
  let crcb = s2 &: ~:stuff &: ~:data &: (l.t_crcleft >:. 0) in
  let cb = msb l.t_crc ^: bit (lc w 5) 6 in
  let w = setl w (fun l -> { l with t_crc = U.upd crcb l.t_crc (sll l.t_crc 1); t_crcleft = U.upd crcb l.t_crcleft (l.t_crcleft -:. 1) }) in
  let w = send_logical g w ~en:crcb cb in
  let to_tail = s2 &: ~:stuff &: ~:data &: ~:crcb in
  let w = setl w (fun l -> { l with t_st = U.upd to_tail l.t_st (U.k 3 3); t_tail = U.upd to_tail l.t_tail (zero 3) }) in
  let w, f1 = tail_or_finish g w ~en:to_tail in
  (* state 3: tail *)
  let w, f2 = tail_or_finish g w ~en:(en &: (st0 ==:. 3)) in
  (* state 5: reply *)
  let l5 = w.c.line in
  let s5 = en &: (st0 ==:. 5) in
  let rb = s5 &: (l5.t_rleft >:. 0) in
  let w = setl w (fun l -> { l with t_rsh = U.upd rb l.t_rsh (srl l.t_rsh 1); t_rleft = U.upd rb l.t_rleft (l.t_rleft -:. 1) }) in
  let w = send_logical g w ~en:rb (lsb l5.t_rsh) in
  let rt = s5 &: ~:rb &: l5.t_rtail in
  let w = setl w (fun l -> { l with t_st = U.upd rt l.t_st (U.k 3 3); t_tail = U.upd rt l.t_tail (zero 3) }) in
  let w, f3 = tail_or_finish g w ~en:rt in
  let w, f4 = finish_tx g w ~en:(s5 &: ~:rb &: ~:rt) in
  w, f1 |: f2 |: f3 |: f4
;;

let transmitter (_ : ctx) (g : cfg) (w : Signal.t W.t) ~cmd ~q_now_v ~q_now_k ~boundary ~shift_edge =
  let tlen = select (lc w 8) 13 0 in
  let stop = bit cmd 2 in
  let w = setl w (fun l -> { l with t_st = U.upd stop l.t_st (zero 3); t_req_v = U.upd stop l.t_req_v gnd }) in
  (* a response rule fired in the previous cycle *)
  let l = w.c.line in
  let take = q_now_v &: (l.t_st ==:. 0) &: g.owner_ok in
  let w = setl w (fun l -> { l with t_err = U.upd (q_now_v &: ~:take) l.t_err (l.t_err |:. 4) }) in
  let q = U.nth l.resp 0 |> fun q0 -> State.Resp.map2 q0 (U.nth l.resp 1) ~f:(fun a b -> mux2 q_now_k b a) in
  let len5 = select q.len 4 0 in
  let rleft = mux2 (len5 >:. 16) (U.k 5 16) (mux2 (len5 ==:. 0) (U.k 5 1) len5) in
  let w =
    setl w (fun l ->
      { l with
        t_rwait = U.upd take l.t_rwait (select q.ctl 13 10)
      ; t_rleft = U.upd take l.t_rleft rleft
      ; t_rsh = U.upd take l.t_rsh q.reply
      ; t_rtail = U.upd take l.t_rtail (bit q.len 5)
      ; t_st = U.upd take l.t_st (U.k 3 4)
      })
  in
  let begin_frame w ~en =
    let w = coder_reset g w ~en in
    let w =
      setl w (fun l ->
        { l with
          t_crc = U.upd en l.t_crc g.crc_init
        ; t_crcleft = U.upd en l.t_crcleft (mux2 (tlen ==:. 0) g.wd (zero 5))
        ; t_st = U.upd en l.t_st (U.k 3 2)
        ; t_bnd = U.upd en l.t_bnd vdd
        })
    in
    ev w ~en 7
  in
  let l = w.c.line in
  let start = bit cmd 0 &: (l.t_st ==:. 0) &: g.owner_ok in
  let w =
    setl w (fun l ->
      { l with
        t_sent = U.upd start l.t_sent (zero 14)
      ; t_nvalid = U.upd start l.t_nvalid gnd
      ; t_req_v = U.upd start l.t_req_v (tlen <>:. 0)
      ; t_req = U.upd start l.t_req (zero 11)
      ; t_st = U.upd (start &: (tlen <>:. 0)) l.t_st (U.k 3 1)
      })
  in
  let w = begin_frame w ~en:(start &: (tlen ==:. 0)) in
  let loaded = ~:start &: (l.t_st ==:. 1) &: l.t_nvalid in
  let w =
    setl w (fun l ->
      { l with
        t_word = U.upd loaded l.t_word l.t_next
      ; t_nvalid = U.upd loaded l.t_nvalid gnd
      ; t_req_v = U.upd (loaded &: (tlen >:. 16)) l.t_req_v vdd
      ; t_req = U.upd (loaded &: (tlen >:. 16)) l.t_req (U.k 11 1)
      })
  in
  let w = begin_frame w ~en:loaded in
  let rw = ~:start &: ~:loaded &: (l.t_st ==:. 4) in
  let go_reply = rw &: (l.t_rwait ==:. 0) in
  let w = coder_reset g w ~en:go_reply in
  let w = setl w (fun l -> { l with t_st = U.upd go_reply l.t_st (U.k 3 5); t_bnd = U.upd go_reply l.t_bnd vdd }) in
  let w = ev w ~en:go_reply 7 in
  let w = setl w (fun l -> { l with t_rwait = U.upd (rw &: ~:go_reply &: boundary) l.t_rwait (l.t_rwait -:. 1) }) in
  (* symbol timing *)
  let l = w.c.line in
  let active = l.t_st ==:. 2 |: (l.t_st ==:. 3) |: (l.t_st ==:. 5) in
  let w, fin = boundary_tx g w ~en:(active &: l.t_bnd) in
  let half = active &: ~:(l.t_bnd) &: (g.code ==:. 2) &: ~:(l.t_half) &: (uresize l.t_acc 17 >=: uresize (srl g.per 1) 17) in
  let w = setl w (fun l -> { l with t_half = U.upd half l.t_half vdd; t_line = U.upd half l.t_line l.t_bit; t_out = U.upd half l.t_out (line_out g l.t_bit) }) in
  let l2 = w.c.line in
  let still = active &: (l2.t_st <>:. 0) in
  let a = uresize l2.t_acc 17 +:. 16 in
  let wrap = a >=: uresize g.per 17 in
  let w =
    setl w (fun l ->
      { l with
        t_bnd = U.upd still l.t_bnd (mux2 g.ext shift_edge wrap)
      ; t_acc = U.upd (still &: ~:(g.ext)) l.t_acc (select (mux2 wrap (a -: uresize g.per 17) a) 15 0)
      })
  in
  w, fin |: still
;;

let line_cycle (ctx : ctx) (w : Signal.t W.t) =
  let g = cfg w in
  let l = w.c.line in
  let cmd = l.cmd in
  let q_now_v = l.q_pv and q_now_k = l.q_pk in
  let serve_w = l.r_wv and serve_widx = l.r_widx and serve_wd = l.r_wd in
  let serve_r = l.t_req_v and serve_ridx = l.t_req in
  let w = setl w (fun l -> { l with cmd = zero 5; q_pv = gnd }) in
  let clr = bit cmd 4 in
  let w =
    setl w (fun l ->
      { l with
        t_done = U.upd clr l.t_done gnd
      ; r_done = U.upd clr l.r_done gnd
      ; r_crcok = U.upd clr l.r_crcok gnd
      ; t_err = U.upd clr l.t_err (zero 3)
      ; r_err = U.upd clr l.r_err (zero 2)
      ; resp = List.map l.resp ~f:(fun q -> { q with fired = U.upd clr q.fired gnd })
      })
  in
  let off = ~:(g.owner_ok) in
  let w =
    setl w (fun l ->
      { l with
        t_st = U.upd off l.t_st (zero 3)
      ; t_req_v = U.upd off l.t_req_v gnd
      ; r_st = U.upd off l.r_st (zero 2)
      ; r_wv = U.upd off l.r_wv gnd
      })
  in
  let w, boundary, shift_edge = receiver ctx g w ~cmd in
  let w, wrote = transmitter ctx g w ~cmd ~q_now_v ~q_now_k ~boundary ~shift_edge in
  (* pad override *)
  let l = w.c.line in
  let txp = select (lc w 3) 3 0 in
  let mine pin = U.get_at w.c.owner pin ~default:(U.k 3 7) ==: uresize l.owner 3 in
  let m0 = mux2 (mine txp) (U.onehot 16 txp) (zero 16) in
  let m1 = mux2 (c_ g 1 &: (txp <:. 15) &: mine (txp +:. 1)) (U.onehot 16 (txp +:. 1)) (zero 16) in
  let m = m0 |: m1 in
  let v =
    (U.onehot 16 txp &: repeat (bit l.t_out 0) 16) |: (U.onehot 16 (uresize txp 5 +:. 1 |> fun x -> select x 3 0) &: repeat (bit l.t_out 1) 16 &: repeat (txp <:. 15) 16)
  in
  let v = mux2 l.t_rel w.c.value v &: m in
  let rise = m &: v &: ~:(w.c.value) and fall = m &: ~:v &: w.c.value in
  let drive = wrote &: g.owner_ok in
  let bs = Core.blocking w ~rise ~fall in
  let anyb = U.any bs in
  let w =
    tmp w (fun x ->
      let ok = drive &: ~:anyb in
      { x with
        l_mask = U.upd ok x.l_mask m
      ; l_val = U.upd ok x.l_val v
      ; l_dir = U.upd ok x.l_dir (mux2 l.t_rel (zero 8) (select m 7 0))
      })
  in
  let firsts = Core.first_of bs in
  let w = List.foldi firsts ~init:w ~f:(fun k w fk -> w_if (drive &: fk) w (fun w -> Core.record ctx w k ~max_kind:gnd)) in
  let stopped = drive &: anyb in
  let w = setl w (fun l -> { l with t_st = U.upd stopped l.t_st (zero 3); t_req_v = U.upd stopped l.t_req_v gnd; t_err = U.upd stopped l.t_err (l.t_err |:. 2) }) in
  (* data memory, system slot: a received word first *)
  let slot = select ctx.n 1 0 ==:. 1 &: g.owner_ok in
  let l = w.c.line in
  let dbase = U.get_at (List.map w.c.th ~f:(fun t -> t.dbase)) l.owner ~default:(zero 10) in
  let dsize = U.get_at (List.map w.c.th ~f:(fun t -> t.dsize)) l.owner ~default:(zero 11) in
  let do_w = slot &: serve_w in
  let w =
    data_req w ~en:do_w ~wen:vdd
      ~addr:(dbase +: select (lc w 10) 9 0 +: serve_widx)
      ~din:serve_wd
  in
  let w = setl w (fun l -> { l with r_wv = U.upd do_w l.r_wv gnd }) in
  let do_r = slot &: ~:serve_w &: serve_r in
  let a = uresize (select (lc w 7) 9 0) 12 +: uresize serve_ridx 12 in
  let inwin = a <: uresize dsize 12 in
  let w = data_req w ~en:(do_r &: inwin) ~wen:gnd ~addr:(dbase +: select a 9 0) ~din:(zero 16) in
  let w =
    setl w (fun l ->
      { l with
        t_rd = do_r &: inwin
      ; t_next = U.upd (do_r &: ~:inwin) l.t_next (zero 16)
      ; t_err = U.upd (do_r &: ~:inwin) l.t_err (l.t_err |:. 1)
      ; t_nvalid = U.upd do_r l.t_nvalid vdd
      ; t_req_v = U.upd (do_r &: l.t_req_v &: (l.t_req ==: serve_ridx)) l.t_req_v gnd
      })
  in
  tmp w (fun x -> { x with l_slot = do_w |: do_r })
;;
