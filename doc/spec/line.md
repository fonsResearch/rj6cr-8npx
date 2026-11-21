# Line unit and response rules

Version 1.1 of 2026-11-21: registered block boundaries (`doc/decisions/spec_v1_1.md`); version 1.0
frozen 2026-11-16 (`doc/decisions/spec_freeze.md`); changed only together with
`spec/model.ml` (`line_cycle`) and `spec/circuit/`. The line unit sends and receives frames of a bit-serial line code at rates the
threads cannot reach (down to one bit per cycle), and two response rules answer inside a frame without
an instruction being executed. Registers, pins and time are as in `machine.md`.

Every statement below is implemented in the model; section 9 lists the tests and what they measured.

**Visibility (v1.1).** The line unit is a block (`spec_v1_1.md`, V1); it already runs on the register
values at the start of the cycle (v1.0). Writes by its owner thread (IOW) or the host to line unit
registers are seen by every reader from the next cycle; the owner's status word is taken at the start
of the cycle as before. Open: the unit's internal pipeline (V4) and its fixed output latency are fixed
after the depth of its stages is measured on the v1.1 circuit; until then this document describes the
unit without it.

## 1. Ownership and access

- The unit has one owner thread (host register, section 3; value 3: none). Only the owner can address
  the unit's I/O registers; for any other thread they are the fault IOPERM. The unit works in the
  owner's data window and drives only pins the owner owns.
- If the owner is faulted the unit is off: transmitter and receiver stop, and the pins take the safe
  pattern through the fault path of `machine.md`.
- A thread reads the registers as they are in its execute cycle; what it writes is seen by the unit in
  the next cycle. The host reads and writes them through the host port (`host.md`).
- The unit's memory accesses use the system slot of the data memory. Order of the users of that slot:
  line unit, host, trace. The unit needs at most one access per 16 bits in each direction.

## 2. Status bits of the owner

Status bits 7 to 13 (`machine.md`, section 8) read 0 for every thread except the owner:

| bit | meaning |
|---|---|
| 7 | transmitter busy |
| 8 | receiver inside a frame |
| 9 | a frame was received (sticky) |
| 10 | a frame or reply was sent (sticky) |
| 11 | any error flag of register 0 is set |
| 12, 13 | response rule 0, 1 has fired (sticky) |

## 3. Registers

Register j is I/O register 0x40 + j for the owner and host register 0xC0 + j.

| j | name | bits |
|---|---|---|
| 0 | command (write) | 0 start a frame, 1 arm the receiver, 2 stop the transmitter, 3 stop the receiver, 4 clear the sticky flags |
| 0 | status (read) | 0 transmitter busy, 1 receiver armed or hunting, 2 receiver inside a frame, 3 frame sent, 4 frame received, 5 its CRC was good, 6 stuffing violated, 7 a received word was lost, 8 a word to send was missing or outside the window, 9 the transmitter was stopped by a rule, 10 a reply was lost, 12 and 13 response rule 0 and 1 fired |
| 1 | control | 0 re-arm the receiver after each frame, 1 pin pair, [3:2] code (0 NRZ, 1 NRZI, 2 Manchester), 4 invert the line, 5 idle level, 6 least significant bit first, 7 stuffing, [10:8] run length (0 means 8), 11 count only ones, 12 stuff after the last bit too, 13 bit clock from a pin, 14 that clock samples on its falling edge, 15 release the pins after a frame |
| 2 | period | bit period in sixteenths of a cycle, at least 16 |
| 3 | pins | [3:0] transmit pin P0..P15, [8:4] receive pin P0..P23, [13:9] clock pin P0..P23 |
| 4 | CRC polynomial | left-aligned in 16 bits, without the leading term |
| 5 | CRC mode | [4:0] width 0..16, 5 start from all ones, 6 send complemented |
| 6 | CRC remainder | the register value that counts as good, left-aligned |
| 7 | transmit base | first word of the frame, relative to the owner's data window |
| 8 | transmit length | data bits, 0..16383 |
| 9 | tail | [2:0] number of tail symbols 0..4; [9:8], [11:10], [13:12], [15:14] their levels (transmit pin, partner) |
| 10 | receive base | first word for received bits, relative to the owner's data window |
| 11 | receive size | words available, 0..2047 |
| 12 | start pattern | [7:0] pattern, [11:8] its length 0..8 |
| 13 | end conditions | 0 both lines of a pair low, 1 stuffing violated, 2 no edge for more than [15:8] bit times, 3 length reached |
| 14 | receive length | bits, for end condition 3 |
| 15 | recovery | [7:0] largest phase correction per edge in cycles (255: every edge is taken as a bit boundary), [9:8] sample point k: period/2 + k period/8 |
| 16 | protected length | number of received bits that are destuffed and covered by the CRC; 0: all |
| 17 | CRC start | [7:0] first transmitted bit, [15:8] first received bit that enters the CRC |
| 18 | received bits | read only |
| 19 | last 16 received bits | read only, the newest in bit 0 |
| 20 | receive CRC register | read only |
| 21 | sent bits | read only |
| 22 | owner | host only: thread 0..2, 3 none |
| 32 + 8k | response rule k: control | 0 enable, 1 one shot, [3:2] position (0 any, 1 at, 2 at or after), 4 CRC register must equal the remainder, 5 test at the end of the frame instead of at each bit, [9:6] pattern length 0..8, [13:10] delay in bit boundaries; reads bit 15 = fired |
| 33 + 8k | pattern | [7:0] value, [15:8] mask, compared with the newest received bits |
| 34 + 8k | position | number of bits received, including the current one |
| 35 + 8k | reply | up to 16 bits, bit 0 first |
| 36 + 8k | reply length | [4:0] 1..16, 5 send the tail after the reply |

