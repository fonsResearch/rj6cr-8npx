# Specification v1.1: registered block boundaries

Status: decided 2026-11-21 (owner's decision: registered block boundaries; this document fixes the
rules). Change process: `spec_freeze.md` 4. Basis: `log/skeleton_gate.md` 7 and the depth analysis
below.

## 1. Why

In v1.0 one cycle evaluates the blocks in sequence and each block sees what the earlier ones did in
the same cycle: line unit, then for each thread fetch, memory, timing and execute, then the line
pin override, the rule engine, the host port, the trace and the pads. The deepest chain runs
through all of them. Logic-depth estimate on the specification circuit (relative levels, calibrated
on the routed skeleton run 44777903562: 253 levels measured as 39.06 ns at the slow corner, about
0.15 ns per level) [estimate]:

| structure | deepest chain | slow corner |
|---|---|---|
| v1.0, one execute stage shared | 510 levels | about 79 ns |
| every block reads registered state | line unit 243 | about 37 ns |
| | host port 123 | about 19 ns |
| | rule engine 78 | about 12 ns |
| | thread timing or execute 70 | about 11 ns |

The clock period is 20.83 ns. Carrier of the chain at each boundary (v1.0): the line unit's verdict
into thread 0's timing; the deadline after a firing commit into execute; an ownership write by
execute (`line_owner`) into the next thread; events emitted by execute into the rule engine; thread
state into the host port; the host's output into the trace and the pads.

## 2. Rules of v1.1

V1. A block reads the registers of every other block as they were at the start of the cycle.
    Blocks: the line unit; each thread (fetch, memory stage, timing, execute of that thread); the
    rule engine; the host port; the trace. Inside a block the v1.0 order is kept: a thread's
    execute still sees the result of its own timing in the same cycle.

V2. Four merges stay in the same cycle because they are shallow and every input to them obeys V1:
    1. pad value and direction registers: commits of each thread on its own pins, the line unit's
       override, the safe pattern of unowned pins (unchanged from v1.0);
    2. verdict registers: the verdicts found in the cycle by the line unit, threads 0, 1, 2 and the
       rule engine are merged in that order; the first in the order is the one recorded, as in
       v1.0;
    3. memory ports: each thread uses its own slot; the system slot is given to the line unit, then
       the host, then the trace, decided from requests registered at the start of the cycle;
    4. a write into another block's registers (an execute write to line unit registers, the rule
       engine faulting a thread, a host write) is applied at the end of the cycle after the owner's
       own update, in the order owner, threads, rule engine, host, as in v1.0.

V3. The rule check of a commit is unchanged: a commit in cycle n is decided from the rule state
    after the events of cycle n-1. Events of cycle n (commit edges, wire edges, EMIT codes, line
    unit symbols) change the rule state seen by commits of cycle n+1. This is the property the
    enforcement proof rests on; the chip meets it by registering the events and forwarding the part
    of the next rule state the check needs (active, count below the minimum), not by changing it.

V4. The line unit is pipelined inside: its outputs (pins, symbols, verdicts, memory writes, status)
    follow its inputs by a fixed number of cycles, defined in `line.md` v1.1 from the measured depth
    of its stages. The number is the same for every output so that the unit's internal timing is
    unchanged relative to itself.

## 3. What changes for a program or a host

| item | v1.0 | v1.1 |
|---|---|---|
| verdict of the cycle in status bits 4 to 6 (BST, WAITS, IOR) | same cycle | next cycle |
| line unit status as seen by its owner | same cycle | next cycle |
| ownership or line unit write by execute, seen by another thread | same cycle | next cycle |
| EMIT seen by the trace | same cycle | next cycle |
| trace freeze on a verdict | same cycle | next cycle |
| host register read | after every block's update of the cycle | start of the cycle |
| rule check of a commit (V3) | rule state after cycle n-1 | unchanged |
| deadline exactness, pad edge cycle, commit order on a thread's own pins | | unchanged |
| line unit outputs (V4) | | later by the pipeline depth |

## 4. Work

1. `spec/model.ml`: a snapshot of the other blocks' registers at the start of `step`; merges of V2
   in the same order as v1.0.
2. Documents: `machine.md`, `rules.md`, `host.md`, `trace.md`, `line.md` sections that state
   same-cycle visibility; version 1.1.
3. `spec/circuit/`: the same change; lockstep cross-check re-run; `doc/spec/circuit.md` 4 rewritten.
4. Tests whose expectations depend on same-cycle visibility are re-derived from the documents, not
   from the new model's output.
5. Depth analysis re-run on the v1.1 circuit; the line unit's pipeline depth for V4 measured.
