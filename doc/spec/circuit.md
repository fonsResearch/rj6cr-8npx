# Specification circuit

Version 1.1 of 2026-11-21 (registered block boundaries, `doc/decisions/spec_v1_1.md`); version 1.0 of 2026-11-16. The specification circuit is the reference model (`spec/model.ml`) written a
second time, as a Hardcaml circuit, from the documents of this directory. It has two uses:

1. It tests the documents and the model. If two implementations of the specification, one sequential
   program and one circuit, hold the same value in every register in every cycle under the same pin
   inputs, then the documents and the model say one thing and say it completely enough to be built.
2. It is the reference of the chip proofs. The chip RTL is proved equal to this circuit, clock by clock,
   with the memory read data left free; this circuit is not the chip and is not optimised.

## 1. Structure

| file (`spec/circuit/`) | content |
|---|---|
| `state.ml` | every register, as nested ppx_hardcaml interfaces, with widths and reset values |
| `dec.ml` | instruction decode, generated from `spec/isa.ml` (the table the model decodes with) |
| `w.ml` | the working state of one cycle and the memory request helpers |
| `core.ml` | verdict recording, rule blocking, commit, timing hardware |
| `exec.ml` | the execute stage |
| `rules.ml` | the rule engine at the end of the cycle |
| `hostp.ml` | host register map, loader, SPI transactions |
| `lregs.ml`, `linep.ml` | line unit registers; receiver, transmitter, response rules, slot access |
| `step.ml` | one cycle in the model's order; trace; pads |
| `top.ml` | registers around the step; memory ports; optional debug outputs of every register |

**Single-assignment form.** The model is sequential code in which a later statement of a cycle sees the
effect of an earlier one. The circuit follows the same order, line unit, then threads 0 to 2 (fetch,
data access, timing hardware, execute), the line unit's pad override, the rule engine, the host port,
the trace and the pads, and writes every assignment as a new version of the state: `w_if c w f` is `f w`
where `c` holds and `w` elsewhere, muxing only the fields `f` changed. Visibility inside a cycle is
therefore the model's by construction; section 4 lists where that creates long combinational paths.

**Memories.** The program memory (512 x 32) and the data memory (1024 x 16) are outside the circuit,
behind one synchronous single-port interface each, as the SRAM macros have: address, enable and write
data in cycle n, read data in cycle n + 1. Port use per cycle is fixed by `machine.md`, section 2
(program memory: threads 0, 1, 2, system in cycles 0 to 3 of the round; data memory: thread 2, system,
thread 0, thread 1). Read data is used where the model uses it: an instruction word is captured one
cycle after its fetch and used from cycle c + 2; LD and LDX take the data memory output in their execute
cycle; the line unit's next word and the host's read buffer take it in the cycle after the slot.

One change to the specification came from this: the model let the host port use memory read data in the
same cycle as the read, which a synchronous memory cannot. The model now delivers it one cycle later
(`host.md`, section 2); all model tests were unchanged by it.

**Representation.** Where the model keeps an unbounded integer the circuit keeps a register that cannot
be told apart by any comparison the model makes: the SPI bit counter saturates at 63 beside a counter
modulo 32; the stuffing runs saturate at 15 (compared with at most 8); the receiver's idle counter
saturates at 511 (compared with at most 255). Reset values are the model's constructors.

**Registers.** `state_bits.md` is generated from `state.ml`: 3,519 register bits in total.

## 2. Cross-check

`spec/circuit/xcheck/` runs the model and the circuit (Cyclesim) in lockstep. In every cycle:

- both get the same pad inputs;
- every register of the circuit, as the model holds it after the previous cycle, is compared with a
  projection of the model's state (`Lockstep.project`); the only fields not compared are those the
  model has no value for (wait fields outside a wait, a fault code outside a fault, the data of an empty
  mailbox or of an absent request);
- the three pad output words are compared;
- each memory port must have at most one user;
- the testbench memories answer reads with the stored word and drive random data when nothing was
  read, so a circuit that used read data at the wrong time would differ.

At the end the testbench memories are compared with the model's. A planted control (a model register
changed behind the circuit's back) is reported in every cycle after it.

The stimulus (`xcheck/stim.ml`) is a host session over the SPI pins with legal timing: random pin
ownership, filters and safe patterns; three random legal programs with their digests (plus rare raw
words, mostly ILLEGAL); random rules on owned pins, pin edges, EMIT codes and line-unit symbols; the
trace; the line unit, either with random registers or set up for frames on a looped-back pin; then a run
phase of register reads and writes, mailbox traffic, memory reads and writes, starts and stops. Input
pins change at random; with loopback, driven pins read back what they drive.