Writing a response rule's control word clears its fired flag. Any other index reads 0 for the host and is
IOPERM for a thread.

## 4. Transmitter

- **Start.** With a non-zero length the unit reads the first word in the next system slot and begins the
  frame in the following cycle; every further word is read ahead while the previous one is sent. A word
  outside the owner's window, or one that did not arrive in time, is sent as zeros and sets status bit 8.
- **Time.** The first bit is on the pads one cycle after the frame begins. Bit k begins
  `ceil(k * period / 16)` cycles after the first, so the average rate is exact and no boundary is early.
  With the clock from a pin, a bit begins after each shift edge of that pin as read.
- **Order within a frame.** Data bits (word by word, bit 0 or bit 15 first), CRC bits from the top of the
  CRC register, tail symbols, end. Before each of them a stuff bit is sent if the run is complete: after
  N equal bits the opposite bit, or with "count only ones" a 0 after N ones. After the last bit a stuff
  bit is sent only with control bit 12.
- **CRC.** A 16-bit register, left-aligned: for each bit d from the first counted bit on,
  `fb = top bit xor d`, shift left, xor the polynomial if fb. Stuff bits are not counted.
- **Coding.** NRZ: the level is the bit. NRZI: the level changes for a 0. Manchester: the first half of
  the bit time is the complement of the bit, the second half the bit. The invert bit applies to all
  three. On a pair the partner pin (transmit pin + 1) carries the complement; tail symbols give both
  levels explicitly.
- **End.** After the tail the unit sets "frame sent", and either drives the idle level or, with control
  bit 15, releases the pins (direction off for P0..P7).
- **Pins and rules.** While it sends, the unit and not the thread decides the value and direction of its
  pins; commits of the thread to those pins are dropped in those cycles. The unit's edges are commit
  events (`rules.md`, class 2 and 3), so rules observe and judge them like a thread's. An edge that a
  hold or fail-stop guarantee rule would keep back is not made: the transmitter stops, sets status bit 9,
  and a fail verdict is recorded. The unit cannot be delayed, since the line code fixes its timing.

## 5. Receiver

- **Start of a frame.** After "arm" the receiver waits until it has read the idle level, then for the
  first cycle with another level; that cycle is phase 0 of the first bit (for Manchester, the middle of
  the first bit). With the clock from a pin the frame starts at once.
- **Bit clock.** A phase accumulator advances by one cycle per cycle and wraps at the period. The line is
  sampled when the phase passes the sample point. An edge of the line inside a frame corrects the phase
  by at most the amount in register 15, towards making the edge a bit boundary; with 255 every edge sets
  the phase to 0. For Manchester only an edge in the middle half of the bit time counts, and it sets the
  phase to the middle.
