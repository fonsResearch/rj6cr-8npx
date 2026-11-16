(* Random stimulus for the lockstep: SPI sessions with legal timing, random legal programs,
   random activity on the input pins. *)
open Spec

(* --- SPI transactions as byte lists --- *)
let w16 v = [ (v lsr 8) land 0xFF; v land 0xFF ]
let w32 v = [ (v lsr 24) land 0xFF; (v lsr 16) land 0xFF; (v lsr 8) land 0xFF; v land 0xFF ]
let reg_write a vs = [ 0x21; a ] @ List.concat_map w16 vs
let reg_read a n = [ 0x11; a ] @ List.init (2 * n) (fun _ -> 0)
let prog_write a ws = [ 0x40 ] @ w16 a @ List.concat_map w32 ws
let prog_read a n = [ 0x30 ] @ w16 a @ List.init (4 * n) (fun _ -> 0)
let data_write a vs = [ 0x60 ] @ w16 a @ List.concat_map w16 vs
let data_read a n = [ 0x50 ] @ w16 a @ List.init (2 * n) (fun _ -> 0)

(* SPI pin levels per cycle for a transaction: (sck, mosi, cs_n) *)
let spi_cycles ~half bytes =
  let out = ref [] in
  let emit ~n sck mosi cs = for _ = 1 to n do out := (sck, mosi, cs) :: !out done in
  emit ~n:half 0 0 0;
  List.iter
    (fun byte ->
      for k = 7 downto 0 do
        let m = (byte lsr k) land 1 in
        emit ~n:half 0 m 0;
        emit ~n:half 1 m 0
      done)
    bytes;
  emit ~n:half 0 0 0;
  emit ~n:(2 * half) 0 0 1;
  List.rev !out
;;

(* --- random legal programs --- *)
let rand_field (f : Isa.field) ~psize ~pins =
  match f.kind with
  | Target -> Random.int psize
  | Pin 16 when pins <> [] && Random.int 16 > 0 -> List.nth pins (Random.int (List.length pins))
  | Pin 8 when Random.int 16 > 0 -> (match List.filter (fun p -> p < 8) pins with [] -> Random.int 8 | l -> List.nth l (Random.int (List.length l)))
  | _ ->
    let m = f.max in
    (* small values are more interesting for immediates, addresses and amounts *)
    if m > 64 && Random.int 3 > 0 then Random.int 64 else Random.int (m + 1)
;;

let weights =
  let open Isa in
  [ Nop, 2; Alu, 6; Alui, 6; Shi, 2; Shv, 1; Crc, 2; Ld, 3; Ldx, 2; St, 3; Stx, 2; Jmp, 2; Jal, 1; Jr, 1; Br, 3
  ; Bri, 3; Djnz, 3; Bbit, 2; Bpin, 2; Bst, 2; Halt, 1; Trap, 1; Pinv, 6; Pdir, 3; Pinr, 2; Pinm, 2; Pdrm, 1
  ; Pini, 2; Pdri, 1; Outs, 3; Outsc, 2; Ins, 2; Insc, 1; Pinrd, 2; Tnow, 4; Taddi, 4; Taddr, 1; Tperi, 2
  ; Tperr, 1; Tget, 2; Tset, 1; Waitp, 3; Waits, 2; Pull, 2; Push, 2; Emit, 2; Ior, 2; Iow, 1; Iowi, 2 ]
;;

let total = List.fold_left (fun a (_, w) -> a + w) 0 weights

let rand_op () =
  let r = ref (Random.int total) in
  fst (List.find (fun (_, w) -> if !r < w then true else (r := !r - w; false)) weights)
;;

