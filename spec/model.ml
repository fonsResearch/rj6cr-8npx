(* Reference model of the chip, one call of [step] per clock cycle. It is the executable form of
   doc/spec/machine.md (threads, timing hardware, pads), rules.md (rule engine), host.md (host port
   and loader), trace.md (trace) and line.md (line unit and response rules). spec/circuit/ is the
   same specification as a circuit; log/xcheck.md compares the two.

   Version 1.1 (doc/decisions/spec_v1_1.md): every block reads the other blocks' registers from
   [view], a copy of the state taken at the start of [step]; writes go to the live state in the
   v1.0 order of blocks, which fixes the merges. *)
open Isa

let m16 = 0xFFFF
let m32 = 0xFFFF_FFFF
let sext16 v = if v land 0x8000 <> 0 then v - 0x10000 else v

let sext32 v =
  let v = v land m32 in
  if v land 0x8000_0000 <> 0 then v - 0x1_0000_0000 else v
;;

type fault =
  | Illegal
  | Pcbound
  | Dbound
  | Pinown
  | Late
  | Ioperm
  | Trap of int
  | Rule of int

let fault_name = function
  | Illegal -> "ILLEGAL"
  | Pcbound -> "PCBOUND"
  | Dbound -> "DBOUND"
  | Pinown -> "PINOWN"
  | Late -> "LATE"
  | Ioperm -> "IOPERM"
  | Trap c -> Printf.sprintf "TRAP %d" c
  | Rule c -> Printf.sprintf "RULE %d" c
;;

type state =
  | Idle
  | Run
  | Wait_ev
  | Halted
  | Faulted of fault

type wait =
  { on_pin : bool
  ; idx : int
  ; cond : int
  ; w_to : bool
  ; w_cm : bool
  ; w_re : bool
  ; w_adv : bool
  ; mutable w_due : int (* 0 waiting, 1 event seen, 2 deadline reached; not 0: commit pending *)
  }

(* One interval rule (doc/spec/rules.md). *)
type rule =
  { mutable en : bool
  ; mutable guarantee : bool (* false: assumption about the peer *)
  ; mutable policy : int (* 0 observe, 1 hold to minimum, 2 fail-stop, 3 as 0 *)
  ; mutable owner : int (* thread 0..2, 3 none *)
  ; mutable ps : int (* time unit 16^ps cycles *)
  ; mutable sel_start : int
  ; mutable sel_stop : int
  ; mutable sel_abort : int
  ; mutable rmin : int
  ; mutable rmax : int
  ; mutable active : bool
  ; mutable cnt : int
  ; mutable v_min : bool
  ; mutable v_max : bool
  ; mutable repaired : bool
  ; mutable obs_min : int
  ; mutable obs_max : int
  }

type verdict =
  { v_rule : int
  ; v_max_kind : bool (* false: minimum violated, true: maximum *)
  ; v_cycle : int
  }

type thread =
  { id : int
  ; mutable state : state
  ; r : int array
  ; mutable pc : int
  ; mutable t_int : int
  ; mutable t_frac : int
  ; mutable p : int
  ; mutable armed : bool
  ; mutable due : bool
  ; mutable adv : bool
  ; mutable deadline : bool (* the armed commit belongs to the deadline t *)
  ; mutable sv : int
  ; mutable sm : int
  ; mutable ev : int
  ; mutable em : int
  ; mutable cap : int
  ; mutable evf : bool
  ; mutable late : bool
  ; mutable slack_min : int
  ; mutable wait : wait option
  ; mutable pbase : int
  ; mutable psize : int
  ; mutable dbase : int
  ; mutable dsize : int
  ; mutable strict : bool
  ; mutable loaded : bool (* the program window holds a completed, checked load *)
  ; mutable loading : bool
  ; mutable load_count : int
  ; mutable crc : int
  ; mutable digest : int
  ; mutable entry : int
  ; mutable flight : (int * int) option (* fetch cycle, word; word -1 = fetch outside the window *)
  ; mutable mem_rd : int
  ; inbox : int Queue.t
  ; outbox : int Queue.t
  }

(* SPI side of the host port. *)
type host =
  { mutable count : int (* bits received in this transaction *)
  ; mutable sh : int (* input shift register *)
  ; mutable cmd : int
  ; mutable haddr : int
  ; mutable osh : int (* output shift register, bit 31 first *)
  ; mutable miso : int
  ; mutable rbuf : int (* memory word read ahead *)
  ; mutable rpend : int option (* a word read in the previous cycle, entering rbuf now *)
  ; mutable req : (bool * bool * int * int) option (* program memory?, write?, address, data *)
  }

(* Line unit and response rules (doc/spec/line.md). *)
type resp =
  { mutable q_ctl : int
  ; mutable q_match : int
  ; mutable q_pos : int
  ; mutable q_reply : int
  ; mutable q_len : int
  ; mutable q_fired : bool
  }

type line =
  { mutable l_owner : int (* thread 0..2, 3: none *)
  ; lc : int array (* configuration registers 1..17, indexed as in the I/O map *)
  ; resp : resp array
  ; mutable l_cmd : int (* command bits written during the previous cycle *)
  ; l_snap : int array (* what a thread reads during this cycle: status, rcnt, hist, rcrc, tcnt *)
  ; mutable l_ev : int (* class 6 events of this cycle *)
  ; mutable l_mask : int (* pad override of this cycle: pins, values, directions *)
  ; mutable l_val : int
  ; mutable l_dir : int
  ; mutable q_pend : int option (* response rule that fired in the previous cycle *)
  (* transmitter *)
  ; mutable t_st : int (* 0 idle, 1 load, 2 frame, 3 tail, 4 reply wait, 5 reply *)
  ; mutable t_acc : int
  ; mutable t_bnd : bool
  ; mutable t_sent : int
  ; mutable t_word : int
  ; mutable t_next : int
  ; mutable t_nvalid : bool
  ; mutable t_req : int option (* index of the word to read *)
  ; mutable t_crc : int
  ; mutable t_crcleft : int
  ; mutable t_run : int
  ; mutable t_last : int
  ; mutable t_line : int
  ; mutable t_bit : int
  ; mutable t_half : bool
  ; mutable t_tail : int
  ; mutable t_out : int (* levels of the transmit pin [0] and its partner [1] *)
  ; mutable t_rel : bool
  ; mutable t_rwait : int
  ; mutable t_rleft : int
  ; mutable t_rsh : int
  ; mutable t_rtail : bool
  ; mutable t_done : bool
  ; mutable t_err : int (* [0] word missing or outside the window, [1] stopped by a rule, [2] reply lost *)
  (* receiver *)
  ; mutable r_st : int (* 0 off, 1 armed, 2 hunt, 3 data *)
  ; mutable r_idle_seen : bool
  ; mutable r_ph : int
  ; mutable r_lv : int
  ; mutable r_prev : int
  ; mutable r_hcnt : int
  ; mutable r_cnt : int
  ; mutable r_sh : int
  ; mutable r_hist : int
  ; mutable r_crc : int
  ; mutable r_run : int
  ; mutable r_last : int
  ; mutable r_quiet : int
  ; mutable r_wbuf : (int * int) option (* word index, data *)
  ; mutable r_done : bool
  ; mutable r_crcok : bool
  ; mutable r_err : int (* [0] stuffing violated, [1] a word was lost *)
  }

