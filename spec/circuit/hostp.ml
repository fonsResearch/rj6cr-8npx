(* Host port, register map and loader (model: prog_write .. host_cycle). *)
open! Base
open Hardcaml
open Signal
open State
open W

let running (t : Signal.t Thread.t) = t.st ==:. 1 |: (t.st ==:. 2)
let hflag (w : Signal.t W.t) ~en b = { w with c = { w.c with hstat = w.c.hstat |: (U.onehot 5 (U.k 3 b) &: repeat en 5) } }

let crc16_word crc word =
  List.fold (List.range 0 32) ~init:crc ~f:(fun c i -> U.crc_bit_msb c (U.k 16 0x1021) (bit word (31 - i)))
;;

(* a write to the program memory (model: prog_write); [addr] 16 bits *)
let prog_write (ctx : ctx) (w : Signal.t W.t) ~en addr word =
  let a = select addr 8 0 in
  let a11 = uresize a 11 in
  let hits =
    List.map w.c.th ~f:(fun t -> a11 >=: uresize t.pbase 11 &: (a11 <: uresize t.pbase 11 +: uresize t.psize 11))
  in
  let refuse =
    U.any
      (List.map3_exn hits w.c.th ctx.s0.th ~f:(fun h t t0 ->
         h &: (running t0 |: (t.loading &: (a11 <>: uresize t.pbase 11 +: uresize t.load_count 11)))))
  in
  let w = hflag w ~en:(en &: refuse) 2 in
  let ok = en &: ~:refuse in
  let w = prog_req w ~en:ok ~wen:vdd ~addr:a ~din:word in
  List.foldi hits ~init:w ~f:(fun id w h ->
    map_th w id (fun t ->
      let go = ok &: h in
      { t with
        crc = U.upd (go &: t.loading) t.crc (crc16_word t.crc word)
      ; load_count = U.upd (go &: t.loading) t.load_count (t.load_count +:. 1)
      ; loaded = U.upd (go &: ~:(t.loading)) t.loaded gnd
      }))
;;

let do_start (ctx : ctx) (w : Signal.t W.t) ~en id =
  let t = th w id and t0 = U.nth ctx.s0.th id in
  let ok = t.loaded &: ~:(running t0) &: ~:(t0.armed) &: (uresize t.dbase 12 +: uresize t.dsize 12 <=:. 1024) in
  let w = hflag w ~en:(en &: ~:ok) 2 in
  map_th w id (fun t ->
    Thread.map2 t
      { t with
        pc = t.entry
      ; st = U.k 3 1
      ; fl_valid = gnd
      ; sm = zero 16
      ; em = zero 8
      ; sv = zero 16
      ; ev = zero 8
      ; evf = gnd
      ; late = gnd
      ; slack_min = U.k 16 0x7FFF
      }
      ~f:(U.upd (en &: ok)))
;;