let rand_instr ~psize ~pins =
  let op = rand_op () in
  let def = List.find (fun (d : Isa.def) -> d.op = op) Isa.defs in
  let args = Array.of_list (List.map (rand_field ~psize ~pins) def.fields) in
  let tm = if def.timed && Random.int 3 = 0 then 1 + Random.int 3 else 0 in
  let i = { Isa.def; args; tm } in
  (* keep TNOW / TADDI deadlines short so that programs move *)
  let own_mask = List.fold_left (fun m p -> m lor (1 lsl p)) 0 pins in
  (match op with
   | Tnow | Taddi -> i.args.(0) <- Random.int 40
   | Ld | St -> i.args.(1) <- (if Random.int 8 = 0 then Random.int 1024 else Random.int 64)
   | Ldx | Stx -> i.args.(2) <- Random.int 16
   | Pinm when Random.int 8 > 0 -> i.args.(1) <- i.args.(1) land own_mask
   | Pdrm when Random.int 8 > 0 -> i.args.(1) <- i.args.(1) land own_mask land 0xFF
   | Pdri when Random.int 8 > 0 -> i.args.(0) <- i.args.(0) land own_mask land 0xFF
   | Pini when Random.int 8 > 0 -> i.args.(1) <- i.args.(1) land (own_mask lsr (8 * i.args.(0))) land 0xFF
   | Iowi when Random.int 2 = 0 -> i.args.(0) <- 0x40 + Random.int 22
   | Ior | Iow when Random.int 2 = 0 -> i.args.(List.length def.fields - 1) <- 0x40 + Random.int 22
   | _ -> ());
  Isa.encode i
;;

(* now and then a raw word, which is mostly ILLEGAL *)
let rand_program ~psize ~pins =
  Array.init psize (fun _ -> if Random.int 60 = 0 then Random.bits () land 0xFFFF_FFFF else rand_instr ~psize ~pins)
;;

(* --- sessions --- *)
type action =
  | Spi of int list
  | Idle of int

let treg t j = 0x40 + (16 * t) + j

type opts =
  { rules : bool
  ; trace : bool
  ; line : bool
  ; fuzz : bool (* random register writes during the run *)
  ; frames : bool (* line unit set up for frames on a looped-back pin *)
  ; directed : bool (* thread 0 pulses P9 under a hold rule; thread 1 owns the line unit, which sends
                       USB-style packets on P0 / P1 and receives them back *)
  ; run : int (* actions in the run phase *)
  }

