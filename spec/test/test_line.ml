open Spec

(* Tests of the line unit and the response rules (doc/spec/line.md). The unit is configured
   through its host registers; uo[4..7] (P12..P15) are wired to ui[4..7] (P20..P23), the
   host port's CS_N (P18) is held high, and a released bidirectional pin reads [pull]. *)

let hw chip j v = Model.reg_write chip (0xC0 + j) v
let hr chip j = Model.reg_peek chip (0xC0 + j)

let wire ?(pull = 0xFF) ?(ext = fun _ -> 0, 0) (chip : Model.chip) =
  let oe = Model.uio_oe chip and out = Model.uio_out chip in
  let uio = (out land oe) lor (pull land lnot oe land 0xFF) in
  let v = uio lor ((Model.uo_out chip land 0xF0) lsl 16) lor (1 lsl 18) in
  let m, x = ext chip.now in
  v land lnot m lor (x land m)
;;

(* Run and keep, for every cycle, the pad word, with uo_out in bits 8..15. *)
let sim ?pull ?ext chip ~cycles =
  Array.init cycles (fun _ ->
    let pv = wire ?pull ?ext chip lor (Model.uo_out chip lsl 8) in
    Model.step chip ~pad:pv;
    pv)
;;

let unit_chip ?(tid = 0) ?(pins = []) () =
  let chip = Model.create () in
  Model.set_window chip tid ~pbase:0 ~psize:16 ~dbase:0 ~dsize:512;
  List.iter (fun p -> Model.set_owner chip p tid) pins;
  hw chip 22 tid;
  chip
;;

(* control register *)
let ctl ?(rearm = false) ?(diff = false) ?(code = 0) ?(inv = false) ?(idle = 1) ?(lsb = true) ?(stuff = 0)
  ?(ones = false) ?(stuff_last = false) ?(ext = false) ?(fall = false) ?(release = false) () =
  let b v k = if v then 1 lsl k else 0 in
  b rearm 0 lor b diff 1 lor (code lsl 2) lor b inv 4 lor (idle lsl 5) lor b lsb 6
  lor b (stuff > 0) 7 lor ((stuff land 7) lsl 8) lor b ones 11 lor b stuff_last 12 lor b ext 13 lor b fall 14
  lor b release 15
;;

let pins_reg ?(tx = 0) ?(rx = 0) ?(clk = 0) () = tx lor (rx lsl 4) lor (clk lsl 9)

(* bits of a byte list, least significant bit of each byte first *)
let bits_lsb bytes = List.concat_map (fun b -> List.init 8 (fun k -> (b lsr k) land 1)) bytes

(* pack bits into 16-bit words, first bit in bit 0 (lsb) or bit 15 *)
let pack ~lsb bits =
  let n = (List.length bits + 15) / 16 in
  let w = Array.make n 0 in
  List.iteri (fun i b -> w.(i / 16) <- w.(i / 16) lor (b lsl if lsb then i land 15 else 15 - (i land 15))) bits;
  w
;;

let show_bits l = String.concat "" (List.map string_of_int l)
let words chip base n = String.concat " " (List.init n (fun k -> Printf.sprintf "%04X" chip.Model.data.(base + k)))

(* Reference encoders, written independently of the model. *)
let stuff ~n ~ones ~last bits =
  let out = ref [] and run = ref 0 and prev = ref (-1) in
  let emit b =
    out := b :: !out;
    if ones
    then run := if b = 1 then !run + 1 else 0
    else if b = !prev
    then incr run
    else begin
      run := 1; prev := b
    end
  in
  let stuff_bit () = emit (if ones then 0 else 1 - !prev) in
  List.iteri
    (fun i b ->
      if !run >= n && i > 0 then stuff_bit ();
      emit b)
    bits;
  if last && !run >= n then stuff_bit ();
  List.rev !out
;;

let nrzi ~start bits =
  let lv = ref start in
  List.map (fun b -> if b = 0 then lv := 1 - !lv; !lv) bits
;;

(* USB CRC16 the usual table-free way: reflected register, complemented, low byte first. *)
let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun b ->
      crc := !crc lxor b;
      for _ = 1 to 8 do crc := if !crc land 1 = 1 then (!crc lsr 1) lxor 0xA001 else !crc lsr 1 done)
    bytes;
  let c = !crc lxor 0xFFFF in
  [ c land 0xFF; c lsr 8 ]
;;

let can_crc15 bits =
  List.fold_left
    (fun crc b ->
      let nxt = b lxor ((crc lsr 14) land 1) in
      let crc = (crc lsl 1) land 0x7FFF in
      if nxt = 1 then crc lxor 0x4599 else crc)
    0 bits
;;

(* level of pad [pin] in the first cycle of bit k of a frame whose first bit is on the pads
   in cycle c0, for a period of [per] sixteenths of a cycle *)
let bit_levels tr ~pin ~c0 ~per ~n =
  List.init n (fun k -> (tr.(c0 + (((k * per) + 15) / 16)) lsr pin) land 1)
