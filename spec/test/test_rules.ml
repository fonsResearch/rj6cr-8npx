open Spec
open Test_core

(* Selector shorthands: commit raises / lowers a pin; pin rises / falls as read. *)
let c_rise p = Model.sel 2 p
let c_fall p = Model.sel 3 p
let w_rise ?qual p = Model.sel ?qual 0 p
let w_fall ?qual p = Model.sel ?qual 1 p

let verdict = function
  | None -> "none"
  | Some (v : Model.verdict) ->
    Printf.sprintf "rule %d %s at cycle %d" v.v_rule (if v.v_max_kind then "max" else "min") v.v_cycle
;;

let show_edges edges = String.concat ", " (List.map (fun (c, _, v) -> Printf.sprintf "%d->%d" c v) edges)

(* A high pulse of [width] cycles on P9, then a second pulse 40 cycles after the first
   falling edge, so that a shift of the schedule is visible. *)
let pulse width =
  Printf.sprintf
    {|
        TNOW 10
        PINV 1, 9 @at
        TADDI %d
        PINV 0, 9 @at
        TADDI 40
        PINV 1, 9 @at
        TADDI %d
        PINV 0, 9 @at
        HALT
    |}
    width width
;;

let%expect_test "an interval rule measures exactly" =
  List.iter
    (fun (width, ps) ->
      let chip = setup (pulse width) in
      Model.set_rule chip 0 ~ps ~start:(c_rise 9) ~stop:(c_fall 9) ();
      let edges = run chip ~cycles:400 ~watch:[ 9 ] in
      let r = chip.rules.(0) in
      Printf.printf "width %3d, unit %3d cycles: edges %s; observed min %d max %d\n" width (1 lsl (4 * ps))
        (show_edges edges) r.obs_min r.obs_max)
    [ 10, 0; 37, 0; 100, 1 ];
  [%expect {|
    width  10, unit   1 cycles: edges 14->1, 24->0, 64->1, 74->0; observed min 10 max 10
    width  37, unit   1 cycles: edges 14->1, 51->0, 91->1, 128->0; observed min 37 max 37
    width 100, unit  16 cycles: edges 14->1, 114->0, 154->1, 254->0; observed min 6 max 7
    |}]
;;

(* Guarantee: P9 stays high for at least 20 cycles. *)
let%expect_test "hold to minimum, fail-stop and observe on the same program" =
  List.iter
    (fun (name, policy) ->
      List.iter
        (fun width ->
          let chip = setup (pulse width) in
          if policy >= 0 then Model.set_rule chip 0 ~policy ~min:20 ~start:(c_rise 9) ~stop:(c_fall 9) ();
          let edges = run chip ~cycles:400 ~watch:[ 9 ] in
          let r = chip.rules.(0) in
          Printf.printf "%-10s width %2d: %s | %s, repaired %b, first fail %s\n" name width (show_edges edges)
            (state_name chip.th.(0)) r.repaired (verdict chip.first_fail))
        [ 30; 10 ])
    [ "no rule", -1; "observe", 0; "hold", 1; "fail-stop", 2 ];
  [%expect {|
    no rule    width 30: 14->1, 44->0, 84->1, 114->0 | halted, repaired false, first fail none
    no rule    width 10: 14->1, 24->0, 64->1, 74->0 | halted, repaired false, first fail none
    observe    width 30: 14->1, 44->0, 84->1, 114->0 | halted, repaired false, first fail none
    observe    width 10: 14->1, 24->0, 64->1, 74->0 | halted, repaired false, first fail rule 0 min at cycle 23
    hold       width 30: 14->1, 44->0, 84->1, 114->0 | halted, repaired false, first fail none
    hold       width 10: 14->1, 34->0, 74->1, 94->0 | halted, repaired true, first fail none
    fail-stop  width 30: 14->1, 44->0, 84->1, 114->0 | halted, repaired false, first fail none
    fail-stop  width 10: 14->1, 34->0 | fault RULE 0, repaired false, first fail rule 0 min at cycle 23
    |}]
;;

(* Random pulse trains under a hold rule: the pads never violate the minimum, and a
   program that respects it is not changed at all. *)