(* The rule engine's inputs of one cycle, registered for the next (V3, v1.1). *)
type rule_in =
  { ri_valid : bool (* false in the first cycle after reset *)
  ; ri_n : int (* the cycle the events belong to *)
  ; ri_wrise : int (* wire edges P0..P23 *)
  ; ri_wfall : int
  ; ri_peer : int (* the pins whose edges are the peer's, at that cycle *)
  ; ri_rise : int (* commit edges P0..P15 *)
  ; ri_fall : int
  ; ri_emits : (int * int) list (* EMITs: (thread, code) *)
  ; ri_lev : int (* line unit symbol events *)
  }

let ri_none =
  { ri_valid = false; ri_n = 0; ri_wrise = 0; ri_wfall = 0; ri_peer = 0; ri_rise = 0; ri_fall = 0
  ; ri_emits = []; ri_lev = 0 }
;;

type chip =
  { mutable now : int
  ; prog : int array
  ; data : int array
  ; th : thread array
  ; mutable value : int (* P0..P15 output values *)
  ; mutable dir : int (* P0..P7 output enables *)
  ; mutable value_n : int
  ; mutable dir_n : int
  ; owner : int array (* per pin P0..P15: 0..2 thread, anything else: no thread *)
  ; mutable od : int (* P0..P7 open-drain mode *)
  ; mutable safe_val : int
  ; mutable safe_dir : int
  ; filt : int array (* per pin P0..P23: glitch filter length 0..3 *)
  ; mutable x : int (* first synchroniser stage *)
  ; mutable s : int (* synchronised, filtered inputs *)
  ; fcnt : int array
  ; mutable pv_prev : int
  ; mutable emits : (int * int * int) list (* cycle, thread, code; newest first *)
  ; fifo_depth : int
  ; rules : rule array
  ; mutable first_fail : verdict option
  ; mutable first_blame : verdict option
  ; mutable blame_before_fail : bool
  ; oe_hist : int array (* oe_hist.(k): uio_oe during cycle now - k *)
  ; mutable ev_rise : int (* edges committed in the current cycle, P0..P15 *)
  ; mutable ev_fall : int
  ; mutable cyc_emits : (int * int) list (* EMITs executed in the current cycle *)
  ; mutable cyc_emits_prev : (int * int) list (* EMITs of the previous cycle, as the trace sees them *)
  ; mutable ri : rule_in (* the rule engine's inputs of the previous cycle (V3, v1.1) *)
  ; mutable ri_faults : (int * int) list (* (rule, owner) faults found by this cycle's rule step *)
  ; mutable hstat : int (* host status flags *)
  ; mutable now_latch : int
  ; host : host
  ; mutable tr_en : bool
  ; mutable tr_freeze : bool (* stop recording after a verdict *)
  ; mutable tr_base : int
  ; mutable tr_size : int (* records *)
  ; mutable tr_mask : int (* pins whose changes are recorded *)
  ; mutable tr_post : int (* records still taken after the verdict *)
  ; mutable tr_ptr : int
  ; mutable tr_wrapped : bool
  ; mutable tr_frozen : bool
  ; mutable tr_trig : bool
  ; mutable tr_left : int
  ; tr_rec : int array (* the record being written *)
  ; mutable tr_widx : int (* next word of it; 4: none in progress *)
  ; mutable tr_lost : bool
  ; line : line
  }

let no_owner = 7

let new_thread id =
  { id; state = Idle; r = Array.make 8 0; pc = 0; t_int = 0; t_frac = 0; p = 0
  ; armed = false; due = false; adv = false; deadline = false; sv = 0; sm = 0; ev = 0; em = 0; cap = 0
  ; evf = false; late = false; slack_min = 32767; wait = None
  ; pbase = 0; psize = 0; dbase = 0; dsize = 0; strict = true
  ; loaded = false; loading = false; load_count = 0; crc = 0; digest = 0; entry = 0
  ; flight = None; mem_rd = 0; inbox = Queue.create (); outbox = Queue.create () }
;;

let new_rule () =
  { en = false; guarantee = false; policy = 0; owner = 3; ps = 0; sel_start = 0x380; sel_stop = 0x380
  ; sel_abort = 0x380; rmin = 0; rmax = 0xFFFF; active = false; cnt = 0; v_min = false; v_max = false
  ; repaired = false; obs_min = 0xFFFF; obs_max = 0 }
;;

let new_line () =
  { l_owner = 3; lc = Array.make 18 0
  ; resp = Array.init 2 (fun _ -> { q_ctl = 0; q_match = 0; q_pos = 0; q_reply = 0; q_len = 0; q_fired = false })
  ; l_cmd = 0; l_snap = Array.make 5 0; l_ev = 0; l_mask = 0; l_val = 0; l_dir = 0; q_pend = None
  ; t_st = 0; t_acc = 0; t_bnd = false; t_sent = 0; t_word = 0; t_next = 0; t_nvalid = false; t_req = None
  ; t_crc = 0; t_crcleft = 0; t_run = 0; t_last = 0; t_line = 0; t_bit = 0; t_half = false; t_tail = 0
  ; t_out = 0; t_rel = false; t_rwait = 0; t_rleft = 0; t_rsh = 0; t_rtail = false; t_done = false; t_err = 0
  ; r_st = 0; r_idle_seen = false; r_ph = 0; r_lv = 0; r_prev = 0; r_hcnt = 0; r_cnt = 0; r_sh = 0; r_hist = 0
  ; r_crc = 0; r_run = 0; r_last = 0; r_quiet = 0; r_wbuf = None; r_done = false; r_crcok = false; r_err = 0 }
;;

let create ?(fifo_depth = 1) ?(n_rules = 4) () =
  { now = 0; prog = Array.make 512 0; data = Array.make 1024 0; th = Array.init 3 new_thread
  ; value = 0; dir = 0; value_n = 0; dir_n = 0; owner = Array.make 16 no_owner; od = 0
  ; safe_val = 0; safe_dir = 0; filt = Array.make 24 0; x = 0; s = 0; fcnt = Array.make 24 0
  ; pv_prev = 0; emits = []; fifo_depth; rules = Array.init n_rules (fun _ -> new_rule ())
  ; first_fail = None; first_blame = None; blame_before_fail = false; oe_hist = Array.make 8 0
  ; ev_rise = 0; ev_fall = 0; cyc_emits = []; cyc_emits_prev = []; ri = ri_none; ri_faults = []; hstat = 0; now_latch = 0
  ; host = { count = 0; sh = 0; cmd = 0; haddr = 0; osh = 0; miso = 0; rbuf = 0; rpend = None; req = None }
  ; tr_en = false; tr_freeze = false; tr_base = 0; tr_size = 0; tr_mask = 0; tr_post = 4; tr_ptr = 0
  ; tr_wrapped = false; tr_frozen = false; tr_trig = false; tr_left = 0; tr_rec = Array.make 4 0
  ; tr_widx = 4; tr_lost = false; line = new_line () }
;;

(* The registers as they are at the start of a cycle: what a block reads of the other blocks
   (doc/decisions/spec_v1_1.md, V1). The memories are shared, not copied: no reader of the
   copy reads them. *)
let copy_thread th =
  { th with r = Array.copy th.r; wait = Option.map (fun w -> { w with w_due = w.w_due }) th.wait
  ; inbox = Queue.copy th.inbox; outbox = Queue.copy th.outbox }
;;

let copy_line l =
  { l with lc = Array.copy l.lc; resp = Array.map (fun q -> { q with q_ctl = q.q_ctl }) l.resp
  ; l_snap = Array.copy l.l_snap }
;;

let copy_chip c =
  { c with th = Array.map copy_thread c.th; owner = Array.copy c.owner; filt = Array.copy c.filt
  ; fcnt = Array.copy c.fcnt; rules = Array.map (fun r -> { r with en = r.en }) c.rules
  ; oe_hist = Array.copy c.oe_hist; host = { c.host with count = c.host.count }
  ; tr_rec = Array.copy c.tr_rec; line = copy_line c.line }
;;

(* --- pins --- *)

(* What a thread reads: P0..P7 and P16..P23 synchronised inputs, P8..P15 the output values. *)
let pins chip = chip.s land 0xFF00FF lor (chip.value land 0xFF00)
let uo_out chip = (chip.value lsr 8) land 0xFF
let uio_out chip = chip.value land 0xFF land lnot chip.od
let uio_oe chip = chip.dir land 0xFF land lnot (chip.od land chip.value)

let owned_mask chip tid =
  let m = ref 0 in
  Array.iteri (fun p o -> if o = tid then m := !m lor (1 lsl p)) chip.owner;
  !m
;;

(* Commit: staged writes reach the pad registers, the pins are captured. *)
let commit chip th ~pv ~staged =
  if staged then begin
    let own = owned_mask chip th.id in
    let m = th.sm land own in
    chip.value_n <- chip.value_n land lnot m lor (th.sv land m);
    let me = th.em land own land 0xFF in
    chip.dir_n <- chip.dir_n land lnot me lor (th.ev land me);
    th.sm <- 0; th.em <- 0; th.sv <- 0; th.ev <- 0
  end;
  th.cap <- pv
;;

let add_p th =
  let total = (th.t_int lsl 8) lor th.t_frac in
  let total = total + th.p in
  th.t_int <- (total lsr 8) land m32;
  th.t_frac <- total land 0xFF
;;

let status ?view chip th =
  let v = Option.value view ~default:chip in
  (if th.evf then 1 else 0)
  lor (if Queue.is_empty th.inbox then 0 else 2)
  lor (if Queue.length th.outbox < chip.fifo_depth then 4 else 0)
  lor (if th.late then 8 else 0)
  lor (if v.first_fail <> None then 16 else 0)
  lor (if v.first_blame <> None then 32 else 0)
  lor (if Array.exists (fun r -> r.repaired) v.rules then 64 else 0)
  lor
  if v.line.l_owner = th.id
  then (
    (* line unit, as its owner sees it: 7 transmitter busy, 8 receiver in a frame, 9 frame
       received, 10 frame sent, 11 any error flag, 12 / 13 response rule 0 / 1 fired *)
    let st = v.line.l_snap.(0) in
    let b k = (st lsr k) land 1 in
    (b 0 lsl 7) lor (b 2 lsl 8) lor (b 4 lsl 9) lor (b 3 lsl 10)
    lor (if st land 0x7C0 <> 0 then 1 lsl 11 else 0)
    lor (b 12 lsl 12) lor (b 13 lsl 13))
  else 0
;;

(* A fault stops the thread and turns the safe pattern of its pins into a pending commit,
   which goes through the same path, and the same rule check, as every other commit. *)
let enter_fault chip th f =
  let own = owned_mask chip th.id in
  th.state <- Faulted f; th.wait <- None; th.flight <- None
  ; th.sm <- own; th.sv <- chip.safe_val land own; th.em <- own land 0xFF
  ; th.ev <- chip.safe_dir land own land 0xFF
  ; th.armed <- true; th.due <- true; th.deadline <- false; th.adv <- false
;;

(* --- rule engine: selectors, hold, verdicts --- *)

(* Event selector: [9:7] class, [6:5] qualifier, [4:0] index. Anything not listed never fires.
   class 0 / 1: rising / falling edge of pin index (0..23) as read; qualifier 0 any, 1 the
                peer's, 2 our own
   class 2 / 3: a commit raises / lowers the value of pin index (0..15)
   class 5:     the rule's owner thread executes EMIT with code index (0..31)
   class 6:     line unit symbol index (0..10), see line_cycle *)
let decode_sel sel =
  let cls = (sel lsr 7) land 7 and q = (sel lsr 5) land 3 and idx = sel land 31 in
  if sel lsr 10 <> 0
  then None
  else (
    match cls with
    | 0 | 1 -> if idx <= 23 && q <= 2 then Some (cls, q, idx) else None
    | 2 | 3 -> if idx <= 15 && q = 0 then Some (cls, q, idx) else None
    | 5 -> if q = 0 then Some (cls, q, idx) else None
    | 6 -> if q = 0 && idx <= 10 then Some (cls, q, idx) else None
    | _ -> None)
;;

let sel ?(qual = 0) cls idx = (cls lsl 7) lor (qual lsl 5) lor idx

(* Edges the pending commit of a thread would put on the pad value registers. *)
let proposed chip th =
  let m = th.sm land owned_mask chip th.id in
  m land th.sv land lnot chip.value, m land lnot th.sv land chip.value
;;

let record chip ~n k ~max_kind =
  let r = chip.rules.(k) in
  if max_kind then r.v_max <- true else r.v_min <- true;
  let v = Some { v_rule = k; v_max_kind = max_kind; v_cycle = n } in
  if r.guarantee
  then (
    if chip.first_fail = None
    then begin
      chip.first_fail <- v;
      chip.blame_before_fail <- chip.first_blame <> None
    end)
  else if chip.first_blame = None
  then chip.first_blame <- v
;;

(* May the pending commit of this thread reach the pads in cycle n? Decided from the rule
   state of this cycle only. A guarantee rule with policy hold or fail-stop that is active
   below its minimum blocks a commit containing its stop edge. Fail-stop also faults the
   thread, whose safe pattern then waits in the same way. *)
let blocking_rules chip ~rise ~fall =
  let blocking = ref [] in
  Array.iteri
    (fun k r ->
      if r.en && r.guarantee && (r.policy = 1 || r.policy = 2) && r.active && r.cnt < r.rmin
      then (
        match decode_sel r.sel_stop with
        | Some (2, _, pin) when (rise lsr pin) land 1 = 1 -> blocking := k :: !blocking
        | Some (3, _, pin) when (fall lsr pin) land 1 = 1 -> blocking := k :: !blocking
        | _ -> ()))
    chip.rules;
  List.rev !blocking
;;

let may_fire chip th ~n =
  let rise, fall = proposed chip th in
  match blocking_rules chip ~rise ~fall with
  | [] -> true
  | ks ->
    let faulted = match th.state with Faulted _ -> true | _ -> false in
    (match List.find_opt (fun k -> chip.rules.(k).policy = 2) ks with
     | Some k when not faulted ->
       record chip ~n k ~max_kind:false;
       enter_fault chip th (Rule k)
     | _ -> List.iter (fun k -> if chip.rules.(k).policy = 1 then chip.rules.(k).repaired <- true) ks);
    false
;;

(* The commit of a thread fires: its edges are events of this cycle. *)
let fire chip th ~pv ~staged =
  if staged
  then begin
    let rise, fall = proposed chip th in
    chip.ev_rise <- chip.ev_rise lor rise;
    chip.ev_fall <- chip.ev_fall lor fall
  end;
  commit chip th ~pv ~staged
;;

(* --- line unit registers (doc/spec/line.md); the unit itself is line_cycle below --- *)

let line_status (l : line) =
  (if l.t_st <> 0 then 1 else 0)
  lor (if l.r_st = 1 || l.r_st = 2 then 2 else 0)
  lor (if l.r_st = 3 then 4 else 0)
  lor (if l.t_done then 8 else 0)
  lor (if l.r_done then 16 else 0)
  lor (if l.r_crcok then 32 else 0)
  lor ((l.r_err land 3) lsl 6)
  lor ((l.t_err land 7) lsl 8)
  lor (if l.resp.(0).q_fired then 1 lsl 12 else 0)
  lor if l.resp.(1).q_fired then 1 lsl 13 else 0
;;

(* Registers of the unit by index: 0 command / status, 1..17 configuration, 18..21 read only,
   22 owner (host only); response rule k at 32 + 8 k + (0..4). *)
let line_peek ?(snap = false) (l : line) j =
  if j = 0
  then if snap then l.l_snap.(0) else line_status l
  else if j >= 1 && j <= 17
  then l.lc.(j)
  else if j >= 18 && j <= 21
  then
    if snap
    then l.l_snap.(j - 17)
    else (match j with 18 -> l.r_cnt | 19 -> l.r_hist | 20 -> l.r_crc | _ -> l.t_sent)
  else if j = 22
  then l.l_owner
  else if j >= 32 && j < 48 && j land 7 <= 4
  then (
    let q = l.resp.((j - 32) / 8) in
    match j land 7 with
    | 0 -> q.q_ctl lor if q.q_fired then 0x8000 else 0
    | 1 -> q.q_match
    | 2 -> q.q_pos
    | 3 -> q.q_reply
    | _ -> q.q_len)
  else 0
;;

let line_poke (l : line) j v =
  let v = v land m16 in
  if j = 0
  then l.l_cmd <- l.l_cmd lor (v land 31)
  else if j >= 1 && j <= 17
  then l.lc.(j) <- v
  else if j = 22
  then l.l_owner <- v land 3
  else if j >= 32 && j < 48 && j land 7 <= 4
  then (
    let q = l.resp.((j - 32) / 8) in
    match j land 7 with
    | 0 ->
      q.q_ctl <- v land 0x3FFF;
      q.q_fired <- false
    | 1 -> q.q_match <- v
    | 2 -> q.q_pos <- v land 0x3FFF
    | 3 -> q.q_reply <- v
    | _ -> q.q_len <- v land 63)
;;

(* Which registers a thread may address: I/O address 0x40 + index, the owner register excluded. *)
let line_io_index addr =
  let j = addr - 0x40 in
  if (j >= 0 && j <= 21) || (j >= 32 && j < 48 && j land 7 <= 4) then Some j else None
;;

(* --- instruction semantics --- *)

let alu fn a b =
  match fn with
  | 0 -> (a + b) land m16
  | 1 -> (a - b) land m16
  | 2 -> a land b
  | 3 -> a lor b
  | 4 -> a lxor b
  | 5 -> a land lnot b land m16
  | 6 -> if a < b then 1 else 0
  | 7 -> if sext16 a < sext16 b then 1 else 0
  | _ -> b
;;

let shift kind a n =
  match kind with
  | 0 -> (a lsl n) land m16
  | 1 -> a lsr n
  | 2 -> (sext16 a asr n) land m16
  | 3 -> ((a lsl n) lor (a lsr (16 - n))) land m16
  | _ -> ((a lsr n) lor (a lsl (16 - n))) land m16
;;

let crc_bit ~refl crc poly d =
  if refl
  then (
    let fb = crc land 1 lxor d in
    let c = crc lsr 1 in
    if fb = 1 then c lxor poly else c)
  else (
    let fb = (crc lsr 15) land 1 lxor d in
    let c = (crc lsl 1) land m16 in
    if fb = 1 then c lxor poly else c)
;;

let crc_step ~refl ~byte crc data poly =
  if not byte
  then crc_bit ~refl crc poly (data land 1)
  else (
    let c = ref crc in
    for k = 0 to 7 do
      let d = if refl then (data lsr k) land 1 else (data lsr (7 - k)) land 1 in
      c := crc_bit ~refl !c poly d
    done;
    !c)
;;

let cond c a b =
  match c with
  | 0 -> a = b
  | 1 -> a <> b
  | 2 -> a < b
  | 3 -> a >= b
  | 4 -> sext16 a < sext16 b
  | _ -> sext16 a >= sext16 b
;;

(* Effective data address of a memory instruction, or None if it is outside the window. *)
let mem_target th (i : instr) =
  let a = arg i in
  let ea =
    match i.def.op with
    | Ld | St -> Some (a "addr")
    | Ldx | Stx -> Some ((th.r.(a "ra") + a "off") land m16)
    | _ -> None
  in
  match ea with
  | None -> None
  | Some ea -> Some (if ea < th.dsize then Some ((th.dbase + ea) land 1023) else None)
;;

(* Cycle c+2 of an instruction fetched in cycle c: the data memory access. *)
let mem_access chip th w =
  match decode w with
  | None -> ()
  | Some i ->
    (match mem_target th i with
     | Some (Some phys) ->
       (match i.def.op with
        | Ld | Ldx -> th.mem_rd <- chip.data.(phys)
        | _ -> chip.data.(phys) <- th.r.(arg i "rs"))
     | _ -> ())
;;

exception Fault_exn of fault
exception Blocked

(* Cycle c+3 of an instruction fetched in cycle c: everything else. All effects are
   collected first and applied only if the instruction neither waits nor faults. *)
let execute ?view chip th ~n ~pv w =
  let view = Option.value view ~default:chip in
  let e = (n + 1) land m32 in
  try
    if w < 0 then raise (Fault_exn Pcbound);
    let i = match decode w with Some i -> i | None -> raise (Fault_exn Illegal) in
    let a = arg i in
    if is_sync i && th.armed then raise Blocked;
    let r = th.r in
    let post = ref [] in
    let later f = post := f :: !post in
    let next_pc = ref (th.pc + 1) in
    let regw = ref None in
    let sv = ref th.sv and sm = ref th.sm and ev = ref th.ev and em = ref th.em in
    let own p = if chip.owner.(p) <> th.id then raise (Fault_exn Pinown) in
    let stage p v =
      own p;
      sm := !sm lor (1 lsl p);
      sv := !sv land lnot (1 lsl p) lor (v lsl p)
    in
    let stage_dir p v =
      own p;
      em := !em lor (1 lsl p);
      ev := !ev land lnot (1 lsl p) lor (v lsl p)
    in
    let t_int = ref th.t_int and t_frac = ref th.t_frac and p = ref th.p in
    let new_wait = ref None and halt = ref false and clr = ref 0 in
    let st = status ~view chip th in
    let pin_src () = if a "src" = 1 then th.cap else pv in
    let branch taken = if taken then next_pc := a "tgt" in
    (match i.def.op with
     | Nop -> ()
     | Alu -> regw := Some (a "rd", alu (a "fn") r.(a "ra") r.(a "rb"))
     | Alui -> regw := Some (a "rd", alu (a "fn") r.(a "rd") (a "imm"))
     | Shi -> regw := Some (a "rd", shift (a "kind") r.(a "ra") (a "amt"))
     | Shv -> regw := Some (a "rd", shift (a "kind") r.(a "ra") (r.(a "rb") land 15))
     | Crc -> regw := Some (a "rd", crc_step ~refl:(a "refl" = 1) ~byte:(a "byte" = 1) r.(a "rd") r.(a "ra") r.(a "rb"))
     | Ld | Ldx | St | Stx ->
       (match mem_target th i with
        | Some (Some _) -> if i.def.op = Ld || i.def.op = Ldx then regw := Some (a "rd", th.mem_rd)
        | _ -> raise (Fault_exn Dbound))
     | Jmp -> next_pc := a "tgt"
     | Jal ->
       regw := Some (a "rd", th.pc + 1);
       next_pc := a "tgt"
     | Jr -> if r.(a "ra") >= th.psize then raise (Fault_exn Pcbound) else next_pc := r.(a "ra")
     | Br -> branch (cond (a "cond") r.(a "ra") r.(a "rb"))
     | Bri -> branch (cond (a "cond") r.(a "ra") (a "imm"))
     | Djnz ->
       let v = (r.(a "rd") - 1) land m16 in
       regw := Some (a "rd", v);
       branch (v <> 0)
     | Bbit -> branch ((r.(a "ra") lsr a "bit") land 1 = a "sense")
     | Bpin -> branch ((pin_src () lsr a "pin") land 1 = a "sense")
     | Bst -> branch ((st lsr a "bit") land 1 = a "sense")
     | Halt -> halt := true
     | Trap -> raise (Fault_exn (Trap (a "code")))
     | Pinv -> stage (a "p") (a "v")
     | Pdir -> stage_dir (a "p") (a "d")
     | Pinr -> stage (a "p") ((r.(a "ra") lsr a "bit") land 1)
     | Pinm -> for q = 0 to 15 do if (a "mask" lsr q) land 1 = 1 then stage q ((r.(a "ra") lsr q) land 1) done
     | Pdrm -> for q = 0 to 7 do if (a "mask" lsr q) land 1 = 1 then stage_dir q ((r.(a "ra") lsr q) land 1) done
     | Pini ->
       for q = 0 to 7 do
         if (a "mask" lsr q) land 1 = 1 then stage ((8 * a "grp") + q) ((a "val" lsr q) land 1)
       done
     | Pdri -> for q = 0 to 7 do if (a "mask" lsr q) land 1 = 1 then stage_dir q ((a "val" lsr q) land 1) done
     | Outs | Outsc ->
       let v = r.(a "rd") in
       let b, v' = if a "dir" = 0 then v land 1, v lsr 1 else (v lsr 15) land 1, (v lsl 1) land m16 in
       stage (a "p") b;
       regw := Some (a "rd", v');
       if i.def.op = Outsc then stage (a "cp") (a "cv")
     | Ins | Insc ->
       let b = (pin_src () lsr a "pin") land 1 in
       let v = r.(a "rd") in
       regw := Some (a "rd", if a "dir" = 0 then (b lsl 15) lor (v lsr 1) else ((v lsl 1) lor b) land m16);
       if i.def.op = Insc then stage (a "cp") (a "cv")
     | Pinrd ->
       let v = pin_src () in
       regw := Some (a "rd", if a "grp" = 0 then v land m16 else (v lsr 16) land 0xFF)
     | Tnow ->
       t_int := (e + a "imm") land m32;
       t_frac := 0
     | Taddi -> t_int := (!t_int + a "imm") land m32
     | Taddr -> t_int := (!t_int + r.(a "ra")) land m32
     | Tperi | Tperr ->
       let v = if i.def.op = Tperi then a "imm" else r.(a "ra") in
       p := if a "half" = 0 then !p land 0xFFFF_0000 lor v else !p land 0xFFFF lor (v lsl 16)
     | Tget ->
       let v =
         match a "sel" with
         | 0 -> e land m16
         | 1 -> e lsr 16
         | 2 -> th.t_int land m16
         | 3 -> th.t_int lsr 16
         | 4 -> th.slack_min land m16
         | 5 -> th.p land m16
         | _ -> th.p lsr 16
       in
       regw := Some (a "rd", v)
     | Tset ->
       t_int := (r.(a "ra") lsl 16) lor r.(a "rb");
       t_frac := 0
     | Waitp ->
       new_wait := Some { on_pin = true; idx = a "pin"; cond = a "cond"; w_to = a "to" = 1; w_cm = a "cm" = 1; w_re = a "re" = 1; w_adv = a "adv" = 1; w_due = 0 }
     | Waits ->
       new_wait := Some { on_pin = false; idx = a "bit"; cond = a "sense"; w_to = a "to" = 1; w_cm = a "cm" = 1; w_re = a "re" = 1; w_adv = a "adv" = 1; w_due = 0 }
     | Pull ->
       if a "ch" <> 0 || Queue.is_empty th.inbox then raise Blocked;
       regw := Some (a "rd", Queue.peek th.inbox);
       later (fun () -> ignore (Queue.pop th.inbox))
     | Push ->
       if a "ch" <> 0 || Queue.length th.outbox >= chip.fifo_depth then raise Blocked;
       let v = r.(a "ra") in
       later (fun () -> Queue.push v th.outbox)
     | Emit ->
       let code = a "code" in
       later (fun () ->
         chip.emits <- (e, th.id, code) :: chip.emits;
         chip.cyc_emits <- (th.id, code) :: chip.cyc_emits)
     | Ior ->
       let addr = a "addr" in
       let k = (addr - 0x20) / 4 in
       if addr = 0
       then regw := Some (a "rd", st)
       else if addr >= 0x20 && k < Array.length view.rules
       then (
         let r = view.rules.(k) in
         let v =
           match addr land 3 with
           | 0 ->
             (if r.active then 1 else 0)
             lor (if r.v_min then 2 else 0)
             lor (if r.v_max then 4 else 0)
             lor if r.repaired then 8 else 0
           | 1 -> r.obs_min
           | 2 -> r.obs_max
           | _ -> r.cnt
         in
         regw := Some (a "rd", v))
       else (
         match line_io_index addr with
         | Some j when view.line.l_owner = th.id -> regw := Some (a "rd", line_peek ~snap:true view.line j)
         | _ -> raise (Fault_exn Ioperm))
     | Iow | Iowi ->
       let addr = a "addr" in
       let v = if i.def.op = Iow then r.(a "ra") else a "imm" in
       if addr = 0
       then clr := v
       else (
         match line_io_index addr with
         | Some j when view.line.l_owner = th.id -> later (fun () -> line_poke chip.line j v)
         | _ -> raise (Fault_exn Ioperm)));
    (* timing: is the deadline still ahead? *)
    let uses_deadline = i.tm >= 2 || (match !new_wait with Some w -> w.w_to | None -> false) in
    let slack = sext32 (!t_int - e) in
    let is_late = uses_deadline && slack < 1 in
    if uses_deadline then th.slack_min <- min th.slack_min (max (-32768) (min 32767 slack));
    if is_late && th.strict then raise (Fault_exn Late);
    (* nothing below can fail: apply *)
    (match !regw with Some (rd, v) -> r.(rd) <- v land m16 | None -> ());
    th.pc <- !next_pc; th.sv <- !sv; th.sm <- !sm; th.ev <- !ev; th.em <- !em
    ; th.t_int <- !t_int; th.t_frac <- !t_frac; th.p <- !p;
    if !clr land 1 <> 0 then th.evf <- false;
    if !clr land 8 <> 0 then th.late <- false;
    if is_late then th.late <- true;
    (* every commit is carried out by the timing hardware, from the next cycle on *)
    (match i.tm with
     | 1 ->
       th.armed <- true; th.due <- true; th.deadline <- false; th.adv <- false
     | 2 | 3 ->
       th.armed <- true; th.due <- is_late; th.deadline <- true; th.adv <- i.tm = 3
     | _ -> ());
    (match !new_wait with
     | Some wt ->
       if is_late then wt.w_due <- 2;
       th.state <- Wait_ev;
       th.wait <- Some wt
     | None -> ());
    if !halt then th.state <- Halted;
    List.iter (fun f -> f ()) (List.rev !post)
  with
  | Blocked -> ()
  | Fault_exn f -> enter_fault chip th f
;;

(* Timing hardware of one thread in cycle n. A commit that is due fires unless the rule
   engine blocks it; a deadline commit that fires in another cycle than t - 1, because it
   was late or blocked, moves t to the cycle in which the pads change. *)
let timing ?view chip th ~n ~pv ~pv_prev =
  let next = (n + 1) land m32 in
  let reach = th.t_int = next in
  if th.armed
  then begin
    if th.deadline && reach then th.due <- true;
    if th.due && may_fire chip th ~n
    then begin
      fire chip th ~pv ~staged:true;
      th.armed <- false; th.due <- false;
      if th.deadline
      then begin
        th.t_int <- next;
        if th.adv then add_p th
      end
    end
  end;
  match th.state, th.wait with
  | Wait_ev, Some wt ->
    if wt.w_due = 0
    then begin
      let hit =
        if wt.on_pin
        then (
          let cur = (pv lsr wt.idx) land 1 and prev = (pv_prev lsr wt.idx) land 1 in
          match wt.cond with
          | 0 -> cur = 0
          | 1 -> cur = 1
          | 2 -> prev = 0 && cur = 1
          | _ -> prev = 1 && cur = 0)
        else (status ?view chip th lsr wt.idx) land 1 = wt.cond
      in
      if hit then wt.w_due <- 1 else if wt.w_to && reach then wt.w_due <- 2
    end;
    if wt.w_due <> 0
    then begin
      let with_commit = wt.w_due = 2 || wt.w_cm in
      if (not with_commit) || may_fire chip th ~n
      then begin
        fire chip th ~pv ~staged:with_commit;
        if wt.w_due = 1
        then begin
          th.evf <- true;
          if wt.w_re then (th.t_int <- next; th.t_frac <- 0)
        end
        else begin
          th.evf <- false;
          th.t_int <- next
        end;
        if wt.w_adv then add_p th;
        th.state <- Run; th.wait <- None
      end
    end
  | _ -> ()
;;

(* Rule engine inputs, at the end of cycle n: the events of this cycle. They are registered and
   the automaton processes them in cycle n + 1 (V3, v1.1). *)
let rule_inputs chip ~n ~pv ~pv_prev =
  (* An edge read on a bidirectional pin is the peer's iff our driver was off throughout a
     window around the two samples it lies between (one cycle of margin on each side for
     pad delay); P16..P23 are always the peer's, P8..P15 always ours. *)
  let peer pin =
    if pin >= 16
    then true
    else if pin >= 8
    then false
    else (
      let f = chip.filt.(pin) in
      List.for_all (fun k -> (chip.oe_hist.(k + f) lsr pin) land 1 = 0) [ 1; 2; 3; 4 ])
  in
  let pm = ref 0 in
  for q = 0 to 23 do if peer q then pm := !pm lor (1 lsl q) done;
  { ri_valid = true; ri_n = n; ri_wrise = pv land lnot pv_prev; ri_wfall = pv_prev land lnot pv
  ; ri_peer = !pm; ri_rise = chip.ev_rise; ri_fall = chip.ev_fall; ri_emits = chip.cyc_emits
  ; ri_lev = chip.line.l_ev }
;;

(* Rule engine, start of cycle n + 1: every enabled rule takes the step of cycle n on the
   registered events of cycle n and the rule configuration as it is now. Its verdicts carry
   cycle n; the faults it finds land at the end of this cycle ([rule_faults]). *)
let rules_step chip =
  let ri = chip.ri in
  chip.ri_faults <- [];
  if ri.ri_valid
  then begin
    let n = ri.ri_n in
    let event (r : rule) s =
      match decode_sel s with
      | Some (((0 | 1) as c), q, pin) ->
        ((if c = 0 then ri.ri_wrise else ri.ri_wfall) lsr pin) land 1 = 1
        && (q = 0 || (q = 1) = ((ri.ri_peer lsr pin) land 1 = 1))
      | Some (2, _, pin) -> (ri.ri_rise lsr pin) land 1 = 1
      | Some (3, _, pin) -> (ri.ri_fall lsr pin) land 1 = 1
      | Some (5, _, code) -> r.owner <= 2 && List.mem (r.owner, code) ri.ri_emits
      | Some (6, _, k) -> (ri.ri_lev lsr k) land 1 = 1
      | _ -> false
    in
    let unit_mask (r : rule) = (1 lsl (4 * r.ps)) - 1 in
    let violations = ref [] in
    Array.iteri
      (fun k r ->
        if not r.en
        then r.active <- false
        else begin
          let tick = if n land unit_mask r = unit_mask r then 1 else 0 in
          let start_ev = event r r.sel_start and stop_ev = event r r.sel_stop and abort_ev = event r r.sel_abort in
          if r.active
          then
            if abort_ev
            then r.active <- false
            else if r.cnt > r.rmax
            then begin
              violations := (k, true) :: !violations;
              r.active <- false
            end
            else if stop_ev
            then begin
              if r.cnt < r.rmin then violations := (k, false) :: !violations;
              r.obs_min <- min r.obs_min r.cnt;
              r.obs_max <- max r.obs_max r.cnt;
              r.active <- false
            end
            else r.cnt <- min 0xFFFF (r.cnt + tick);
          if (not r.active) && start_ev
          then begin
            r.active <- true;
            r.cnt <- tick
          end
        end)
      chip.rules;
    List.iter
      (fun (k, max_kind) ->
        record chip ~n k ~max_kind;
        let r = chip.rules.(k) in
        if r.policy = 2 && r.owner <= 2 then chip.ri_faults <- (k, r.owner) :: chip.ri_faults)
      (List.rev !violations);
    chip.ri_faults <- List.rev chip.ri_faults
  end
;;

(* The faults of this cycle's rule step, after the threads' own update: a thread that faulted or
   stopped on its own in this cycle keeps that. *)
let rule_faults chip =
  List.iter
    (fun (k, o) ->
      let th = chip.th.(o) in
      match th.state with
      | Faulted _ | Idle -> ()
      | _ -> enter_fault chip th (Rule k))
    chip.ri_faults
;;

(* --- host port: registers, loader, SPI (doc/spec/host.md) --- *)

let running th =
  match th.state with
  | Run | Wait_ev -> true
  | _ -> false
;;

(* Program digest: CRC-16/CCITT-FALSE over the 32-bit words in address order, bit 31 first. *)
let crc16_word crc w =
  let c = ref crc in
  for k = 31 downto 0 do c := crc_bit ~refl:false !c 0x1021 ((w lsr k) land 1) done;
  !c
;;

let digest_of words = Array.fold_left crc16_word 0xFFFF words

(* Host status flags: 0 unknown command, 1 load error, 2 refused, 3 mailbox to the thread
   was full, 4 mailbox from the thread was empty. *)
let hflag chip b = chip.hstat <- chip.hstat lor (1 lsl b)

(* A write to the program memory. Inside the window of a running thread it is refused.
   Inside a window that is being loaded it must be the next word in sequence, and enters the
   digest. Inside any other window it is done and the window is no longer loaded. *)
let prog_write ?view chip addr word =
  let view = Option.value view ~default:chip in
  let a = addr land 511 in
  let hits = List.filter (fun th -> a >= th.pbase && a < th.pbase + th.psize) (Array.to_list chip.th) in
  if List.exists (fun th -> running view.th.(th.id) || (th.loading && a <> th.pbase + th.load_count)) hits
  then begin
    hflag chip 2;
    false
  end
  else begin
    chip.prog.(a) <- word land m32;
    List.iter
      (fun th ->
        if th.loading
        then begin
          th.crc <- crc16_word th.crc (word land m32);
          th.load_count <- th.load_count + 1
        end
        else th.loaded <- false)
      hits;
    true
  end
;;

(* Stop by the host: as a fault, the pins go to the safe pattern through a pending commit. *)
let enter_stop chip th =
  enter_fault chip th Illegal;
  th.state <- Idle
;;

let do_start ?view chip th =
  let tv = match view with Some v -> v.th.(th.id) | None -> th in
  if th.loaded && (not (running tv)) && (not tv.armed) && th.dbase + th.dsize <= 1024
  then begin
    th.pc <- th.entry; th.state <- Run; th.flight <- None; th.wait <- None
    ; th.sm <- 0; th.em <- 0; th.sv <- 0; th.ev <- 0; th.evf <- false; th.late <- false
    ; th.slack_min <- 32767
  end
  else hflag chip 2
;;

let thread_reg addr = if addr >= 0x40 && addr < 0x70 then Some ((addr - 0x40) / 16, addr land 15) else None

let rule_reg chip addr =
  let k = (addr - 0x80) / 16 in
  if addr >= 0x80 && k < Array.length chip.rules then Some (k, addr land 15) else None
;;

let verdict_info v ~flag =
  match v with
  | None -> 0, 0
  | Some v -> 0x8000 lor (if v.v_max_kind then 0x4000 else 0) lor (if flag then 0x2000 else 0) lor v.v_rule, v.v_cycle
;;

(* Value of a host register; reading has no effect except latching the high half of now. *)
let reg_peek ?view chip addr =
  let live = chip in
  let chip = Option.value view ~default:chip in
  let owners k =
    let v = ref 0 in
    for j = 3 downto 0 do v := (!v lsl 4) lor (chip.owner.((4 * k) + j) land 7) done;
    !v
  in
  let filt base =
    let v = ref 0 in
    for j = 7 downto 0 do v := (!v lsl 2) lor chip.filt.(base + j) done;
    !v
  in
  let fail_info, fail_cycle = verdict_info chip.first_fail ~flag:chip.blame_before_fail in
  let blame_info, blame_cycle = verdict_info chip.first_blame ~flag:false in
  match addr with
  | 0x00 -> 0x8401
  | 0x01 -> Array.length chip.rules lor (chip.fifo_depth lsl 4) lor (Array.length chip.th lsl 8)
  | 0x02 ->
    live.now_latch <- chip.now lsr 16;
    chip.now land m16
  | 0x03 -> chip.now_latch
  | 0x04 -> chip.hstat
  | 0x08 -> chip.value
  | 0x09 -> chip.dir
  | 0x0A -> pins chip land m16
  | 0x0B -> pins chip lsr 16
  | 0x10 | 0x11 | 0x12 | 0x13 -> owners (addr - 0x10)
  | 0x14 -> chip.od
  | 0x15 -> chip.safe_val
  | 0x16 -> chip.safe_dir
  | 0x18 -> filt 0
  | 0x19 -> filt 16
  | 0x20 -> fail_info
  | 0x21 -> fail_cycle land m16
  | 0x22 -> fail_cycle lsr 16
  | 0x24 -> blame_info
  | 0x25 -> blame_cycle land m16
  | 0x26 -> blame_cycle lsr 16
  | 0x30 -> (if chip.tr_en then 1 else 0) lor if chip.tr_freeze then 2 else 0
  | 0x31 -> chip.tr_base
  | 0x32 -> chip.tr_size
  | 0x33 -> chip.tr_mask land m16
  | 0x34 -> chip.tr_mask lsr 16
  | 0x35 -> chip.tr_ptr lor (if chip.tr_wrapped then 0x8000 else 0) lor if chip.tr_frozen then 0x4000 else 0
  | 0x36 -> chip.tr_post
  | _ when addr >= 0xC0 -> line_peek chip.line (addr - 0xC0)
  | _ ->
    (match thread_reg addr, rule_reg chip addr with
     | Some (t, j), _ ->
       let th = chip.th.(t) in
       (match j with
        | 1 ->
          let st, code, a =
            match th.state with
            | Idle -> 0, 0, 0
            | Run -> 1, 0, 0
            | Wait_ev -> 2, 0, 0
            | Halted -> 3, 0, 0
            | Faulted f ->
              let code, a =
                match f with
                | Illegal -> 1, 0
                | Pcbound -> 2, 0
                | Dbound -> 3, 0
                | Pinown -> 4, 0
                | Late -> 5, 0
                | Ioperm -> 6, 0
                | Trap c -> 7, c
                | Rule k -> 8, k
              in
              4, code, a
          in
          st lor (code lsl 4) lor (a lsl 8)
        | 2 -> th.entry
        | 3 -> th.pbase
        | 4 -> th.psize
        | 5 -> th.dbase
        | 6 -> th.dsize
        | 7 -> if th.strict then 1 else 0
        | 9 -> (match Queue.peek_opt th.outbox with Some v -> v | None -> 0)
        | 10 ->
          (if Queue.length th.inbox < chip.fifo_depth then 1 else 0) lor if Queue.is_empty th.outbox then 0 else 2
        | 11 -> th.slack_min land m16
        | 12 -> th.digest
        | 14 ->
          (if th.loaded then 1 else 0)
          lor (if th.loading then 2 else 0)
          lor (if th.late then 4 else 0)
          lor if th.evf then 8 else 0
        | 15 -> th.pc
        | _ -> 0)
     | None, Some (k, j) ->
       let r = chip.rules.(k) in
       (match j with
        | 0 -> r.sel_start
        | 1 -> r.sel_stop
        | 2 -> r.sel_abort
        | 3 -> r.rmin
        | 4 -> r.rmax
        | 5 ->
          (if r.en then 1 else 0)
          lor (if r.guarantee then 2 else 0)
          lor (r.policy lsl 2)
          lor (r.owner lsl 4)
          lor (r.ps lsl 6)
        | 6 ->
          (if r.active then 1 else 0)
          lor (if r.v_min then 2 else 0)
          lor (if r.v_max then 4 else 0)
          lor if r.repaired then 8 else 0
        | 7 -> r.obs_min
        | 8 -> r.obs_max
        | 9 -> r.cnt
        | _ -> 0)
     | None, None -> 0)
;;

(* The host has read a whole register word: the one read with an effect is the mailbox. *)
let reg_read_done ?view chip addr =
  let view = Option.value view ~default:chip in
  match thread_reg addr with
  | Some (t, 9) ->
    let th = chip.th.(t) in
    if Queue.is_empty view.th.(t).outbox then hflag chip 4 else ignore (Queue.pop th.outbox)
  | _ -> ()
;;

let reg_write ?view chip addr v =
  let view_ = view in
  let view = Option.value view ~default:chip in
  let v = v land m16 in
  match addr with
  | 0x04 -> chip.hstat <- chip.hstat land lnot v
  | 0x10 | 0x11 | 0x12 | 0x13 ->
    for j = 0 to 3 do
      let pin = (4 * (addr - 0x10)) + j in
      if pin <> 8 then chip.owner.(pin) <- (v lsr (4 * j)) land 7
    done
  | 0x14 -> chip.od <- v land 0xFF
  | 0x15 -> chip.safe_val <- v
  | 0x16 -> chip.safe_dir <- v land 0xFF
  | 0x18 -> for j = 0 to 7 do chip.filt.(j) <- (v lsr (2 * j)) land 3 done
  | 0x19 -> for j = 0 to 7 do chip.filt.(16 + j) <- (v lsr (2 * j)) land 3 done
  | 0x27 ->
    if v land 1 = 1
    then begin
      chip.first_fail <- None;
      chip.first_blame <- None;
      chip.blame_before_fail <- false
    end
  | 0x30 ->
    chip.tr_en <- v land 1 = 1; chip.tr_freeze <- v land 2 = 2; chip.tr_ptr <- 0
    ; chip.tr_wrapped <- false; chip.tr_frozen <- false; chip.tr_trig <- false; chip.tr_widx <- 4
    ; chip.tr_lost <- false
  | 0x31 -> chip.tr_base <- v land 1023
  | 0x32 -> chip.tr_size <- min v 256
  | 0x33 -> chip.tr_mask <- chip.tr_mask land 0xFF0000 lor v
  | 0x34 -> chip.tr_mask <- chip.tr_mask land m16 lor ((v land 0xFF) lsl 16)
  | 0x36 -> chip.tr_post <- v land 0xFF
  | _ when addr >= 0xC0 -> line_poke chip.line (addr - 0xC0) v
  | _ ->
    (match thread_reg addr, rule_reg chip addr with
     | Some (t, j), _ ->
       let th = chip.th.(t) and tv = view.th.(t) in
       let stopped_only f = if running tv then hflag chip 2 else f () in
       (match j with
        | 0 ->
          (match v with
           | 1 -> do_start ?view:view_ chip th
           | 2 -> if tv.state <> Idle then enter_stop chip th
           | 3 ->
             if (not (running tv)) && th.psize >= 1 && th.pbase + th.psize <= 512
             then begin
               th.loading <- true; th.loaded <- false; th.crc <- 0xFFFF; th.load_count <- 0
             end
             else hflag chip 2
           | _ -> hflag chip 2)
        | 2 -> stopped_only (fun () -> th.entry <- v land 0x3FF)
        | 3 ->
          stopped_only (fun () ->
            th.pbase <- v land 511; th.loaded <- false; th.loading <- false)
        | 4 ->
          stopped_only (fun () ->
            if v > 512 then hflag chip 2 else (th.psize <- v; th.loaded <- false; th.loading <- false))
        | 5 -> stopped_only (fun () -> th.dbase <- v land 1023)
        | 6 -> stopped_only (fun () -> if v > 1024 then hflag chip 2 else th.dsize <- v)
        | 7 -> th.strict <- v land 1 = 1
        | 8 -> if Queue.length tv.inbox < chip.fifo_depth then Queue.push v th.inbox else hflag chip 3
        | 13 ->
          if th.loading && th.load_count = th.psize && th.crc = v
          then begin
            th.loaded <- true;
            th.digest <- th.crc
          end
          else hflag chip 1;
          th.loading <- false
        | _ -> ())
     | None, Some (k, j) ->
       let r = chip.rules.(k) in
       (match j with
        | 0 -> r.sel_start <- v
        | 1 -> r.sel_stop <- v
        | 2 -> r.sel_abort <- v
        | 3 -> r.rmin <- v
        | 4 -> r.rmax <- v
        | 5 ->
          r.en <- v land 1 = 1; r.guarantee <- v land 2 = 2; r.policy <- (v lsr 2) land 3
          ; r.owner <- (v lsr 4) land 3; r.ps <- (v lsr 6) land 3
          ; r.active <- false; r.cnt <- 0; r.v_min <- false; r.v_max <- false; r.repaired <- false
          ; r.obs_min <- 0xFFFF; r.obs_max <- 0
        | _ -> ())
     | None, None -> ())
;;

type region =
  | R_reg
  | R_prog
  | R_data

(* SPI command byte: region, write?, address increments? *)
let cmd_info = function
  | 0x10 -> Some (R_reg, false, false)
  | 0x11 -> Some (R_reg, false, true)
  | 0x20 -> Some (R_reg, true, false)
  | 0x21 -> Some (R_reg, true, true)
  | 0x30 -> Some (R_prog, false, true)
  | 0x40 -> Some (R_prog, true, true)
  | 0x50 -> Some (R_data, false, true)
  | 0x60 -> Some (R_data, true, true)
  | _ -> None
;;

(* The host port in cycle n. SCK, MOSI and CS_N are the synchronised pins P16, P17, P18. *)
let host_cycle ?view chip ~n ~pv ~pv_prev ~slot_free =
  let b k = (pv lsr k) land 1 and bp k = (pv_prev lsr k) land 1 in
  let h = chip.host in
  (* the memories have a synchronous read: a word read in cycle n is in rbuf from cycle n + 1 *)
  (match h.rpend with
   | Some v ->
     h.rbuf <- v;
     h.rpend <- None
   | None -> ());
  (* a waiting memory access is done in the system slot of its memory *)
  (match h.req with
   | Some (prog, write, a, d) when (prog && n land 3 = 3) || ((not prog) && n land 3 = 1 && slot_free) ->
     if prog
     then if write then ignore (prog_write ?view chip a d) else h.rpend <- Some chip.prog.(a land 511)
     else if write
     then chip.data.(a land 1023) <- d land m16
     else h.rpend <- Some chip.data.(a land 1023);
     h.req <- None
   | _ -> ());
  if b 18 = 1
  then begin
    h.count <- 0; h.cmd <- 0; h.miso <- 0; h.osh <- 0
  end
  else begin
    if bp 16 = 0 && b 16 = 1
    then begin
      h.sh <- ((h.sh lsl 1) lor b 17) land m32;
      h.count <- h.count + 1;
      let c = h.count in
      if c = 8
      then begin
        h.cmd <- h.sh land 0xFF;
        if cmd_info h.cmd = None then hflag chip 0
      end
      else (
        match cmd_info h.cmd with
        | None -> ()
        | Some (R_reg, write, inc) ->
          if c = 16
          then begin
            h.haddr <- h.sh land 0xFF;
            if not write then h.osh <- reg_peek ?view chip h.haddr lsl 16
          end
          else if c > 16 && (c - 16) land 15 = 0
          then begin
            if write then reg_write ?view chip h.haddr (h.sh land m16) else reg_read_done ?view chip h.haddr;
            if inc then h.haddr <- (h.haddr + 1) land 0xFF;
            if not write then h.osh <- reg_peek ?view chip h.haddr lsl 16
          end
        | Some (region, write, _) ->
          let prog = region = R_prog in
          let w = if prog then 32 else 16 in
          let first = if write then 24 else 32 in
          if c = 24
          then begin
            h.haddr <- h.sh land m16;
            if not write then h.req <- Some (prog, false, h.haddr, 0)
          end
          else if c >= first && (c - first) mod w = 0
          then
            if write
            then begin
              h.req <- Some (prog, true, h.haddr, if prog then h.sh else h.sh land m16);
              h.haddr <- (h.haddr + 1) land m16
            end
            else begin
              h.osh <- (if prog then h.rbuf else h.rbuf lsl 16);
              h.haddr <- (h.haddr + 1) land m16;
              h.req <- Some (prog, false, h.haddr, 0)
            end)
    end;
    if bp 16 = 1 && b 16 = 0
    then begin
      h.miso <- (h.osh lsr 31) land 1;
      h.osh <- (h.osh lsl 1) land m32
    end
  end
;;

(* --- line unit and response rules (doc/spec/line.md) --- *)

(* The line unit in cycle n. It runs before the threads, on the register values of this
   cycle; what a thread writes in cycle n is seen here in cycle n + 1. Returns whether the
   unit uses the system slot of the data memory in this cycle. *)
let line_cycle chip ~n ~pv ~pv_prev =
  let l = chip.line in
  let ctl = l.lc.(1) in
  let c b = (ctl lsr b) land 1 = 1 in
  let per = max 16 l.lc.(2) in
  let bitp v q = if q <= 23 then (v lsr q) land 1 else 0 in
  let inv = (ctl lsr 4) land 1 and idle = (ctl lsr 5) land 1 in
  let code = (ctl lsr 2) land 3 in
  let ext = c 13 in
  let ones = c 11 in
  let stuff_n = match (ctl lsr 8) land 7 with 0 -> 8 | k -> k in
  let w = min 16 (l.lc.(5) land 31) in
  let crc_init = if l.lc.(5) land 32 <> 0 then (0xFFFF lsl (16 - w)) land m16 else 0 in
  let tx_skip = l.lc.(17) land 0xFF and rx_skip = l.lc.(17) lsr 8 in
  let poly = l.lc.(4) in
  let owner_ok =
    l.l_owner <= 2 && (match chip.th.(l.l_owner).state with Faulted _ -> false | _ -> true)
  in
  (* what the threads read during this cycle *)
  l.l_snap.(0) <- line_status l; l.l_snap.(1) <- l.r_cnt; l.l_snap.(2) <- l.r_hist
  ; l.l_snap.(3) <- l.r_crc; l.l_snap.(4) <- l.t_sent;
  l.l_ev <- 0; l.l_mask <- 0;
  let ev k = l.l_ev <- l.l_ev lor (1 lsl k) in
  let cmd = l.l_cmd in
  l.l_cmd <- 0;
  let q_now = l.q_pend in
  l.q_pend <- None;
  let serve_w = l.r_wbuf and serve_r = l.t_req in
  if cmd land 16 <> 0
  then begin
    l.t_done <- false; l.r_done <- false; l.r_crcok <- false; l.t_err <- 0; l.r_err <- 0;
    Array.iter (fun q -> q.q_fired <- false) l.resp
  end;
  if not owner_ok
  then begin
    l.t_st <- 0; l.t_req <- None; l.r_st <- 0; l.r_wbuf <- None
  end;
  (* ---------------- receiver ---------------- *)
  let rxp = (l.lc.(3) lsr 4) land 31 in
  let dp = bitp pv rxp and dm = bitp pv (rxp + 1) in
  let se0 = c 1 && dp = 0 && dm = 0 in
  let lv = dp lxor inv in
  let clkp = (l.lc.(3) lsr 9) land 31 in
  let ck = bitp pv clkp and ckp = bitp pv_prev clkp in
  let sample_edge = ext && (if c 14 then ckp = 1 && ck = 0 else ckp = 0 && ck = 1) in
  let shift_edge = ext && (if c 14 then ckp = 0 && ck = 1 else ckp = 1 && ck = 0) in
  let edge = lv <> l.r_lv in
  l.r_lv <- lv;
  if cmd land 8 <> 0 then l.r_st <- 0;
  if cmd land 2 <> 0 && owner_ok
  then begin
    l.r_st <- 1; l.r_idle_seen <- false
  end;
  let sync_len = min 8 ((l.lc.(12) lsr 8) land 15) in
  let started = ref false in
  if l.r_st = 1
  then
    if ext || (l.r_idle_seen && lv <> idle && not se0)
    then begin
      started := true;
      (* the first edge of a Manchester frame is taken as the middle of its first bit *)
      l.r_ph <- (if code = 2 then per lsr 1 else 0); l.r_prev <- idle; l.r_hcnt <- 0; l.r_cnt <- 0; l.r_sh <- 0; l.r_hist <- 0
      ; l.r_crc <- crc_init; l.r_run <- 0; l.r_last <- idle; l.r_quiet <- 0;
      if sync_len = 0
      then begin
        l.r_st <- 3; ev 1
      end
      else l.r_st <- 2
    end
    else if lv = idle && not se0
    then l.r_idle_seen <- true;
  let boundary = ref false and strobe = ref false in
  if ext
  then begin
    strobe := sample_edge; boundary := shift_edge
  end
  else begin
    let sp = (per lsr 1) + ((per lsr 3) * ((l.lc.(15) lsr 8) land 3)) in
    if l.r_st >= 2 && edge && not !started
    then
      if code = 2
      then (
        (* only an edge near the middle of a bit counts, for the phase and for the idle detection *)
        if l.r_ph >= per lsr 2 && l.r_ph < per - (per lsr 2)
        then begin
          l.r_ph <- per lsr 1; l.r_quiet <- 0
        end)
      else begin
        let sjw = l.lc.(15) land 0xFF in
        if l.r_ph < sp
        then l.r_ph <- (if sjw = 0xFF then 0 else l.r_ph - min l.r_ph (16 * sjw))
        else if sjw = 0xFF || per - l.r_ph <= 16 * sjw
        then begin
          l.r_ph <- 0; boundary := true
        end
        else l.r_ph <- l.r_ph + (16 * sjw)
      end;
    strobe := l.r_ph < sp && l.r_ph + 16 >= sp;
    let ph = l.r_ph + 16 in
    if ph >= per
    then begin
      l.r_ph <- ph - per; boundary := true
    end
    else l.r_ph <- ph
  end;
  if l.r_st >= 2 && edge && code <> 2 then l.r_quiet <- 0;
  let push_word idx d =
    let ok =
      owner_ok && idx < l.lc.(11) land 0x7FF
      && (l.lc.(10) land 0x3FF) + idx < chip.th.(l.l_owner).dsize
      && l.r_wbuf = None
    in
    if ok then l.r_wbuf <- Some (idx, d) else l.r_err <- l.r_err lor 2
  in
  let resp_check ~at_end =
    Array.iteri
      (fun k q ->
        if q.q_ctl land 1 = 1 && (q.q_ctl lsr 5) land 1 = Bool.to_int at_end && l.q_pend = None
        then begin
          let pos = q.q_pos land 0x3FFF in
          let pos_ok = match (q.q_ctl lsr 2) land 3 with 1 -> l.r_cnt = pos | 2 -> l.r_cnt >= pos | _ -> true in
          let crc_ok = (q.q_ctl lsr 4) land 1 = 0 || l.r_crc = l.lc.(6) in
          let ml = min 8 ((q.q_ctl lsr 6) land 15) in
          let m = (q.q_match lsr 8) land ((1 lsl ml) - 1) in
          if pos_ok && crc_ok && (l.r_hist lxor q.q_match) land m = 0
          then begin
            q.q_fired <- true; ev (9 + k); l.q_pend <- Some k;
            if q.q_ctl land 2 <> 0 then q.q_ctl <- q.q_ctl land lnot 1
          end
        end)
      l.resp
  in
  let frame_end () =
    if l.r_cnt land 15 <> 0 then push_word (l.r_cnt lsr 4) l.r_sh;
    l.r_done <- true; l.r_crcok <- l.r_crc = l.lc.(6); ev 2; ev (if l.r_crcok then 3 else 4);
    resp_check ~at_end:true;
    l.r_st <- (if c 0 then 1 else 0); l.r_idle_seen <- false
  in
  let finish () =
    if l.r_st = 3
    then frame_end ()
    else begin
      l.r_st <- 1; l.r_idle_seen <- false
    end
  in
  if l.r_st >= 2 && !strobe
  then begin
    l.r_quiet <- l.r_quiet + 1;
    let endc = l.lc.(13) in
    if endc land 1 <> 0 && se0
    then finish ()
    else if endc land 4 <> 0 && l.r_quiet > max 1 (endc lsr 8)
    then finish ()
    else begin
      let bit = if code = 1 then if lv = l.r_prev then 1 else 0 else lv in
      l.r_prev <- lv;
      (* the protected part of a frame: destuffed and covered by the CRC *)
      let send = l.lc.(16) land 0x3FFF in
      let prot = send = 0 || l.r_st = 2 || l.r_cnt < send in
      let due = c 7 && prot && l.r_run >= stuff_n in
      let track b =
        if ones
        then l.r_run <- (if b = 1 then l.r_run + 1 else 0)
        else if b = l.r_last
        then l.r_run <- l.r_run + 1
        else begin
          l.r_run <- 1; l.r_last <- b
        end
      in
      if due && bit = (if ones then 0 else 1 - l.r_last)
      then track bit (* a stuff bit: dropped *)
      else begin
        if due
        then begin
          l.r_err <- l.r_err lor 1; ev 5
        end;
        if due && endc land 2 <> 0
        then finish ()
        else begin
          track bit;
          l.r_hist <- ((l.r_hist lsl 1) lor bit) land m16;
          if l.r_st = 2
          then begin
            l.r_hcnt <- min 8 (l.r_hcnt + 1);
            let m = (1 lsl sync_len) - 1 in
            if l.r_hcnt >= sync_len && l.r_hist land m = l.lc.(12) land m
            then begin
              l.r_st <- 3; ev 1
            end
          end
          else begin
            if l.r_cnt >= rx_skip && prot then l.r_crc <- crc_bit ~refl:false l.r_crc poly bit;
            let pos = l.r_cnt land 15 in
            l.r_sh <- l.r_sh lor (bit lsl (if c 6 then pos else 15 - pos));
            l.r_cnt <- l.r_cnt + 1;
            if l.r_cnt land 15 = 0
            then begin
              push_word ((l.r_cnt lsr 4) - 1) l.r_sh;
              l.r_sh <- 0
            end;
            ev 0;
            resp_check ~at_end:false;
            if l.r_cnt = 0x3FF0
            then begin
              l.r_err <- l.r_err lor 2; frame_end ()
            end
            else if endc land 8 <> 0 && l.r_cnt = l.lc.(14) land 0x3FFF
            then frame_end ()
          end
        end
      end
    end
  end;
  (* ---------------- transmitter ---------------- *)
  let txp = l.lc.(3) land 15 in
  let tlen = l.lc.(8) land 0x3FFF in
  let wrote = ref false in
  let idle_out () =
    let o = idle lxor inv in
    l.t_out <- o lor ((1 - o) lsl 1)
  in
  let finish_tx () =
    l.t_st <- 0; l.t_done <- true; ev 8; wrote := true;
    if c 15 then l.t_rel <- true else begin l.t_rel <- false; idle_out () end
  in
  let send_logical b =
    if ones
    then l.t_run <- (if b = 1 then l.t_run + 1 else 0)
    else if b = l.t_last
    then l.t_run <- l.t_run + 1
    else begin
      l.t_run <- 1; l.t_last <- b
    end;
    (match code with
     | 1 -> if b = 0 then l.t_line <- 1 - l.t_line
     | 2 -> l.t_line <- 1 - b
     | _ -> l.t_line <- b);
    l.t_bit <- b; l.t_half <- false;
    let o = l.t_line lxor inv in
    l.t_out <- o lor ((1 - o) lsl 1); l.t_rel <- false; ev 6
  in
  let tail_or_finish () =
    if l.t_tail < min 4 (l.lc.(9) land 7)
    then begin
      l.t_out <- (l.lc.(9) lsr (8 + (2 * l.t_tail))) land 3;
      l.t_rel <- false; l.t_tail <- l.t_tail + 1; l.t_half <- true
    end
    else finish_tx ()
  in
  let coder_reset () =
    l.t_run <- 0; l.t_last <- idle; l.t_line <- idle; l.t_acc <- 0; l.t_half <- false
  in
  let boundary_tx () =
    match l.t_st with
    | 2 ->
      let more = l.t_sent < tlen || l.t_crcleft > 0 in
      if c 7 && l.t_run >= stuff_n && (more || c 12)
      then send_logical (if ones then 0 else 1 - l.t_last)
      else if l.t_sent < tlen
      then begin
        let pos = l.t_sent land 15 in
        if pos = 0 && l.t_sent > 0
        then begin
          if not l.t_nvalid then l.t_err <- l.t_err lor 1;
          l.t_word <- (if l.t_nvalid then l.t_next else 0);
          l.t_nvalid <- false;
          if l.t_sent + 16 < tlen then l.t_req <- Some ((l.t_sent lsr 4) + 1)
        end;
        let b = (l.t_word lsr (if c 6 then pos else 15 - pos)) land 1 in
        if l.t_sent >= tx_skip then l.t_crc <- crc_bit ~refl:false l.t_crc poly b;
        l.t_sent <- l.t_sent + 1;
        if l.t_sent = tlen then l.t_crcleft <- w;
        send_logical b
      end
      else if l.t_crcleft > 0
      then begin
        let b = ((l.t_crc lsr 15) land 1) lxor ((l.lc.(5) lsr 6) land 1) in
        l.t_crc <- (l.t_crc lsl 1) land m16;
        l.t_crcleft <- l.t_crcleft - 1;
        send_logical b
      end
      else begin
        l.t_st <- 3; l.t_tail <- 0; tail_or_finish ()
      end
    | 3 -> tail_or_finish ()
    | 5 ->
      if l.t_rleft > 0
      then begin
        let b = l.t_rsh land 1 in
        l.t_rsh <- l.t_rsh lsr 1; l.t_rleft <- l.t_rleft - 1;
        send_logical b
      end
      else if l.t_rtail
      then begin
        l.t_st <- 3; l.t_tail <- 0; tail_or_finish ()
      end
      else finish_tx ()
    | _ -> ()
  in
  if cmd land 4 <> 0
  then begin
    l.t_st <- 0; l.t_req <- None
  end;
  (match q_now with
   | Some k when l.t_st = 0 && owner_ok ->
     let q = l.resp.(k) in
     l.t_rwait <- (q.q_ctl lsr 10) land 15; l.t_rleft <- max 1 (min 16 (q.q_len land 31))
     ; l.t_rsh <- q.q_reply; l.t_rtail <- q.q_len land 32 <> 0; l.t_st <- 4
   | Some _ -> l.t_err <- l.t_err lor 4
   | None -> ());
  let begin_frame () =
    coder_reset ();
    l.t_crc <- crc_init; l.t_crcleft <- (if tlen = 0 then w else 0); l.t_st <- 2; l.t_bnd <- true; ev 7
  in
  if cmd land 1 <> 0 && l.t_st = 0 && owner_ok
  then begin
    l.t_sent <- 0; l.t_nvalid <- false; l.t_req <- None;
    if tlen = 0
    then begin_frame ()
    else begin
      l.t_st <- 1; l.t_req <- Some 0
    end
  end
  else if l.t_st = 1 && l.t_nvalid
  then begin
    l.t_word <- l.t_next; l.t_nvalid <- false;
    if tlen > 16 then l.t_req <- Some 1;
    begin_frame ()
  end
  else if l.t_st = 4
  then
    if l.t_rwait = 0
    then begin
      coder_reset ();
      l.t_st <- 5; l.t_bnd <- true; ev 7
    end
    else if !boundary
    then l.t_rwait <- l.t_rwait - 1;
  if l.t_st = 2 || l.t_st = 3 || l.t_st = 5
  then begin
    if l.t_bnd
    then boundary_tx ()
    else if code = 2 && (not l.t_half) && l.t_acc >= per lsr 1
    then begin
      (* second half of a Manchester symbol *)
      l.t_half <- true; l.t_line <- l.t_bit;
      let o = l.t_line lxor inv in
      l.t_out <- o lor ((1 - o) lsl 1)
    end;
    if l.t_st <> 0
    then begin
      wrote := true;
      if ext
      then l.t_bnd <- shift_edge
      else begin
        let a = l.t_acc + 16 in
        if a >= per
        then begin
          l.t_acc <- a - per; l.t_bnd <- true
        end
        else begin
          l.t_acc <- a; l.t_bnd <- false
        end
      end
    end
  end;
  (* pad override: the transmit pin and, on a pair, the next pin, if the owner owns them *)
  if !wrote && owner_ok
  then begin
    let m = ref 0 in
    if chip.owner.(txp) = l.l_owner then m := 1 lsl txp;
    if c 1 && txp < 15 && chip.owner.(txp + 1) = l.l_owner then m := !m lor (2 lsl txp);
    let v = ((l.t_out land 1) lsl txp) lor (((l.t_out lsr 1) land 1) lsl (txp + 1)) in
    let v = (if l.t_rel then chip.value else v) land !m in
    let rise = !m land v land lnot chip.value and fall = !m land lnot v land chip.value in
    match blocking_rules chip ~rise ~fall with
    | [] ->
      l.l_mask <- !m; l.l_val <- v; l.l_dir <- (if l.t_rel then 0 else !m land 0xFF)
    | k :: _ ->
      (* an edge of the unit that a hold or fail-stop rule forbids: the unit stops instead *)
      record chip ~n k ~max_kind:false;
      l.t_st <- 0; l.t_req <- None; l.t_err <- l.t_err lor 2
  end;
  (* data memory, system slot: one access per round, a received word first *)
  if n land 3 = 1 && owner_ok
  then begin
    let th = chip.th.(l.l_owner) in
    match serve_w, serve_r with
    | Some (idx, d), _ ->
      chip.data.((th.dbase + (l.lc.(10) land 0x3FF) + idx) land 1023) <- d;
      l.r_wbuf <- None;
      true
    | None, Some idx ->
      let a = (l.lc.(7) land 0x3FF) + idx in
      if a < th.dsize
      then l.t_next <- chip.data.((th.dbase + a) land 1023)
      else begin
        l.t_next <- 0; l.t_err <- l.t_err lor 1
      end;
      l.t_nvalid <- true;
      if l.t_req = serve_r then l.t_req <- None;
      true
    | None, None -> false
  end
  else false
;;

(* --- trace (doc/spec/trace.md) --- *)

(* The trace in cycle n. A record is four words in the data memory, written one word per
   round in the system slot when the host does not use it:
     word 0  now[15:0]      word 1  now[31:16]
     word 2  pins P0..P15
     word 3  [15] changes or events were lost before this record
             [14] 0: pin record, [7:0] = pins P16..P23
                  1: EMIT record, [13:12] = thread, [7:0] = code *)
let trace_cycle ?view chip ~n ~pv ~pv_prev ~slot_free =
  let view = Option.value view ~default:chip in
  if chip.tr_en && chip.tr_size > 0
  then begin
    if chip.tr_widx < 4 && n land 3 = 1 && slot_free
    then begin
      chip.data.((chip.tr_base + (4 * chip.tr_ptr) + chip.tr_widx) land 1023) <- chip.tr_rec.(chip.tr_widx);
      chip.tr_widx <- chip.tr_widx + 1;
      if chip.tr_widx = 4
      then begin
        chip.tr_ptr <- chip.tr_ptr + 1;
        if chip.tr_ptr >= chip.tr_size
        then begin
          chip.tr_ptr <- 0;
          chip.tr_wrapped <- true
        end;
        if chip.tr_trig && chip.tr_left > 0 then chip.tr_left <- chip.tr_left - 1
      end
    end;
    if chip.tr_freeze && (view.first_fail <> None || view.first_blame <> None) && not chip.tr_trig
    then begin
      chip.tr_trig <- true;
      chip.tr_left <- chip.tr_post
    end;
    if chip.tr_trig && chip.tr_left = 0 && chip.tr_widx = 4 then chip.tr_frozen <- true;
    if not chip.tr_frozen
    then begin
      let changed = (pv lxor pv_prev) land chip.tr_mask <> 0 in
      let emits = chip.cyc_emits_prev in
      if chip.tr_widx < 4
      then (if changed || emits <> [] then chip.tr_lost <- true)
      else if changed || emits <> [] || chip.tr_lost
      then begin
        let pin_record = changed || emits = [] in
        let lost = chip.tr_lost || (changed && emits <> []) || List.length emits > 1 in
        chip.tr_rec.(0) <- n land m16;
        chip.tr_rec.(1) <- (n lsr 16) land m16;
        chip.tr_rec.(2) <- pv land m16;
        chip.tr_rec.(3)
        <- (if lost then 0x8000 else 0)
           lor
           if pin_record
           then (pv lsr 16) land 0xFF
           else (
             let t, code = List.hd (List.rev emits) in
             0x4000 lor (t lsl 12) lor code);
        chip.tr_widx <- 0;
        chip.tr_lost <- false
      end
    end
  end
;;

(* The records in the trace window, oldest first: (cycle, pins or -1, emit (thread, code) or
   none, lost). For tests and host software. *)
let trace_records chip =
  let rec_at k =
    let a j = chip.data.((chip.tr_base + (4 * k) + j) land 1023) in
    let w3 = a 3 in
    let cycle = a 0 lor (a 1 lsl 16) in
    if w3 land 0x4000 = 0
    then cycle, a 2 lor ((w3 land 0xFF) lsl 16), None, w3 land 0x8000 <> 0
    else cycle, -1, Some ((w3 lsr 12) land 3, w3 land 0xFF), w3 land 0x8000 <> 0
  in
  let idx =
    if chip.tr_wrapped
    then List.init chip.tr_size (fun k -> (chip.tr_ptr + k) mod chip.tr_size)
    else List.init chip.tr_ptr (fun k -> k)
  in
  List.map rec_at idx
;;

(* --- the same host operations without the SPI timing, for tests --- *)

let treg tid j = 0x40 + (16 * tid) + j

let set_window chip tid ~pbase ~psize ~dbase ~dsize =
  reg_write chip (treg tid 3) pbase;
  reg_write chip (treg tid 4) psize;
  reg_write chip (treg tid 5) dbase;
  reg_write chip (treg tid 6) dsize
;;

let set_owner chip pin tid =
  if pin = 8 || pin < 0 || pin > 15 then invalid_arg "set_owner";
  let a = 0x10 + (pin / 4) and sh = 4 * (pin land 3) in
  reg_write chip a (reg_peek chip a land lnot (15 lsl sh) lor (tid lsl sh))
;;

(* Load a program into the thread's window; true if the chip accepted it. *)
let load_thread chip tid words =
  let th = chip.th.(tid) in
  reg_write chip (treg tid 0) 3;
  Array.iteri (fun k w -> ignore (prog_write chip (th.pbase + k) w)) words;
  reg_write chip (treg tid 13) (digest_of words);
  th.loaded
;;

let start chip tid ~pc =
  reg_write chip (treg tid 2) pc;
  reg_write chip (treg tid 0) 1
;;

let set_rule chip k ?(guarantee = true) ?(policy = 0) ?(owner = 3) ?(ps = 0) ?(abort = 0x380) ?(min = 0)
  ?(max = 0xFFFF) ~start ~stop () =
  let a = 0x80 + (16 * k) in
  List.iteri (fun j v -> reg_write chip (a + j) v) [ start; stop; abort; min; max ];
  reg_write chip (a + 5) (1 lor (if guarantee then 2 else 0) lor (policy lsl 2) lor (owner lsl 4) lor (ps lsl 6))
;;

let host_push chip tid v =
  if reg_peek chip (treg tid 10) land 1 = 1
  then begin
    reg_write chip (treg tid 8) v;
    true
  end
  else false
;;

let host_pop chip tid =
  if reg_peek chip (treg tid 10) land 2 = 2
  then begin
    let v = reg_peek chip (treg tid 9) in
    reg_read_done chip (treg tid 9);
    Some v
  end
  else None
;;

(* One clock cycle. [pad] holds the levels of P0..P7 and P16..P23 sampled by the first
   synchroniser stage at the clock edge that begins this cycle. *)
let step chip ~pad =
  let n = chip.now in
  (* synchroniser and glitch filter: s(n) from x(n-1) *)
  let s_old = chip.s in
  let s_new = ref s_old in
  for q = 0 to 23 do
    let xb = (chip.x lsr q) land 1 and sb = (s_old lsr q) land 1 in
    if xb = sb
    then chip.fcnt.(q) <- 0
    else begin
      chip.fcnt.(q) <- chip.fcnt.(q) + 1;
      if chip.fcnt.(q) > chip.filt.(q)
      then begin
        s_new := !s_new lxor (1 lsl q);
        chip.fcnt.(q) <- 0
      end
    end
  done;
  chip.s <- !s_new land 0xFF00FF;
  chip.x <- pad land 0xFF00FF;
  (* v1.1: every block reads the other blocks' registers as they are now *)
  let view = copy_chip chip in
  (* V3: the rule step of the previous cycle; its verdicts come first in this cycle's merge *)
  rules_step chip;
  let pv = pins chip in
  let pv_prev = chip.pv_prev in
  chip.value_n <- chip.value;
  chip.dir_n <- chip.dir;
  chip.oe_hist.(0) <- uio_oe chip;
  chip.ev_rise <- 0;
  chip.ev_fall <- 0;
  chip.cyc_emits <- [];
  let line_uses_slot = line_cycle chip ~n ~pv ~pv_prev in
  (* the line unit's status as the threads read it in this cycle *)
  Array.blit chip.line.l_snap 0 view.line.l_snap 0 (Array.length view.line.l_snap);
  Array.iter
    (fun th ->
      (* fetch, on the state the thread has during this cycle *)
      if th.state = Run && n land 3 = th.id && th.flight = None
      then th.flight <- Some (n, if th.pc < th.psize then chip.prog.((th.pbase + th.pc) land 511) else -1);
      (match th.flight with
       | Some (c, w) when c = n - 2 && w >= 0 -> mem_access chip th w
       | _ -> ());
      (* timing events come first; an instruction in its execute cycle sees their result *)
      timing ~view chip th ~n ~pv ~pv_prev;
      match th.flight with
      | Some (c, w) when c = n - 3 ->
        th.flight <- None;
        execute ~view chip th ~n ~pv w
      | _ -> ())
    chip.th;
  (* while the line unit transmits, its pins follow it and not the commits of a thread *)
  (let l = chip.line in
   if l.l_mask <> 0
   then begin
     chip.ev_rise <- chip.ev_rise land lnot l.l_mask lor (l.l_mask land l.l_val land lnot chip.value);
     chip.ev_fall <- chip.ev_fall land lnot l.l_mask lor (l.l_mask land lnot l.l_val land chip.value);
     chip.value_n <- chip.value_n land lnot l.l_mask lor l.l_val;
     let m8 = l.l_mask land 0xFF in
     chip.dir_n <- chip.dir_n land lnot m8 lor (l.l_dir land m8)
   end);
  rule_faults chip;
  chip.ri <- rule_inputs chip ~n ~pv ~pv_prev;
  let host_uses_slot =
    match chip.host.req with Some (false, _, _, _) -> n land 3 = 1 && not line_uses_slot | _ -> false
  in
  (* the host's writes land after every other block's own update (V2.4), so the trace runs first *)
  trace_cycle ~view chip ~n ~pv ~pv_prev ~slot_free:(not (host_uses_slot || line_uses_slot));
  host_cycle ~view chip ~n ~pv ~pv_prev ~slot_free:(not line_uses_slot);
  for k = 7 downto 1 do chip.oe_hist.(k) <- chip.oe_hist.(k - 1) done;
  (* pins without a thread as owner hold the safe pattern *)
  let unowned = ref 0 in
  Array.iteri (fun q o -> if o < 0 || o > 2 then unowned := !unowned lor (1 lsl q)) chip.owner;
  let u = !unowned land lnot 0x100 in
  chip.value <- chip.value_n land lnot u lor (chip.safe_val land u) land lnot 0x100 lor (chip.host.miso lsl 8);
  let u8 = u land 0xFF in
  chip.dir <- chip.dir_n land lnot u8 lor (chip.safe_dir land u8);
  chip.pv_prev <- pv;
  chip.cyc_emits_prev <- chip.cyc_emits;
  chip.now <- (n + 1) land m32
;;