;;

let%expect_test "NRZ transmit: bit k starts ceil(k * period) cycles after the first, also for a fractional period" =
  List.iter
    (fun per ->
      let chip = unit_chip ~pins:[ 12 ] () in
      chip.data.(0) <- 0xA5C3; chip.data.(1) <- 0x0F;
      hw chip 1 (ctl ()); hw chip 2 per; hw chip 3 (pins_reg ~tx:12 ()); hw chip 8 20;
      hw chip 0 1;
      let tr = sim chip ~cycles:200 in
      let edges = List.filter (fun c -> c > 0 && (tr.(c) lxor tr.(c - 1)) land (1 lsl 20) <> 0) (List.init 200 Fun.id) in
      let got = bit_levels tr ~pin:20 ~c0:3 ~per ~n:20 in
      Printf.printf "period %4.2f: sent %s, expected %s; pad changes at %s; status %04X\n" (float per /. 16.) (show_bits got)
        (show_bits (List.init 20 (fun i -> ((0xA5C3 lor (0x0F lsl 16)) lsr i) land 1)))
        (String.concat " " (List.map string_of_int edges)) (hr chip 0))
    [ 64; 104; 16 ];
  [%expect {|
    period 4.00: sent 11000011101001011111, expected 11000011101001011111; pad changes at 3 11 27 39 43 47 55 59 63; status 0008
    period 6.50: sent 11000011101001011111, expected 11000011101001011111; pad changes at 3 16 42 62 68 75 88 94 101; status 0008
    period 1.00: sent 11000011101001011111, expected 11000011101001011111; pad changes at 3 5 9 12 13 14 16 17 18; status 0008
    |}]
;;

(* A USB full-speed style data packet: NRZI, a 0 after six 1s, CRC16 complemented, end of
   packet as two bit times of both lines low and one of idle, on the pair P0 / P1, received by
   the same unit from the same pins. *)
let usb_cfg chip =
  hw chip 1 (ctl ~diff:true ~code:1 ~stuff:6 ~ones:true ~stuff_last:true ~release:true ());
  hw chip 2 64;
  hw chip 3 (pins_reg ~tx:0 ~rx:0 ());
  hw chip 4 0x8005; hw chip 5 (16 lor 32 lor 64); hw chip 6 0x800D; hw chip 17 (16 lor (8 lsl 8));
  hw chip 9 (3 lor (0b010000 lsl 8));
  hw chip 10 64; hw chip 11 32; hw chip 12 (0x01 lor (8 lsl 8)); hw chip 13 1; hw chip 15 0xFF
;;

let%expect_test "USB-style packet: transmit waveform against a reference encoder, and loop back" =
  let payload = [ 0xFF; 0xFF; 0x00; 0x7E; 0xFE; 0x01; 0xFF; 0xFF; 0xFF ] in
  let head = [ 0x80; 0xC3 ] in
  let chip = unit_chip ~pins:[ 0; 1 ] () in
  usb_cfg chip;
  Array.iteri (fun k w -> chip.data.(k) <- w) (pack ~lsb:true (bits_lsb (head @ payload)));
  hw chip 8 (8 * List.length (head @ payload));
  hw chip 0 3;
  let tr = sim ~pull:0xFD chip ~cycles:700 in
  let crc = usb_crc16 payload in
  let line = nrzi ~start:1 (stuff ~n:6 ~ones:true ~last:true (bits_lsb (head @ payload @ crc))) in
  let n = List.length line in
  let dp = bit_levels tr ~pin:0 ~c0:3 ~per:64 ~n:(n + 4) and dm = bit_levels tr ~pin:1 ~c0:3 ~per:64 ~n:(n + 4) in
  let take k l = List.filteri (fun i _ -> i < k) l and drop k l = List.filteri (fun i _ -> i >= k) l in
  Printf.printf "line bits %d (%d of them stuffed); D+ equals the reference: %b; D- is its complement: %b\n" n
    (n - (8 * (List.length (head @ payload) + 2))) (take n dp = line)
    (List.for_all2 (fun a b -> a = 1 - b) (take n dp) (take n dm));
  Printf.printf "after the last bit, D+ D-: %s %s (two bit times low, then idle, then released)\n" (show_bits (drop n dp))
    (show_bits (drop n dm));
  Printf.printf "CRC sent %s, reference %02X %02X\n" (words chip (64 + ((8 * (1 + List.length payload)) / 16)) 2)
    (List.nth crc 0) (List.nth crc 1);
  Printf.printf "received %d bits: %s\n" (hr chip 18) (words chip 64 6);
  Printf.printf "status %04X (frame sent, frame received, CRC good)\n" (hr chip 0);
  [%expect {|
    line bits 113 (9 of them stuffed); D+ equals the reference: true; D- is its complement: true
    after the last bit, D+ D-: 0011 0000 (two bit times low, then idle, then released)
    CRC sent 49EC 0000, reference EC 49
    received 96 bits: FFC3 00FF FE7E FF01 FFFF 49EC
    status 0038 (frame sent, frame received, CRC good)
    |}]
