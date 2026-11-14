(* Reference model of the core: three threads, their timing hardware and the pad stage,
   one call of [step] per clock cycle. It is the executable form of doc/spec/machine.md.

   and of the rule engine (doc/spec/rules.md).

   and of the host port and loader (doc/spec/host.md).

   Not modelled yet (their documents are not written): line unit, response rules, trace. *)
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
  ; mutable req : (bool * bool * int * int) option (* program memory?, write?, address, data *)
  }

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
  ; mutable hstat : int (* host status flags *)
  ; mutable now_latch : int
  ; host : host
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

let create ?(fifo_depth = 1) ?(n_rules = 4) () =
  { now = 0; prog = Array.make 512 0; data = Array.make 1024 0; th = Array.init 3 new_thread
  ; value = 0; dir = 0; value_n = 0; dir_n = 0; owner = Array.make 16 no_owner; od = 0
  ; safe_val = 0; safe_dir = 0; filt = Array.make 24 0; x = 0; s = 0; fcnt = Array.make 24 0
  ; pv_prev = 0; emits = []; fifo_depth; rules = Array.init n_rules (fun _ -> new_rule ())
  ; first_fail = None; first_blame = None; blame_before_fail = false; oe_hist = Array.make 8 0
  ; ev_rise = 0; ev_fall = 0; cyc_emits = []; hstat = 0; now_latch = 0
  ; host = { count = 0; sh = 0; cmd = 0; haddr = 0; osh = 0; miso = 0; rbuf = 0; req = None } }
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

let status chip th =
  (if th.evf then 1 else 0)
  lor (if Queue.is_empty th.inbox then 0 else 2)
  lor (if Queue.length th.outbox < chip.fifo_depth then 4 else 0)
  lor (if th.late then 8 else 0)
  lor (if chip.first_fail <> None then 16 else 0)
  lor (if chip.first_blame <> None then 32 else 0)
  lor if Array.exists (fun r -> r.repaired) chip.rules then 64 else 0
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
   class 5:     the rule's owner thread executes EMIT with code index (0..31) *)
let decode_sel sel =
  let cls = (sel lsr 7) land 7 and q = (sel lsr 5) land 3 and idx = sel land 31 in
  if sel lsr 10 <> 0
  then None
  else (
    match cls with
    | 0 | 1 -> if idx <= 23 && q <= 2 then Some (cls, q, idx) else None
    | 2 | 3 -> if idx <= 15 && q = 0 then Some (cls, q, idx) else None
    | 5 -> if q = 0 then Some (cls, q, idx) else None
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
let may_fire chip th ~n =
  let rise, fall = proposed chip th in
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
  match List.rev !blocking with
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
let execute chip th ~n ~pv w =
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
    let st = status chip th in
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
       else if addr >= 0x20 && k < Array.length chip.rules
       then (
         let r = chip.rules.(k) in
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
       else raise (Fault_exn Ioperm)
     | Iow | Iowi ->
       if a "addr" <> 0 then raise (Fault_exn Ioperm);
       clr := if i.def.op = Iow then r.(a "ra") else a "imm");
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
let timing chip th ~n ~pv ~pv_prev =
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
        else (status chip th lsr wt.idx) land 1 = wt.cond
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

(* Rule engine, end of cycle n: every enabled rule sees the events of this cycle. *)
let rules_update chip ~n ~pv ~pv_prev =
  let wire_rise = pv land lnot pv_prev and wire_fall = pv_prev land lnot pv in
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
  let event (r : rule) s =
    match decode_sel s with
    | Some (((0 | 1) as c), q, pin) ->
      ((if c = 0 then wire_rise else wire_fall) lsr pin) land 1 = 1
      && (q = 0 || (q = 1) = peer pin)
    | Some (2, _, pin) -> (chip.ev_rise lsr pin) land 1 = 1
    | Some (3, _, pin) -> (chip.ev_fall lsr pin) land 1 = 1
    | Some (5, _, code) -> r.owner <= 2 && List.mem (r.owner, code) chip.cyc_emits
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
      if r.policy = 2 && r.owner <= 2
      then (
        let th = chip.th.(r.owner) in
        match th.state with
        | Faulted _ | Idle -> ()
        | _ -> enter_fault chip th (Rule k)))
    (List.rev !violations)
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
let prog_write chip addr word =
  let a = addr land 511 in
  let hits = List.filter (fun th -> a >= th.pbase && a < th.pbase + th.psize) (Array.to_list chip.th) in
  if List.exists (fun th -> running th || (th.loading && a <> th.pbase + th.load_count)) hits
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

