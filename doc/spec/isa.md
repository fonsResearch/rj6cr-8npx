# Instruction encoding

Generated from `spec/isa.ml` by `spec/gen_isa_doc.exe`; do not edit. The meaning of every
instruction is in `machine.md`; the executable definition is `spec/model.ml`.

Word: `[31:26]` opcode, `[25:24]` timing mode tm (0 none, 1 now, 2 at, 3 adv), `[23:0]` operand
fields. A word is legal iff the opcode is listed, tm is 0 where the instruction is not timed, every
field is within its range and all operand bits outside the fields are 0. Every other word is ILLEGAL.

48 of 64 opcodes are defined.

| opcode | mnemonic | fields `[hi:lo]` | timed | waits for an armed commit | meaning |
|---|---|---|---|---|---|
| 0x00 | NOP | none | yes | if timed | No operation. With a timing mode it is a pure commit or wait. |
| 0x01 | ALU | `fn[23:20]`, `rd[19:17]`, `ra[16:14]`, `rb[13:11]` | yes | if timed | rd := fn(ra, rb). |
| 0x02 | ALUI | `fn[23:20]`, `rd[19:17]`, `imm[15:0]` | yes | if timed | rd := fn(rd, imm). With fn = mov it loads a constant. |
| 0x03 | SHI | `kind[23:21]`, `rd[20:18]`, `ra[17:15]`, `amt[3:0]` | yes | if timed | rd := ra shifted or rotated by amt. |
| 0x04 | SHV | `kind[23:21]`, `rd[20:18]`, `ra[17:15]`, `rb[14:12]` | yes | if timed | rd := ra shifted or rotated by rb[3:0]. |
| 0x06 | CRC | `refl[23:23]`, `byte[22:22]`, `rd[21:19]`, `ra[18:16]`, `rb[15:13]` | yes | if timed | rd := CRC register rd advanced by one bit (ra[0]) or one byte (ra[7:0]) with polynomial rb; refl selects the right-shifting form. |
| 0x08 | LD | `rd[23:21]`, `addr[9:0]` | yes | if timed | rd := data[addr]. |
| 0x09 | LDX | `rd[23:21]`, `ra[20:18]`, `off[9:0]` | yes | if timed | rd := data[ra + off]. |
| 0x0A | ST | `rs[23:21]`, `addr[9:0]` | no | never | data[addr] := rs. |
| 0x0B | STX | `rs[23:21]`, `ra[20:18]`, `off[9:0]` | no | never | data[ra + off] := rs. |
| 0x10 | JMP | `tgt[8:0]` | yes | if timed | pc := tgt. |
| 0x11 | JAL | `rd[23:21]`, `tgt[8:0]` | yes | if timed | rd := pc + 1; pc := tgt. |
| 0x12 | JR | `ra[23:21]` | yes | if timed | pc := ra. |
| 0x13 | BR | `cond[23:21]`, `ra[20:18]`, `rb[17:15]`, `tgt[8:0]` | yes | if timed | If cond(ra, rb) then pc := tgt. |
| 0x14 | BRI | `cond[23:21]`, `ra[20:18]`, `imm[16:9]`, `tgt[8:0]` | yes | if timed | If cond(ra, imm) then pc := tgt; imm is zero-extended. |
| 0x15 | DJNZ | `rd[23:21]`, `tgt[8:0]` | yes | if timed | rd := rd - 1; if rd is not 0 then pc := tgt. |
| 0x16 | BBIT | `sense[23:23]`, `ra[22:20]`, `bit[19:16]`, `tgt[8:0]` | yes | if timed | If bit of ra equals sense then pc := tgt. |
| 0x17 | BPIN | `sense[23:23]`, `src[22:22]`, `pin[21:17]`, `tgt[8:0]` | yes | if src = cap or timed | If the pin, live or as captured, equals sense then pc := tgt. |
| 0x18 | BST | `sense[23:23]`, `bit[22:19]`, `tgt[8:0]` | yes | if timed | If the status bit equals sense then pc := tgt. |
| 0x19 | HALT | none | no | always | Stop the thread; its pins keep their values. |
| 0x1A | TRAP | `code[7:0]` | no | never | Fault with a user code. |
| 0x20 | PINV | `v[23:23]`, `p[22:19]` | yes | always | Stage pin p := v. |
| 0x21 | PDIR | `d[23:23]`, `p[22:20]` | yes | always | Stage the output enable of pin p := d. |
| 0x22 | PINR | `p[23:20]`, `ra[19:17]`, `bit[16:13]` | yes | always | Stage pin p := bit of ra. |
| 0x23 | PINM | `ra[23:21]`, `mask[15:0]` | yes | always | Stage pins P0..P15 selected by mask := the same bits of ra. |
| 0x24 | PDRM | `ra[23:21]`, `mask[7:0]` | yes | always | Stage the output enables of P0..P7 selected by mask := the same bits of ra. |
| 0x25 | PINI | `grp[23:23]`, `mask[15:8]`, `val[7:0]` | yes | always | Stage pins P0..P7 (grp 0) or P8..P15 (grp 1) selected by mask := val. |
| 0x26 | PDRI | `mask[15:8]`, `val[7:0]` | yes | always | Stage the output enables of P0..P7 selected by mask := val. |
| 0x27 | OUTS | `dir[23:23]`, `p[22:19]`, `rd[18:16]` | yes | always | Shift out: stage pin p := rd[0] and shift rd right (dir 0), or rd[15] and shift left (dir 1). |
| 0x28 | OUTSC | `dir[23:23]`, `p[22:19]`, `rd[18:16]`, `cp[15:12]`, `cv[11:11]` | yes | always | OUTS, and stage a second pin cp := cv (a clock). |
| 0x29 | INS | `dir[23:23]`, `src[22:22]`, `pin[21:17]`, `rd[16:14]` | yes | if src = cap or timed | Shift in: rd := rd shifted right with the pin entering at bit 15 (dir 0), or shifted left with the pin entering at bit 0 (dir 1). |
| 0x2A | INSC | `dir[23:23]`, `src[22:22]`, `pin[21:17]`, `rd[16:14]`, `cp[13:10]`, `cv[9:9]` | yes | always | INS, and stage a second pin cp := cv (a clock). |
| 0x2B | PINRD | `src[23:23]`, `grp[22:22]`, `rd[21:19]` | yes | if src = cap or timed | rd := pins P0..P15 (grp 0) or P16..P23 zero-extended (grp 1), live or as captured. |
| 0x30 | TNOW | `imm[15:0]` | yes | always | t := now + imm, fraction 0. |
| 0x31 | TADDI | `imm[15:0]` | yes | always | t := t + imm cycles. |
| 0x32 | TADDR | `ra[23:21]` | yes | always | t := t + ra cycles. |
| 0x33 | TPERI | `half[23:23]`, `imm[15:0]` | yes | always | p[15:0] := imm (half 0) or p[31:16] := imm (half 1); p is cycles with 8 fraction bits. |
| 0x34 | TPERR | `half[23:23]`, `ra[22:20]` | yes | always | As TPERI, from ra. |
| 0x35 | TGET | `sel[23:21]`, `rd[20:18]` | yes | if timed | rd := 16 bits of now, t, p or the slack minimum. |
| 0x36 | TSET | `ra[23:21]`, `rb[20:18]` | yes | always | t := ra * 65536 + rb, fraction 0. |
| 0x37 | WAITP | `cond[23:22]`, `pin[21:17]`, `to[16:16]`, `cm[15:15]`, `re[14:14]`, `adv[13:13]` | no | always | Sleep until the pin condition holds, or until the deadline if to = 1. cm: commit the staged writes at the event. re: t := the cycle after the event. adv: then t := t + p. |
| 0x38 | WAITS | `sense[23:23]`, `bit[22:19]`, `to[18:18]`, `cm[17:17]`, `re[16:16]`, `adv[15:15]` | no | always | As WAITP, for a status bit equal to sense. |
| 0x3A | PULL | `rd[23:21]`, `ch[20:19]` | yes | if timed | rd := next word of channel ch; waits while it is empty. |
| 0x3B | PUSH | `ra[23:21]`, `ch[20:19]` | yes | if timed | Append ra to channel ch; waits while it is full. |
| 0x3C | EMIT | `code[7:0]` | yes | if timed | Send an event code to the rule engine and the trace. |
| 0x3D | IOR | `rd[23:21]`, `addr[7:0]` | yes | if timed | rd := I/O register addr. |
| 0x3E | IOW | `ra[23:21]`, `addr[7:0]` | yes | if timed | I/O register addr := ra. |
| 0x3F | IOWI | `addr[23:16]`, `imm[15:0]` | yes | if timed | I/O register addr := imm. |