;;

(* A CAN-style frame from another node, 1 % slower than the unit's bit clock, on a wired-AND
   bus (P20 reads the other node AND our transmit pin P12). The unit receives it and a
   response rule answers in the acknowledge slot. *)
let%expect_test "CAN-style frame: receive with resynchronisation, acknowledge by a response rule" =
  let msb v n = List.init n (fun k -> (v lsr (n - 1 - k)) land 1) in
  let body = [ 0 ] @ msb 0x123 11 @ [ 0; 0; 0 ] @ msb 2 4 @ msb 0xA5 8 @ msb 0x00 8 in
  let crc = can_crc15 body in
  let prot = body @ msb crc 15 in
  let line = stuff ~n:5 ~ones:false ~last:false prot @ [ 1; 1; 1 ] @ List.init 10 (fun _ -> 1) in
  let nstuffed = List.length line - 13 in
  let t0 = 100 and per = 48.5 in
  let other n =
    if n < t0 then 1 else (match List.nth_opt line (int_of_float (float (n - t0) /. per)) with Some b -> b | None -> 1)
  in
  let chip = unit_chip ~pins:[ 12 ] () in
  chip.value <- chip.value lor (1 lsl 12);
  let ext n = 1 lsl 20, (other n land ((Model.uo_out chip lsr 4) land 1)) lsl 20 in
  hw chip 1 (ctl ~lsb:false ~stuff:5 ());
  hw chip 2 (48 * 16); hw chip 3 (pins_reg ~tx:12 ~rx:20 ());
  hw chip 4 (0x4599 lsl 1); hw chip 5 15; hw chip 6 0;
  hw chip 10 64; hw chip 11 16; hw chip 13 (4 lor (10 lsl 8)); hw chip 15 (4 lor (2 lsl 8));
  hw chip 16 (List.length prot);
  (* rule 0: at bit 50, if the CRC register is 0, two bit boundaries later, one dominant bit *)
  hw chip 32 (1 lor (1 lsl 2) lor (1 lsl 4) lor (2 lsl 10)); hw chip 34 (List.length prot);
  hw chip 35 0; hw chip 36 1;
  hw chip 0 2;
  let tr = sim ~ext chip ~cycles:(t0 + 75 * 49) in
  let low = List.filter (fun c -> (tr.(c) lsr 12) land 1 = 0) (List.init (Array.length tr) Fun.id) in
  let slot = float t0 +. (float (nstuffed + 1) *. per) in
  Printf.printf "protected bits %d, on the line %d; CRC %04X\n" (List.length prot) nstuffed crc;
  Printf.printf "received %d bits: %s\n" (hr chip 18) (words chip 64 5);
  Printf.printf "expected first 50:  %s\n"
    (String.concat " " (Array.to_list (Array.map (Printf.sprintf "%04X") (pack ~lsb:false prot))));
  Printf.printf "our pin is dominant for %d cycles, starting %.1f cycles into the acknowledge slot of the other node\n"
    (List.length low) (float (List.hd low) -. slot);
  Printf.printf "status %04X (frame received, CRC good, rule 0 fired)\n" (hr chip 0);
  [%expect {|
    protected bits 50, on the line 52; CRC 2DA2
    received 62 bits: 1230 54A0 0B68 AFFC 0000
    expected first 50:  1230 54A0 0B68 8000
    our pin is dominant for 48 cycles, starting 1.5 cycles into the acknowledge slot of the other node
    status 1038 (frame received, CRC good, rule 0 fired)
    |}]
;;

let%expect_test "UART receive: start edge, ten bits, re-armed for the next frame" =
  let frame b = [ 0 ] @ List.init 8 (fun k -> (b lsr k) land 1) @ [ 1 ] in
  let line = frame 0x55 @ [ 1; 1; 1 ] @ frame 0xA7 in
  let per = 48e6 /. 115200. in
  let ext n = 1 lsl 20, (if n < 50 then 1 else match List.nth_opt line (int_of_float (float (n - 50) /. per)) with Some b -> b | None -> 1) lsl 20 in
  let chip = unit_chip () in
  hw chip 1 (ctl ~rearm:true ());
  hw chip 2 6667; hw chip 3 (pins_reg ~rx:20 ());
  hw chip 10 64; hw chip 11 1; hw chip 13 8; hw chip 14 10;
  hw chip 0 2;
  ignore (sim ~ext chip ~cycles:(50 + 4600));
  Printf.printf "after the first frame:  word %04X, %d bits, status %04X\n" chip.data.(64) (hr chip 18) (hr chip 0);
  ignore (sim ~ext chip ~cycles:6000);
  Printf.printf "after the second frame: word %04X, %d bits, status %04X\n" chip.data.(64) (hr chip 18) (hr chip 0);
  Printf.printf "expected words %04X %04X\n" ((0x55 lsl 1) lor 0x200) ((0xA7 lsl 1) lor 0x200);
  [%expect {|
    after the first frame:  word 02AA, 10 bits, status 0032
    after the second frame: word 034E, 10 bits, status 0032
    expected words 02AA 034E
    |}]
