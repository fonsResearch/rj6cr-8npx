# Cross-check: reference model against specification circuit

Method: `doc/spec/circuit.md`, section 2. Every register and every pad output compared in every cycle;
memories compared at the end; at most one user per memory port per cycle.

## Campaigns of 2026-11-21, specification v1.1

Same scenarios, seeds and session counts as 2026-11-16. Session lengths are set by the stimulus and
are the same as for v1.0. Run twice, with the same result: on v1.1 as first written (commit c1e61a5)
and on v1.1 with V3 amended (the commit that adds this sentence; the comparison then also covers the
registered rule engine inputs `ri_*`).

| scenario | seed | sessions | cycles | mismatches | port conflicts | memory words differing |
|---|---|---|---|---|---|---|
| core | 11 | 20 | 1,338,592 | 0 | 0 | 0 |
| rules | 12 | 20 | 1,470,154 | 0 | 0 | 0 |
| frames | 13 | 20 | 1,807,441 | 0 | 0 | 0 |
| fuzz | 14 | 20 | 1,712,861 | 0 | 0 | 0 |
| directed | 21 | 8 | 777,360 | 0 | 0 | 0 |
| **total** | | **88** | **7,106,408** | **0** | **0** | **0** |

The coverage counts below are those of v1.0 and were not recounted for v1.1.

## Campaigns of 2026-11-16, specification v1.0

Run with `spec/circuit/xcheck/bin/xcheck.exe <scenario> <seed> <runs>` at the commit that adds this log.

| scenario | seed | sessions | cycles | mismatches | port conflicts | memory words differing |
|---|---|---|---|---|---|---|
| core: threads and host | 11 | 20 | 1,338,592 | 0 | 0 | 0 |
| rules: rules and trace | 12 | 20 | 1,470,154 | 0 | 0 | 0 |
| frames: line unit on a looped-back pin, rules, trace | 13 | 20 | 1,807,441 | 0 | 0 | 0 |
| fuzz: random register writes, random line unit registers | 14 | 20 | 1,712,861 | 0 | 0 | 0 |
| directed: hold rule on a pulse train; USB-style packets on P0 / P1 looped back | 21 | 8 | 777,360 | 0 | 0 | 0 |
| **total** | | **88** | **7,106,408** | **0** | **0** | **0** |

`dune test` runs 2 sessions of each of the first four scenarios (629,586 cycles; the test names the
frames scenario `line`) and the planted control.

## Coverage (counted on the model, summed over the sessions of a scenario)

| item | core | rules | frames | fuzz | directed |
|---|---|---|---|---|---|
| instructions fetched | 91,999 | 60,468 | 209,996 | 82,333 | 168,015 |
| instruction kinds fetched (of 48) | 48 | 48 | 44 | 48 | 25 |
| faults ILLEGAL / PCBOUND / DBOUND / PINOWN | 16 / 63 / 5 / 22 | 36 / 25 / 12 / 15 | 10 / 45 / 8 / 18 | 6 / 50 / 8 / 8 | 1 / 2 / 4 / 0 |
| faults LATE / IOPERM / TRAP / RULE | 33 / 28 / 26 / 0 | 56 / 72 / 8 / 1 | 34 / 11 / 7 / 14 | 44 / 36 / 6 / 3 | 14 / 10 / 4 / 0 |
| cycles with a thread waiting for an event | 18,268 | 823 | 50,120 | 135,150 | not counted |
| pad output changes | 378 | 532 | 7,350 | 2,369 | 12,947 |
| fail / blame verdicts | 0 / 0 | 8 / 4 | 7 / 6 | 11 / 4 | 0 / 0 |
| a hold rule repaired an edge | 0 | 0 | 0 | 0 | 5 |
| trace records | 0 | 21,703 | 34,362 | 28,936 | 20,954 |
| line unit: bits sent / frames sent | 0 / 0 | 0 / 0 | 8,740 / 352 | 1,764 / 30 | 6,479 / 85 |
| line unit: bits received / frames received | 0 / 0 | 0 / 0 | 9,944 / 1,138 | 1,283 / 15 | 728 / 11 |
| line unit: frames with a good CRC / stuffing errors | 0 / 0 | 0 / 0 | 0 / 750 | 0 / 62 | 11 / 0 |
| response-rule replies | 0 | 0 | 496 | 0 | 0 |

## Gaps

- Response-rule replies and a good receive CRC never occurred in the same session; the handshake of
  `test_line.ml` (reply only after a good CRC) has not been run in lockstep.
- Pin-clocked receive (clock from P19) ran only as part of the random line configurations; its count was
  not separated.
- Mailbox depth is 1 in all runs (the generator parameter is not varied).
- No session lasted past 2^32 cycles, so the wrap of `now` and of deadlines is not covered; it is a
  property for the proof step.
- The stimulus keeps the SPI clock at 10 to 16 cycles per period, inside the rule of `host.md`; faster
  SPI clocks are specified but not cross-checked.