let reg_peek (ctx : ctx) (_ : Signal.t W.t) addr =
  let c = ctx.s0 in
  let owners kk =
    concat_lsb (List.init 4 ~f:(fun j -> uresize (U.nth c.owner ((4 * kk) + j)) 4))
  in
  let filt base = concat_lsb (List.init 8 ~f:(fun j -> U.nth c.filt (base + j))) in
  let info (v : Signal.t Verdict.t) flag =
    mux2 v.valid (concat_msb [ vdd; v.max_kind; flag; zero 11; v.rule ]) (zero 16)
  in
  let cyc (v : Signal.t Verdict.t) hi = mux2 v.valid (if hi then select v.cycle 31 16 else select v.cycle 15 0) (zero 16) in
  let tr = c.trace in
  let thread_word (t : Signal.t Thread.t) j =
    let status_w =
      mux2 (t.st ==:. 4) (concat_msb [ t.farg; t.fcode; zero 1; t.st ]) (uresize t.st 16)
    in
    let words =
      [ zero 16; status_w; uresize t.entry 16; uresize t.pbase 16; uresize t.psize 16; uresize t.dbase 16
      ; uresize t.dsize 16; uresize t.strict 16; zero 16; mux2 t.out_v t.out_d (zero 16)
      ; uresize (concat_lsb [ ~:(t.in_v); t.out_v ]) 16; t.slack_min; t.digest; zero 16
      ; uresize (concat_lsb [ t.loaded; t.loading; t.late; t.evf ]) 16; uresize t.pc 16 ]
    in
    mux j words
  in
  let rule_word (r : Signal.t Rule.t) j =
    mux j
      [ r.sel_start; r.sel_stop; r.sel_abort; r.rmin; r.rmax
      ; uresize (concat_lsb [ r.en; r.guarantee; r.policy; r.owner; r.ps ]) 16
      ; uresize (concat_lsb [ r.active; r.v_min; r.v_max; r.repaired ]) 16; r.obs_min; r.obs_max; r.cnt; zero 16 ]
  in
  let g =
    [ 0x00, U.k 16 0x8401
    ; 0x01, U.k 16 (4 lor (1 lsl 4) lor (3 lsl 8))
    ; 0x02, select ctx.n 15 0
    ; 0x03, c.now_latch
    ; 0x04, uresize c.hstat 16
    ; 0x08, c.value
    ; 0x09, uresize c.dir 16
    ; 0x0A, select ctx.pv 15 0
    ; 0x0B, uresize (select ctx.pv 23 16) 16
    ; 0x10, owners 0; 0x11, owners 1; 0x12, owners 2; 0x13, owners 3
    ; 0x14, uresize c.od 16
    ; 0x15, c.safe_val
    ; 0x16, uresize c.safe_dir 16
    ; 0x18, filt 0
    ; 0x19, filt 16
    ; 0x20, info c.fail c.blame_before_fail
    ; 0x21, cyc c.fail false; 0x22, cyc c.fail true
    ; 0x24, info c.blame gnd
    ; 0x25, cyc c.blame false; 0x26, cyc c.blame true
    ; 0x30, uresize (concat_lsb [ tr.en; tr.freeze ]) 16
    ; 0x31, uresize tr.base 16
    ; 0x32, uresize tr.size 16
    ; 0x33, select tr.mask 15 0
    ; 0x34, uresize (select tr.mask 23 16) 16
    ; 0x35, concat_msb [ tr.wrapped; tr.frozen; zero 6; tr.ptr ]
    ; 0x36, uresize tr.post 16
    ]
  in
  let table =
    List.init 256 ~f:(fun a ->
      match List.Assoc.find g ~equal:Int.equal a with
      | Some v -> v
      | None ->
        if a >= 0xC0
        then Lregs.line_peek ~snap:c.line c.line (U.k 6 (a - 0xC0))
        else if a >= 0x40 && a < 0x70
        then thread_word (U.nth c.th ((a - 0x40) / 16)) (U.k 4 (a land 15))
        else if a >= 0x80 && a < 0xC0
        then rule_word (U.nth c.rules ((a - 0x80) / 16)) (U.k 4 (a land 15))
        else zero 16)
  in
  mux addr table
;;

let reg_read_done (ctx : ctx) (w : Signal.t W.t) ~en addr =
  List.fold (List.range 0 3) ~init:w ~f:(fun w id ->
    let hit = en &: (addr ==:. 0x40 + (16 * id) + 9) in
    let t = U.nth ctx.s0.th id in
    let w = hflag w ~en:(hit &: ~:(t.out_v)) 4 in
    map_th w id (fun t -> { t with out_v = U.upd hit t.out_v gnd }))
;;