;;

let%expect_test "Manchester: half-bit waveform at 2 cycles per half, loop back at 8 cycles per half" =
  let bytes = [ 0x55; 0x55; 0x55; 0xD5; 0x12; 0x34; 0xAB; 0xCD ] in
  let run per =
    let chip = unit_chip ~pins:[ 12 ] () in
    Array.iteri (fun k w -> chip.data.(k) <- w) (pack ~lsb:true (bits_lsb bytes));
    hw chip 1 (ctl ~code:2 ~idle:0 ());
    hw chip 2 per; hw chip 3 (pins_reg ~tx:12 ~rx:20 ()); hw chip 8 64;
    hw chip 10 64; hw chip 11 8; hw chip 12 (0xAB lor (8 lsl 8)); hw chip 13 (4 lor (1 lsl 8)); hw chip 15 (2 lsl 8);
    hw chip 0 3;
    chip, sim chip ~cycles:(80 * per / 16)
  in
  let _, tr = run 64 in
  Printf.printf "first 8 bits (1 0 1 0 1 0 1 0), one character per cycle from cycle 3: %s\n"
    (String.concat "" (List.init 32 (fun k -> string_of_int ((tr.(3 + k) lsr 20) land 1))));
  let chip, _ = run 256 in
  Printf.printf "loop back: %d bits after the start delimiter: %s; status %04X\n" (hr chip 18) (words chip 64 2) (hr chip 0);
  [%expect {|
    first 8 bits (1 0 1 0 1 0 1 0), one character per cycle from cycle 3: 00111100001111000011110000111100
    loop back: 32 bits after the start delimiter: 3412 CDAB; status 0038
    |}]
;;

(* An I2C-style address byte clocked by a pin (SCL on P19), data on the open-drain pin P0.
   The response rule compares the eight bits and pulls the data line low for the ninth clock. *)
let%expect_test "pin-clocked receive: address match answered inside the next clock period" =
  List.iter
    (fun addr ->
      let chip = unit_chip ~pins:[ 0 ] () in
      Model.reg_write chip 0x14 1;
      hw chip 1 (ctl ~lsb:false ~ext:true ());
      hw chip 3 (pins_reg ~tx:0 ~rx:0 ~clk:19 ());
      hw chip 10 64; hw chip 11 4;
      hw chip 32 (1 lor 2 lor (1 lsl 2) lor (8 lsl 6) lor (1 lsl 10)); hw chip 33 (0xA0 lor (0xFF lsl 8));
      hw chip 34 8; hw chip 35 0; hw chip 36 1;
      hw chip 0 2;
      (* SCL: low 60, high 60 cycles from cycle 40; bit k is put on the line 30 cycles before its rising edge *)
      let byte = (addr lsl 1) land 0xFF in
      let scl n = if n < 40 then 0 else if (n - 40) mod 120 >= 60 then 1 else 0 in
      let ctrl_sda n =
        let k = (n - 10) / 120 in
        if n < 10 || k >= 8 then 1 else (byte lsr (7 - k)) land 1
      in
      let chip_sda () = if Model.uio_oe chip land 1 = 1 then Model.uio_out chip land 1 else 1 in
      let ext n = (1 lsl 19) lor 1, (scl n lsl 19) lor (ctrl_sda n land chip_sda ()) in
      let tr = sim ~ext chip ~cycles:1300 in
      let fall k = 40 + (120 * k) + 120 in
      let driven = List.filter (fun c -> c > fall 7 - 20 && tr.(c) land 1 = 0) (List.init 1300 Fun.id) in
      Printf.printf "address %02X: data line during the ninth clock high: %d; " addr (tr.(40 + (120 * 8) + 90) land 1);
      (match driven with
       | [] -> Printf.printf "not driven"
       | c :: _ ->
         Printf.printf "low from %d cycles after the eighth falling clock edge to %d cycles after the ninth"
           (c - fall 7) (List.fold_left max 0 driven + 1 - fall 8));
      Printf.printf "; rule fired %b\n" ((hr chip 0 lsr 12) land 1 = 1))
    [ 0x50; 0x51 ];
  [%expect {|
    address 50: data line during the ninth clock high: 0; low from 3 cycles after the eighth falling clock edge to 3 cycles after the ninth; rule fired true
    address 51: data line during the ninth clock high: 1; not driven; rule fired false
    |}]
;;

