## How it works

A reprogrammable protocol emulator. Three program threads share one four-stage pipeline, each executing
one instruction every four clock cycles. A thread stages pin writes and commits them on a deadline held in
a per-thread timer with a fractional period, so edges land on exact clock cycles. Programs are loaded by a
host over SPI into an on-chip SRAM. The architecture is described in `doc/decisions/arch_selection.md` and
the machine model in `doc/spec/machine.md`.

The pin assignment below is provisional.

## How to test

No test procedure exists yet: the RTL is not written. The executable specification is exercised with
`dune test`.

## External hardware

A host with an SPI controller, for example the microcontroller on the Tiny Tapeout demo board.