let reg_write (ctx : ctx) (w : Signal.t W.t) ~en addr v =
  let at a = en &: (addr ==:. a) in
  let c = w.c in
  let c = { c with hstat = U.upd (at 0x04) c.hstat (c.hstat &: ~:(select v 4 0)) } in
  let c =
    { c with
      owner =
        List.mapi c.owner ~f:(fun pin o ->
          if pin = 8 then o else U.upd (at (0x10 + (pin / 4))) o (select v ((4 * (pin land 3)) + 2) (4 * (pin land 3))))
    }
  in
  let c =
    { c with
      od = U.upd (at 0x14) c.od (select v 7 0)
    ; safe_val = U.upd (at 0x15) c.safe_val v
    ; safe_dir = U.upd (at 0x16) c.safe_dir (select v 7 0)
    ; filt =
        List.mapi c.filt ~f:(fun q x ->
          if q < 8
          then U.upd (at 0x18) x (select v ((2 * q) + 1) (2 * q))
          else if q >= 16
          then U.upd (at 0x19) x (select v ((2 * (q - 16)) + 1) (2 * (q - 16)))
          else x)
    }
  in
  let clr = at 0x27 &: lsb v in
  let c =
    { c with
      fail = { c.fail with valid = U.upd clr c.fail.valid gnd }
    ; blame = { c.blame with valid = U.upd clr c.blame.valid gnd }
    ; blame_before_fail = U.upd clr c.blame_before_fail gnd
    }
  in
  let tr = c.trace in
  let tc = at 0x30 in
  let tr =
    { tr with
      en = U.upd tc tr.en (bit v 0)
    ; freeze = U.upd tc tr.freeze (bit v 1)
    ; ptr = U.upd tc tr.ptr (zero 8)
    ; wrapped = U.upd tc tr.wrapped gnd
    ; frozen = U.upd tc tr.frozen gnd
    ; trig = U.upd tc tr.trig gnd
    ; widx = U.upd tc tr.widx (U.k 3 4)
    ; lost = U.upd tc tr.lost gnd
    ; base = U.upd (at 0x31) tr.base (select v 9 0)
    ; size = U.upd (at 0x32) tr.size (mux2 (v >:. 256) (U.k 9 256) (select v 8 0))
    ; mask =
        (let m = U.upd (at 0x33) tr.mask (select tr.mask 23 16 @: v) in
         U.upd (at 0x34) m (select v 7 0 @: select m 15 0))
    ; post = U.upd (at 0x36) tr.post (select v 7 0)
    }
  in
  let c = { c with trace = tr } in
  let line_en = en &: (addr >=:. 0xC0) in
  let c = { c with line = Lregs.line_poke c.line ~en:line_en (select addr 5 0) v } in
  let w = { w with c } in
  (* threads *)
  let w =
    List.fold (List.range 0 3) ~init:w ~f:(fun w id ->
      let a j = at (0x40 + (16 * id) + j) in
      let t = th w id and t0 = U.nth ctx.s0.th id in
      let run = running t0 in
      (* register 0: commands *)
      let cmd = a 0 in
      let w = do_start ctx w ~en:(cmd &: (v ==:. 1)) id in
      let stop = cmd &: (v ==:. 2) &: ~:(t0.st ==:. 0) in
      let w = w_if stop w (fun w -> map_th (Core.enter_fault w id ~code:1 ~arg:(zero 8)) id (fun t -> { t with st = U.k 3 0 })) in
      let load_ok = ~:run &: (t.psize >=:. 1) &: (uresize t.pbase 11 +: uresize t.psize 11 <=:. 512) in
      let ld = cmd &: (v ==:. 3) in
      let w = hflag w ~en:((ld &: ~:load_ok) |: (cmd &: ~:(v ==:. 1) &: ~:(v ==:. 2) &: ~:(v ==:. 3))) 2 in
      let w =
        map_th w id (fun t ->
          let g = ld &: load_ok in
          { t with
            loading = U.upd g t.loading vdd
          ; loaded = U.upd g t.loaded gnd
          ; crc = U.upd g t.crc (U.k 16 0xFFFF)
          ; load_count = U.upd g t.load_count (zero 10)
          })
      in
      (* registers that need a stopped thread *)
      let stopped j = a j &: ~:run in
      let w = hflag w ~en:(run &: U.any (List.map [ 2; 3; 4; 5; 6 ] ~f:a)) 2 in
      let w = hflag w ~en:((stopped 4 &: (v >:. 512)) |: (stopped 6 &: (v >:. 1024))) 2 in
      let w =
        map_th w id (fun t ->
          let p3 = stopped 3 and p4 = stopped 4 &: ~:(v >:. 512) in
          { t with
            entry = U.upd (stopped 2) t.entry (select v 9 0)
          ; pbase = U.upd p3 t.pbase (select v 8 0)
          ; psize = U.upd p4 t.psize (select v 9 0)
          ; loaded = U.upd (p3 |: p4) t.loaded gnd
          ; loading = U.upd (p3 |: p4) t.loading gnd
          ; dbase = U.upd (stopped 5) t.dbase (select v 9 0)
          ; dsize = U.upd (stopped 6 &: ~:(v >:. 1024)) t.dsize (select v 10 0)
          ; strict = U.upd (a 7) t.strict (lsb v)
          })
      in
      (* mailbox to the thread: full or not as at the start of the cycle *)
      let full0 = t0.in_v in
      let w = hflag w ~en:(a 8 &: full0) 3 in
      let w = map_th w id (fun t -> { t with in_v = U.upd (a 8) t.in_v vdd; in_d = U.upd (a 8 &: ~:full0) t.in_d v }) in
      (* end of a load *)
      let t = th w id in
      let good = a 13 &: t.loading &: (uresize t.load_count 16 ==: uresize t.psize 16) &: (t.crc ==: v) in
      let w = hflag w ~en:(a 13 &: ~:good) 1 in
      map_th w id (fun t ->
        { t with
          loaded = U.upd good t.loaded vdd
        ; digest = U.upd good t.digest t.crc
        ; loading = U.upd (a 13) t.loading gnd
        }))
  in
  (* rules *)
  List.fold (List.range 0 4) ~init:w ~f:(fun w k ->
    let a j = at (0x80 + (16 * k) + j) in
    let r = rule w k in
    let a5 = a 5 in
    set_rule w k
      { Rule.sel_start = U.upd (a 0) r.sel_start v
      ; sel_stop = U.upd (a 1) r.sel_stop v
      ; sel_abort = U.upd (a 2) r.sel_abort v
      ; rmin = U.upd (a 3) r.rmin v
      ; rmax = U.upd (a 4) r.rmax v
      ; en = U.upd a5 r.en (bit v 0)
      ; guarantee = U.upd a5 r.guarantee (bit v 1)
      ; policy = U.upd a5 r.policy (select v 3 2)
      ; owner = U.upd a5 r.owner (select v 5 4)
      ; ps = U.upd a5 r.ps (select v 7 6)
      ; active = U.upd a5 r.active gnd
      ; cnt = U.upd a5 r.cnt (zero 16)
      ; v_min = U.upd a5 r.v_min gnd
      ; v_max = U.upd a5 r.v_max gnd
      ; repaired = U.upd a5 r.repaired gnd
      ; obs_min = U.upd a5 r.obs_min (U.k 16 0xFFFF)
      ; obs_max = U.upd a5 r.obs_max (zero 16)
      })