let session o =
  let acts = ref [] in
  let add a = acts := a :: !acts in
  let spi b = add (Spi b) in
  (* pins: owners, open drain, safe pattern, filters *)
  let owner = Array.init 16 (fun p -> if p = 8 then 7 else match Random.int 5 with 3 | 4 -> 7 | k -> k mod 3) in
  (* every thread owns at least two pins *)
  List.iteri (fun t (a, b) -> owner.(a) <- t; owner.(b) <- t) [ 0, 9; 1, 10; 2, 11 ];
  let nib k = List.fold_left (fun acc j -> acc lor (owner.((4 * k) + j) lsl (4 * j))) 0 [ 0; 1; 2; 3 ] in
  spi (reg_write 0x10 [ nib 0; nib 1; nib 2; nib 3; Random.int 256; Random.int 65536; Random.int 256 ]);
  spi (reg_write 0x18 [ Random.int 65536; Random.int 65536 ]);
  let pins t = List.filter (fun p -> owner.(p) = t) (List.init 16 Fun.id) in
  (* with frames, the line unit's owner runs a program that does not fault: the unit stops
     when its owner faults *)
  let line_owner = if o.directed then 1 else Random.int 3 in
  if o.directed then (owner.(0) <- 1; owner.(1) <- 1; owner.(9) <- 0; spi (reg_write 0x10 [ nib 0; nib 1; nib 2; nib 3 ]));
  let progs =
    List.init 3 (fun t ->
      let psize = if o.directed && t = 0 then 15 else 8 + Random.int 40 in
      let pbase = 160 * t in
      let pulse () =
        let b = Buffer.create 256 in
        Buffer.add_string b "TNOW 10\n";
        for k = 1 to 6 do Buffer.add_string b (Printf.sprintf "PINV %d, 9 @at\nTADDI %d\n" (k land 1) (4 + Random.int 40)) done;
        Buffer.add_string b "PINV 0, 9 @at\nJMP 0\n";
        Asm.assemble (Buffer.contents b)
      in
      let words =
        if o.directed && t = 0
        then pulse ()
        else if (o.frames || o.directed) && t = line_owner
        then Array.init psize (fun k -> if k = psize - 1 then Asm.assemble "JMP 0" |> fun a -> a.(0) else Isa.encode { def = List.find (fun (d : Isa.def) -> d.op = Isa.Alui) Isa.defs; args = [| 0; k mod 8; Random.int 65536 |]; tm = 0 })
        else rand_program ~psize ~pins:(pins t)
      in
      spi (reg_write (treg t 3) [ pbase; psize; 256 * t; 64 + Random.int 192; (if Random.int 4 = 0 then 1 else 0) ]);
      spi (reg_write (treg t 0) [ 3 ]);
      spi (prog_write pbase (Array.to_list words));
      spi (reg_write (treg t 13) [ Model.digest_of words ]);
      spi (reg_write (treg t 2) [ Random.int psize ]);
      pbase, psize, words)
  in
  if o.rules
  then
    for k = 0 to 3 do
      let pin () = match pins (Random.int 3) with [] -> Random.int 16 | l -> List.nth l (Random.int (List.length l)) in
      let sel () =
        match Random.int 6 with
        | 0 -> (2 lsl 7) lor pin ()
        | 1 -> (3 lsl 7) lor pin ()
        | 2 -> (Random.int 2 lsl 7) lor (Random.int 3 lsl 5) lor Random.int 24
        | 3 -> (5 lsl 7) lor Random.int 8
        | 4 -> (6 lsl 7) lor Random.int 11
        | _ -> Random.int 1024
      in
      let ctl = 1 lor (Random.int 2 lsl 1) lor (Random.int 4 lsl 2) lor (Random.int 4 lsl 4) lor (Random.int 3 lsl 6) in
      spi (reg_write (0x80 + (16 * k)) [ sel (); sel (); (if Random.bool () then 0x380 else sel ()); Random.int 30; 20 + Random.int 200; ctl ])
    done;
  if o.directed
  then begin
    (* rule 0: P9 high for at least m cycles, held to the minimum *)
    spi (reg_write 0x80 [ (2 lsl 7) lor 9; (3 lsl 7) lor 9; 0x380; 10 + Random.int 30; 0xFFFF; 1 lor 2 lor (1 lsl 2) lor (3 lsl 4) ]);
    (* the line unit as in test_line.ml, "USB-style packet" *)
    spi (reg_write 0xC1 [ 2 lor (1 lsl 2) lor (1 lsl 5) lor (1 lsl 6) lor (1 lsl 7) lor (6 lsl 8) lor (1 lsl 11) lor (1 lsl 12) lor (1 lsl 15); 64; 0 ]);
    spi (reg_write 0xC4 [ 0x8005; 16 lor 32 lor 64; 0x800D ]);
    spi (reg_write 0xC9 [ 3 lor (0b010000 lsl 8); 64; 32; 0x01 lor (8 lsl 8); 1 ]);
    spi (reg_write 0xCF [ 0xFF; 0; 16 lor (8 lsl 8) ]);
    spi (reg_write 0xD6 [ line_owner ])
  end;
  if o.trace
  then spi (reg_write 0x31 [ 768; 1 + Random.int 40; Random.int 65536; Random.int 256 ]);
  if o.trace then spi (reg_write 0x36 [ Random.int 6 ]);
  if o.trace then spi (reg_write 0x30 [ 1 lor (Random.int 2 lsl 1) ]);
  if o.frames
  then begin
    let t = line_owner in
    (* the transmit pin is looped back: P0..P7 to themselves, P12..P15 to P20..P23 *)
    let cand = List.filter (fun p -> p < 8 || p >= 12) (pins t) in
    let txp = match cand with [] -> owner.(12) <- t; 12 | l -> List.nth l (Random.int (List.length l)) in
    spi (reg_write 0x13 [ nib 3 ]);
    let rx = if txp < 8 then txp else txp + 8 in
    let ext = Random.int 5 = 0 in
    let code = Random.int 3 in
    let stuff = Random.int 2 in
    let ctl =
      1 lor (code lsl 2) lor (Random.int 2 lsl 4) lor ((if code = 2 then 0 else Random.int 2) lsl 5)
      lor (Random.int 2 lsl 6) lor (stuff lsl 7) lor ((3 + Random.int 5) lsl 8) lor (Random.int 2 lsl 11)
      lor (Random.int 2 lsl 12) lor ((if ext then 1 else 0) lsl 13) lor (Random.int 2 lsl 14) lor (Random.int 2 lsl 15)
    in
    let per = 16 * (if code = 2 then 4 + Random.int 12 else 1 + Random.int 12) + Random.int 16 in
    let tlen = 1 + Random.int 120 in
    let sync = Random.int 9 in
    let words = List.init 10 (fun _ -> Random.int 65536) in
    spi (data_write (256 * t) words);
    let regs =
      [ ctl; per; txp lor (rx lsl 4) lor (19 lsl 9); [| 0x8005; 0x1021; 0x4599 lsl 1 |].(Random.int 3)
      ; (Random.int 17) lor (Random.int 2 lsl 5) lor (Random.int 2 lsl 6); Random.int 65536; 0; tlen
      ; Random.int 5 lor (Random.int 256 lsl 8); 32; 16 + Random.int 16
      ; (if sync = 0 then 0 else (Random.int 256) lor (sync lsl 8)); 4 lor (Random.int 2 lsl 3) lor ((2 + Random.int 6) lsl 8)
      ; Random.int 140; (if Random.int 2 = 0 then 255 else Random.int 8) lor (Random.int 4 lsl 8); 0
      ; Random.int 4 lor (Random.int 4 lsl 8) ]
    in
    spi (reg_write 0xC1 regs);
    for k = 0 to 1 do
      spi (reg_write (0xE0 + (8 * k))
             [ 1 lor (Random.int 2 lsl 1) lor (Random.int 3 lsl 2) lor (Random.int 2 lsl 4) lor (Random.int 2 lsl 5)
               lor (Random.int 9 lsl 6) lor (Random.int 4 lsl 10)
             ; Random.int 65536; Random.int 64; Random.int 65536; 1 + Random.int 40 ])
    done;
    spi (reg_write 0xD6 [ t ]);
    spi (reg_write 0xC0 [ 3 ])
  end;
  if o.line
  then begin
    let t = Random.int 3 in
    let txp = match List.filter (fun p -> p <> 8) (pins t) with [] -> Random.int 16 | l -> List.nth l (Random.int (List.length l)) in
    let ctl =
      Random.int 2 lor (Random.int 2 lsl 1) lor (Random.int 3 lsl 2) lor (Random.int 2 lsl 4) lor (Random.int 2 lsl 5)
      lor (Random.int 2 lsl 6) lor (Random.int 2 lsl 7) lor (Random.int 8 lsl 8) lor (Random.int 2 lsl 11)
      lor (Random.int 2 lsl 12) lor ((if Random.int 4 = 0 then 1 else 0) lsl 13) lor (Random.int 2 lsl 14)
      lor (Random.int 2 lsl 15)
    in
    let rx = match Random.int 3 with 0 -> txp | 1 -> 16 + Random.int 8 | _ -> Random.int 8 in
    let regs =
      [ ctl; 16 + Random.int 120; txp lor (rx lsl 4) lor ((16 + Random.int 8) lsl 9); Random.int 65536
      ; Random.int 128; Random.int 65536; Random.int 16; Random.int 80; Random.int 2048; Random.int 32
      ; Random.int 64; Random.int 4096; Random.int 65536; Random.int 200; Random.int 1024; Random.int 100
      ; Random.int 65536 ]
    in
    spi (reg_write 0xC1 regs);
    for k = 0 to 1 do
      spi (reg_write (0xE0 + (8 * k)) [ Random.int 16384; Random.int 65536; Random.int 64; Random.int 65536; Random.int 64 ])
    done;
    spi (reg_write 0xD6 [ t ]);
    spi (reg_write 0xC0 [ Random.int 32 ])
  end;
  List.iteri (fun t _ -> spi (reg_write (treg t 0) [ 1 ])) progs;
  let packet () =
    let payload = List.init (1 + Random.int 10) (fun _ -> Random.int 256) in
    let bytes = [ 0x80; 0xC3 ] @ payload in
    let words = List.init ((List.length bytes + 1) / 2) (fun k ->
      let lo = List.nth bytes (2 * k) and hi = try List.nth bytes ((2 * k) + 1) with _ -> 0 in
      lo lor (hi lsl 8)) in
    spi (data_write (256 * line_owner) words);
    spi (reg_write 0xC8 [ 8 * List.length bytes ]);
    spi (reg_write 0xC0 [ 3 ]);
    add (Idle (600 + (40 * List.length payload)))
  in
  if o.directed then for _ = 1 to 4 do packet () done;
  for _ = 1 to o.run do
    if o.directed && Random.int 3 = 0 then packet ();
    match Random.int (if o.fuzz then 12 else 10) with
    | 0 | 1 -> add (Idle (Random.int 300))
    | 3 -> spi (reg_read (Random.int 256) (1 + Random.int 3))
    | 4 -> spi (reg_write (treg (Random.int 3) 8) [ Random.int 65536 ])
    | 5 -> spi (reg_read (treg (Random.int 3) 9) 1)
    | 6 -> spi (data_write (Random.int 1024) (List.init (1 + Random.int 4) (fun _ -> Random.int 65536)))
    | 7 -> spi (data_read (Random.int 1024) (1 + Random.int 3))
    | 8 -> let t = Random.int 3 in spi (reg_write (treg t 0) [ (if Random.int 4 = 0 then 2 else 1) ])
    | 2 -> List.iter (fun t -> spi (reg_write (treg t 0) [ 1 ])) [ 0; 1; 2 ]
    | 9 ->
      if o.frames then spi (reg_write 0xC0 [ [| 1; 2; 3; 16; 3; 3 |].(Random.int 6) ])
      else if o.line then spi (reg_write 0xC0 [ Random.int 32 ])
      else spi (prog_read (Random.int 512) (1 + Random.int 2))
    | _ -> spi (reg_write (Random.int 256) [ Random.int 65536 ])
  done;
  List.rev !acts
