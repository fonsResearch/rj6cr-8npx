open Spec
open Isa

let%expect_test "table shape" =
  let timed = List.filter (fun d -> d.timed) defs in
  Printf.printf "%d instructions, %d timed, %d of 64 opcodes unused\n" (List.length defs) (List.length timed)
    (64 - List.length defs);
  [%expect {| 48 instructions, 42 timed, 16 of 64 opcodes unused |}]
;;

(* Every 32-bit word either decodes to exactly one instruction that encodes back to the
   same word, or is ILLEGAL. Checked on random words and on every opcode / timing mode
   with random operands. *)
let%expect_test "decode is total and canonical" =
  Random.init 20261114;
  let legal = ref 0 and total = ref 0 in
  let check w =
    incr total;
    match decode w with
    | None -> ()
    | Some i ->
      incr legal;
      if encode i <> w then Printf.printf "MISMATCH %08X -> %s -> %08X\n" w (Asm.disassemble w) (encode i)
  in
  for _ = 1 to 200_000 do check (Random.bits () lor (Random.bits () lsl 30) land 0xFFFF_FFFF) done;
  let random_legal = !legal in
  for op = 0 to 63 do
    for tm = 0 to 3 do
      for _ = 1 to 500 do check ((op lsl 26) lor (tm lsl 24) lor Random.int 0x1000000) done
    done
  done;
  Printf.printf "%d words checked, no mismatch printed above means canonical\n" !total;
  Printf.printf "legal among 200000 uniformly random words: %.1f %%\n" (100. *. float random_legal /. 200000.);
  [%expect {|
    328000 words checked, no mismatch printed above means canonical
    legal among 200000 uniformly random words: 2.7 %
    |}]
;;

(* Every instruction with random legal operands survives encode -> decode. *)
let%expect_test "encode then decode" =
  Random.init 7;
  let bad = ref 0 in
  List.iter
    (fun def ->
      for _ = 1 to 300 do
        let args = Array.of_list (List.map (fun f -> Random.int (f.max + 1)) def.fields) in
        let tm = if def.timed then Random.int 4 else 0 in
        match decode (encode { def; args; tm }) with
        | Some i when i.def == def && i.args = args && i.tm = tm -> ()
        | _ -> incr bad
      done)
    defs;
  Printf.printf "failures: %d\n" !bad;
  [%expect {| failures: 0 |}]
;;

let%expect_test "assembler and disassembler" =
  let words =
    Asm.assemble
      {|
        ALUI mov, r0, 0x2AA      ; constant
loop:   OUTS 0, 9, r0 @adv
        DJNZ r1, loop
        WAITP rise, 19, 0, 1, 1, 0
        HALT
      |}
  in
  Array.iter (fun w -> Printf.printf "%08X  %s\n" w (Asm.disassemble w)) words;
  [%expect {|
    088002AA  ALUI mov, r0, 682
    9F480000  OUTS 0, 9, r0 @adv
    54200001  DJNZ r1, 1
    DCA6C000  WAITP rise, 19, 0, 1, 1, 0
    64000000  HALT
    |}]
;;

let%expect_test "CRC step against published check values" =
  let run ~refl ~poly ~init =
    let c = ref init in
    String.iter (fun ch -> c := Model.crc_step ~refl ~byte:true !c (Char.code ch) poly) "123456789";
    !c
  in
  Printf.printf "CRC-16/CCITT-FALSE %04X (29B1)\n" (run ~refl:false ~poly:0x1021 ~init:0xFFFF);
  Printf.printf "CRC-16/ARC         %04X (BB3D)\n" (run ~refl:true ~poly:0xA001 ~init:0);
  Printf.printf "CRC-8, left-aligned %04X (F400)\n" (run ~refl:false ~poly:0x0700 ~init:0);
  (* bit-serial form gives the same result as the byte form *)
  let c = ref 0xFFFF in
  String.iter
    (fun ch -> for k = 7 downto 0 do c := Model.crc_step ~refl:false ~byte:false !c ((Char.code ch lsr k) land 1) 0x1021 done)
    "123456789";
  Printf.printf "bit-serial CCITT   %04X\n" !c;
  [%expect {|
    CRC-16/CCITT-FALSE 29B1 (29B1)
    CRC-16/ARC         BB3D (BB3D)
    CRC-8, left-aligned F400 (F400)
    bit-serial CCITT   29B1
    |}]
;;