let%expect_test "an edge of the unit that a hold rule forbids does not reach the pad; the unit stops" =
  let chip = unit_chip ~pins:[ 12 ] () in
  chip.data.(0) <- 0x0005;
  hw chip 1 (ctl ~idle:0 ()); hw chip 2 64; hw chip 3 (pins_reg ~tx:12 ()); hw chip 8 16;
  Model.set_rule chip 0 ~policy:1 ~min:100 ~start:(Model.sel 2 12) ~stop:(Model.sel 3 12) ();
  hw chip 0 1;
  let tr = sim chip ~cycles:60 in
  let edges = List.filter (fun c -> c > 0 && (tr.(c) lxor tr.(c - 1)) land (1 lsl 20) <> 0) (List.init 60 Fun.id) in
  Printf.printf "pad changes at %s; status %04X (stopped by a rule); first fail %s\n"
    (String.concat " " (List.map string_of_int edges)) (hr chip 0) (Test_rules.verdict chip.first_fail);
  [%expect {| pad changes at 3; status 0200 (stopped by a rule); first fail rule 0 min at cycle 6 |}]
;;

(* The unit driven by a program: configure, store a word, start, wait for "frame sent". *)
let%expect_test "from a program: start latency per thread, and no access for a thread that is not the owner" =
  let src =
    Printf.sprintf
      {|
        IOWI 0x41, %d
        IOWI 0x42, 64
        IOWI 0x43, 12
        IOWI 0x48, 16
        ALUI mov, r0, 0xF5
        ST r0, 0
        IOWI 0x40, 1
        WAITS 1, 10, 0, 0, 0, 0
        IOR r1, 0x40
        HALT
  |}
      (ctl ~idle:0 ())
  in
  List.iter
    (fun (tid, owner) ->
      let chip = Model.create () in
      let words = Asm.assemble src in
      Model.set_window chip tid ~pbase:(16 * tid) ~psize:(Array.length words) ~dbase:(256 * tid) ~dsize:256;
      assert (Model.load_thread chip tid words);
      Model.set_owner chip 12 tid;
      hw chip 22 owner;
      Model.start chip tid ~pc:0;
      let tr = sim chip ~cycles:200 in
      let first = List.find_opt (fun c -> (tr.(c) lsr 20) land 1 = 1) (List.init 200 Fun.id) in
      (* the start command is the 7th instruction: fetched in cycle tid + 24, executed 3 cycles later *)
      let x = tid + 24 + 3 in
      Printf.printf "thread %d, owner %d: %s; first bit on the pad %s; r1 = %04X\n" tid owner
        (Test_core.state_name chip.th.(tid))
        (match first with Some c -> Printf.sprintf "%d cycles after the start instruction executes" (c - x) | None -> "never")
        chip.th.(tid).r.(1))
    [ 0, 0; 1, 1; 2, 2; 1, 0 ];
  [%expect {|
    thread 0, owner 0: halted; first bit on the pad 4 cycles after the start instruction executes; r1 = 0008
    thread 1, owner 1: halted; first bit on the pad 7 cycles after the start instruction executes; r1 = 0008
    thread 2, owner 2: halted; first bit on the pad 6 cycles after the start instruction executes; r1 = 0008
    thread 1, owner 0: fault IOPERM; first bit on the pad never; r1 = 0000
    |}]
;;

(* Three users of the system slot at once: the unit stores received words, the trace records
   pin changes, and nothing is lost by the unit. *)
let%expect_test "system slot: the line unit comes before the trace" =
  let chip = unit_chip ~pins:[ 12 ] () in
  (* the first bit is a 1: with idle level 0 and no start pattern a frame begins at its first 1 *)
  for k = 0 to 15 do chip.data.(k) <- 0x5A5B + (2 * k) done;
  hw chip 1 (ctl ~idle:0 ()); hw chip 2 16; hw chip 3 (pins_reg ~tx:12 ~rx:20 ()); hw chip 8 256;
  hw chip 10 64; hw chip 11 32; hw chip 13 8; hw chip 14 240;
  Model.reg_write chip 0x31 512; Model.reg_write chip 0x32 64; Model.reg_write chip 0x33 0x1000; Model.reg_write chip 0x30 1;
  hw chip 0 3;
  ignore (sim chip ~cycles:400);
  let same = List.for_all (fun k -> chip.data.(64 + k) = chip.data.(k)) (List.init 15 Fun.id) in
  Printf.printf "received %d bits at one bit per cycle; 15 words equal to the transmitted ones: %b; status %04X; trace records %d\n"
    (hr chip 18) same (hr chip 0) (List.length (Model.trace_records chip));
  [%expect {| received 240 bits at one bit per cycle; 15 words equal to the transmitted ones: true; status 0038; trace records 10 |}]
;;

(* A USB full-speed peer on the pair P0 / P1: D+ levels [line], then two bit times with both
   lines low and one bit time of idle, with bit period [per] cycles and each bit boundary
   moved by up to [jit] cycles. After the packet the peer releases the lines. *)