- **Decoding.** NRZI: a bit is 1 if the level equals the level at the previous sample. Stuffing: when the
  run is complete the next bit must be the stuff bit and is dropped; if it is not, status bit 6 is set
  and the bit is kept (or the frame ends, with end condition 1).
- **Start pattern.** With a pattern length the receiver first hunts for the pattern in the decoded bits;
  the pattern bits are not stored or counted. Without one the frame's first bit is its first data bit.
- **Data.** Bits are assembled into 16-bit words and written to the receive window, one word per 16 bits
  and the remainder at the end. A word that does not fit the window or the size, or that finds the
  previous one still waiting for its slot, is dropped and sets status bit 7.
- **End of a frame.** By any enabled end condition, or after 16368 bits. The unit sets "frame received"
  and "CRC good" if the CRC register equals register 6, and re-arms itself with control bit 0. A frame
  that ends before its start pattern was found is discarded, and the receiver stays armed.

## 6. Response rules

A rule is tested at each stored bit, or at the end of the frame (control bit 5). It fires if it is
enabled, the position condition holds, the newest bits match the pattern under the mask, and, if
required, the CRC register equals the remainder. If both rules would fire in one cycle only rule 0 does.

When a rule fires its flag is set, a one-shot rule disables itself, and the transmitter, if idle, waits
for the given number of bit boundaries of the receive clock and then sends the reply bits through the
coder and the stuffer, optionally followed by the tail. With delay 0 the pads change two cycles after
the cycle in which the bit was sampled. If the transmitter is busy the reply is lost and status bit 10
is set.

What a rule cannot do: test a pattern and the end-of-frame CRC together. A protocol that needs both (a
handshake only for a matching address) uses rule 0 for the pattern and lets the firmware enable rule 1
when rule 0 has fired (status bit 12); see open point 2.

## 7. Events for the rule engine

Selector class 6 (`rules.md`, section 3), qualifier 0:

| index | event in cycle n |
|---|---|
| 0 | a received bit was stored |
| 1 | a received frame started (after its start pattern) |
| 2 | a received frame ended |
| 3, 4 | it ended with a good, a bad CRC |
| 5 | stuffing was violated |
| 6 | a transmitted bit began |
| 7, 8 | a transmitted frame or reply began, ended |
| 9, 10 | response rule 0, 1 fired |

## 8. State

| group | registers | bits |
|---|---|---|
| configuration | control | 16 |
|  | bit period | 16 |
|  | pins | 14 |
|  | CRC polynomial, mode, expected remainder | 39 |
|  | CRC start positions | 16 |
|  | transmit window base, length, tail | 35 |
|  | receive window base, size | 21 |
|  | start pattern, end conditions, length, protected length | 52 |
|  | resynchronisation and sample point | 10 |
| | subtotal | 219 |
| response rules | two response rules: control, pattern, position, reply, length, fired flag | 134 |
| | subtotal | 134 |
| transmitter | transmit state, phase accumulator, boundary | 20 |
|  | bit counter, current and next word, fetch request | 58 |
|  | CRC register and counter | 21 |
|  | stuffing run, coder, half bit, tail counter, output levels, release | 14 |
|  | reply delay, counter, shift register, tail flag | 26 |
|  | flags | 4 |
| | subtotal | 143 |
| receiver | receive state, idle seen, phase accumulator | 19 |
|  | level, previous level, start-pattern counter | 6 |
|  | bit counter, word being assembled, last 16 bits | 46 |
|  | CRC register | 16 |
|  | stuffing run, idle counter | 14 |
|  | word waiting for the system slot | 27 |
|  | flags | 4 |
| | subtotal | 132 |
| other | owner, command bits, rule fired in the previous cycle | 9 |
| | subtotal | 9 |
| | **total** | **637** |

The architecture budget gave the line unit and the response rules 50.3k um^2 of local synthesis area.
637 bits held in enable flip-flops are 42.8k um^2 before any logic (67.13 um^2 per bit,
typical liberty), so this draft does not fit that budget as it stands. That is an estimate from the bit
count, not a synthesis result; the specification circuit will give the number. The reductions, in order
of what they cost in function, are in open point 1.

## 9. Tests

`spec/test/test_line.ml`, on the model. The peers and the reference encoders (stuffing, NRZI, the two
CRCs) are written in the test, independently of the model.

