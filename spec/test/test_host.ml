open Spec
open Test_core

(* An SPI controller on the pads: SCK = ui[0] (P16), MOSI = ui[1] (P17), CS_N = ui[2] (P18),
   MISO = uo[0]. Mode 0, most significant bit first, [half] clock cycles per SCK phase. *)
type spi =
  { chip : Model.chip
  ; half : int
  ; mutable sck : int
  ; mutable mosi : int
  ; mutable cs_n : int
  }

let spi ?(half = 5) chip = { chip; half; sck = 0; mosi = 0; cs_n = 1 }
let pad s = (s.sck lsl 16) lor (s.mosi lsl 17) lor (s.cs_n lsl 18)
let wait s k = for _ = 1 to k do Model.step s.chip ~pad:(pad s) done

(* One transaction: send the bytes, return the bytes read at the same time. *)
let xfer s bytes =
  s.cs_n <- 0;
  wait s s.half;
  let rx =
    List.map
      (fun byte ->
        let got = ref 0 in
        for k = 7 downto 0 do
          s.mosi <- (byte lsr k) land 1;
          wait s s.half;
          got := (!got lsl 1) lor (Model.uo_out s.chip land 1);
          s.sck <- 1;
          wait s s.half;
          s.sck <- 0
        done;
        !got)
      bytes
  in
  wait s s.half;
  s.cs_n <- 1;
  wait s (2 * s.half);
  rx
;;

let word16 = function hi :: lo :: _ -> (hi lsl 8) lor lo | _ -> -1
let rec drop k l = if k = 0 then l else drop (k - 1) (List.tl l)
let wreg s a v = ignore (xfer s [ 0x20; a; v lsr 8; v land 0xFF ])
let rreg s a = word16 (drop 2 (xfer s [ 0x10; a; 0; 0 ]))
let bytes_of ~width v = List.init (width / 8) (fun k -> (v lsr (width - 8 - (8 * k))) land 0xFF)

let wmem s ~prog addr words =
  let width = if prog then 32 else 16 in
  ignore (xfer s ([ (if prog then 0x40 else 0x60); addr lsr 8; addr land 0xFF ] @ List.concat_map (bytes_of ~width) words))
;;

let rmem s ~prog addr n =
  let width = if prog then 32 else 16 in
  let rx = drop 4 (xfer s ([ (if prog then 0x30 else 0x50); addr lsr 8; addr land 0xFF; 0 ] @ List.init (n * width / 8) (fun _ -> 0))) in
  let rec words = function
    | [] -> []
    | l ->
      let k = width / 8 in
      List.fold_left (fun acc b -> (acc lsl 8) lor b) 0 (List.filteri (fun i _ -> i < k) l) :: words (drop k l)
  in
  words rx
;;

let echo =
  Asm.assemble
    {|
        PINV 1, 9 @now
loop:   PULL r0, 0
        ALUI add, r0, 1
        PUSH r0, 0
        JMP loop
    |}
;;

let%expect_test "a session over SPI: configure, load, start, mailbox, memory" =
  let chip = Model.create () in
  let s = spi chip in
  Printf.printf "ID %04X, info %04X\n" (rreg s 0x00) (rreg s 0x01);
  wreg s 0x12 0x7707;
  (* owner of P9 := thread 0 *)
  wreg s 0x43 0;
  wreg s 0x44 (Array.length echo);
  wreg s 0x45 0;
  wreg s 0x46 256;
  wreg s 0x40 3;
  wmem s ~prog:true 0 (Array.to_list echo);
  wreg s 0x4D (Model.digest_of echo);
  let flags = rreg s 0x4E in
  let digest = rreg s 0x4C in
  let hstat = rreg s 0x04 in
  Printf.printf "flags %X (1 = loaded), digest %04X (%04X), host status %X\n" flags digest (Model.digest_of echo) hstat;
  Printf.printf "program read back correctly: %b\n" (rmem s ~prog:true 0 (Array.length echo) = Array.to_list echo);
  wreg s 0x42 0;
  wreg s 0x40 1;
  wait s 40;
  Printf.printf "thread state %X (1 = running; a PULL on an empty mailbox retries), P9 = %d\n" (rreg s 0x41) (level chip 9);
  wreg s 0x48 0x1234;
  wait s 40;
  let before = rreg s 0x4A in
  let word = rreg s 0x49 in
  let after = rreg s 0x4A in
  Printf.printf "mailbox status %X (bit 1: a word is waiting), word %04X, status after reading %X\n" before word after;
  wmem s ~prog:false 0x100 [ 0xBEEF; 0x0042; 0xFFFF ];
  Printf.printf "data read back: %s\n" (String.concat " " (List.map (Printf.sprintf "%04X") (rmem s ~prog:false 0x100 3)));
  let n0 = chip.now in
  let lo = rreg s 0x02 in
  let n1 = chip.now in
  let hi = rreg s 0x03 in
  let now = lo lor (hi lsl 16) in
  Printf.printf "now read as %d, taken during the read (between cycles %d and %d): %b\n" now n0 n1 (now >= n0 && now <= n1);
  [%expect {|
    ID 8401, info 0314
    flags 1 (1 = loaded), digest 5603 (5603), host status 0
    program read back correctly: true
    thread state 1 (1 = running; a PULL on an empty mailbox retries), P9 = 1
    mailbox status 3 (bit 1: a word is waiting), word 1235, status after reading 1
    data read back: BEEF 0042 FFFF
    now read as 12061, taken during the read (between cycles 11900 and 12240): true
    |}]
;;

