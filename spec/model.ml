(* Reference model of the core: three threads, their timing hardware and the pad stage,
   one call of [step] per clock cycle. It is the executable form of doc/spec/machine.md.

   Not modelled yet (their documents are not written): host port and loader, line unit,
   response rules, rule engine (only its [hold] input exists), trace. *)
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
  ; mutable hold : int -> bool (* rule engine: hold this thread's armed commit *)
  }

let no_owner = 7

let new_thread id =
  { id; state = Idle; r = Array.make 8 0; pc = 0; t_int = 0; t_frac = 0; p = 0
  ; armed = false; due = false; adv = false; sv = 0; sm = 0; ev = 0; em = 0; cap = 0
  ; evf = false; late = false; slack_min = 32767; wait = None
  ; pbase = 0; psize = 0; dbase = 0; dsize = 0; strict = true
  ; flight = None; mem_rd = 0; inbox = Queue.create (); outbox = Queue.create () }
;;

let create ?(fifo_depth = 1) () =
  { now = 0; prog = Array.make 512 0; data = Array.make 1024 0; th = Array.init 3 new_thread
  ; value = 0; dir = 0; value_n = 0; dir_n = 0; owner = Array.make 16 no_owner; od = 0
  ; safe_val = 0; safe_dir = 0; filt = Array.make 24 0; x = 0; s = 0; fcnt = Array.make 24 0
  ; pv_prev = 0; emits = []; fifo_depth; hold = (fun _ -> false) }
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
  th.pc <- pc; th.state <- Run; th.flight <- None; th.armed <- false; th.due <- false
  ; th.sm <- 0; th.em <- 0; th.sv <- 0; th.ev <- 0; th.wait <- None; th.evf <- false
  ; th.late <- false; th.slack_min <- 32767
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
  lor if th.late then 8 else 0
;;

let enter_fault chip th f =
  th.state <- Faulted f; th.armed <- false; th.due <- false; th.wait <- None; th.flight <- None
  ; th.sm <- 0; th.em <- 0; th.sv <- 0; th.ev <- 0;
  let own = owned_mask chip th.id in
  chip.value_n <- chip.value_n land lnot own lor (chip.safe_val land own);
  let own8 = own land 0xFF in
  chip.dir_n <- chip.dir_n land lnot own8 lor (chip.safe_dir land own8)
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
       new_wait := Some { on_pin = true; idx = a "pin"; cond = a "cond"; w_to = a "to" = 1; w_cm = a "cm" = 1; w_re = a "re" = 1; w_adv = a "adv" = 1 }
     | Waits ->
       new_wait := Some { on_pin = false; idx = a "bit"; cond = a "sense"; w_to = a "to" = 1; w_cm = a "cm" = 1; w_re = a "re" = 1; w_adv = a "adv" = 1 }
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
       later (fun () -> chip.emits <- (e, th.id, code) :: chip.emits)
     | Ior -> if a "addr" = 0 then regw := Some (a "rd", st) else raise (Fault_exn Ioperm)
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
    (match i.tm with
     | 1 -> commit chip th ~pv ~staged:true
     | 2 | 3 ->
       if is_late
       then begin
         commit chip th ~pv ~staged:true;
         th.t_int <- e;
         if i.tm = 3 then add_p th
       end
       else begin
         th.armed <- true; th.due <- false; th.adv <- i.tm = 3
       end
     | _ -> ());
    (match !new_wait with
     | Some wt ->
       if is_late then th.t_int <- (e + 1) land m32;
       th.state <- Wait_ev;
       th.wait <- Some wt
     | None -> ());
    if !halt then th.state <- Halted;
    List.iter (fun f -> f ()) (List.rev !post)
  with
  | Blocked -> ()
  | Fault_exn f -> enter_fault chip th f
;;

(* Timing hardware of one thread in cycle n. *)
let timing chip th ~n ~pv ~pv_prev =
  let reach = th.t_int = (n + 1) land m32 in
  if th.armed
  then begin
    if reach then th.due <- true;
    if th.due && not (chip.hold th.id)
    then begin
      commit chip th ~pv ~staged:true;
      th.armed <- false; th.due <- false;
      if th.adv then add_p th
    end
  end;
  match th.state, th.wait with
  | Wait_ev, Some wt ->
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
    if hit
    then begin
      commit chip th ~pv ~staged:wt.w_cm;
      th.evf <- true;
      if wt.w_re then (th.t_int <- (n + 1) land m32; th.t_frac <- 0);
      if wt.w_adv then add_p th;
      th.state <- Run; th.wait <- None
    end
    else if wt.w_to && reach
    then begin
      commit chip th ~pv ~staged:true;
      th.evf <- false;
      if wt.w_adv then add_p th;
      th.state <- Run; th.wait <- None
    end
  | _ -> ()
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
