open Spec

(* Run [cycles] cycles and return every change of the watched pins as (cycle, pin, level),
   where level is 0, 1 or 2 for a released bidirectional pin. The level listed for cycle n
   is the pad register value during cycle n. *)
let level chip p =
  if p >= 8
  then (Model.uo_out chip lsr (p - 8)) land 1
  else if (Model.uio_oe chip lsr p) land 1 = 0
  then 2
  else (Model.uio_out chip lsr p) land 1
;;

let run ?(pad = fun _ -> 0) chip ~cycles ~watch =
  let last = Array.of_list (List.map (level chip) watch) in
  let out = ref [] in
  for _ = 1 to cycles do
    let n = chip.Model.now in
    List.iteri
      (fun k p ->
        let v = level chip p in
        if v <> last.(k)
        then begin
          out := (n, p, v) :: !out;
          last.(k) <- v
        end)
      watch;
    Model.step chip ~pad:(pad n)
  done;
  List.rev !out
;;

let setup ?(tid = 0) ?(pins = [ 9 ]) ?(base = 0) src =
  let chip = Model.create () in
  let words = Asm.assemble src in
  Model.load chip ~base words;
  Model.set_window chip tid ~pbase:base ~psize:(Array.length words) ~dbase:(tid * 256) ~dsize:256;
  List.iter (fun p -> Model.set_owner chip p tid) pins;
  Model.start chip tid ~pc:0;
  chip
;;

let state_name (th : Model.thread) =
  match th.state with
  | Idle -> "idle"
  | Run -> "run"
  | Wait_ev -> "wait"
  | Halted -> "halted"
  | Faulted f -> "fault " ^ Model.fault_name f
;;

(* 8N1 frame of 0x55 at 48 MHz / 115200 = 416.67 cycles per bit: p = 416 + 171/256. *)
let uart =
  {|
        ALUI mov, r0, 0x2AA      ; stop bit, 0x55, start bit; sent from bit 0
        ALUI mov, r1, 10
        TPERI 0, 0xA0AB
        TPERI 1, 0x0001
        PINV 1, 9 @now           ; idle level
        TNOW 20
loop:   OUTS 0, 9, r0 @adv
        DJNZ r1, loop
        HALT
  |}
;;

let%expect_test "UART frame: every edge on its deadline, no drift" =
  let chip = setup uart in
  let edges = run chip ~cycles:6000 ~watch:[ 9 ] in
  let t0 = match edges with _ :: (c, _, _) :: _ -> c | _ -> -1 in
  List.iter (fun (c, _, v) -> Printf.printf "cycle %5d  tx=%d  offset %d\n" c v (c - t0)) edges;
  (* the k-th bit boundary must be at floor(k * 416.668) after the start bit *)
  let ok =
    List.for_all2
      (fun (c, _, _) k -> c - t0 = k * 0x1A0AB / 256)
      (List.tl edges)
      (List.init (List.length edges - 1) (fun k -> k))
  in
  Printf.printf "all bit boundaries at floor(k * p): %b; thread %s; slack minimum %d\n" ok (state_name chip.th.(0))
    chip.th.(0).slack_min;
  [%expect {|
    cycle    21  tx=1  offset -23
    cycle    44  tx=0  offset 0
    cycle   460  tx=1  offset 416
    cycle   877  tx=0  offset 833
    cycle  1294  tx=1  offset 1250
    cycle  1710  tx=0  offset 1666
    cycle  2127  tx=1  offset 2083
    cycle  2544  tx=0  offset 2500
    cycle  2960  tx=1  offset 2916
    cycle  3377  tx=0  offset 3333
    cycle  3794  tx=1  offset 3750
    all bit boundaries at floor(k * p): true; thread halted; slack minimum 16
    |}]
;;

