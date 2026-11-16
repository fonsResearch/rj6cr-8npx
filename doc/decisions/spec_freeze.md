# Specification freeze

Frozen on 2026-11-16 at the commit that adds this file. From this commit on, the documents below are
normative, and a change to any of them is made as described in section 4.

## 1. What is frozen

| document | content | executable form |
|---|---|---|
| `doc/spec/isa.md` | 48 instructions, encodings, timing modes (generated) | `spec/isa.ml`, `spec/asm.ml` |
| `doc/spec/machine.md` | threads, round, timing hardware, pins, windows, faults | `spec/model.ml` |
| `doc/spec/rules.md` | interval rules, attribution, enforcement, verdicts | `spec/model.ml` |
| `doc/spec/host.md` | SPI host port, register map, loader and load gate | `spec/model.ml` |
| `doc/spec/trace.md` | pin and EMIT trace into the data memory | `spec/model.ml` |
| `doc/spec/line.md` | line unit and the two response rules | `spec/model.ml` |
| `doc/spec/circuit.md` | the specification circuit and the cross-check method | `spec/circuit/` |
| `doc/spec/state_bits.md` | register bits per block (generated) | `spec/circuit/state.ml` |
| `doc/spec/fig/timing_contract.png` | one deadline commit, cycle by cycle (generated from the model) | `spec/contract_trace.ml` |

The model and the specification circuit agree register by register in every cycle on 88 sessions and
7.1 million cycles (`log/xcheck.md`); that is a test, not a proof.

## 2. Decisions taken in the documents

Every decision below was taken by me under the delegation of 2026-11-14 and can be overridden; the
alternative and its cost are in the named document.

| # | decision | where |
|---|---|---|
| D1 | a commit is armed and the thread keeps running | `machine.md` 14 |
| D2 | every instruction carries a timing mode | `machine.md` 14 |
| D3 | 32-bit time with 8 fraction bits | `machine.md` 14 |
| D4 | compare-and-branch, no flags | `machine.md` 14 |
| D5 | no toggle, no post-increment, no hardware loop | `machine.md` 14 |
| D6 | program and data addresses relative to the thread's window | `machine.md` 14 |
| D7 | non-zero unused instruction bits are ILLEGAL | `machine.md` 14 |
| D8 | mailbox depth is a generator parameter, 1 in this chip | `machine.md` 14 |
| D9 | CRC as a register-to-register step of 1 or 8 bits | `machine.md` 14 |
| D10 | a late or held deadline commit re-anchors `t` to the actual pad change | `machine.md` 14 |
| D11 | every commit goes through the timing hardware (`@now` one cycle after the effect cycle) | `machine.md` 14 |
| H1 | one SPI host port sampled in the core clock; SCK period of at least 10 cycles (estimate) | `host.md` 2 |
| H2 | the load digest covers the program words only | `host.md` 3 |
| H3 | a register read with a side effect (mailbox) takes effect when its word is fully clocked | `host.md` 2 |
| H4 | the memories read synchronously; host read data is available from the cycle after the slot (new) | `host.md` 2 |
| H5 | the data memory is not gated against the host | `host.md` 2 |
| R1 | an edge on a bidirectional pin is the peer's iff our driver was off over a 4-cycle window (plus the filter delay) | `rules.md` 3 |
| R2 | a hold or fail-stop guarantee blocks a commit containing its stop edge while below its minimum, decided from registers only | `rules.md` 7 |
| R3 | fail-stop faults the owner; its safe pattern goes through the same check | `rules.md` 7 |
| T1 | trace records of 4 words, at least 16 cycles each, in the system slot after line unit and host | `trace.md` 2 |
| T2 | the trace freezes a set number of records (default 4) after the first verdict | `trace.md` 3 |
| L1 to L8 | line unit: one transmitter for frames and replies; stop on a forbidden edge; frames in the owner's window; left-aligned 16-bit CRC; one stuffing rule; phase-accumulator recovery; 8-bit reply patterns; host-assigned owner | `line.md` 10 |
| C1 | the specification circuit keeps the memories outside, behind the macros' synchronous interface | `circuit.md` 1 |

## 3. Open after the freeze

None of these changes what a program or a host sees today; each is decided with measured data and goes
through section 4 if it changes the specification.

| item | decided in | possible change to the specification |
|---|---|---|
| the same-cycle paths of `circuit.md` 4 at 48 MHz, above all rule blocking into the fire decision | skeleton gate, minimum chip RTL | compute the blocking decision one cycle ahead (`rules.md` 12.2) |
| line unit area: 692 register bits in the circuit against a budget estimate of 637 | skeleton gate | the reductions of `line.md` 11.1 |
| total size: the specification circuit maps to 679,487 um^2 locally, about 88 % of the core with macros and the routed factor [estimate]; its execute stage is triplicated, the chip's will not be (`circuit.md` 6) | skeleton gate | measure per block; if the shared design is still over the envelope, reduce scope before RTL |
| number of rule slots and observation registers | skeleton gate | fewer slots; observation registers on some slots |
| SCK limit with real pad delays | sign-off | a stricter host rule |
| digest over pin configuration and rule table | toolchain step | host register addition |
| reset style of the chip (synchronous clear as specified, or the cells' asynchronous reset) | minimum chip RTL | none: reset values are specified, not the mechanism |

## 4. Changing a frozen document

A change is one commit that changes the document, `spec/model.ml`, `spec/circuit/` and the tests
together, keeps `dune test` passing, re-runs the lockstep campaigns of `log/xcheck.md`, and adds a line
to the table below with the reason.

| date | change | reason | commit |
|---|---|---|---|