| test | measured |
|---|---|
| NRZ transmit | bit k begins `ceil(k * period)` cycles after the first for periods of 4, 6.5 and 1 cycle |
| USB-style packet, loop back | 113 line bits equal to the reference encoder (9 stuff bits), complement on the partner pin, two bit times with both lines low, idle, release; CRC16 equal to the reference; the same unit receives all 96 bits with a good CRC |
| USB-style receive from a peer | 40 random packets at 4 cycles per bit with the peer clock at -0.25 %, 0 and +0.25 %: all received with edge jitter up to +-0.5 cycle; at +-1 cycle 12, 40 and 11 of 40 |
| wrong CRC, missing stuff bit | each sets its flag; the frame is still delivered |
| USB-style handshake | reply (SYNC, ACK, end of packet) equal to the reference, starting 3.5 bit times after the peer's lines return to idle; no reply after a wrong CRC |
| CAN-style frame | a 50-bit frame with stuff bits from a peer 1 % slow is received with CRC register 0; the response rule drives the acknowledge bit for 48 cycles, beginning 1.5 cycles into the peer's slot |
| UART receive | two frames, re-armed in between |
| Manchester transmit | 2 cycles per half bit |
| Manchester receive from a peer | at 8 cycles per bit, peer clock at -1 %, 0, +1 %: all 30 frames with jitter up to +-0.5 cycle, 1 to 3 of 30 at +-1 cycle. At 4 cycles per bit, peer clock at -0.01 %, 0, +0.01 %: all 30 without jitter, 12 to 16 of 30 at +-0.25 cycle |
| pin-clocked receive | an address byte clocked by a pin; the reply pulls the data line low 3 cycles after the eighth falling clock edge and releases it 3 cycles after the ninth; no reply for another address |
| a forbidden edge | the transmitter stops, the pad keeps its level, a fail verdict is recorded |
| from a program | the first bit is on the pad 4, 7 and 6 cycles after the start instruction executes for thread 0, 1 and 2; IOPERM for a thread that is not the owner |
| system slot | at one bit per cycle 240 bits are received and stored while the trace records |
| symbols as rule events | a rule measures frame start to frame end as 247 to 248 units of 16 cycles for 9.5 bit times of 416.67 cycles |
| response rule with delay 0 | commit event one cycle after the rule fires, pad change one cycle later |

Limits these results show:

- Manchester receive at 4 cycles per bit (10 Mbit/s at a 40 MHz clock) does not tolerate a quarter cycle
  of jitter. It needs the both-edge input sampling of the feature increments; transmit is not affected.
- The clock recovery was exercised with uniform random edge displacement, not with a model of a real
  line receiver, and not with a noisy line.

## 10. Decisions taken in this document

| # | decision | alternative, and its cost |
|---|---|---|
| L1 | one unit, half duplex in practice: a reply and a frame use the same transmitter | a separate reply path, about 40 more state bits |
| L2 | the unit stops when a rule forbids its edge | delaying it would break the line code for the peer |
| L3 | words in the owner's data window, fetched and stored in the system slot | a FIFO to the thread costs state and an instruction per word |
| L4 | CRC as a left-aligned 16-bit register, bit serial | 32-bit CRCs (Ethernet) are left to the thread's CRC instruction |
| L5 | stuffing by run of equal bits or run of ones, one length | covers the CAN and USB forms; other stuffing is firmware |
| L6 | clock recovery as a phase accumulator with a bounded correction per edge | an oversampling majority vote costs a shift register per sample |
| L7 | response rules test the newest 8 bits, a position and the CRC | longer patterns cost 2 bits of state per pattern bit |
| L8 | the owner register is host configuration | letting a thread claim the unit needs an arbitration rule |

## 11. Open points

1. Area (section 8). Reductions: configuration held in latches instead of flip-flops; one response rule;
   a 12-bit period; no pin-clocked mode; no separate protected length. To be decided on the synthesis
   result of the specification circuit.
2. A condition "rule 0 has fired in this frame" for rule 1, so that a handshake for a matching address
   needs no instruction in between (one control bit and one state bit).
3. Transmit abort on a readback mismatch (arbitration on a shared line) is not in this draft.
4. Sampling on both clock edges for Manchester receive at 4 cycles per bit.