;;

(* SPI command byte -> valid, region (0 registers, 1 program, 2 data), write, increment *)
let cmd_info cmd =
  let cases = [ 0x10, 0, false, false; 0x11, 0, false, true; 0x20, 0, true, false; 0x21, 0, true, true
              ; 0x30, 1, false, true; 0x40, 1, true, true; 0x50, 2, false, true; 0x60, 2, true, true ] in
  let hit = List.map cases ~f:(fun (c, rg, wr, inc) -> cmd ==:. c, rg, wr, inc) in
  let valid = U.any (List.map hit ~f:(fun (h, _, _, _) -> h)) in
  let pick f = U.any (List.map hit ~f:(fun (h, rg, wr, inc) -> if f rg wr inc then h else gnd)) in
  valid, pick (fun rg _ _ -> rg = 0), pick (fun rg _ _ -> rg = 1), pick (fun rg _ _ -> rg = 2), pick (fun _ wr _ -> wr), pick (fun _ _ inc -> inc)
;;

let peek_into (ctx : ctx) (w : Signal.t W.t) ~en addr =
  let v = reg_peek ctx w addr in
  let w = { w with c = { w.c with now_latch = U.upd (en &: (addr ==:. 2)) w.c.now_latch (select ctx.n 31 16) } } in
  let h = w.c.host in
  { w with c = { w.c with host = { h with osh = U.upd en h.osh (v @: zero 16) } } }
;;