Results are in `log/xcheck.md`. `dune test` runs a short version (`spec/circuit/test`); long campaigns run
with `xcheck.exe <scenario> <seed> <runs>`.

## 3. What this shows and what it does not

It shows that the circuit and the model agree on the sessions that were run, register by register. It
does not show equivalence for all inputs; that is the proof step, and it will be done between the chip
RTL and this circuit, not between this circuit and the model. Coverage gaps of the campaigns are listed
in `log/xcheck.md`.

## 4. Same-cycle dependencies

In version 1.0 every block of a cycle saw what the earlier blocks had done in the same cycle, and the
deepest chain ran through all of them (`spec_v1_1.md` 1). In version 1.1 each block reads the other
blocks' registers from `ctx.s0`, the state at the start of the cycle; `Step` still threads the working
state through the blocks in the v1.0 order, which now only orders the writes (V2). The dependencies
that remain inside one cycle:

1. Inside a thread: its timing decides whether its commit fires and moves `t`; its execute computes
   with that `t` (TADDI, TADDR, the slack of a timed instruction). Path: rule comparators, the fire
   decision, a 40-bit add, a 32-bit subtract and compare.
2. The rule engine's step (`Rules.rules_step`) runs at the start of the cycle on the registered
   events of the previous cycle (`ri_*`, and `trace.em_*` for EMIT), V3 as amended; its result is
   what the commit checks of the line unit and the threads read (forwarding). The faults it finds are
   applied after the threads (`Rules.rule_faults`), and the events of this cycle are registered at the
   v1.0 place of the rule engine (`Rules.capture`).
3. The pad merge: commits on own pins, the line unit's override, the safe pattern (V2).
4. The verdict merge: candidates of the line unit, threads 0 to 2 and the rule engine, first wins (V2).
5. Inside the line unit, its whole bit-level pipeline (V4, open).

The trace and the host now run in the order trace, host, so that the host's writes land after the
trace's own update; the trace's view of EMIT is the registered `trace.em_*` of the previous cycle.

## 5. Notes for the Verilog of the chip

- One clock, rising edge only; no latches, no tri-states, no falling-edge registers.
- Reset is a synchronous clear to non-zero values for some registers (pin owners 7, rule maxima 0xFFFF,
  trace post count 4, line owner 3, slack minimum 0x7FFF, strict policy 1). The SG13CMOS5L library has
  no flip-flop without an asynchronous reset pin, so a synchronous clear costs a gate in front of every
  D input; whether the chip uses the cell's asynchronous reset instead is a decision of the RTL step.
- The host register read is a 256-way multiplexer and the line unit's a 64-way one; both are large and
  are kept because they are the specification.
- The circuit has no clock gating and no memories inside.

## 6. Mapped size

`flow/map/map_spec.sh` maps this circuit to SG13CMOS5L cells with the PDK's Yosys techmaps, typical
liberty, `synth -flatten -nofsm` (FSM extraction did not finish in 38 minutes and is off). Result of
2026-11-16 [measured, local synthesis only: no placement, buffering, hold or timing repair]:

| item | value |
|---|---|
| cells | 51,437 |
| area | 679,487 um^2 |
| of which flip-flops (3,428 `dfrbpq_1`) | 167,934 um^2 (24.7 %) |
| `mux2_1` | 6,485 cells, about 118k um^2 |

With the routed factor 1.33 and both macros (159.4k um^2) of `arch_selection.md` 7 this is about 88 % of
the 1,208,173 um^2 core [estimate]: the circuit as written does not fit, and it is 2.2 times the 310.3k
estimated for the minimum configuration (3 threads, 4 rule slots), which it implements. The flip-flop
count is close to the state table (3,519 bits, `state_bits.md`; the difference is constant or unread
bits removed by Yosys), so the excess is logic: about 511k um^2 against the estimate's 100 um^2 per bit
including logic. Known contributors, not yet measured one by one:

- the execute stage is built once per thread (`Step`, three copies of `Exec.execute`, each enabled in
  its slot); the chip has one, shared;
- every conditional update in the single-assignment form is a multiplexer over each field it writes;
- the host's 256-way and the line unit's 64-way register read multiplexers (section 5).

This circuit is the reference for the proof, not a floorplan. The chip's size is measured at the
skeleton gate, where a per-block mapping is part of the gate.

