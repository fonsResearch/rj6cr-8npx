(* The instruction set, defined once.

   Everything that depends on the encoding is derived from [defs]: the decoder and the
   encoder below, the assembler (asm.ml), the reference model (model.ml) and the tables
   in doc/spec/isa.md (gen_isa_doc.ml).

   Word format:  [31:26] opcode   [25:24] tm   [23:0] operand fields
   A word is legal iff its opcode is defined, tm is 0 unless the instruction is timed,
   every field is within its range, and every operand bit not covered by a field is 0.
   Every other word is ILLEGAL, which is defined behaviour (the thread faults). *)

type kind =
  | Reg (* r0..r7 *)
  | Uint (* unsigned number *)
  | Bit (* single flag *)
  | Pin of int (* pin index below the given count *)
  | Target (* program address inside the thread's window *)
  | Enum of string array

type field =
  { name : string
  ; hi : int
  ; lo : int
  ; max : int
  ; kind : kind
  }

let fld ?max name hi lo kind =
  let w = hi - lo + 1 in
  let max =
    match max, kind with
    | Some m, _ -> m
    | None, Enum names -> Array.length names - 1
    | None, Pin n -> n - 1
    | None, _ -> (1 lsl w) - 1
  in
  { name; hi; lo; max; kind }
;;

let reg name hi = fld name hi (hi - 2) Reg
let bit name pos = fld name pos pos Bit
let uint name hi lo = fld name hi lo Uint
let tgt = fld "tgt" 8 0 Target
let alu_fn = [| "add"; "sub"; "and"; "or"; "xor"; "andn"; "sltu"; "slt"; "mov" |]
let sh_kind = [| "shl"; "shr"; "asr"; "rol"; "ror" |]
let br_cond = [| "eq"; "ne"; "ltu"; "geu"; "lt"; "ge" |]
let tget_sel = [| "now_lo"; "now_hi"; "t_lo"; "t_hi"; "slack"; "p_lo"; "p_hi" |]
let wait_cond = [| "low"; "high"; "rise"; "fall" |]
let src_sel = [| "live"; "cap" |]

type op =
  | Nop | Alu | Alui | Shi | Shv | Crc
  | Ld | Ldx | St | Stx
  | Jmp | Jal | Jr | Br | Bri | Djnz | Bbit | Bpin | Bst | Halt | Trap
  | Pinv | Pdir | Pinr | Pinm | Pdrm | Pini | Pdri | Outs | Outsc | Ins | Insc | Pinrd
  | Tnow | Taddi | Taddr | Tperi | Tperr | Tget | Tset | Waitp | Waits
  | Pull | Push | Emit | Ior | Iow | Iowi

(* When an instruction has to wait for an armed commit (doc/spec/machine.md, section 6). *)
type sync =
  | Plain (* only if tm is not 0 *)
  | Sync (* always *)
  | Sync_if_cap (* if its src field selects the captured pins, or tm is not 0 *)

type def =
  { op : op
  ; mnem : string
  ; code : int
  ; fields : field list
  ; timed : bool (* tm may be non-zero *)
  ; sync : sync
  ; summary : string
  }

let d ?(timed = true) ?(sync = Plain) op mnem code fields summary =
  { op; mnem; code; fields; timed; sync; summary }
;;

let src pos = fld "src" pos pos (Enum src_sel)

let defs : def list =
  [ d Nop "NOP" 0x00 [] "No operation. With a timing mode it is a pure commit or wait."
  ; d Alu "ALU" 0x01
      [ fld "fn" 23 20 (Enum alu_fn); reg "rd" 19; reg "ra" 16; reg "rb" 13 ]
      "rd := fn(ra, rb)."
  ; d Alui "ALUI" 0x02
      [ fld "fn" 23 20 (Enum alu_fn); reg "rd" 19; uint "imm" 15 0 ]
      "rd := fn(rd, imm). With fn = mov it loads a constant."
  ; d Shi "SHI" 0x03
      [ fld "kind" 23 21 (Enum sh_kind); reg "rd" 20; reg "ra" 17; uint "amt" 3 0 ]
      "rd := ra shifted or rotated by amt."
  ; d Shv "SHV" 0x04
      [ fld "kind" 23 21 (Enum sh_kind); reg "rd" 20; reg "ra" 17; reg "rb" 14 ]
      "rd := ra shifted or rotated by rb[3:0]."
  ; d Crc "CRC" 0x06
      [ bit "refl" 23; bit "byte" 22; reg "rd" 21; reg "ra" 18; reg "rb" 15 ]
      "rd := CRC register rd advanced by one bit (ra[0]) or one byte (ra[7:0]) with \
       polynomial rb; refl selects the right-shifting form."
  ; d Ld "LD" 0x08 [ reg "rd" 23; uint "addr" 9 0 ] "rd := data[addr]."
  ; d Ldx "LDX" 0x09 [ reg "rd" 23; reg "ra" 20; uint "off" 9 0 ] "rd := data[ra + off]."
  ; d ~timed:false St "ST" 0x0A [ reg "rs" 23; uint "addr" 9 0 ] "data[addr] := rs."
  ; d ~timed:false Stx "STX" 0x0B
      [ reg "rs" 23; reg "ra" 20; uint "off" 9 0 ]
      "data[ra + off] := rs."
  ; d Jmp "JMP" 0x10 [ tgt ] "pc := tgt."
  ; d Jal "JAL" 0x11 [ reg "rd" 23; tgt ] "rd := pc + 1; pc := tgt."
  ; d Jr "JR" 0x12 [ reg "ra" 23 ] "pc := ra."
  ; d Br "BR" 0x13
      [ fld "cond" 23 21 (Enum br_cond); reg "ra" 20; reg "rb" 17; tgt ]
      "If cond(ra, rb) then pc := tgt."
  ; d Bri "BRI" 0x14
      [ fld "cond" 23 21 (Enum br_cond); reg "ra" 20; uint "imm" 16 9; tgt ]
      "If cond(ra, imm) then pc := tgt; imm is zero-extended."
  ; d Djnz "DJNZ" 0x15 [ reg "rd" 23; tgt ] "rd := rd - 1; if rd is not 0 then pc := tgt."
  ; d Bbit "BBIT" 0x16
      [ bit "sense" 23; reg "ra" 22; uint "bit" 19 16; tgt ]
      "If bit of ra equals sense then pc := tgt."
  ; d ~sync:Sync_if_cap Bpin "BPIN" 0x17
      [ bit "sense" 23; src 22; fld "pin" 21 17 (Pin 24); tgt ]
      "If the pin, live or as captured, equals sense then pc := tgt."
  ; d Bst "BST" 0x18
      [ bit "sense" 23; uint "bit" 22 19; tgt ]
      "If the status bit equals sense then pc := tgt."
  ; d ~timed:false ~sync:Sync Halt "HALT" 0x19 [] "Stop the thread; its pins keep their values."
  ; d ~timed:false Trap "TRAP" 0x1A [ uint "code" 7 0 ] "Fault with a user code."
  ; d ~sync:Sync Pinv "PINV" 0x20 [ bit "v" 23; fld "p" 22 19 (Pin 16) ] "Stage pin p := v."
  ; d ~sync:Sync Pdir "PDIR" 0x21
      [ bit "d" 23; fld "p" 22 20 (Pin 8) ]
      "Stage the output enable of pin p := d."
  ; d ~sync:Sync Pinr "PINR" 0x22
      [ fld "p" 23 20 (Pin 16); reg "ra" 19; uint "bit" 16 13 ]
      "Stage pin p := bit of ra."
  ; d ~sync:Sync Pinm "PINM" 0x23
      [ reg "ra" 23; uint "mask" 15 0 ]
      "Stage pins P0..P15 selected by mask := the same bits of ra."
  ; d ~sync:Sync Pdrm "PDRM" 0x24
      [ reg "ra" 23; uint "mask" 7 0 ]
      "Stage the output enables of P0..P7 selected by mask := the same bits of ra."
  ; d ~sync:Sync Pini "PINI" 0x25
      [ bit "grp" 23; uint "mask" 15 8; uint "val" 7 0 ]
      "Stage pins P0..P7 (grp 0) or P8..P15 (grp 1) selected by mask := val."
  ; d ~sync:Sync Pdri "PDRI" 0x26
      [ uint "mask" 15 8; uint "val" 7 0 ]
      "Stage the output enables of P0..P7 selected by mask := val."
  ; d ~sync:Sync Outs "OUTS" 0x27
      [ bit "dir" 23; fld "p" 22 19 (Pin 16); reg "rd" 18 ]
      "Shift out: stage pin p := rd[0] and shift rd right (dir 0), or rd[15] and shift \
       left (dir 1)."
  ; d ~sync:Sync Outsc "OUTSC" 0x28
      [ bit "dir" 23; fld "p" 22 19 (Pin 16); reg "rd" 18; fld "cp" 15 12 (Pin 16); bit "cv" 11 ]
      "OUTS, and stage a second pin cp := cv (a clock)."
  ; d ~sync:Sync_if_cap Ins "INS" 0x29
      [ bit "dir" 23; src 22; fld "pin" 21 17 (Pin 24); reg "rd" 16 ]
      "Shift in: rd := rd shifted right with the pin entering at bit 15 (dir 0), or \
       shifted left with the pin entering at bit 0 (dir 1)."
  ; d ~sync:Sync Insc "INSC" 0x2A
      [ bit "dir" 23; src 22; fld "pin" 21 17 (Pin 24); reg "rd" 16; fld "cp" 13 10 (Pin 16); bit "cv" 9 ]
      "INS, and stage a second pin cp := cv (a clock)."
  ; d ~sync:Sync_if_cap Pinrd "PINRD" 0x2B
      [ src 23; bit "grp" 22; reg "rd" 21 ]
      "rd := pins P0..P15 (grp 0) or P16..P23 zero-extended (grp 1), live or as captured."
  ; d ~sync:Sync Tnow "TNOW" 0x30 [ uint "imm" 15 0 ] "t := now + imm, fraction 0."
  ; d ~sync:Sync Taddi "TADDI" 0x31 [ uint "imm" 15 0 ] "t := t + imm cycles."
  ; d ~sync:Sync Taddr "TADDR" 0x32 [ reg "ra" 23 ] "t := t + ra cycles."
  ; d ~sync:Sync Tperi "TPERI" 0x33
      [ bit "half" 23; uint "imm" 15 0 ]
      "p[15:0] := imm (half 0) or p[31:16] := imm (half 1); p is cycles with 8 fraction bits."
  ; d ~sync:Sync Tperr "TPERR" 0x34 [ bit "half" 23; reg "ra" 22 ] "As TPERI, from ra."
  ; d Tget "TGET" 0x35 [ fld "sel" 23 21 (Enum tget_sel); reg "rd" 20 ] "rd := 16 bits of now, t, p or the slack minimum."
  ; d ~sync:Sync Tset "TSET" 0x36 [ reg "ra" 23; reg "rb" 20 ] "t := ra * 65536 + rb, fraction 0."
  ; d ~timed:false ~sync:Sync Waitp "WAITP" 0x37
      [ fld "cond" 23 22 (Enum wait_cond); fld "pin" 21 17 (Pin 24); bit "to" 16; bit "cm" 15; bit "re" 14; bit "adv" 13 ]
      "Sleep until the pin condition holds, or until the deadline if to = 1. cm: commit the \
       staged writes at the event. re: t := the cycle after the event. adv: then t := t + p."
  ; d ~timed:false ~sync:Sync Waits "WAITS" 0x38
      [ bit "sense" 23; uint "bit" 22 19; bit "to" 18; bit "cm" 17; bit "re" 16; bit "adv" 15 ]
      "As WAITP, for a status bit equal to sense."
  ; d Pull "PULL" 0x3A [ reg "rd" 23; uint "ch" 20 19 ] "rd := next word of channel ch; waits while it is empty."
  ; d Push "PUSH" 0x3B [ reg "ra" 23; uint "ch" 20 19 ] "Append ra to channel ch; waits while it is full."
  ; d Emit "EMIT" 0x3C [ uint "code" 7 0 ] "Send an event code to the rule engine and the trace."
  ; d Ior "IOR" 0x3D [ reg "rd" 23; uint "addr" 7 0 ] "rd := I/O register addr."
  ; d Iow "IOW" 0x3E [ reg "ra" 23; uint "addr" 7 0 ] "I/O register addr := ra."
  ; d Iowi "IOWI" 0x3F [ uint "addr" 23 16; uint "imm" 15 0 ] "I/O register addr := imm."
  ]
;;

let tm_names = [| ""; "now"; "at"; "adv" |]

let field_mask f = ((1 lsl (f.hi - f.lo + 1)) - 1) lsl f.lo
let used_mask def = List.fold_left (fun m f -> m lor field_mask f) 0 def.fields
let by_code : def option array =
  let a = Array.make 64 None in
  List.iter
    (fun def ->
      assert (a.(def.code) = None);
      (* fields must not overlap and must lie in the operand bits *)
      let total = List.fold_left (fun n f -> n + (f.hi - f.lo + 1)) 0 def.fields in
      let m = used_mask def in
      let pop = ref 0 in
      for i = 0 to 23 do if (m lsr i) land 1 = 1 then incr pop done;
      assert (total = !pop && m land (lnot 0xFFFFFF) = 0);
      a.(def.code) <- Some def)
    defs;
  a
;;

let by_mnem m = List.find_opt (fun def -> def.mnem = m) defs

type instr =
  { def : def
  ; args : int array
  ; tm : int
  }

let decode (w : int) : instr option =
  let w = w land 0xFFFF_FFFF in
  match by_code.(w lsr 26) with
  | None -> None
  | Some def ->
    let tm = (w lsr 24) land 3 in
    let operand = w land 0xFFFFFF in
    let args = Array.of_list (List.map (fun f -> (operand land field_mask f) lsr f.lo) def.fields) in
    let in_range = List.for_all2 (fun f v -> v <= f.max) def.fields (Array.to_list args) in
    if (tm <> 0 && not def.timed) || operand land lnot (used_mask def) <> 0 || not in_range
    then None
    else Some { def; args; tm }
;;

let encode (i : instr) : int =
  let fields = i.def.fields in
  if List.length fields <> Array.length i.args then invalid_arg (i.def.mnem ^ ": operand count");
  if i.tm < 0 || i.tm > 3 || (i.tm <> 0 && not i.def.timed) then invalid_arg (i.def.mnem ^ ": timing mode");
  let operand =
    List.fold_left
      (fun (acc, k) f ->
        let v = i.args.(k) in
        if v < 0 || v > f.max then invalid_arg (Printf.sprintf "%s: %s out of range" i.def.mnem f.name);
        acc lor (v lsl f.lo), k + 1)
      (0, 0) fields
    |> fst
  in
  (i.def.code lsl 26) lor (i.tm lsl 24) lor operand
;;

let arg (i : instr) name =
  let rec go k = function
    | [] -> invalid_arg (i.def.mnem ^ ": no field " ^ name)
    | f :: rest -> if f.name = name then i.args.(k) else go (k + 1) rest
  in
  go 0 i.def.fields
;;

(* Does this instruction have to wait for an armed commit? *)
let is_sync (i : instr) =
  i.tm <> 0
  ||
  match i.def.sync with
  | Plain -> false
  | Sync -> true
  | Sync_if_cap -> arg i "src" = 1
;;

let kind_text f =
  match f.kind with
  | Reg -> "register"
  | Uint -> Printf.sprintf "0..%d" f.max
  | Bit -> "0 or 1"
  | Pin n -> Printf.sprintf "pin P0..P%d" (n - 1)
  | Target -> "program address"
  | Enum names -> String.concat ", " (Array.to_list (Array.mapi (fun k n -> Printf.sprintf "%d %s" k n) names))
;;

let to_markdown () =
  let b = Buffer.create 4096 in
  let p fmt = Printf.bprintf b fmt in
  p "# Instruction encoding\n\n";
  p "Generated from `spec/isa.ml` by `spec/gen_isa_doc.exe`; do not edit. The meaning of every\n";
  p "instruction is in `machine.md`; the executable definition is `spec/model.ml`.\n\n";
  p "Word: `[31:26]` opcode, `[25:24]` timing mode tm (0 none, 1 now, 2 at, 3 adv), `[23:0]` operand\n";
  p "fields. A word is legal iff the opcode is listed, tm is 0 where the instruction is not timed, every\n";
  p "field is within its range and all operand bits outside the fields are 0. Every other word is ILLEGAL.\n\n";
  p "%d of 64 opcodes are defined.\n\n" (List.length defs);
  p "| opcode | mnemonic | fields `[hi:lo]` | timed | waits for an armed commit | meaning |\n|---|---|---|---|---|---|\n";
  List.iter
    (fun def ->
      let fs =
        match def.fields with
        | [] -> "none"
        | fs -> String.concat ", " (List.map (fun f -> Printf.sprintf "`%s[%d:%d]`" f.name f.hi f.lo) fs)
      in
      let sy = match def.sync with Plain -> "if timed" | Sync -> "always" | Sync_if_cap -> "if src = cap or timed" in
      let sy = if def.sync = Plain && not def.timed then "never" else sy in
      p "| 0x%02X | %s | %s | %s | %s | %s |\n" def.code def.mnem fs (if def.timed then "yes" else "no") sy def.summary)
    defs;
  p "\n## Field ranges\n\n| mnemonic | field | values |\n|---|---|---|\n";
  List.iter (fun def -> List.iter (fun f -> p "| %s | %s | %s |\n" def.mnem f.name (kind_text f)) def.fields) defs;
  Buffer.contents b
;;