(* One commit per round: a straight line of timed pin writes with period 4.0, for every
   thread and every alignment of the first deadline to the thread's slot. *)
let%expect_test "one edge every 4 cycles is sustained at any phase" =
  let prog lead =
    let b = Buffer.create 256 in
    Buffer.add_string b (Printf.sprintf "TPERI 0, 0x0400\nTPERI 1, 0\nTNOW %d\n" lead);
    for k = 1 to 12 do Buffer.add_string b (Printf.sprintf "PINV %d, 9 @adv\n" (k land 1)) done;
    Buffer.add_string b "HALT\n";
    Buffer.contents b
  in
  for tid = 0 to 2 do
    for lead = 5 to 9 do
      let chip = setup ~tid (prog lead) in
      let edges = run chip ~cycles:120 ~watch:[ 9 ] in
      let cs = List.map (fun (c, _, _) -> c) edges in
      let gaps = List.sort_uniq compare (List.map2 (fun a b -> b - a) (List.rev (List.tl (List.rev cs))) (List.tl cs)) in
      Printf.printf "thread %d lead %d: %2d edges, first at %2d, gaps {%s}, %s, slack minimum %d\n" tid lead
        (List.length edges) (List.hd cs)
        (String.concat "," (List.map string_of_int gaps))
        (state_name chip.th.(tid)) chip.th.(tid).slack_min
    done
  done;
  [%expect {|
    thread 0 lead 5: 12 edges, first at 17, gaps {4}, halted, slack minimum 1
    thread 0 lead 6: 12 edges, first at 18, gaps {4}, halted, slack minimum 2
    thread 0 lead 7: 12 edges, first at 19, gaps {4}, halted, slack minimum 3
    thread 0 lead 8: 12 edges, first at 20, gaps {4}, halted, slack minimum 4
    thread 0 lead 9: 12 edges, first at 21, gaps {4}, halted, slack minimum 1
    thread 1 lead 5: 12 edges, first at 18, gaps {4}, halted, slack minimum 1
    thread 1 lead 6: 12 edges, first at 19, gaps {4}, halted, slack minimum 2
    thread 1 lead 7: 12 edges, first at 20, gaps {4}, halted, slack minimum 3
    thread 1 lead 8: 12 edges, first at 21, gaps {4}, halted, slack minimum 4
    thread 1 lead 9: 12 edges, first at 22, gaps {4}, halted, slack minimum 1
    thread 2 lead 5: 12 edges, first at 19, gaps {4}, halted, slack minimum 1
    thread 2 lead 6: 12 edges, first at 20, gaps {4}, halted, slack minimum 2
    thread 2 lead 7: 12 edges, first at 21, gaps {4}, halted, slack minimum 3
    thread 2 lead 8: 12 edges, first at 22, gaps {4}, halted, slack minimum 4
    thread 2 lead 9: 12 edges, first at 23, gaps {4}, halted, slack minimum 1
    |}]
;;

(* Reaction to an input edge: the staged write is committed by the timing hardware, and the
   deadline is re-anchored to the event, so later edges keep an exact distance to it. *)
let%expect_test "event wait: constant latency and re-anchored deadline" =
  let src : (int -> string, unit, string) format =
    {|
        PINV 1, 9                 ; staged, not committed
        WAITP rise, 19, 0, 1, 1, 0
        TADDI %d
        PINV 0, 9 @at
        HALT
    |}
  in
  (* 12 cycles is the shortest distance that is on time for every alignment of the event to
     the thread's slot; with 11 one alignment is late and the thread faults. *)
  List.iter
    (fun dist ->
      List.iter
        (fun rise ->
          let chip = setup (Printf.sprintf src dist) in
          let edges = run chip ~cycles:120 ~watch:[ 9 ] ~pad:(fun n -> if n >= rise then 1 lsl 19 else 0) in
          Printf.printf "distance %d, input sampled high at cycle %d: %s; %s, slack minimum %d\n" dist rise
            (String.concat ", " (List.map (fun (c, _, v) -> Printf.sprintf "out=%d at %d (+%d)" v c (c - rise)) edges))
            (state_name chip.th.(0)) chip.th.(0).slack_min)
        [ 40; 41; 42; 43 ])
    [ 12; 11 ];
  [%expect {|
    distance 12, input sampled high at cycle 40: out=1 at 42 (+2), out=0 at 54 (+14); halted, slack minimum 2
    distance 12, input sampled high at cycle 41: out=1 at 43 (+2), out=0 at 55 (+14); halted, slack minimum 3
    distance 12, input sampled high at cycle 42: out=1 at 44 (+2), out=0 at 56 (+14); halted, slack minimum 4
    distance 12, input sampled high at cycle 43: out=1 at 45 (+2), out=0 at 57 (+14); halted, slack minimum 1
    distance 11, input sampled high at cycle 40: out=1 at 42 (+2), out=0 at 53 (+13); halted, slack minimum 1
    distance 11, input sampled high at cycle 41: out=1 at 43 (+2), out=0 at 54 (+13); halted, slack minimum 2
    distance 11, input sampled high at cycle 42: out=1 at 44 (+2), out=0 at 55 (+13); halted, slack minimum 3
    distance 11, input sampled high at cycle 43: out=1 at 45 (+2), out=0 at 57 (+14); fault LATE, slack minimum 0
    |}]
;;

(* With adv in the wait itself the first deadline can be 8 cycles after the event commit. *)
let%expect_test "event wait with adv: 8 cycles to the next edge" =
  let src : (int -> string, unit, string) format =
    {|
        TPERI 0, %d
        TPERI 1, 0
        PINV 1, 9
        WAITP rise, 19, 0, 1, 1, 1
        PINV 0, 9 @at
        HALT
    |}
  in
  List.iter
    (fun period ->
      List.iter
        (fun rise ->
          let chip = setup (Printf.sprintf src (period * 256)) in
          let edges = run chip ~cycles:120 ~watch:[ 9 ] ~pad:(fun n -> if n >= rise then 1 lsl 19 else 0) in
          Printf.printf "period %d, input sampled high at cycle %d: %s; %s, slack minimum %d\n" period rise
            (String.concat ", " (List.map (fun (c, _, v) -> Printf.sprintf "out=%d at %d (+%d)" v c (c - rise)) edges))
            (state_name chip.th.(0)) chip.th.(0).slack_min)
        [ 40; 41; 42; 43 ])
    [ 8; 7 ];
  [%expect {|
    period 8, input sampled high at cycle 40: out=1 at 42 (+2), out=0 at 50 (+10); halted, slack minimum 2
    period 8, input sampled high at cycle 41: out=1 at 43 (+2), out=0 at 51 (+10); halted, slack minimum 3
    period 8, input sampled high at cycle 42: out=1 at 44 (+2), out=0 at 52 (+10); halted, slack minimum 4
    period 8, input sampled high at cycle 43: out=1 at 45 (+2), out=0 at 53 (+10); halted, slack minimum 1
    period 7, input sampled high at cycle 40: out=1 at 42 (+2), out=0 at 49 (+9); halted, slack minimum 1
    period 7, input sampled high at cycle 41: out=1 at 43 (+2), out=0 at 50 (+9); halted, slack minimum 2
    period 7, input sampled high at cycle 42: out=1 at 44 (+2), out=0 at 51 (+9); halted, slack minimum 3
    period 7, input sampled high at cycle 43: out=1 at 45 (+2), out=0 at 53 (+10); fault LATE, slack minimum 0
    |}]
;;

let%expect_test "a deadline that has passed: fault, or commit at once and flag" =
  let src = "TNOW 2\nPINV 1, 9 @at\nHALT\n" in
  List.iter
    (fun strict ->
      let chip = setup src in
      chip.th.(0).strict <- strict;
      let edges = run chip ~cycles:40 ~watch:[ 9 ] in
      Printf.printf "strict=%b: %s; edges: %s; late flag %b; slack minimum %d\n" strict (state_name chip.th.(0))
        (String.concat ", " (List.map (fun (c, _, v) -> Printf.sprintf "%d->%d" c v) edges))
        chip.th.(0).late chip.th.(0).slack_min)
    [ true; false ];
  [%expect {|
    strict=true: fault LATE; edges: ; late flag false; slack minimum -2
    strict=false: halted; edges: 9->1; late flag true; slack minimum -2
    |}]
;;

let%expect_test "faults leave the pins in the safe pattern" =
  let try_ name src =
    let chip = setup ~pins:[ 9; 3 ] src in
    chip.safe_val <- 0;
    chip.safe_dir <- 0;
    ignore (run chip ~cycles:60 ~watch:[ 9 ]);
    Printf.printf "%-22s %-14s pc=%d P9=%d P3=%d\n" name (state_name chip.th.(0)) chip.th.(0).pc (level chip 9) (level chip 3)
  in
  try_ "pin of another owner" "PINV 1, 9 @now\nPDIR 1, 3 @now\nPINV 1, 10 @now\nHALT\n";
  try_ "data address" "PINV 1, 9 @now\nLD r0, 300\nHALT\n";
  try_ "run off the window" "PINV 1, 9 @now\nNOP\n";
  try_ "user trap" "PINV 1, 9 @now\nTRAP 42\n";
  try_ "undefined I/O register" "PINV 1, 9 @now\nIOR r0, 99\n";
  try_ "halt keeps the pins" "PINV 1, 9 @now\nPDIR 1, 3 @now\nHALT\n";
  [%expect {|
    pin of another owner   fault PINOWN   pc=2 P9=0 P3=2
    data address           fault DBOUND   pc=1 P9=0 P3=2
    run off the window     fault PCBOUND  pc=2 P9=0 P3=2
    user trap              fault TRAP 42  pc=1 P9=0 P3=2
    undefined I/O register fault IOPERM   pc=1 P9=0 P3=2
    halt keeps the pins    halted         pc=3 P9=1 P3=0
    |}]
;;

(* Thread 0's pins do not depend on what the other threads run. *)
let%expect_test "isolation: same trace with and without neighbours" =
  let alone = run (setup uart) ~cycles:6000 ~watch:[ 9 ] in
  let busy = setup uart in
  let noise tid pin base =
    let words =
      Asm.assemble
        (Printf.sprintf
           {|
        TPERI 0, 0x2000
        TPERI 1, 0
        ALUI mov, r3, 0xACE1
        TNOW 9
again:  OUTS 0, %d, r3 @adv
        ALUI xor, r3, 0x5A5A
        ALU mov, r4, r3, r3
        ALUI and, r4, 0x00FF
        STX r3, r4, 0
        JMP again
           |}
           pin)
    in
    Model.load busy ~base words;
    Model.set_window busy tid ~pbase:base ~psize:(Array.length words) ~dbase:(tid * 256) ~dsize:256;
    Model.set_owner busy pin tid;
    Model.start busy tid ~pc:0
  in
  noise 1 10 64;
  noise 2 11 128;
  let together = run busy ~cycles:6000 ~watch:[ 9; 10; 11 ] in
  let mine = List.filter (fun (_, p, _) -> p = 9) together in
  Printf.printf "thread 0 edges alone %d, with neighbours %d, identical: %b\n" (List.length alone) (List.length mine)
    (alone = mine);
  Printf.printf "neighbour edges: P10 %d, P11 %d; neighbour states: %s, %s\n"
    (List.length (List.filter (fun (_, p, _) -> p = 10) together))
    (List.length (List.filter (fun (_, p, _) -> p = 11) together))
    (state_name busy.th.(1)) (state_name busy.th.(2));
  [%expect {|
    thread 0 edges alone 11, with neighbours 11, identical: true
    neighbour edges: P10 8, P11 8; neighbour states: run, run
    |}]
;;

(* Mailbox and data memory. *)
let%expect_test "host mailbox round trip" =
  let chip =
    setup
      {|
loop:   PULL r0, 0
        ST r0, 5
        LD r1, 5
        ALUI add, r1, 1
        PUSH r1, 0
        JMP loop
      |}
  in
  let got = ref [] in
  let sent = ref 0 in
  for _ = 1 to 400 do
    if !sent < 5 && Model.host_push chip 0 (100 * (!sent + 1)) then incr sent;
    (match Model.host_pop chip 0 with Some v -> got := v :: !got | None -> ());
    Model.step chip ~pad:0
  done;
  Printf.printf "sent %d words, received %s\n" !sent (String.concat " " (List.rev_map string_of_int !got));
  [%expect {| sent 5 words, received 101 201 301 401 501 |}]
;;

(* SPI controller, mode 0, most significant bit first, against a target modelled in the test.
   OUTSC puts the next MOSI bit and SCK low into one commit; INSC shifts in MISO as captured
   at that commit (the bit the target presented during the previous high phase) and stages
   SCK high. The first bit shifted in is therefore not data and ends up above bit 7. *)
let%expect_test "SPI controller: one byte each way, three instructions per bit" =
  let src : (int -> string, unit, string) format =
    {|
        ALUI mov, r0, 0xA500
        ALUI mov, r1, 0
        ALUI mov, r2, 8
        TPERI 0, %d
        TPERI 1, 0
        TNOW 12
loop:   OUTSC 1, 10, r0, 9, 0 @adv
        INSC 1, cap, 19, r1, 9, 1 @adv
        DJNZ r2, loop
        PINV 0, 9 @adv
        INS 1, cap, 19, r1
        HALT
    |}
  in
  List.iter
    (fun half ->
      let chip = setup ~pins:[ 9; 10 ] (Printf.sprintf src (half * 256)) in
      let tx = 0x3C in
      let idx = ref 7 and rx = ref 0 and sck_prev = ref 0 and miso_prev = ref 0 in
      let rises = ref [] in
      for n = 0 to 399 do
        let sck = level chip 9 and mosi = level chip 10 in
        if !sck_prev = 0 && sck = 1
        then begin
          rx := ((!rx lsl 1) lor mosi) land 0xFF;
          rises := n :: !rises
        end;
        if !sck_prev = 1 && sck = 0 then decr idx;
        sck_prev := sck;
        let miso = if !idx >= 0 then (tx lsr !idx) land 1 else 0 in
        Model.step chip ~pad:(!miso_prev lsl 19);
        miso_prev := miso
      done;
      let rs = List.rev !rises in
      let gaps = List.sort_uniq compare (List.map2 (fun a b -> b - a) (List.rev (List.tl (List.rev rs))) (List.tl rs)) in
      Printf.printf "half period %d: %d clock pulses, period {%s} cycles; target got %02X (A5), chip got %02X (3C); %s, slack minimum %d\n"
        half (List.length rs)
        (String.concat "," (List.map string_of_int gaps))
        !rx
        (chip.th.(0).r.(1) land 0xFF)
        (state_name chip.th.(0)) chip.th.(0).slack_min)
    [ 8; 6; 5 ];
  [%expect {|
    half period 8: 8 clock pulses, period {16} cycles; target got A5 (A5), chip got 3C (3C); halted, slack minimum 8
    half period 6: 8 clock pulses, period {12} cycles; target got A5 (A5), chip got 3C (3C); halted, slack minimum 4
    half period 5: 2 clock pulses, period {10} cycles; target got 02 (A5), chip got 00 (3C); fault LATE, slack minimum 0
    |}]
;;
