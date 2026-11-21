(* Lockstep of the reference model (spec/model.ml) and the specification circuit: the same
   pad inputs every cycle; every register of the circuit is compared with the model's state
   every cycle, through [project], and the memories at the end. *)
open Spec
module S = Spec_circuit.State
module Top = Spec_circuit.Top
open Hardcaml

let b x = if x then 1 else 0
let none = -1 (* don't care *)

let fault_code (f : Model.fault) =
  match f with
  | Illegal -> 1, 0
  | Pcbound -> 2, 0
  | Dbound -> 3, 0
  | Pinown -> 4, 0
  | Late -> 5, 0
  | Ioperm -> 6, 0
  | Trap c -> 7, c
  | Rule k -> 8, k
;;

let project_thread (c : Model.chip) (t : Model.thread) : int S.Thread.t =
  let st, (fc, fa) =
    match t.state with
    | Idle -> 0, (none, none)
    | Run -> 1, (none, none)
    | Wait_ev -> 2, (none, none)
    | Halted -> 3, (none, none)
    | Faulted f -> 4, fault_code f
  in
  let wt = t.wait in
  let wf f = match wt with Some w when st = 2 -> f w | _ -> none in
  let fl_valid, fl_pcb, fl_word =
    match t.flight with None -> 0, none, none | Some (_, w) -> 1, b (w < 0), (if w < 0 then none else w)
  in
  let q_v q = b (not (Queue.is_empty q)) and q_d q = match Queue.peek_opt q with Some v -> v | None -> none in
  ignore c;
  { st; fcode = fc; farg = fa; r = Array.to_list t.r; pc = t.pc; t_int = t.t_int; t_frac = t.t_frac; p = t.p
  ; armed = b t.armed; due = b t.due; adv = b t.adv; deadline = b t.deadline; sv = t.sv; sm = t.sm; ev = t.ev
  ; em = t.em; cap = t.cap; evf = b t.evf; late = b t.late; slack_min = t.slack_min land 0xFFFF
  ; w_pin = wf (fun w -> b w.on_pin); w_idx = wf (fun w -> w.idx); w_cond = wf (fun w -> w.cond)
  ; w_to = wf (fun w -> b w.w_to); w_cm = wf (fun w -> b w.w_cm); w_re = wf (fun w -> b w.w_re)
  ; w_adv = wf (fun w -> b w.w_adv); w_due = wf (fun w -> w.w_due); pbase = t.pbase; psize = t.psize
  ; dbase = t.dbase; dsize = t.dsize; strict = b t.strict; loaded = b t.loaded; loading = b t.loading
  ; load_count = t.load_count; crc = t.crc; digest = t.digest; entry = t.entry; fl_valid; fl_pcb; fl_word
  ; in_v = q_v t.inbox; in_d = q_d t.inbox; out_v = q_v t.outbox; out_d = q_d t.outbox }
;;

let project_rule (r : Model.rule) : int S.Rule.t =
  { en = b r.en; guarantee = b r.guarantee; policy = r.policy; owner = r.owner; ps = r.ps; sel_start = r.sel_start
  ; sel_stop = r.sel_stop; sel_abort = r.sel_abort; rmin = r.rmin; rmax = r.rmax; active = b r.active; cnt = r.cnt
  ; v_min = b r.v_min; v_max = b r.v_max; repaired = b r.repaired; obs_min = r.obs_min; obs_max = r.obs_max }
;;

let project_verdict (v : Model.verdict option) : int S.Verdict.t =
  match v with
  | None -> { valid = 0; rule = none; max_kind = none; cycle = none }
  | Some v -> { valid = 1; rule = v.v_rule; max_kind = b v.v_max_kind; cycle = v.v_cycle }
;;

let project (c : Model.chip) : int S.Chip.t =
  let h = c.host in
  let rq_v, rq_prog, rq_write, rq_addr, rq_data =
    match h.req with
    | None -> 0, none, none, none, none
    | Some (p, wr, a, d) -> 1, b p, b wr, a, if wr then d else none
  in
  let l = c.line in
  let sat m v = if v > m then m else v in
  let resp (q : Model.resp) : int S.Resp.t =
    { ctl = q.q_ctl; mtch = q.q_match; pos = q.q_pos; reply = q.q_reply; len = q.q_len; fired = b q.q_fired }
  in
  let line : int S.Line.t =
    { owner = l.l_owner; lc = List.init 17 (fun j -> l.lc.(j + 1)); resp = Array.to_list (Array.map resp l.resp)
    ; cmd = l.l_cmd; q_pv = b (l.q_pend <> None); q_pk = (match l.q_pend with Some k -> k | None -> none)
    ; t_st = l.t_st; t_acc = l.t_acc; t_bnd = b l.t_bnd; t_sent = l.t_sent; t_word = l.t_word; t_next = l.t_next
    ; t_rd = 0; t_nvalid = b l.t_nvalid; t_req_v = b (l.t_req <> None)
    ; t_req = (match l.t_req with Some i -> i | None -> none); t_crc = l.t_crc; t_crcleft = l.t_crcleft
    ; t_run = sat 15 l.t_run; t_last = l.t_last; t_line = l.t_line; t_bit = l.t_bit; t_half = b l.t_half
    ; t_tail = l.t_tail; t_out = l.t_out; t_rel = b l.t_rel; t_rwait = l.t_rwait; t_rleft = l.t_rleft
    ; t_rsh = l.t_rsh; t_rtail = b l.t_rtail; t_done = b l.t_done; t_err = l.t_err; r_st = l.r_st
    ; r_idle_seen = b l.r_idle_seen; r_ph = l.r_ph; r_lv = l.r_lv; r_prev = l.r_prev; r_hcnt = l.r_hcnt
    ; r_cnt = l.r_cnt; r_sh = l.r_sh; r_hist = l.r_hist; r_crc = l.r_crc; r_run = sat 15 l.r_run
    ; r_last = l.r_last; r_quiet = sat 511 l.r_quiet; r_wv = b (l.r_wbuf <> None)
    ; r_widx = (match l.r_wbuf with Some (i, _) -> i | None -> none)
    ; r_wd = (match l.r_wbuf with Some (_, d) -> d | None -> none); r_done = b l.r_done; r_crcok = b l.r_crcok
    ; r_err = l.r_err }
  in
  { now = c.now; value = c.value; dir = c.dir; owner = Array.to_list c.owner; od = c.od; safe_val = c.safe_val
  ; safe_dir = c.safe_dir; filt = Array.to_list c.filt; x = c.x; s = c.s; fcnt = Array.to_list c.fcnt
  ; pv_prev = c.pv_prev; oe_hist = List.init 7 (fun k -> c.oe_hist.(k + 1)); fail = project_verdict c.first_fail
  ; blame = project_verdict c.first_blame; blame_before_fail = b c.blame_before_fail; hstat = c.hstat
  ; now_latch = c.now_latch
  ; host =
      { count = sat 63 h.count; cmod = h.count land 31; sh = h.sh; cmd = h.cmd; haddr = h.haddr; osh = h.osh
      ; miso = h.miso; rbuf = (match h.rpend with Some v -> v | None -> h.rbuf); rd_p = 0; rd_d = 0; rq_v; rq_prog
      ; rq_write; rq_addr; rq_data }
  ; trace =
      { en = b c.tr_en; freeze = b c.tr_freeze; base = c.tr_base; size = c.tr_size; mask = c.tr_mask; post = c.tr_post
      ; ptr = c.tr_ptr; wrapped = b c.tr_wrapped; frozen = b c.tr_frozen; trig = b c.tr_trig; left = c.tr_left
      ; rec_ = Array.to_list c.tr_rec; widx = c.tr_widx; lost = b c.tr_lost
      ; em_v = b (c.cyc_emits_prev <> [])
      ; em_t = (match c.cyc_emits_prev with (t, _) :: _ -> t | [] -> 0)
      ; em_c = (match c.cyc_emits_prev with (_, k) :: _ -> k | [] -> 0) }
  ; line
  ; th = Array.to_list (Array.map (project_thread c) c.th)
  ; rules = Array.to_list (Array.map project_rule c.rules)
  ; ri_valid = b c.ri.ri_valid
    (* the circuit keeps the pins of two cycles back; the model the edges between them *)
  ; ri_pp = c.pv_prev land lnot c.ri.ri_wrise lor c.ri.ri_wfall
  ; ri_peer = c.ri.ri_peer land 0xFF; ri_rise = c.ri.ri_rise; ri_fall = c.ri.ri_fall; ri_lev = c.ri.ri_lev }
;;

type t =
  { model : Model.chip
  ; sim : Cyclesim.t_port_list
  ; prog : int array
  ; data : int array
  ; mutable prog_dout : int
  ; mutable data_dout : int
  ; mutable cycles : int
  ; mutable mismatches : (int * string * int * int) list (* cycle, field, model, circuit *)
  ; mutable port_conflicts : int
  ; ports : (string, Bits.t ref) Hashtbl.t
  ; cov : (string, int) Hashtbl.t (* coverage counters, from the model *)
  }

let circuit = lazy (Top.circuit ~debug:true ())
let names = S.Chip.map S.Chip.port_names_and_widths ~f:(fun (n, w) -> "dbg_" ^ n, w)

let create () =
  let sim = Cyclesim.create (Lazy.force circuit) in
  let t =
    { model = Model.create (); sim; prog = Array.make 512 0; data = Array.make 1024 0; prog_dout = 0; data_dout = 0
    ; cycles = 0; mismatches = []; port_conflicts = 0; ports = Hashtbl.create 1024; cov = Hashtbl.create 64 }
  in
  Cyclesim.in_port sim "clear" := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.in_port sim "clear" := Bits.gnd;
  t
;;

let out t nm =
  let r =
    match Hashtbl.find_opt t.ports nm with
    | Some r -> r
    | None ->
      let r = Cyclesim.out_port ~clock_edge:Before t.sim nm in
      Hashtbl.add t.ports nm r;
      r
  in
  Bits.to_int !r
;;

let bump t k = Hashtbl.replace t.cov k (1 + Option.value ~default:0 (Hashtbl.find_opt t.cov k))

(* what happened in the model during one step: for coverage *)
let observe t (before : Model.chip) =
  let m = t.model in
  Array.iteri
    (fun i (th : Model.thread) ->
      (match th.flight with
       | Some (c, w) when c = m.now - 1 ->
         bump t "fetch";
         (match Isa.decode w with Some i -> bump t ("op " ^ i.def.mnem) | None -> ())
       | _ -> ());
      (match before.th.(i).state, th.state with
       | Faulted _, _ -> ()
       | _, Faulted f -> bump t ("fault " ^ Model.fault_name f)
       | _ -> ());
      if th.state = Wait_ev then bump t "wait cycle")
    m.th;
  if Model.uo_out m <> Model.uo_out before || Model.uio_out m <> Model.uio_out before || Model.uio_oe m <> Model.uio_oe before
  then bump t "pad change";
  if m.first_fail <> None && before.first_fail = None then bump t "fail verdict";
  if m.first_blame <> None && before.first_blame = None then bump t "blame verdict";
  if m.tr_ptr <> before.tr_ptr then bump t "trace record";
  List.iteri
    (fun k name -> if (m.line.l_ev lsr k) land 1 = 1 then bump t ("line " ^ name))
    [ "rx bit"; "rx start"; "rx end"; "rx crc good"; "rx crc bad"; "rx stuff error"; "tx bit"; "tx begin"; "tx end"
    ; "reply 0"; "reply 1" ];
  if m.line.l_mask <> 0 then bump t "line drives";
  Array.iteri (fun k (r : Model.rule) -> if r.repaired && not before.rules.(k).repaired then bump t "rule repaired") m.rules;
  if m.rules.(0).repaired && m.value <> before.value then bump t "pad change while a rule repairs"
;;

(* a shallow copy of what [observe] compares *)
let snapshot (c : Model.chip) =
  { c with
    th = Array.map (fun (th : Model.thread) -> { th with state = th.state }) c.th
  ; rules = Array.map (fun (r : Model.rule) -> { r with repaired = r.repaired }) c.rules
  ; line = { c.line with t_done = c.line.t_done }
  }
;;
let max_reported = 20

let name_list = S.Chip.to_list names |> List.map fst

let refs t =
  match Hashtbl.find_opt t.ports "__all" with
  | Some _ -> ()
  | None ->
    List.iter (fun nm -> ignore (out t nm)) name_list;
    Hashtbl.add t.ports "__all" (ref Bits.gnd)
;;

let compare_state t =
  refs t;
  let expected = S.Chip.to_list (project t.model) in
  List.iter2
    (fun nm e ->
      if e <> none
      then (
        let got = Bits.to_int !(Hashtbl.find t.ports nm) in
        if got <> e && List.length t.mismatches < max_reported
        then t.mismatches <- (t.cycles, nm, e, got) :: t.mismatches))
    name_list expected;
  List.iter
    (fun (nm, e) ->
      let got = out t nm in
      if got <> e && List.length t.mismatches < max_reported
      then t.mismatches <- (t.cycles, nm, e, got) :: t.mismatches)
    [ "uo_out", Model.uo_out t.model; "uio_out", Model.uio_out t.model; "uio_oe", Model.uio_oe t.model ]
;;

(* one cycle with pad inputs [pad] (P0..P7 in bits 7..0, P16..P23 in bits 23..16) *)
let step t ~pad =
  let set nm v w = Cyclesim.in_port t.sim nm := Bits.of_int ~width:w v in
  set "pad" (pad land 0xFF00FF) 24;
  set "prog_dout" t.prog_dout 32;
  set "data_dout" t.data_dout 16;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  compare_state t;
  if out t "prog_users" > 1 || out t "data_users" > 1 then t.port_conflicts <- t.port_conflicts + 1;
  (* memories: synchronous read, garbage on the data outputs when nothing was read *)
  t.prog_dout <- Random.bits () land 0xFFFF_FFFF;
  t.data_dout <- Random.bits () land 0xFFFF;
  if out t "prog_en" = 1
  then (
    let a = out t "prog_addr" in
    if out t "prog_wen" = 1 then t.prog.(a) <- out t "prog_din" else t.prog_dout <- t.prog.(a));
  if out t "data_en" = 1
  then (
    let a = out t "data_addr" in
    if out t "data_wen" = 1 then t.data.(a) <- out t "data_din" else t.data_dout <- t.data.(a));
  let before = snapshot t.model in
  Model.step t.model ~pad;
  observe t before;
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  t.cycles <- t.cycles + 1
;;

let memories_equal t =
  let diff a b = Array.fold_left ( + ) 0 (Array.mapi (fun i x -> if x <> b.(i) then 1 else 0) a) in
  diff t.prog t.model.prog, diff t.data t.model.data
;;

let report t =
  let pd, dd = memories_equal t in
  Printf.printf "%d cycles: %d mismatches, %d port conflicts, %d program and %d data words differ\n" t.cycles
    (List.length t.mismatches) t.port_conflicts pd dd;
  List.iter
    (fun (c, nm, e, g) -> Printf.printf "  cycle %d %s: model %d (0x%X), circuit %d (0x%X)\n" c nm e e g g)
    (List.rev t.mismatches)
;;

let coverage ?(ops = false) t =
  let l = Hashtbl.fold (fun k v acc -> (k, v) :: acc) t.cov [] |> List.sort compare in
  let is_op (k, _) = String.length k > 3 && String.sub k 0 3 = "op " in
  let ev = List.filter (fun x -> not (is_op x)) l and op = List.filter is_op l in
  Printf.printf "  coverage: %s\n" (String.concat ", " (List.map (fun (k, v) -> Printf.sprintf "%s %d" k v) ev));
  if ops
  then (
    let missing =
      List.filter (fun (d : Isa.def) -> not (List.mem_assoc ("op " ^ d.mnem) op)) Isa.defs
      |> List.map (fun (d : Isa.def) -> d.mnem)
    in
    Printf.printf "  ops fetched: %d of %d kinds%s\n" (List.length op) (List.length Isa.defs)
      (if missing = [] then "" else "; not fetched: " ^ String.concat " " missing))
;;