let usb_peer ~t0 ~per ~jit line =
  let n = List.length line in
  let edge = Array.init (n + 4) (fun k -> float t0 +. (float k *. per) +. if k = 0 then 0. else Random.float (2. *. jit) -. jit) in
  let arr = Array.of_list line in
  fun c ->
    let f = float c in
    if f < edge.(0)
    then 3, 1
    else if f >= edge.(n + 3)
    then 0, 0
    else (
      let k = ref 0 in
      while f >= edge.(!k + 1) do incr k done;
      3, if !k < n then arr.(!k) lor ((1 - arr.(!k)) lsl 1) else if !k < n + 2 then 0 else 1)
;;

let usb_line ?(crc_of = fun p -> usb_crc16 p) ?(stuffed = true) payload =
  let bits = bits_lsb ([ 0x80; 0xC3 ] @ payload @ crc_of payload) in
  nrzi ~start:1 (if stuffed then stuff ~n:6 ~ones:true ~last:true bits else bits)
;;

let usb_rx ~per ~jit line =
  let chip = unit_chip () in
  usb_cfg chip;
  hw chip 0 2;
  ignore (sim ~pull:0xFD ~ext:(usb_peer ~t0:40 ~per ~jit line) chip ~cycles:(40 + int_of_float (float (List.length line + 8) *. per)));
  chip
;;

let%expect_test "USB-style receive from a peer with a clock offset and edge jitter" =
  Random.init 5;
  let payloads = List.init 40 (fun _ -> List.init (1 + Random.int 12) (fun _ -> if Random.int 4 = 0 then 0xFF else Random.int 256)) in
  List.iter
    (fun jit ->
      List.iter
        (fun per ->
          let good =
            List.filter
              (fun payload ->
                let chip = usb_rx ~per ~jit (usb_line payload) in
                let expect = pack ~lsb:true (bits_lsb ([ 0xC3 ] @ payload @ usb_crc16 payload)) in
                hr chip 0 land 0xFF0 = 0x030
                && hr chip 18 = 8 * (3 + List.length payload)
                && List.for_all (fun k -> chip.data.(64 + k) = expect.(k)) (List.init (Array.length expect) Fun.id))
              payloads
          in
          Printf.printf "jitter +-%.2f cycles, bit period %.2f cycles: %2d of 40 packets received with good CRC\n" jit per
            (List.length good))
        [ 3.99; 4.00; 4.01 ])
    [ 0.; 0.25; 0.5; 1.0 ];
  [%expect {|
    jitter +-0.00 cycles, bit period 3.99 cycles: 40 of 40 packets received with good CRC
    jitter +-0.00 cycles, bit period 4.00 cycles: 40 of 40 packets received with good CRC
    jitter +-0.00 cycles, bit period 4.01 cycles: 40 of 40 packets received with good CRC
    jitter +-0.25 cycles, bit period 3.99 cycles: 40 of 40 packets received with good CRC
    jitter +-0.25 cycles, bit period 4.00 cycles: 40 of 40 packets received with good CRC
    jitter +-0.25 cycles, bit period 4.01 cycles: 40 of 40 packets received with good CRC
    jitter +-0.50 cycles, bit period 3.99 cycles: 40 of 40 packets received with good CRC
    jitter +-0.50 cycles, bit period 4.00 cycles: 40 of 40 packets received with good CRC
    jitter +-0.50 cycles, bit period 4.01 cycles: 40 of 40 packets received with good CRC
    jitter +-1.00 cycles, bit period 3.99 cycles: 12 of 40 packets received with good CRC
    jitter +-1.00 cycles, bit period 4.00 cycles: 40 of 40 packets received with good CRC
    jitter +-1.00 cycles, bit period 4.01 cycles: 11 of 40 packets received with good CRC
    |}]
;;

let%expect_test "USB-style receive: a wrong CRC and a missing stuff bit are flagged" =
  let payload = [ 0x12; 0xFF; 0xFF; 0x34 ] in
  let show name line =
    let chip = usb_rx ~per:4.0 ~jit:0. line in
    let st = hr chip 0 in
    Printf.printf "%-22s frame received %d, CRC good %d, stuffing violated %d\n" name ((st lsr 4) land 1) ((st lsr 5) land 1)
      ((st lsr 6) land 1)
  in
  show "correct packet" (usb_line payload);
  show "one CRC bit wrong" (usb_line ~crc_of:(fun p -> match usb_crc16 p with a :: r -> (a lxor 4) :: r | [] -> []) payload);
  show "sent without stuffing" (usb_line ~stuffed:false payload);
  [%expect {|
    correct packet         frame received 1, CRC good 1, stuffing violated 0
    one CRC bit wrong      frame received 1, CRC good 0, stuffing violated 0
    sent without stuffing  frame received 1, CRC good 0, stuffing violated 1
    |}]
;;

(* The handshake: a response rule at the end of a frame with a good CRC sends SYNC and the
   ACK PID, then the end-of-packet pattern, with no instruction executed in between. *)
