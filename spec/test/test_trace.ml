open Spec
open Test_core

let trace_on chip ?(freeze = false) ?(post = 4) ~base ~size ~mask () =
  Model.reg_write chip 0x31 base;
  Model.reg_write chip 0x32 size;
  Model.reg_write chip 0x33 (mask land 0xFFFF);
  Model.reg_write chip 0x34 (mask lsr 16);
  Model.reg_write chip 0x36 post;
  Model.reg_write chip 0x30 (1 lor if freeze then 2 else 0)
;;

let show_rec (cycle, pins, emit, lost) =
  let what =
    match emit with
    | Some (t, code) -> Printf.sprintf "emit %d by thread %d" code t
    | None -> Printf.sprintf "P9=%d P19=%d" ((pins lsr 9) land 1) ((pins lsr 19) land 1)
  in
  Printf.sprintf "%d: %s%s" cycle what (if lost then " (lost before)" else "")
;;

(* The trace sees a pad value one cycle after it is on the pad register only for inputs;
   P8..P15 are read from the register itself, so the record carries the cycle of the edge. *)
let%expect_test "the trace of the UART frame is its edge list" =
  let chip = setup uart in
  trace_on chip ~base:512 ~size:32 ~mask:(1 lsl 9) ();
  let edges = run chip ~cycles:6000 ~watch:[ 9 ] in
  let recs = Model.trace_records chip in
  let from_trace = List.map (fun (c, pins, _, _) -> c, 9, (pins lsr 9) land 1) recs in
  Printf.printf "%d edges, %d records, identical: %b, any lost: %b\n" (List.length edges) (List.length recs)
    (edges = from_trace)
    (List.exists (fun (_, _, _, l) -> l) recs);
  [%expect {| 11 edges, 11 records, identical: true, any lost: false |}]
;;

let%expect_test "edges faster than one record per 16 cycles are marked, the last state is kept" =
  let b = Buffer.create 256 in
  Buffer.add_string b "TPERI 0, 0x0400\nTPERI 1, 0\nTNOW 8\n";
  for k = 1 to 9 do Buffer.add_string b (Printf.sprintf "PINV %d, 9 @adv\n" (k land 1)) done;
  Buffer.add_string b "EMIT 7\nHALT\n";
  let chip = setup (Buffer.contents b) in
  trace_on chip ~base:512 ~size:32 ~mask:(1 lsl 9) ();
  let edges = run chip ~cycles:200 ~watch:[ 9 ] in
  Printf.printf "pad edges: %s\n" (String.concat " " (List.map (fun (c, _, v) -> Printf.sprintf "%d->%d" c v) edges));
  List.iter (fun r -> print_endline (show_rec r)) (Model.trace_records chip);
  [%expect {|
    pad edges: 20->1 24->0 28->1 32->0 36->1 40->0 44->1 48->0 52->1
    20: P9=1 P19=0
    33: P9=0 P19=0 (lost before)
    49: P9=0 P19=0 (lost before)
    65: P9=1 P19=0 (lost before)
    |}]
;;

(* A peer pulse shorter than the assumed 40 cycles. The thread answers the blame with three
   edges on P9; with two records allowed after the verdict the trace keeps the pulse and the
   first of them. *)
let%expect_test "the trace is frozen after a verdict" =
  let chip =
    setup "WAITS 1, 5, 0, 0, 0, 0\nTNOW 30\nPINV 1, 9 @at\nTADDI 30\nPINV 0, 9 @at\nTADDI 30\nPINV 1, 9 @at\nHALT\n"
  in
  Model.set_rule chip 1 ~guarantee:false ~min:40 ~start:(Model.sel 0 19) ~stop:(Model.sel 1 19) ();
  trace_on chip ~freeze:true ~post:2 ~base:512 ~size:32 ~mask:((1 lsl 9) lor (1 lsl 19)) ();
  let edges = run chip ~cycles:300 ~watch:[ 9 ] ~pad:(fun n -> if n >= 30 && n < 50 then 1 lsl 19 else 0) in
  Printf.printf "blame at cycle %d; P9 edges on the pad: %s\n"
    (match chip.first_blame with Some v -> v.v_cycle | None -> -1)
    (String.concat " " (List.map (fun (c, _, v) -> Printf.sprintf "%d->%d" c v) edges));
  List.iter (fun r -> print_endline (show_rec r)) (Model.trace_records chip);
  Printf.printf "pointer register %04X (bit 14: frozen)\n" (Model.reg_peek chip 0x35);
  [%expect {|
    blame at cycle 51; P9 edges on the pad: 90->1 120->0 150->1
    31: P9=0 P19=1
    51: P9=0 P19=0
    90: P9=1 P19=0
    pointer register 4003 (bit 14: frozen)
    |}]
;;

let%expect_test "the window is a ring" =
  let chip = setup uart in
  trace_on chip ~base:512 ~size:4 ~mask:(1 lsl 9) ();
  let edges = run chip ~cycles:6000 ~watch:[ 9 ] in
  let last4 = List.filteri (fun k _ -> k >= List.length edges - 4) edges in
  let recs = List.map (fun (c, pins, _, _) -> c, 9, (pins lsr 9) land 1) (Model.trace_records chip) in
  Printf.printf "%d edges into 4 records: the last four are kept: %b; pointer register %04X (bit 15: wrapped)\n"
    (List.length edges) (recs = last4) (Model.reg_peek chip 0x35);
  [%expect {| 11 edges into 4 records: the last four are kept: true; pointer register 8003 (bit 15: wrapped) |}]
;;

(* v1.1 (doc/decisions/spec_v1_1.md 3): the trace sees an EMIT in the cycle after it is
   executed, so the record carries that cycle. *)
let%expect_test "an EMIT is recorded with the cycle after its execution" =
  let chip = setup "TNOW 8\nEMIT 7\nHALT\n" in
  trace_on chip ~base:512 ~size:32 ~mask:0 ();
  ignore (run chip ~cycles:100 ~watch:[]);
  (* the EMIT log holds the effect cycle n + 1 of an instruction executed in cycle n *)
  let executed = List.map (fun (e, t, k) -> e - 1, t, k) chip.emits in
  List.iter (fun (c, t, k) -> Printf.printf "EMIT %d by thread %d executed in cycle %d\n" k t c) executed;
  List.iter (fun r -> print_endline (show_rec r)) (Model.trace_records chip);
  (match executed, Model.trace_records chip with
   | [ (c, _, _) ], [ (rc, _, Some _, _) ] -> Printf.printf "record cycle - execute cycle = %d\n" (rc - c)
   | _ -> print_endline "unexpected");
  [%expect {|
    EMIT 7 by thread 0 executed in cycle 7
    8: emit 7 by thread 0
    record cycle - execute cycle = 1
    |}]
;;
