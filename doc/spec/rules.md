# Rule engine and enforcement

Version 1.1 of 2026-11-21: registered block boundaries (`doc/decisions/spec_v1_1.md`); version 1.0
frozen 2026-11-16 (`doc/decisions/spec_freeze.md`). Executable form: `spec/model.ml` (`rules_update`, `may_fire`,
`record`); examples in `spec/test/test_rules.ml`. Read `machine.md` first.

**Visibility (v1.1).** The rule check of a commit is unchanged (`spec_v1_1.md`, V3): a commit in cycle
n is decided from the rule state after the events of cycle n-1, and the events of cycle n (commit edges,
wire edges, EMIT codes, line unit symbols) are processed at the end of cycle n. Verdicts found in one
cycle are merged in the order line unit, thread 0, 1, 2, rule engine, and the first is recorded, as in
v1.0 (V2). What changes is who sees the result when: threads (status bits), the trace (freeze) and the
host (registers 0x20 to 0x26, rule registers) see a verdict or a rule register from the cycle after it
was recorded.

## 1. What a rule is

A rule watches one interval: from a start event to a stop event, optionally cancelled by an abort event,
and checks its length against a minimum and a maximum. Each rule has a role:

- **guarantee**: something the chip promises. A violation is a FAIL.
- **assumption**: something the peer is expected to do. A violation is a BLAME.

Rules are loaded by the host into N rule slots (generator parameter, 4 or 8). Nothing in a rule is fixed
at tape-out.

## 2. Rule table entry

Six 16-bit words per rule.

| word | content |
|---|---|
| 0 | start selector, bits [9:0] |
| 1 | stop selector, bits [9:0] |
| 2 | abort selector, bits [9:0] |
| 3 | minimum, 0 to 65535 units; 0 disables the check |
| 4 | maximum, 0 to 65535 units; 65535 disables the check |
| 5 | [0] enable, [1] role (1 guarantee), [3:2] policy, [5:4] owner thread (3 none), [7:6] unit |

Policy: 0 observe, 1 hold to minimum, 2 fail-stop, 3 as 0. Unit: 16^unit cycles (1, 16, 256, 4096).
Every value of every word is defined: selector values not listed in section 3, including any with bits
[15:10] set, never fire.

## 3. Events

A selector is `[9:7]` class, `[6:5]` qualifier, `[4:0]` index.

| class | event in cycle n | index | qualifier |
|---|---|---|---|
| 0 | pin rises as read: 0 in cycle n-1, 1 in cycle n | pin 0..23 | 0 any, 1 the peer's, 2 our own |
| 1 | pin falls as read | pin 0..23 | as class 0 |
| 2 | a commit that fires in cycle n raises the value of the pin | pin 0..15 | 0 |
| 3 | a commit that fires in cycle n lowers the value of the pin | pin 0..15 | 0 |
| 5 | the rule's owner thread executes EMIT with this code in cycle n | code 0..31 | 0 |
| 6 | a line unit symbol in cycle n (`line.md`, section 7) | symbol 0..10 | 0 |

"As read" is the value a thread reads (`machine.md`, section 3): the synchronised input for P0..P7 and
P16..P23, the output value for P8..P15. A commit that fires in cycle n changes the pads in cycle n+1, so
class 2 and 3 events are one cycle ahead of the pad and are not delayed by the input synchroniser.

**Attribution** (qualifier 1 and 2, for bidirectional pins). An edge read in cycle n on P0..P7 is the
peer's iff the chip's driver for that pin was off in cycles n-1-F to n-4-F, where F is the pin's filter
length; otherwise it is our own. The window covers the two samples the edge lies between and one cycle
on either side for pad delay. Edges on P16..P23 are always the peer's, on P8..P15 always our own.

## 4. Length of an interval

With unit u = 16^unit, an interval that started in cycle n0 has, in cycle n, the length

    L(n) = floor(n / u) - floor(n0 / u)        (saturating at 65535)

For u = 1 this is n - n0 exactly. For larger units it counts the boundaries of a chip-wide divider of
`now`, so a real duration d and its measured length satisfy (L - 1) * u < d < (L + 1) * u.

## 5. The rule automaton

Each enabled rule is idle or active. In every cycle n, with the events of that cycle:

1. If active: an abort event makes it idle. Otherwise, if L(n) > maximum, it records a maximum violation
   and becomes idle. Otherwise, on a stop event, it records a minimum violation if L(n) < minimum, updates
   the observed minimum and maximum with L(n), and becomes idle. Otherwise it stays active.
2. Then, if it is idle (including having just become idle) and there is a start event, it becomes active
   with n0 = n.

So one event may be both stop and start (period measurement), abort has priority over everything, and a
stop event while idle is ignored. A disabled rule is idle.

## 6. Verdicts

- Per rule, sticky: minimum violated, maximum violated, repaired (section 7); and the observed minimum and
  maximum of all completed intervals.
- Chip-wide: the first FAIL and the first BLAME, each with rule number, kind (minimum or maximum) and
  cycle; and whether a BLAME was already recorded when the first FAIL occurred. A fail after a blame
  points at the peer; a fail without one points at the firmware.
- With policy fail-stop, a violation recorded by the automaton faults the rule's owner thread with RULE.