let%expect_test "load gate" =
  let chip = Model.create () in
  let s = spi chip in
  let n = Array.length echo in
  let status () =
    let v = rreg s 0x04 in
    wreg s 0x04 0xFFFF;
    v
  in
  wreg s 0x12 0x7707;
  wreg s 0x44 n;
  wreg s 0x46 256;
  wreg s 0x40 1;
  Printf.printf "start without a load: state %X, host status %X (4 = refused)\n" (rreg s 0x41) (status ());
  wreg s 0x40 3;
  wmem s ~prog:true 0 (Array.to_list echo);
  wreg s 0x4D (Model.digest_of echo lxor 1);
  Printf.printf "wrong digest: flags %X, host status %X (2 = load error)\n" (rreg s 0x4E) (status ());
  wreg s 0x40 3;
  wmem s ~prog:true 0 (List.rev (Array.to_list echo));
  wreg s 0x4D (Model.digest_of echo);
  Printf.printf "words in the wrong order: flags %X, host status %X\n" (rreg s 0x4E) (status ());
  wreg s 0x40 3;
  wmem s ~prog:true 1 (List.tl (Array.to_list echo));
  Printf.printf "load not starting at the window base: host status %X\n" (status ());
  wreg s 0x40 3;
  wmem s ~prog:true 0 (Array.to_list echo);
  wreg s 0x4D (Model.digest_of echo);
  wreg s 0x40 1;
  wait s 20;
  Printf.printf "correct load: flags %X, state %X, host status %X\n" (rreg s 0x4E) (rreg s 0x41 land 7) (status ());
  wmem s ~prog:true 2 [ 0 ];
  Printf.printf "write into the running thread's window: host status %X, word unchanged %b\n" (status ())
    (rmem s ~prog:true 2 1 = [ echo.(2) ]);
  wreg s 0x44 3;
  Printf.printf "window change while running: host status %X, size still %d\n" (status ()) (rreg s 0x44);
  wreg s 0x40 2;
  wait s 8;
  Printf.printf "stop: state %X, P9 = %d (safe pattern)\n" (rreg s 0x41 land 7) (level chip 9);
  wmem s ~prog:true 2 [ 0 ];
  wreg s 0x40 1;
  Printf.printf "write into the stopped window: flags %X; start: state %X, host status %X\n" (rreg s 0x4E) (rreg s 0x41 land 7)
    (status ());
  wmem s ~prog:true 100 [ 0xDEADBEEF ];
  Printf.printf "write outside every window: %08X, host status %X\n" (List.hd (rmem s ~prog:true 100 1)) (status ());
  [%expect {|
    start without a load: state 0, host status 4 (4 = refused)
    wrong digest: flags 0, host status 2 (2 = load error)
    words in the wrong order: flags 0, host status 2
    load not starting at the window base: host status 4
    correct load: flags 1, state 1, host status 0
    write into the running thread's window: host status 4, word unchanged true
    window change while running: host status 4, size still 5
    stop: state 0, P9 = 0 (safe pattern)
    write into the stopped window: flags 0; start: state 0, host status 4
    write outside every window: DEADBEEF, host status 0
    |}]
;;

(* How fast may SCK be? The model has no pad delay, so this is a lower bound on the period. *)
let%expect_test "SCK period on the model" =
  List.iter
    (fun half ->
      let chip = Model.create () in
      let s = spi ~half chip in
      wreg s 0x15 0xA5C3;
      let id = rreg s 0x00 and v = rreg s 0x15 in
      wmem s ~prog:false 7 [ 0x1357; 0x2468 ];
      let d = rmem s ~prog:false 7 2 in
      Printf.printf "SCK period %2d cycles: ID %04X, register %04X, data %s -> %s\n" (2 * half) id v
        (String.concat " " (List.map (Printf.sprintf "%04X") d))
        (if id = 0x8401 && v = 0xA5C3 && d = [ 0x1357; 0x2468 ] then "ok" else "WRONG"))
    [ 5; 4; 3; 2; 1 ];
  [%expect {|
    SCK period 10 cycles: ID 8401, register A5C3, data 1357 2468 -> ok
    SCK period  8 cycles: ID 8401, register A5C3, data 1357 2468 -> ok
    SCK period  6 cycles: ID 8401, register A5C3, data 1357 2468 -> ok
    SCK period  4 cycles: ID 8401, register A5C3, data 1357 2468 -> ok
    SCK period  2 cycles: ID 4200, register 52E1, data 09AB 9234 -> WRONG
    |}]
;;

(* The same program started over SPI and through the direct calls gives the same pins. *)
let%expect_test "loading over SPI and loading directly are the same" =
  let words = Asm.assemble uart in
  let chip = Model.create () in
  let s = spi chip in
  wreg s 0x12 0x7707;
  wreg s 0x44 (Array.length words);
  wreg s 0x46 256;
  wreg s 0x40 3;
  wmem s ~prog:true 0 (Array.to_list words);
  wreg s 0x4D (Model.digest_of words);
  wreg s 0x40 1;
  let t_start = chip.now in
  let edges = run chip ~cycles:6000 ~watch:[ 9 ] in
  let direct = run (setup uart) ~cycles:6000 ~watch:[ 9 ] in
  let rel l = match l with (c0, _, _) :: _ -> List.map (fun (c, _, v) -> c - c0, v) l | [] -> [] in
  Printf.printf "%d edges after the SPI start at cycle %d, %d edges directly; same waveform: %b\n" (List.length edges) t_start
    (List.length direct)
    (rel edges = rel direct);
  [%expect {| 11 edges after the SPI start at cycle 5180, 11 edges directly; same waveform: true |}]
;;
