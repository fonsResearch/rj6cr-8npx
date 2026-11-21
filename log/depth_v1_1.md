# Logic depth of the specification circuit, version 1.1

Tool: a logic-depth count over the Hardcaml graph of `Step.step` (scratch, not in the repository):
adders and comparators cost about 2 log2(width) levels, a k-way mux log2(k) + 1, gates 1. Levels are
relative. Calibration: on the routed skeleton run 44777903562, 253 levels were 39.06 ns at the slow
corner, about 0.15 ns per level. At 20.83 ns this puts the budget near 130 levels at the slow corner
(estimate from one calibration point; wires, fan-out and the real cell mapping are not modelled).

## 1. Whole cycle

| circuit | deepest endpoint | levels | slow corner, estimate |
|---|---|---|---|
| v1.0 | blame/fail through every block | about 510 | about 79 ns |
| v1.1 | `fail_valid` | 357 | about 54 ns |
| v1.1, line unit outputs registered (V4) | `th_st` (owner fault) | 148 | about 22 ns |
| v1.1, line unit outputs and rule engine inputs registered | `hstat` (host) | 123 | about 18 ns |

## 2. Each block alone (all block boundaries cut)

| block | levels | deepest output |
|---|---|---|
| line unit | 243 | verdict, symbol mask (`tmp.l_mask` 234) |
| thread fetch to timing | 31 | data enable |
| thread timing | 63 | 32 of them are the serial verdict merge (3) |
| thread execute | about 72 | thread state |
| rule engine | about 60 | thread state (fail-stop) |
| trace | about 31 | trace record |
| host | 123 | `hstat`; program window digest and loaded flag 107, CRC 99 |

## 3. Chains that remain in v1.1

1. **Verdict merge.** The circuit records verdicts one after another (line unit, then up to eight
   candidates per thread in timing, then the rule engine), each step reading the `fail.valid` the
   step before wrote: about 4 levels per candidate, 32 per thread, 112 from the line unit to the end.
   This is a structure of the specification circuit, not of the specification: the first-wins merge
   of V2 is a priority select over candidates that are computed in parallel. No change of the
   specification is needed.
2. **Line unit.** 243 levels inside one block. V4 pipelines it; at about 130 levels per stage this is
   at least two stages (estimate). The stage boundaries and the latency are not fixed yet.
3. **Events, rule engine, owner fault.** Thread timing decides the commit (`t_int` 52 levels), execute
   produces the EMIT code (99), the codes of the three threads are merged (105), the rule engine's
   automaton finds a violation and faults the owner thread with RULE (145 to 148). Commit edges take
   the same route with a shorter front. V3 keeps the commit check (blocking) on the rule state after
   the events of cycle n-1, which registered events plus forwarding meet. V3 does not cover the
   automaton's own result: in v1.1 an event of cycle n that violates a rule records the verdict and
   faults the owner in cycle n, so the owner's pins hold the safe pattern from n + 1 (`machine.md` 9).
4. **Host.** 123 levels inside the host block, from its registered inputs. Under the budget, with
   little margin (estimate).

## 4. After the amendment of V3 (automaton one cycle behind its events)

With the line unit's outputs cut (V4), the deepest endpoint not in the verdict merge is 132 levels
(`th_st`, `th_sv`, `th_sm`): thread 0's own timing and execute (101 levels at the end of its execute),
then 28 levels in the RULE fault application, which the specification circuit writes as twelve
conditional updates in a row (4 rules by 3 threads), each reading the thread state the one before
wrote. The chip applies them as one override of the thread state (a few levels), which leaves about
105 levels (estimate). No chain passes through the automaton any more. The rule engine's step
from its registered inputs feeds the commit checks of the line unit and the threads.