let%expect_test "hold: sound and transparent on random programs" =
  Random.init 11;
  let violations = ref 0 and changed_compliant = ref 0 and repaired_runs = ref 0 and compliant_runs = ref 0 in
  for _ = 1 to 300 do
    let m = 5 + Random.int 40 in
    let widths = List.init 6 (fun _ -> 5 + Random.int 60) in
    let b = Buffer.create 256 in
    Buffer.add_string b "TNOW 10\n";
    List.iteri (fun k wd -> Buffer.add_string b (Printf.sprintf "PINV %d, 9 @at\nTADDI %d\n" ((k + 1) land 1) wd)) widths;
    Buffer.add_string b "PINV 1, 9 @at\nHALT\n";
    let src = Buffer.contents b in
    let free = run (setup src) ~cycles:700 ~watch:[ 9 ] in
    let chip = setup src in
    Model.set_rule chip 0 ~policy:1 ~min:m ~start:(c_rise 9) ~stop:(c_fall 9) ();
    let held = run chip ~cycles:700 ~watch:[ 9 ] in
    let rec highs = function
      | (c1, _, 1) :: ((c2, _, 0) :: _ as rest) -> (c2 - c1) :: highs rest
      | _ :: rest -> highs rest
      | [] -> []
    in
    if List.exists (fun h -> h < m) (highs held) then incr violations;
    let compliant = List.for_all (fun h -> h >= m) (highs free) in
    if compliant then incr compliant_runs;
    if compliant && free <> held then incr changed_compliant;
    if chip.rules.(0).repaired then incr repaired_runs
  done;
  Printf.printf "300 programs: %d compliant, %d repaired; minimum violated on the pads in %d; compliant programs changed: %d\n"
    !compliant_runs !repaired_runs !violations !changed_compliant;
  [%expect {| 300 programs: 121 compliant, 179 repaired; minimum violated on the pads in 0; compliant programs changed: 0 |}]
;;

(* Assumption about the peer: a high pulse on input P19 lasts at least 8 cycles. The
   thread waits for the blame bit and answers on P9. *)
let%expect_test "assumption violated by the peer: blame, with time, visible to the thread" =
  let src = "WAITS 1, 5, 0, 0, 0, 0\nPINV 1, 9 @now\nHALT\n" in
  List.iter
    (fun width ->
      let chip = setup src in
      Model.set_rule chip 1 ~guarantee:false ~min:8 ~start:(w_rise 19) ~stop:(w_fall 19) ();
      let edges = run chip ~cycles:120 ~watch:[ 9 ] ~pad:(fun n -> if n >= 30 && n < 30 + width then 1 lsl 19 else 0) in
      Printf.printf "peer pulse %2d cycles: first blame %s, first fail %s, observed %d; P9: %s\n" width
        (verdict chip.first_blame) (verdict chip.first_fail) chip.rules.(1).obs_min (show_edges edges))
    [ 12; 5 ];
  [%expect {|
    peer pulse 12 cycles: first blame none, first fail none, observed 12; P9:
    peer pulse  5 cycles: first blame rule 1 min at cycle 36, first fail none, observed 5; P9: 45->1
    |}]
;;

(* Guarantee with a maximum: after P19 rises the chip raises P9 within 30 cycles. *)
let%expect_test "maximum: a late response is a fail" =
  let src : (int -> string, unit, string) format = "WAITP rise, 19, 0, 0, 1, 0\nTADDI %d\nPINV 1, 9 @at\nHALT\n" in
  List.iter
    (fun delay ->
      let chip = setup (Printf.sprintf src delay) in
      Model.set_rule chip 0 ~policy:2 ~owner:0 ~max:30 ~start:(w_rise 19) ~stop:(c_rise 9) ();
      let edges = run chip ~cycles:200 ~watch:[ 9 ] ~pad:(fun n -> if n >= 40 then 1 lsl 19 else 0) in
      Printf.printf "response after %2d: P9 %s; %s; first fail %s; observed max %d\n" delay (show_edges edges)
        (state_name chip.th.(0)) (verdict chip.first_fail) chip.rules.(0).obs_max)
    [ 20; 50 ];
  [%expect {|
    response after 20: P9 62->1; halted; first fail none; observed max 20
    response after 50: P9 ; fault RULE 0; first fail rule 0 max at cycle 72; observed max 0
    |}]
;;

