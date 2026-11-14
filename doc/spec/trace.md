# Trace

Draft 0.1 of 2026-11-14, not frozen. Executable form: `spec/model.ml` (`trace_cycle`,
`trace_records`); examples in `spec/test/test_trace.ml`.

## 1. What is recorded

A record is written when a pin selected by the trace mask changes as read (`machine.md`, section 3), or
when a thread executes EMIT. It holds the cycle and the pins, so the trace of a slow signal is its edge
list with exact cycle numbers. Records go into a window of the data memory that the host chooses, used as
a ring.

| word | content |
|---|---|
| 0 | `now[15:0]` of the cycle in which the change was read |
| 1 | `now[31:16]` |
| 2 | pins P0..P15 in that cycle |
| 3 | [15] lost; [14] kind. Kind 0, pin record: [7:0] pins P16..P23. Kind 1, EMIT record: [13:12] thread, [7:0] code |

## 2. Rate and loss

The four words of a record are written one per round, in the system slot of the data memory, and only in
slots the host port does not use. A record therefore takes 16 cycles or more.

- A change or EMIT while a record is being written is not recorded and sets a pending "lost" mark.
- When the writer is free and the mark is set, a pin record of the current cycle is written with its
  lost bit set, so the last record always shows the final pin state.
- A pin change and an EMIT in the same cycle give a pin record with the lost bit; of several EMITs in one
  cycle one is recorded, with the lost bit.

The trace is exact for edges at least 16 cycles apart on the selected pins (333 ns at 48 MHz) and says so
when it is not.

## 3. Freeze

With freeze enabled, the first verdict (FAIL or BLAME, `rules.md`) stops the trace after a set number of
further records have been completed, counting a record that was already being written. The verdict
registers give the rule and the cycle; the trace gives the waveform around it. An edge that causes a
verdict is read one cycle (output pins) or more (inputs, through the synchroniser) after the commit that
fired it, so at least 2 further records are needed to see it; the reset value is 4.

## 4. Host registers

| address | name | access | content |
|---|---|---|---|
| 0x30 | TR_CTRL | R/W | [0] enable, [1] freeze on verdict. Writing it restarts the trace: pointer 0, not wrapped, not frozen |
| 0x31 | TR_BASE | R/W | first word of the window in the data memory |
| 0x32 | TR_SIZE | R/W | records in the window, 0 to 256; 0 switches the trace off |
| 0x33, 0x34 | TR_MASK_LO, TR_MASK_HI | R/W | pins P0..P15 and P16..P23 whose changes are recorded |
| 0x35 | TR_PTR | R | [8:0] index of the next record, [15] the ring has wrapped, [14] frozen |
| 0x36 | TR_POST | R/W | records completed after the verdict before the freeze, 0 to 255 |

The host reads the window with the data-memory read command. The oldest record is at the pointer if the
ring has wrapped, else at index 0. A window that overlaps a thread's data window is the host's mistake.

## 5. State

Configuration 53 bits; pointer, flags and counters about 22; the record being written 64. About 140
bits.

## 6. Tests

| test | shows |
|---|---|
| the trace of the UART frame is its edge list | 11 edges, 11 records, same cycles and levels |
| edges faster than one record per 16 cycles | lost marks, and the final state in the last record |
| the trace is frozen after a verdict | records up to the set number after a blame, none later |
| the window is a ring | the newest records replace the oldest |

## 7. Open points

1. Slot order once the line unit streams into the data memory: line unit, host, trace.
2. Whether a record for the verdict itself is worth its 16 cycles (the verdict registers already hold it).