## Field ranges

| mnemonic | field | values |
|---|---|---|
| ALU | fn | 0 add, 1 sub, 2 and, 3 or, 4 xor, 5 andn, 6 sltu, 7 slt, 8 mov |
| ALU | rd | register |
| ALU | ra | register |
| ALU | rb | register |
| ALUI | fn | 0 add, 1 sub, 2 and, 3 or, 4 xor, 5 andn, 6 sltu, 7 slt, 8 mov |
| ALUI | rd | register |
| ALUI | imm | 0..65535 |
| SHI | kind | 0 shl, 1 shr, 2 asr, 3 rol, 4 ror |
| SHI | rd | register |
| SHI | ra | register |
| SHI | amt | 0..15 |
| SHV | kind | 0 shl, 1 shr, 2 asr, 3 rol, 4 ror |
| SHV | rd | register |
| SHV | ra | register |
| SHV | rb | register |
| CRC | refl | 0 or 1 |
| CRC | byte | 0 or 1 |
| CRC | rd | register |
| CRC | ra | register |
| CRC | rb | register |
| LD | rd | register |
| LD | addr | 0..1023 |
| LDX | rd | register |
| LDX | ra | register |
| LDX | off | 0..1023 |
| ST | rs | register |
| ST | addr | 0..1023 |
| STX | rs | register |
| STX | ra | register |
| STX | off | 0..1023 |
| JMP | tgt | program address |
| JAL | rd | register |
| JAL | tgt | program address |
| JR | ra | register |
| BR | cond | 0 eq, 1 ne, 2 ltu, 3 geu, 4 lt, 5 ge |
| BR | ra | register |
| BR | rb | register |
| BR | tgt | program address |
| BRI | cond | 0 eq, 1 ne, 2 ltu, 3 geu, 4 lt, 5 ge |
| BRI | ra | register |
| BRI | imm | 0..255 |
| BRI | tgt | program address |
| DJNZ | rd | register |
| DJNZ | tgt | program address |
| BBIT | sense | 0 or 1 |
| BBIT | ra | register |
| BBIT | bit | 0..15 |
| BBIT | tgt | program address |
| BPIN | sense | 0 or 1 |
| BPIN | src | 0 live, 1 cap |
| BPIN | pin | pin P0..P23 |
| BPIN | tgt | program address |
| BST | sense | 0 or 1 |
| BST | bit | 0..15 |
| BST | tgt | program address |
| TRAP | code | 0..255 |
| PINV | v | 0 or 1 |
| PINV | p | pin P0..P15 |
| PDIR | d | 0 or 1 |
| PDIR | p | pin P0..P7 |
| PINR | p | pin P0..P15 |
| PINR | ra | register |
| PINR | bit | 0..15 |
| PINM | ra | register |
| PINM | mask | 0..65535 |
| PDRM | ra | register |
| PDRM | mask | 0..255 |
| PINI | grp | 0 or 1 |
| PINI | mask | 0..255 |
| PINI | val | 0..255 |
| PDRI | mask | 0..255 |
| PDRI | val | 0..255 |
| OUTS | dir | 0 or 1 |
| OUTS | p | pin P0..P15 |
| OUTS | rd | register |
| OUTSC | dir | 0 or 1 |
| OUTSC | p | pin P0..P15 |
| OUTSC | rd | register |
| OUTSC | cp | pin P0..P15 |
| OUTSC | cv | 0 or 1 |
| INS | dir | 0 or 1 |
| INS | src | 0 live, 1 cap |
| INS | pin | pin P0..P23 |
| INS | rd | register |
| INSC | dir | 0 or 1 |
| INSC | src | 0 live, 1 cap |
| INSC | pin | pin P0..P23 |
| INSC | rd | register |
| INSC | cp | pin P0..P15 |
| INSC | cv | 0 or 1 |
| PINRD | src | 0 live, 1 cap |
| PINRD | grp | 0 or 1 |
| PINRD | rd | register |
| TNOW | imm | 0..65535 |
| TADDI | imm | 0..65535 |
| TADDR | ra | register |
| TPERI | half | 0 or 1 |
| TPERI | imm | 0..65535 |
| TPERR | half | 0 or 1 |
| TPERR | ra | register |
| TGET | sel | 0 now_lo, 1 now_hi, 2 t_lo, 3 t_hi, 4 slack, 5 p_lo, 6 p_hi |
| TGET | rd | register |
| TSET | ra | register |
| TSET | rb | register |
| WAITP | cond | 0 low, 1 high, 2 rise, 3 fall |
| WAITP | pin | pin P0..P23 |
| WAITP | to | 0 or 1 |
| WAITP | cm | 0 or 1 |
| WAITP | re | 0 or 1 |
| WAITP | adv | 0 or 1 |
| WAITS | sense | 0 or 1 |
| WAITS | bit | 0..15 |
| WAITS | to | 0 or 1 |
| WAITS | cm | 0 or 1 |
| WAITS | re | 0 or 1 |
| WAITS | adv | 0 or 1 |
| PULL | rd | register |
| PULL | ch | 0..3 |
| PUSH | ra | register |
| PUSH | ch | 0..3 |
| EMIT | code | 0..255 |
| IOR | rd | register |
| IOR | addr | 0..255 |
| IOW | ra | register |
| IOW | addr | 0..255 |
| IOWI | addr | 0..255 |
| IOWI | imm | 0..65535 |