let host_cycle (ctx : ctx) (w : Signal.t W.t) ~slot_free =
  let h = w.c.host in
  let slot = select ctx.n 1 0 in
  (* a waiting memory access is done in the system slot of its memory *)
  let service = h.rq_v &: ((h.rq_prog &: (slot ==:. 3)) |: (~:(h.rq_prog) &: (slot ==:. 1) &: slot_free)) in
  let pw = service &: h.rq_prog &: h.rq_write and pr = service &: h.rq_prog &: ~:(h.rq_write) in
  let dw = service &: ~:(h.rq_prog) &: h.rq_write and dr = service &: ~:(h.rq_prog) &: ~:(h.rq_write) in
  let w = prog_write ctx w ~en:pw h.rq_addr h.rq_data in
  let w = prog_req w ~en:pr ~wen:gnd ~addr:(select h.rq_addr 8 0) ~din:(zero 32) in
  let w = data_req w ~en:(dw |: dr) ~wen:dw ~addr:(select h.rq_addr 9 0) ~din:(select h.rq_data 15 0) in
  let set_h (w : Signal.t W.t) f = { w with c = { w.c with host = f w.c.host } } in
  let w = set_h w (fun h -> { h with rq_v = U.upd service h.rq_v gnd; rd_p = pr; rd_d = dr }) in
  (* SPI: SCK = P16, MOSI = P17, CS_N = P18, synchronised *)
  let pv = ctx.pv and pp = ctx.pv_prev in
  let cs = bit pv 18 and sck = bit pv 16 and sck_prev = bit pp 16 and mosi = bit pv 17 in
  let w =
    w_if cs w (fun w -> set_h w (fun h -> { h with count = zero 6; cmod = zero 5; cmd = zero 8; miso = gnd; osh = zero 32 }))
  in
  let rise = ~:cs &: ~:sck_prev &: sck in
  let fall = ~:cs &: sck_prev &: ~:sck in
  let w =
    w_if rise w (fun w ->
      let h = w.c.host in
      let sh = select h.sh 30 0 @: mosi in
      let c = mux2 (h.count ==:. 63) h.count (h.count +:. 1) in
      let cm = h.cmod +:. 1 in
      let w = set_h w (fun h -> { h with sh; count = c; cmod = cm }) in
      let c8 = c ==:. 8 in
      let valid_new, _, _, _, _, _ = cmd_info (select sh 7 0) in
      let w = set_h w (fun h -> { h with cmd = U.upd c8 h.cmd (select sh 7 0) }) in
      let w = hflag w ~en:(c8 &: ~:valid_new) 0 in
      let valid, is_reg, is_prog, is_data, write, inc = cmd_info h.cmd in
      let other = ~:c8 &: valid in
      (* registers *)
      let r16 = other &: is_reg &: (c ==:. 16) in
      let rword = other &: is_reg &: (c >:. 16) &: (select cm 3 0 ==:. 0) in
      let w = set_h w (fun h -> { h with haddr = U.upd r16 h.haddr (uresize (select sh 7 0) 16) }) in
      let w = peek_into ctx w ~en:(r16 &: ~:write) (select (w.c.host.haddr) 7 0) in
      let haddr0 = select w.c.host.haddr 7 0 in
      let w = reg_write ctx w ~en:(rword &: write) haddr0 (select sh 15 0) in
      let w = reg_read_done ctx w ~en:(rword &: ~:write) haddr0 in
      let w =
        set_h w (fun h ->
          { h with haddr = U.upd (rword &: inc) h.haddr (uresize (select h.haddr 7 0 +:. 1) 16) })
      in
      let w = peek_into ctx w ~en:(rword &: ~:write) (select w.c.host.haddr 7 0) in
      (* memories *)
      let mem = other &: (is_prog |: is_data) in
      let a24 = mem &: (c ==:. 24) in
      let first_ok = mux2 write (c >=:. 24) (c >=:. 32) in
      let phase =
        mux2 is_prog (mux2 write (cm ==:. 24) (cm ==:. 0)) (mux2 write (select cm 3 0 ==:. 8) (select cm 3 0 ==:. 0))
      in
      let mword = mem &: ~:(c ==:. 24) &: first_ok &: phase in
      let w = set_h w (fun h -> { h with haddr = U.upd a24 h.haddr (select sh 15 0) }) in
      let w =
        set_h w (fun h ->
          let hn = h.haddr +:. 1 in
          let rd_req = (a24 &: ~:write) |: (mword &: ~:write) in
          let wr_req = mword &: write in
          { h with
            osh = U.upd (mword &: ~:write) h.osh (mux2 is_prog h.rbuf (select h.rbuf 15 0 @: zero 16))
          ; rq_v = U.upd (rd_req |: wr_req) h.rq_v vdd
          ; rq_prog = U.upd (rd_req |: wr_req) h.rq_prog is_prog
          ; rq_write = U.upd (rd_req |: wr_req) h.rq_write wr_req
          ; rq_addr = U.upd (rd_req |: wr_req) h.rq_addr (mux2 (mword &: ~:write) hn h.haddr)
          ; rq_data = U.upd wr_req h.rq_data (mux2 is_prog sh (uresize (select sh 15 0) 32))
          ; haddr = U.upd mword h.haddr hn
          })
      in
      w)
  in
  w_if fall w (fun w -> set_h w (fun h -> { h with miso = msb h.osh; osh = sll h.osh 1 }))
;;
