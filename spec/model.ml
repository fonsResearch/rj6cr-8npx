(* Reference model of the core: three threads, their timing hardware and the pad stage,
   one call of [step] per clock cycle. It is the executable form of doc/spec/machine.md.

   and of the rule engine (doc/spec/rules.md).

   Not modelled yet (their documents are not written): host port and loader, line unit,
   response rules, trace. *)
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
  ; mutable flight : (int * int) option (* fetch cycle, word; word -1 = fetch outside the window *)
  ; mutable mem_rd : int
  ; inbox : int Queue.t
  ; outbox : int Queue.t
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
  }

let no_owner = 7

let new_thread id =
  { id; state = Idle; r = Array.make 8 0; pc = 0; t_int = 0; t_frac = 0; p = 0
  ; armed = false; due = false; adv = false; deadline = false; sv = 0; sm = 0; ev = 0; em = 0; cap = 0
  ; evf = false; late = false; slack_min = 32767; wait = None
  ; pbase = 0; psize = 0; dbase = 0; dsize = 0; strict = true
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
  ; ev_rise = 0; ev_fall = 0; cyc_emits = [] }
;;

(* --- what the host can do; each call takes effect at a clock edge --- *)

let load chip ~base words = Array.iteri (fun k w -> chip.prog.((base + k) land 511) <- w land m32) words

let set_window chip tid ~pbase ~psize ~dbase ~dsize =
  let th = chip.th.(tid) in
  assert (psize <= 512 && dsize <= 1024);
  th.pbase <- pbase; th.psize <- psize; th.dbase <- dbase; th.dsize <- dsize
;;

(* P8 carries the host port's output and cannot be given to a thread. *)
let set_owner chip pin tid =
  if pin = 8 || pin < 0 || pin > 15 then invalid_arg "set_owner";
  chip.owner.(pin) <- tid
;;

let start chip tid ~pc =
  let th = chip.th.(tid) in
  th.pc <- pc; th.state <- Run; th.flight <- None; th.armed <- false; th.due <- false; th.deadline <- false
  ; th.sm <- 0; th.em <- 0; th.sv <- 0; th.ev <- 0; th.wait <- None; th.evf <- false
  ; th.late <- false; th.slack_min <- 32767
;;

let set_rule chip k ?(guarantee = true) ?(policy = 0) ?(owner = 3) ?(ps = 0) ?(abort = 0x380) ?(min = 0)
  ?(max = 0xFFFF) ~start ~stop () =
  let r = chip.rules.(k) in
  r.en <- true; r.guarantee <- guarantee; r.policy <- policy; r.owner <- owner; r.ps <- ps
  ; r.sel_start <- start; r.sel_stop <- stop; r.sel_abort <- abort; r.rmin <- min; r.rmax <- max
  ; r.active <- false; r.cnt <- 0; r.v_min <- false; r.v_max <- false; r.repaired <- false
  ; r.obs_min <- 0xFFFF; r.obs_max <- 0
;;

let host_push chip tid v =
  let th = chip.th.(tid) in
  if Queue.length th.inbox < chip.fifo_depth then (Queue.push (v land m16) th.inbox; true) else false
;;

let host_pop chip tid = Queue.take_opt chip.th.(tid).outbox

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
  for k = 7 downto 1 do chip.oe_hist.(k) <- chip.oe_hist.(k - 1) done;
  (* pins without a thread as owner hold the safe pattern *)
  let unowned = ref 0 in
  Array.iteri (fun q o -> if o < 0 || o > 2 then unowned := !unowned lor (1 lsl q)) chip.owner;
  let u = !unowned land lnot 0x100 in
  chip.value <- chip.value_n land lnot u lor (chip.safe_val land u);
  let u8 = u land 0xFF in
  chip.dir <- chip.dir_n land lnot u8 lor (chip.safe_dir land u8);
  chip.pv_prev <- pv;
  chip.now <- (n + 1) land m32
;;