(* Open-drain line P0 shared with a peer. Rule 0 counts low pulses the peer makes, rule 1
   low pulses we make. The wire is low if either side pulls it low. *)
let%expect_test "attribution on a shared open-drain line" =
  let chip =
    setup ~pins:[ 0 ]
      {|
        PINV 1, 0
        PDIR 1, 0 @now          ; enabled, released
        TNOW 40
        PINV 0, 0 @at           ; we pull low at 44 + 40
        TADDI 15
        PINV 1, 0 @at           ; and release
        HALT
      |}
  in
  chip.od <- 1;
  Model.set_rule chip 0 ~guarantee:false ~start:(w_fall ~qual:1 0) ~stop:(w_rise ~qual:1 0) ();
  Model.set_rule chip 1 ~start:(w_fall ~qual:2 0) ~stop:(w_rise ~qual:2 0) ();
  let peer_low n = n >= 150 && n < 172 in
  let prev = ref 1 in
  let our_low = ref [] in
  for n = 0 to 259 do
    let ours_low = Model.uio_oe chip land 1 = 1 && Model.uio_out chip land 1 = 0 in
    if ours_low then our_low := n :: !our_low;
    let wire = if ours_low || peer_low n then 0 else 1 in
    (* the level sampled at the edge that begins cycle n is the wire at the end of cycle n - 1 *)
    Model.step chip ~pad:!prev;
    prev := wire
  done;
  Printf.printf "we drive low in cycles %d..%d\n" (List.fold_left min max_int !our_low) (List.fold_left max 0 !our_low);
  let show k = let r = chip.rules.(k) in if r.obs_max = 0 then "nothing" else Printf.sprintf "%d cycles" r.obs_max in
  Printf.printf "peer's low pulse (22 cycles driven): %s; our low pulse (15 cycles driven): %s\n" (show 0) (show 1);
  [%expect {|
    we drive low in cycles 52..66
    peer's low pulse (22 cycles driven): 22 cycles; our low pulse (15 cycles driven): 15 cycles
    |}]
;;

(* A thread reads a rule's measurement through the I/O registers. *)
let%expect_test "rule measurements are readable by a thread" =
  let chip =
    setup
      {|
        TNOW 10
        PINV 1, 9 @at
        TADDI 25
        PINV 0, 9 @at
        NOP @now
        IOR r0, 0x21             ; rule 0, observed minimum
        IOR r1, 0x22             ; rule 0, observed maximum
        IOR r2, 0x20             ; rule 0, flags
        HALT
      |}
  in
  Model.set_rule chip 0 ~start:(c_rise 9) ~stop:(c_fall 9) ();
  ignore (run chip ~cycles:200 ~watch:[ 9 ]);
  Printf.printf "r0=%d r1=%d r2=%d %s\n" chip.th.(0).r.(0) chip.th.(0).r.(1) chip.th.(0).r.(2) (state_name chip.th.(0));
  [%expect {| r0=25 r1=25 r2=0 halted |}]
;;

(* V3 (v1.1): the automaton takes the step of cycle n in cycle n + 1. A violation found for
   cycle n is recorded during cycle n + 1 with cycle n as its time, and with fail-stop the owner
   faults at the end of cycle n + 1. *)
let%expect_test "an automaton verdict is recorded and acted on in the cycle after its event" =
  let chip = setup "WAITP rise, 19, 0, 0, 1, 0\nTADDI 50\nPINV 1, 9 @at\nHALT\n" in
  Model.set_rule chip 0 ~policy:2 ~owner:0 ~max:30 ~start:(w_rise 19) ~stop:(c_rise 9) ();
  for _ = 1 to 200 do
    let n = chip.Model.now in
    if n >= 71 && n <= 75
    then
      Printf.printf "start of cycle %d: first fail %s; thread 0 %s\n" n (verdict chip.first_fail)
        (state_name chip.th.(0));
    Model.step chip ~pad:(if n >= 40 then 1 lsl 19 else 0)
  done;
  [%expect {|
    start of cycle 71: first fail none; thread 0 run
    start of cycle 72: first fail none; thread 0 run
    start of cycle 73: first fail none; thread 0 run
    start of cycle 74: first fail rule 0 max at cycle 72; thread 0 fault RULE 0
    start of cycle 75: first fail rule 0 max at cycle 72; thread 0 fault RULE 0
    |}]
;;
