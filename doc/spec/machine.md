# Machine model: threads, time and pins

Draft 0.1 of 2026-11-14. Normative once frozen; until then `spec/model.ml` and this text are changed
together. Scope: the three program threads, their timing hardware, the pad stage, memory windows, faults.
Not yet specified, and named here only where they touch the core: host port and loader, line unit,
response rules, rule engine, trace. Instruction encodings are in `isa.md`, generated from `spec/isa.ml`.

Every statement below is implemented in `spec/model.ml`; the tests named in section 12 show the timing
statements on running programs.

## 1. Conventions

- One clock. All state changes at its rising edge. Cycle n is the interval between the edge that begins it
  and the next edge; "during cycle n" refers to register values in that interval.
- `now` is a 32-bit counter holding the cycle number modulo 2^32; it is 0 in the first cycle after reset.
- Registers are 16 bits, r0 to r7 per thread. There is no flags register and no register that reads as 0.
- Reset: all threads idle, pad values 0, all bidirectional pins released, `now` = 0. Memory contents are
  not reset.

## 2. Round

Thread T (0, 1, 2) fetches only in cycles with `now mod 4 = T`. The fourth cycle belongs to the system
slot (host, loader, line unit, trace). An instruction fetched in cycle c

| cycle | what happens |
|---|---|
| c | the word at `pbase + pc` is read from the program memory |
| c+2 | data memory access of LD, LDX, ST, STX; a store is in the memory from cycle c+3 |
| c+3 | execute: everything else is computed from the state of this cycle |
| c+4 | the effects are visible; this cycle is called the instruction's effect cycle e |

A thread has at most one instruction in flight; its next fetch is in cycle c+4. Each memory port
therefore has one owner per cycle: program memory T0, T1, T2, system in cycles 0 to 3 of the round; data
memory T2, system, T0, T1.

An instruction that has to wait (sections 5 and 8) has no effect at all and is fetched again in cycle
c+4, so it retries every round.

## 3. Pins