## 7. Enforcement at the pad

Every change of a pad register is a commit that fires (`machine.md`, section 5), and a commit fires only
if the rule engine lets it. In cycle n the pending commit of a thread is **blocked** iff there is a rule
that is enabled, a guarantee, with policy hold or fail-stop, active, with L(n) < minimum, whose stop
selector is class 2 or 3 for a pin on which that commit would make exactly that edge.

- **Hold.** The commit stays pending and fires in the first cycle in which it is not blocked. The
  blocking rules get their repaired flag. If it was a deadline commit, t is set to the cycle in which the
  pads actually change, so the distances the program asked for after that edge are kept.
- **Fail-stop.** A FAIL is recorded and the thread faults with RULE. Its staged set is replaced by the
  safe pattern of its pins, which is a pending commit like any other: if the safe pattern contains the
  same edge, it waits until the minimum is reached.
- **Observe.** Nothing is blocked; the automaton records the violation when the stop event occurs.

The blocking decision uses only registered state of cycle n (rule state, the staged set, the pad
registers). A commit that is not blocked fires in the cycle it would fire in without any rule.

What this gives, stated for one rule with policy hold or fail-stop, a class 2 or 3 stop selector and
unit 1:

- **Sound.** If a stop edge fires in cycle n1 while the rule is active with start cycle n0, then
  n1 - n0 >= minimum. The pad shows that edge in cycle n1 + 1; if the start is also a commit edge, the
  pad showed it in cycle n0 + 1, so the distance on the pads is at least the minimum. (A start and a stop
  event in the same cycle do not form an interval, section 5.)
- **Transparent.** If no commit of a run is ever blocked, the pads are identical, cycle for cycle, to the
  same run with all rules disabled.

What it does not give:

- Maxima cannot be enforced (the chip would have to invent an edge); they are recorded, and with
  fail-stop they stop the thread.
- A rule whose stop selector is not a commit edge is observed only.
- Changes of an output enable are not events. For an open-drain pin, pulling low and releasing are value
  edges and are covered; releasing a push-pull pin is not.
- Host reconfiguration (pin owner, safe pattern) acts on pads directly.

## 8. What a thread sees

- Status bits: 4 a FAIL is recorded, 5 a BLAME is recorded, 6 some rule was repaired. They can be
  branched on (BST) and waited for (WAITS). A thread cannot clear them.
- I/O registers, read-only, for rule k: `0x20 + 4k` flags ([0] active, [1] minimum violated, [2] maximum
  violated, [3] repaired); `+1` observed minimum; `+2` observed maximum; `+3` current length.
- EMIT codes 0 to 31 are events for rules owned by the emitting thread, so firmware can start, stop or
  abort a rule at a protocol-level moment (for example: abort on a bus reset).

## 9. State and cost

Per rule: table entry 70 bits (3 x 10 selector, 2 x 16 limits, 8 control); state 52 bits (active, 16-bit
length, three flags, two 16-bit observations). 122 bits per rule: 488 for 4 rules, 976 for 8. Chip-wide:
two verdict records of 37 bits and one flag, 75 bits; driver history for attribution, 7 cycles x 8 pins,
56 bits.

This is above the 105 bits per rule assumed in the area budget. The two observation registers (32 bits)
are the part that can be dropped or kept only for some slots; that is decided with the skeleton run.

## 10. Examples

| purpose | start | stop | limits | role, policy |
|---|---|---|---|---|
| our clock low time of at least 4.7 us at 48 MHz | commit lowers SCL | commit raises SCL | min 226 | guarantee, hold |
| peer's pulse at least 8 cycles | pin rises, peer's | pin falls, peer's | min 8 | assumption, observe |
| we answer within 30 cycles | pin rises | commit raises our pin | max 30 | guarantee, fail-stop |
| bit period, measured | pin falls | pin falls | none | assumption, observe |

## 11. Tests

| test | shows |
|---|---|
| an interval rule measures exactly | L for unit 1 and unit 16 |
| hold, fail-stop and observe on the same program | a 10-cycle pulse under minimum 20: recorded, stretched to 20, or stopped with the safe pattern held to 20; a 30-cycle pulse is untouched |
| hold: sound and transparent on random programs | 300 random pulse trains: no minimum violated on the pads; compliant programs unchanged |
| assumption violated by the peer | BLAME with rule and cycle; a thread waiting on status bit 5 reacts |
| maximum: a late response is a fail | FAIL of kind maximum in the cycle the length exceeds it |
| attribution on a shared open-drain line | the peer's and our own low pulses are told apart |
| rule measurements are readable by a thread | I/O registers 0x20.. |

## 12. Open points

1. (closed) Line-unit symbols are class 6 events. Edges made by the line unit are class 2 and 3 events;
   a hold or fail-stop rule that would keep one back stops the unit instead (`line.md`, section 4).
2. Whether the blocking decision, which sits in front of the fire decision and the execute stage, meets
   48 MHz. Fallback: compute it one cycle ahead; every input is a register, and L changes by at most one
   per cycle.
3. Number of slots and whether every slot has observation registers (skeleton run).
4. The trace is frozen on the first verdict; defined in the trace document.