let%expect_test "USB-style handshake by a response rule" =
  let payload = [ 0x00; 0x01; 0x02; 0x03 ] in
  let run line =
    let chip = unit_chip ~pins:[ 0; 1 ] () in
    usb_cfg chip;
    hw chip 32 (1 lor (1 lsl 4) lor (1 lsl 5) lor (5 lsl 10)); hw chip 35 0xD280; hw chip 36 (16 lor 32);
    hw chip 0 2;
    let n = List.length line in
    let tr = sim ~pull:0xFD ~ext:(usb_peer ~t0:40 ~per:4.0 ~jit:0. line) chip ~cycles:(40 + (4 * (n + 40))) in
    let se0_end = 40 + (4 * (n + 2)) in
    let k = List.find_opt (fun c -> c > se0_end && tr.(c) land 1 = 0) (List.init (Array.length tr) Fun.id) in
    chip, tr, se0_end, k
  in
  let chip, tr, se0_end, k = run (usb_line payload) in
  (match k with
   | None -> print_endline "no reply"
   | Some c0 ->
     let dp = bit_levels tr ~pin:0 ~c0 ~per:64 ~n:19 and dm = bit_levels tr ~pin:1 ~c0 ~per:64 ~n:19 in
     let reference = nrzi ~start:1 (bits_lsb [ 0x80; 0xD2 ]) in
     Printf.printf "reply starts %.2f bit times after the peer's lines return to idle (allowed 2 to 6.5)\n"
       (float (c0 - se0_end) /. 4.);
     Printf.printf "D+ %s\nD- %s\nreference for the first 16: %s; equal %b\n" (show_bits dp) (show_bits dm) (show_bits reference)
       (List.filteri (fun i _ -> i < 16) dp = reference);
     Printf.printf "status %04X; drivers after the reply: %02X\n" (hr chip 0) (Model.uio_oe chip));
  let chip, _, _, k = run (usb_line ~crc_of:(fun _ -> [ 0; 0 ]) payload) in
  Printf.printf "wrong CRC: reply %s, status %04X\n" (if k = None then "none" else "sent") (hr chip 0);
  [%expect {|
    reply starts 3.50 bit times after the peer's lines return to idle (allowed 2 to 6.5)
    D+ 0101010011011000001
    D- 1010101100100111000
    reference for the first 16: 0101010011011000; equal true
    status 1038; drivers after the reply: 00
    wrong CRC: reply none, status 0010
    |}]
;;

(* A Manchester transmitter on P20 with its own clock: [per] cycles per bit, started [phase]
   cycles after cycle 40, each half-bit boundary moved by up to [jit] cycles. *)
let%expect_test "Manchester receive from a peer: what clock offset and jitter are tolerated" =
  Random.init 9;
  let frames = List.init 30 (fun _ -> List.init 6 (fun _ -> Random.int 256)) in
  let try_one ~per ~jit ~phase bytes =
    let halves = List.concat_map (fun b -> [ 1 - b; b ]) (bits_lsb ([ 0x55; 0x55; 0x55; 0xD5 ] @ bytes)) in
    let arr = Array.of_list halves in
    let n = Array.length arr in
    let edge = Array.init (n + 1) (fun k -> 40. +. phase +. (float k *. per /. 2.) +. Random.float (2. *. jit +. 1e-9) -. jit) in
    let ext c =
      let f = float c in
      let k = ref (-1) in
      while !k < n && f >= edge.(!k + 1) do incr k done;
      1 lsl 20, (if !k < 0 || !k >= n then 0 else arr.(!k)) lsl 20
    in
    let chip = unit_chip () in
    let p16 = int_of_float (Float.round (16. *. Float.round per)) in
    hw chip 1 (ctl ~code:2 ~idle:0 ());
    hw chip 2 p16; hw chip 3 (pins_reg ~rx:20 ());
    hw chip 10 64; hw chip 11 8; hw chip 12 (0xAB lor (8 lsl 8)); hw chip 13 (4 lor (1 lsl 8)); hw chip 15 (2 lsl 8);
    hw chip 0 2;
    ignore (sim ~ext chip ~cycles:(80 + int_of_float (float (n / 2 + 6) *. per)));
    let expect = pack ~lsb:true (bits_lsb bytes) in
    hr chip 18 = 48 && List.for_all (fun k -> chip.data.(64 + k) = expect.(k)) [ 0; 1; 2 ]
  in
  List.iter
    (fun (nominal, offs, jits) ->
      List.iter
        (fun jit ->
          List.iter
            (fun off ->
              let per = float nominal *. (1. +. off) in
              let good = List.filter (fun bytes -> try_one ~per ~jit ~phase:(Random.float 1.) bytes) frames in
              Printf.printf "%d cycles per bit, peer clock %+.2f %%, jitter +-%.2f cycles: %2d of 30 frames received\n" nominal
                (100. *. off) jit (List.length good))
            offs)
        jits)
    [ 8, [ -0.01; 0.; 0.01 ], [ 0.; 0.5; 1.0 ]; 4, [ -0.0001; 0.; 0.0001 ], [ 0.; 0.25 ] ];
  [%expect {|
    8 cycles per bit, peer clock -1.00 %, jitter +-0.00 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock +0.00 %, jitter +-0.00 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock +1.00 %, jitter +-0.00 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock -1.00 %, jitter +-0.50 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock +0.00 %, jitter +-0.50 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock +1.00 %, jitter +-0.50 cycles: 30 of 30 frames received
    8 cycles per bit, peer clock -1.00 %, jitter +-1.00 cycles:  1 of 30 frames received
    8 cycles per bit, peer clock +0.00 %, jitter +-1.00 cycles:  3 of 30 frames received
    8 cycles per bit, peer clock +1.00 %, jitter +-1.00 cycles:  1 of 30 frames received
    4 cycles per bit, peer clock -0.01 %, jitter +-0.00 cycles: 30 of 30 frames received
    4 cycles per bit, peer clock +0.00 %, jitter +-0.00 cycles: 30 of 30 frames received
    4 cycles per bit, peer clock +0.01 %, jitter +-0.00 cycles: 30 of 30 frames received
    4 cycles per bit, peer clock -0.01 %, jitter +-0.25 cycles: 15 of 30 frames received
    4 cycles per bit, peer clock +0.00 %, jitter +-0.25 cycles: 12 of 30 frames received
    4 cycles per bit, peer clock +0.01 %, jitter +-0.25 cycles: 16 of 30 frames received
    |}]