let do_start chip th =
  if th.loaded && (not (running th)) && (not th.armed) && th.dbase + th.dsize <= 1024
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
let reg_peek chip addr =
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
    chip.now_latch <- chip.now lsr 16;
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
let reg_read_done chip addr =
  match thread_reg addr with
  | Some (t, 9) ->
    let th = chip.th.(t) in
    if Queue.is_empty th.outbox then hflag chip 4 else ignore (Queue.pop th.outbox)
  | _ -> ()
;;

let reg_write chip addr v =
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
  | _ ->
    (match thread_reg addr, rule_reg chip addr with
     | Some (t, j), _ ->
       let th = chip.th.(t) in
       let stopped_only f = if running th then hflag chip 2 else f () in
       (match j with
        | 0 ->
          (match v with
           | 1 -> do_start chip th
           | 2 -> if th.state <> Idle then enter_stop chip th
           | 3 ->
             if (not (running th)) && th.psize >= 1 && th.pbase + th.psize <= 512
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
        | 8 -> if Queue.length th.inbox < chip.fifo_depth then Queue.push v th.inbox else hflag chip 3
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
let host_cycle chip ~n ~pv ~pv_prev =
  let b k = (pv lsr k) land 1 and bp k = (pv_prev lsr k) land 1 in
  let h = chip.host in
  (* a waiting memory access is done in the system slot of its memory *)
  (match h.req with
   | Some (prog, write, a, d) when (prog && n land 3 = 3) || ((not prog) && n land 3 = 1) ->
     if prog
     then if write then ignore (prog_write chip a d) else h.rbuf <- chip.prog.(a land 511)
     else if write
     then chip.data.(a land 1023) <- d land m16
     else h.rbuf <- chip.data.(a land 1023);
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
            if not write then h.osh <- reg_peek chip h.haddr lsl 16
          end
          else if c > 16 && (c - 16) land 15 = 0
          then begin
            if write then reg_write chip h.haddr (h.sh land m16) else reg_read_done chip h.haddr;
            if inc then h.haddr <- (h.haddr + 1) land 0xFF;
            if not write then h.osh <- reg_peek chip h.haddr lsl 16
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
  let pv = pins chip in
  let pv_prev = chip.pv_prev in
  chip.value_n <- chip.value;
  chip.dir_n <- chip.dir;
  chip.oe_hist.(0) <- uio_oe chip;
  chip.ev_rise <- 0;
  chip.ev_fall <- 0;
  chip.cyc_emits <- [];
  Array.iter
    (fun th ->
      (* fetch, on the state the thread has during this cycle *)
      if th.state = Run && n land 3 = th.id && th.flight = None
      then th.flight <- Some (n, if th.pc < th.psize then chip.prog.((th.pbase + th.pc) land 511) else -1);
      (match th.flight with
       | Some (c, w) when c = n - 2 && w >= 0 -> mem_access chip th w
       | _ -> ());
      (* timing events come first; an instruction in its execute cycle sees their result *)
      timing chip th ~n ~pv ~pv_prev;
      match th.flight with
      | Some (c, w) when c = n - 3 ->
        th.flight <- None;
        execute chip th ~n ~pv w
      | _ -> ())
    chip.th;
  rules_update chip ~n ~pv ~pv_prev;
  host_cycle chip ~n ~pv ~pv_prev;
  for k = 7 downto 1 do chip.oe_hist.(k) <- chip.oe_hist.(k - 1) done;
  (* pins without a thread as owner hold the safe pattern *)
  let unowned = ref 0 in
  Array.iteri (fun q o -> if o < 0 || o > 2 then unowned := !unowned lor (1 lsl q)) chip.owner;
  let u = !unowned land lnot 0x100 in
  chip.value <- chip.value_n land lnot u lor (chip.safe_val land u) land lnot 0x100 lor (chip.host.miso lsl 8);
  let u8 = u land 0xFF in
  chip.dir <- chip.dir_n land lnot u8 lor (chip.safe_dir land u8);
  chip.pv_prev <- pv;
  chip.now <- (n + 1) land m32
;;
