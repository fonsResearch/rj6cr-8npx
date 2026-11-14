# Macro probe

Branch `probe-macros`. Question: do the two SRAM macro types of the architecture, 512x32 for programs and
1024x16 for data, go through this flow on the 8x4 tile at 20.83 ns (ground truth item O1)? Only the
256x16 type has been through it before, on another design.

## 1. The probe design

`probe/macros/probe_macros.ml`, emitted to `src/probe_macros.v`: both macros, every macro pin driven from
a register, every output captured by a register, a 72-bit shift register on `ui_in` to set up one access,
a byte selector on `uo_out`. 449 cells, 10.3k um^2 of logic by local synthesis. `test/test.py` writes one
word to each macro and reads both back; it passes on the RTL with the PDK's behavioural models
(`test/models`, copies from the pinned PDK), and the same test runs on the gate-level netlist in CI.

## 2. Power: how the macros get it

The tile's power grid is vertical Metal4 stripes only. The macros take power on vertical Metal4 columns,
2.81 um wide: VDD! and VSS! alternating at 5.62 um, VDD! below a horizontal break at y = 38.8 to 45.5 um
and VDDARRAY! above it on the same columns. The two bit-cell halves of a macro have the same column pitch;
the band between them is irregular.

The method, taken over from the earlier design where it passed sign-off for the 256x16 type:

1. Stripe pitch 44.96 um (four column pitches), spacing 3.52, width 2.1, offset 6.15.
2. A macro x position at which stripes fall inside columns of the same polarity.
3. `PDN_OBSTRUCTIONS` for the stripes over the macro that do not.
4. The step `Tile.MacroColumnStripes` (`librelane_plugin_tile_pdn.py`, `flow/pdn`), after the PDN is
   generated, makes each aligned stripe one full-height stripe across the macro, and fails if a power
   shape over a macro is outside a same-polarity column, touches the other polarity, leaves a supply pin
   unconnected, or a power pin breaks the Tiny Tapeout full-height rule.

Facts from `flow/pdn/plan_macros.py` on the LEFs of the pinned PDK:

| macro | size (um) | aligned VPWR + VGND pairs | where |
|---|---|---|---|
| 512x32 | 416.64 x 191.34 | 8 | x = 48.0 + 134.88 k (10 positions on the tile); 4 pairs at 328 other positions |
| 1024x16 | 236.80 x 336.46 | 4 | the same x positions; 2 pairs at 373 others |

Placement in the probe: program macro at (48.0, 41.58), data macro at (587.52, 41.58), both in orientation
FS so that their signal pins face up, towards the logic. Six obstructions remove 8 of the 76 stripes. On
the stripe model the planned result has no violation of the property for either macro.

The full-height VPWR stripes cross the break between VDD! and VDDARRAY!. `flow/pdn/check_sram_bar_gds.py`
on the macro GDS of the pinned PDK: under all 12 VPWR footprints (8 and 4) the break has no Metal4 and no
Via3; the nearest Metal4 is 2.82 um away.

## 3. Timing data from the liberty files

Slow corner (1.08 V, 125 C), largest table values, read by a simple parser and to be replaced by the
flow's timing report:

| macro | clock to data out | address setup | data-in setup |
|---|---|---|---|
| 512x32 | 6.7 ns | 1.4 ns | 1.1 ns |
| 1024x16 | 7.4 ns | 1.4 ns | 0.9 ns |

At 20.83 ns this leaves about 13 ns after a read for logic in the same cycle. The data-out pins have a
maximum load of 0.064 pF.

## 4. Settings and decisions for the run

- Magic DRC stays on. Its deck has no exceptions for the inside of the IHP SRAM (on the earlier design
  it reported 7,817 errors inside a 64x16 macro), so `ERROR_ON_MAGIC_DRC` is 0: the errors are counted
  and reported without stopping the flow. The precheck runs the PDK's KLayout deck on the full layout.
- `ERROR_ON_ILLEGAL_OVERLAPS` 0 (stripes over the macro's obstruction at the break) and
  `ERROR_ON_PDN_VIOLATIONS` 0 (the check that runs before the stripes are extended), as on the earlier
  design.
- Macro halo 2.0 / 0.48 um, post-route design repair on with a 30 % capacitance margin, as on the
  earlier design. These are starting values, not tuned for 48 MHz.

## 5. Results

None yet.