;;

let%expect_test "line unit symbols as rule events: frame duration measured by a rule" =
  let frame b = [ 0 ] @ List.init 8 (fun k -> (b lsr k) land 1) @ [ 1 ] in
  let line = frame 0x55 @ [ 1; 1; 1 ] @ frame 0xA7 in
  let per = 48e6 /. 115200. in
  let ext n = 1 lsl 20, (if n < 50 then 1 else match List.nth_opt line (int_of_float (float (n - 50) /. per)) with Some b -> b | None -> 1) lsl 20 in
  let chip = unit_chip () in
  hw chip 1 (ctl ~rearm:true ());
  hw chip 2 6667; hw chip 3 (pins_reg ~rx:20 ());
  hw chip 10 64; hw chip 11 1; hw chip 13 8; hw chip 14 10;
  Model.set_rule chip 0 ~guarantee:false ~ps:1 ~start:(Model.sel 6 1) ~stop:(Model.sel 6 2) ~max:250 ();
  Model.set_rule chip 1 ~guarantee:false ~start:(Model.sel 6 0) ~stop:(Model.sel 6 0) ();
  hw chip 0 2;
  ignore (sim ~ext chip ~cycles:11000);
  let r0 = chip.rules.(0) and r1 = chip.rules.(1) in
  Printf.printf "frame start to frame end: %d to %d units of 16 cycles (9.5 bit times are %.1f)\n" r0.obs_min r0.obs_max
    (9.5 *. per /. 16.);
  Printf.printf "bit strobe to bit strobe: %d to %d cycles (one bit time is %.2f, the gap between the frames 4 bit times); first blame %s\n"
    r1.obs_min r1.obs_max per
    (Test_rules.verdict chip.first_blame);
  [%expect {|
    frame start to frame end: 247 to 248 units of 16 cycles (9.5 bit times are 247.4)
    bit strobe to bit strobe: 416 to 1667 cycles (one bit time is 416.67, the gap between the frames 4 bit times); first blame none
    |}]
;;

let%expect_test "a response rule with delay 0: from the sampled bit to the pad" =
  let chip = unit_chip ~pins:[ 12 ] () in
  let ext n = 1 lsl 21, (if n >= 30 && n < 30 + 64 then 0 else 1) lsl 21 in
  hw chip 1 (ctl ()); hw chip 2 256; hw chip 3 (pins_reg ~tx:12 ~rx:21 ());
  hw chip 10 64; hw chip 11 1; hw chip 13 8; hw chip 14 8;
  hw chip 32 (1 lor 2 lor (2 lsl 2)); hw chip 34 1; hw chip 35 0; hw chip 36 1;
  Model.set_rule chip 0 ~guarantee:false ~start:(Model.sel 6 9) ~stop:(Model.sel 3 12) ();
  Model.set_rule chip 1 ~guarantee:false ~start:(Model.sel 6 1) ~stop:(Model.sel 6 0) ();
  chip.value <- chip.value lor (1 lsl 12);
  hw chip 0 2;
  let tr = sim ~ext chip ~cycles:200 in
  let fall = List.find (fun c -> (tr.(c) lsr 20) land 1 = 0) (List.init 200 Fun.id) in
  Printf.printf "line falls on the pad in cycle 30; frame start to first bit strobe %d cycles (half a bit is 8)\n"
    chip.rules.(1).obs_min;
  Printf.printf "rule fires to commit event %d cycle(s); reply on the pad in cycle %d\n" chip.rules.(0).obs_min fall;
  [%expect {|
    line falls on the pad in cycle 30; frame start to first bit strobe 7 cycles (half a bit is 8)
    rule fires to commit event 1 cycle(s); reply on the pad in cycle 40
    |}]
;;