| pins | pad | a thread can | reads as |
|---|---|---|---|
| P0..P7 | `uio[0..7]` | drive, release | synchronised pad input |
| P8..P15 | `uo[0..7]` | drive (P8 is the host port's output and cannot be owned) | the output value |
| P16..P23 | `ui[0..7]` | read (`ui[0..2]` are also the host port's inputs) | synchronised pad input |

Pin assignment to the host port is provisional until the host document and the floorplan.

- **Pad registers.** `value[15:0]` for P0..P15 and `dir[7:0]` for P0..P7.
  `uo = value[15:8]`; for a push-pull pin `uio_out = value`, `uio_oe = dir`; for a pin in open-drain mode
  `uio_out = 0` and `uio_oe = dir and not value`, so it is never driven high.
- **Owner.** Each of P0..P15 has an owner: thread 0, 1, 2, or none. A pin with no thread as owner holds
  the safe pattern (`safe_val`, `safe_dir`), which the host sets. Owner, open-drain mode and safe pattern
  are host configuration.
- **Inputs.** `x(n)` is the pad level sampled by the first synchroniser stage at the edge that begins
  cycle n. With filter length F (0 to 3, per pin), the synchronised value `s` changes to a new level in
  cycle n if `x(n-1-F) .. x(n-1)` all have that level. With F = 0, `s(n) = x(n-1)`. There is no path from
  a pad to a thread that bypasses the synchroniser.
- **Staging.** Pin instructions do not change the pads. They write the thread's staged set: a value and a
  mask for P0..P15, and a value and a mask for the output enables of P0..P7. Staging a pin the thread
  does not own is the fault PINOWN.
- **Commit.** A commit copies the staged values of the masked pins the thread owns into the pad
  registers, clears the staged set, and loads the thread's capture register `cap` with all 24 pin values
  as read in the cycle before. A commit with an empty staged set is a pure capture.

## 4. Timing modes

Bits [25:24] of every timed instruction select what follows its own effect:

| tm | name | meaning |
|---|---|---|
| 0 | | nothing |
| 1 | `@now` | commit in the effect cycle e: the pads change in cycle e |
| 2 | `@at` | arm a commit for the deadline t: the pads change in cycle t |
| 3 | `@adv` | as `@at`, and when the commit happens t := t + p |

## 5. Deadlines

- Each thread has a deadline `t` (32 bits of cycles and 8 fraction bits) and a period `p` (24 bits of
  cycles and 8 fraction bits). Only the integer part of t is compared with `now`; the fraction makes
  average rates exact: after k steps of `@adv` the deadline is `t0 + floor(k * p)`.
- **Arming** in effect cycle e is on time iff `t - e >= 1`, taken as a signed 32-bit difference. The
  thread then continues with its next instructions while the commit is armed.
- **Late.** If `t - e < 1`: with the strict policy the thread faults LATE and the instruction has no
  effect; with the lenient policy the commit happens in cycle e, t := e (then `+ p` for `@adv`) and the
  sticky LATE status bit is set. The policy is host configuration per thread.
- **Firing.** In cycle t - 1 the armed commit fires: the pads have the new values during cycle t, `cap`
  holds the pins as read in cycle t - 1, and the commit is no longer armed. While the rule engine holds
  the thread (section 11), firing is postponed.
- **Order within a cycle.** Timing events are applied first; an instruction in its execute cycle acts on
  the result. An instruction whose execute cycle is the cycle in which the armed commit fires is
  therefore not kept waiting and sees the new capture.
- **Instructions that wait while a commit is armed:** every instruction with tm not 0; every instruction
  that stages a pin, reads `cap`, or writes t or p; WAITP, WAITS, HALT. The column in `isa.md` lists
  them. Everything else (arithmetic, memory, branches on registers or live pins, mailboxes) runs while a
  commit is armed, so the time before a deadline is available for computing the next value.
- **Slack.** At every arming, and every event wait with a deadline, `t - e` is recorded if it is smaller
  than the recorded minimum (16 bits, saturating). The minimum is readable by the thread (TGET) and the
  host. A value of 1 means the program met its deadline with nothing to spare.

Consequences, each shown by a test (section 12):

1. A thread can commit once per round, i.e. every 4 cycles, for any alignment of its deadlines to its
   slot.
2. An edge produced by `@at` or `@adv` is in cycle t exactly, whatever the instruction count before it;
   otherwise the thread has faulted or, under the lenient policy, the LATE bit is set.

## 6. Event waits

WAITP (a pin: low, high, rising, falling) and WAITS (a status bit equal to a value) put the thread to
sleep from their effect cycle e. In every cycle n >= e the condition is evaluated on the values read in
cycle n; an edge compares cycle n with cycle n - 1.

- **Event** in cycle n: the pads take the staged values in cycle n + 1 if `cm` = 1 (otherwise the staged
  set is kept); `cap` holds the pins as read in cycle n; status bit EV := 1; if `re` = 1 then t := n + 1
  with fraction 0; if `adv` = 1 then t := t + p; the thread runs again from cycle n + 1.
- **Deadline**, only if `to` = 1, in cycle t - 1 without an event in that cycle: as an armed commit, and
  EV := 0. Lateness at e is handled as in section 5; under the lenient policy the timeout is taken in
  cycle e.
- With `to` = 0 and a condition that never holds the thread sleeps until the host stops it.

From the pad to the pad, a reaction with `cm` = 1 is constant: an input level first sampled at the edge
that begins cycle k (F = 0) changes the output register at the edge that begins cycle k + 2.

After an event the thread needs up to 4 cycles to reach its slot and 4 per instruction. A deadline set by
one further instruction after the wait (for example TADDI) is on time for every alignment if it is at
least 12 cycles after the cycle in which the event commit became visible; with `adv` in the wait itself,
8 cycles.

## 7. Memory windows

- Program: `pc` is relative to the thread's window. Fetching with `pc >= psize` is the fault PCBOUND; the
  word read is `prog[(pbase + pc) mod 512]`. Branch targets are 9 bits; JR to a value `>= psize` faults at
  the JR.
- Data: the effective address (10-bit constant, or register plus 10-bit constant, modulo 2^16) is
  relative to the window; `>= dsize` is the fault DBOUND and nothing is read or written.
- Windows are host configuration. The isolation claim assumes the host gives threads disjoint windows and
  disjoint pin sets.
- ST and STX are not timed, so a store is never repeated.

## 8. Mailboxes, status, I/O registers

- Channel 0 of PULL and PUSH is the thread's mailbox pair with the host: host to thread, thread to host,
  each a queue of depth D (generator parameter, 1 in the area budget). PULL waits while its queue is
  empty, PUSH while its queue is full. Channels 1 to 3 are reserved for thread-to-thread bridges; without
  them an access waits for ever.
- Status bits (BST, WAITS, I/O register 0): 0 EV, 1 mailbox from host not empty, 2 mailbox to host not
  full, 3 LATE (sticky). Bits 4 to 15 read 0 until the line unit, response rule and rule engine documents
  define them.
- I/O register 0: read gives the status bits; writing 1 to bit 0 or bit 3 clears EV or LATE. Any other
  address is the fault IOPERM until the documents of the other blocks define it.

## 9. Faults

| fault | cause |
|---|---|
| ILLEGAL | a word that is not a legal instruction |
| PCBOUND | fetch or JR outside the program window |
| DBOUND | data address outside the data window |
| PINOWN | staging a pin of another owner |
| LATE | deadline not ahead, strict policy |
| IOPERM | I/O register not accessible |
| TRAP | the TRAP instruction, with its code |
| RULE | fail-stop by the rule engine, with the rule number |

A faulting instruction has no other effect. The thread stops with `pc` at that instruction, an armed
commit is cancelled, its staged set is cleared, and from the effect cycle its pins hold the safe pattern.
HALT stops the thread and leaves its pins as they are.

## 10. Instruction semantics

The table in `isa.md` gives one line per instruction; where it is not exhaustive, `spec/model.ml`
(function `execute`) is the definition. Points that are easy to get wrong:

- `now` in TNOW and TGET is the effect cycle e of that instruction.
- ALUI and BRI zero-extend their constant. `slt`, `lt`, `ge` compare as signed 16-bit numbers.
- Shift amounts are 0 to 15; SHV uses `rb[3:0]`.
- CRC, not reflected: for each data bit d (bit 7 first in byte mode), `fb = rd[15] xor d`, `rd := rd << 1`,
  then `rd := rd xor rb` if fb. Reflected: `fb = rd[0] xor d` (bit 0 first), `rd := rd >> 1`, then the same.
  Polynomials narrower than 16 bits are left-aligned in the non-reflected form.
- JAL stores `pc + 1`, a window-relative address.
- DJNZ decrements modulo 2^16 and branches if the result is not 0.

## 11. Hooks for blocks not yet specified

- `hold(T)`: while the rule engine asserts it, an armed commit of thread T does not fire. How a held
  commit moves t, and how hold applies to the commit of an event wait, belongs to the rule document.
- EMIT produces (effect cycle, thread, code) for the rule engine and the trace.
- Host: loading, start and stop of a thread, windows, pin configuration, mailbox access.

## 12. Tests

`dune test` runs `spec/test`:

| test | shows |
|---|---|
| decode is total and canonical | every word is ILLEGAL or decodes to one instruction that encodes back to it |
| CRC step against published check values | CRC-16/CCITT-FALSE, CRC-16/ARC, CRC-8 |
| UART frame | bit boundaries at `t0 + floor(k * 416.668)` |
| one edge every 4 cycles | section 5, consequence 1, three threads, five alignments |
| event wait | constant 2-cycle reaction; 12-cycle rule of section 6, and the fault at 11 |
| a deadline that has passed | strict and lenient policy |
| faults leave the pins in the safe pattern | section 9 |
| isolation | thread 0's trace is identical with and without two running neighbours |
| host mailbox round trip | PULL, ST, LD, PUSH |

These are examples, not proofs. The claims of the architecture document are proved on the RTL against a
circuit form of this model in a later step.

## 13. State

| per thread | bits |
|---|---|
| registers | 128 |
| pc | 10 |
| deadline t, period p | 40 + 32 |
| armed, due, adv | 3 |
| staged set | 48 |
| capture | 24 |
| state, fault code and argument | 15 |
| EV, LATE | 2 |
| slack minimum | 16 |
| event-wait condition | 12 |
| windows, late policy | 41 |
| mailboxes (D = 1) | 34 |
| total | 405 |

Shared: `now` 32; pad registers 24; pin configuration (owner, open drain, safe pattern, filter length)
108; synchronisers, filter counters and previous values 88. Core state: 3 x 405 + 252 = 1,467 bits, not
counting pipeline registers.

## 14. Decisions taken in this draft

To be confirmed or changed when the documents are frozen.

| # | decision | alternative and its cost |
|---|---|---|
| D1 | a commit is armed and the thread keeps running | sleeping until the deadline is simpler to explain but limits a thread to one edge per two rounds |
| D2 | every instruction carries a timing mode | separate wait instructions: one more instruction, 4 cycles, per timed action |
| D3 | 32-bit time, 8 fraction bits | 24-bit time saves 8 bits per comparator but wraps after 0.35 s at 48 MHz |
| D4 | compare-and-branch, no flags | flags add state that every proof about a thread has to carry |
| D5 | no toggle, no post-increment, no hardware loop | each would save an instruction in some loops; a serial bit costs 2 instructions (8 cycles) |
| D6 | all program and data addresses relative to a window | absolute addresses make a loaded program position-dependent |
| D7 | non-zero unused bits are ILLEGAL | ignoring them is slightly smaller but gives one instruction many encodings |
| D8 | mailbox depth is a generator parameter | fixed depth 4 costs about 300 more flip-flops |
| D9 | CRC as a register-to-register step of 1 or 8 bits | a per-thread CRC register adds state; a 16-bit step is deeper logic |
| D10 | lenient late policy re-anchors t to the actual commit | keeping t would make every later deadline late as well |

## 15. Open points

1. Hold and event waits (section 11).
2. Start and stop of a thread by the host, and what start resets.
3. Whether the "timing events first" order, which puts the fire decision in front of the execute stage,
   meets 48 MHz once the rule engine's hold is in that path. Fallback: decide hold one cycle earlier from
   registered values.
4. Status bits 4 to 15 and the I/O register map.
5. Firmware rates quoted in the architecture document are estimates; from the rules above a serial bit
   needs 8 cycles (6 Mbit/s at 48 MHz) and an SPI controller bit with a clocked shift 12 cycles (4 MHz).
   Neither SPI figure is demonstrated by a test yet.