;;

(* run a session; [toggle]: chance in 1/1000 per cycle that an input pin changes *)
let run (t : Lockstep.t) ?(toggle = 30) ?(loopback = false) ?(usb = false) acts =
  let half = 5 + Random.int 4 in
  let pins = ref (Random.int 256 lor (Random.int 32 lsl 19)) in
  let clk = ref 0 and clk_half = 3 + Random.int 20 in
  let tick spi_bits =
    for q = 0 to 23 do
      if (q < 8 || q >= 19) && Random.int 1000 < toggle then pins := !pins lxor (1 lsl q)
    done;
    if usb then pins := !pins land lnot 3 lor 1;
    let p = !pins land lnot (7 lsl 16) lor spi_bits in
    let p =
      if not loopback
      then p
      else (
        (* driven uio pins read back what they drive; P20..P23 follow uo[4..7]; P19 is a clock *)
        let m = t.model in
        incr clk;
        let ck = (!clk / clk_half) land 1 in
        let oe = Model.uio_oe m and out = Model.uio_out m in
        let uio = (p land 0xFF land lnot oe) lor (out land oe) in
        let uo = (Model.uo_out m lsr 4) land 0xF in
        uio lor (p land 0xF80000 land lnot (0xF lsl 20) land lnot (1 lsl 19)) lor (uo lsl 20) lor (ck lsl 19)
        lor (p land (7 lsl 16)))
    in
    Lockstep.step t ~pad:p
  in
  List.iter
    (function
      | Idle n -> for _ = 1 to n do tick (1 lsl 18) done
      | Spi bytes ->
        List.iter (fun (sck, mosi, cs) -> tick ((sck lsl 16) lor (mosi lsl 17) lor (cs lsl 18))) (spi_cycles ~half bytes))
    acts
;;
