# Ground truth

Facts this design relies on, each with its source and the date it was checked. A line is a **fact** only if
it was read from the named file or produced by the named command; everything else is listed under open
items until it is.

## 1. Flow and template (checked 2026-11-13, GitHub API)

| item | value | source |
|---|---|---|
| project template | TinyTapeout/ttihp-verilog-template `4b1204ab` (2026-10-28) | repository head |
| action | `TinyTapeout/tt-gds-action@ttihp27a` (`e7a50f8f`) | template workflows |
| tools | tt-support-tools `9d13ff3e`; LibreLane 3.1.0.dev4 for ihp-sg13cmos5l | action at that tag |
| PDK | IHP-GmbH/IHP-Open-PDK `89d42ee6d2fd9b50b86a1aada6fee6673c3e6008` (2026-10-16) | pinned by the precheck |
| valid tile sizes | include 8x4 | template `info.yaml` |
| template defaults | `CLOCK_PERIOD` 20, `PL_TARGET_DENSITY_PCT` 60, hold margins 0.1 / 0.05 | template `src/config.json` |

## 2. Tile (checked 2026-11-11, `tech/ihp-sg13cmos5l/def/tt_block_8x4_pgvdd.def`, tt-support-tools main)

- Die 1724.16 x 710.64 um.
- All 43 signal pins are on the top edge between x = 29.8 and 191.0 um, i.e. in the top-left corner.
- Project routing layers Metal2 to Metal4; Metal3 is the only horizontal one; Metal4 also carries the power
  stripes.
- Power pins (pin check, same rules on the main and the ihp-sg13cmos5l branch of the tools): Metal4, at
  least 2.1 um wide, within 10 um of both the top and the bottom edge, inside the die.

## 3. Memory macros (checked 2026-11-13, PDK revision above)

`ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` is a link to the SG13G2 SRAM library. 30 macros have LEF, GDS and
liberty, among them single-port 64x16, 256x16, 256x32, 512x16, 512x32, 1024x8, 1024x16 and dual-port
256x16, 512x16, 512x32, 1024x16.

LEF sizes at that revision (`ihp-sg13g2/libs.ref/sg13g2_sram/lef`):

| macro | size (um) | area (um^2) |
|---|---|---|
| 256x16 single-port | 236.8 x 118.78 | 28,127 |
| 256x32 single-port | 416.64 x 118.78 | 49,488 |
| 512x16 single-port | 236.8 x 191.34 | 45,309 |
| 512x32 single-port | 416.64 x 191.34 | 79,720 |
| 1024x16 single-port | 236.8 x 336.46 | 79,674 |
| 1024x8 single-port | 146.88 x 336.46 | 49,419 |
| 64x16 single-port | 236.8 x 64.36 | 15,240 |
| 256x16 dual-port | 419.95 x 136.97 | 57,521 |
| 512x16 dual-port | 402.61 x 219.77 | 88,482 |

## 4. Standard cells (checked 2026-11-13, `sg13cmos5l_stdcell_typ_1p20V_25C.lib`)

| cell | area (um^2) |
|---|---|
| `dfrbpq_1` flip-flop with reset | 48.99 |
| `mux2_1` | 18.14 |
| flip-flop bit with enable (the two above) | 67.13 |
| `dlhq_1` / `dlhrq_1` latches | 30.84 / 27.22 |
| `lgcp_1` clock gate | 27.22 |

## 5. Hardcaml (v0.17.1, opam switch `hardcaml`, OCaml 5.3.0)

- `Reg_spec.create ?clear ?reset () ~clock`; the clock edge is set with
  `Reg_spec.override ~clock_edge:Edge.Falling`. The Verilog writer emits `always @(negedge clock)` for it.
- **Cyclesim ignores the clock edge.** `probe/edges` (2026-11-13) builds `r0 -> qf (falling) -> qfr` next
  to `r0 -> qr1 -> qr2`. Icarus on the emitted Verilog gives `qfr = qr1` (one cycle after `r0`); Cyclesim
  gives `qfr = qr2` (two cycles) and raises no error. A block with falling-edge registers therefore cannot
  be simulated or expect-tested in Cyclesim as written; see open item O2.
- The library has no latch primitive; a latch can only enter a design as an instantiated library cell.

## 6. Routed density reached before (earlier 6x4 design, same flow family, 30 MHz)

Utilisation = (routed standard cells + macros) / core. Routed with margin at 43.5 to 48.6 %; routed with
+0.5 ns slow slack at 53.5 %; did not converge near 68 %. Routed cell area was 1.33 x local synthesis.
Nothing has been routed at 48 MHz or on 8x4 with this design.

## 7. Continuous integration

- The hardening workflow of the earlier 6x4 design took a median of 240 minutes wall time per run (12
  runs, GitHub API run timing).
- While this repository was private (until 2026-11-14) the docs and test workflows failed only at the
  artifact upload: the account's artifact storage quota was exhausted. Since it is public both pass.
- The hardening workflow is started by hand (Actions tab or API), not by a push.
- **First hardening run, 2026-11-14** (run 43545793352, commit 84cfbe5: the template's example design as
  placeholder, template settings, 8x4, 20.83 ns). All four jobs passed.
  - gds job 54.9 minutes, of which Magic DRC about 47 on an almost empty tile, with no errors. Magic DRC
    is the only DRC inside this job with the template settings (`RUN_KLAYOUT_DRC` is 0).
  - Floorplan: die 0 0 1724.16 710.64, core 2.88 3.78 1721.28 706.86, core area 1,208,172.672 um^2.
  - Precheck 18 minutes, passed. It runs the IHP-SG13CMOS5L KLayout DRC runset (FEOL, BEOL, pin and
    forbidden-layer rules, about 16 minutes), then zero-area, top macro name, forbidden layer,
    prBoundary, pin and Verilog syntax checks.
  - Gate-level test passed.
- Decision 2026-11-14: Magic DRC stays on, and the hardening job has no time cap of its own (GitHub's
  limit for a job is 6 hours).

## 8. Local tools

Checked 2026-11-13 by running the tools: Yosys 0.69 (git 9f75ca1f) and Icarus Verilog 13.0 under
`.toolchain/eda`; dune 3.24.2; hardcaml and ppx_hardcaml v0.17.1, hardcaml_verify v0.17.0, ppx_expect
v0.17.3, core v0.17.2. SymbiYosys is installed there but was not exercised today. `test/requirements.txt`
pins cocotb 2.0.1 and pytest 8.4.2.

## 9. Open items

| # | item | state |
|---|---|---|
| O1 | 512x32 and 1024x16 macros through this flow and the precheck (only 256x16 has been) | closed 2026-11-14 by run 43581583299 on branch `probe-macros` (section 10; full record in `log/macro_probe.md` on that branch) |
| O2 | how to verify falling-edge registers, given the Cyclesim result above | deferred 2026-11-15 to the feature-increment step: only the both-edge receive front end needs falling-edge registers (`line.md`, section 9), so the minimum chip has none and needs no answer. The options stay as listed in the increments log: no falling-edge registers; a two-phase Cyclesim model at twice the clock with a proof against the emitted Verilog; Verilog-level simulation and formal for that block only |
| O3 | latch storage from an instantiated cell: simulation model, emitted Verilog, equivalence method | deferred 2026-11-15 to the skeleton gate: it is a reduction, worth about 2 points of utilisation on the budget estimate, and is worked out only if the skeleton shows that the area is needed |
| O4 | core area from a real 8x4 floorplan report | closed 2026-11-14: 1,208,172.672 um^2 (section 7) |
| O5 | pad and clock frequency limits on this shuttle | closed 2026-11-15 as an estimate, not a measurement: the competition FAQ (updated 2026-11-09) quotes Tiny Tapeout's estimate of about 10 ns round trip through pads and mux and a maximum output frequency of about 66 MHz, notes that no CMOS5L silicon is back, and says that a 60 MHz clock was confirmed. At 48 MHz an output may change every cycle (at most a 24 MHz square wave). Every pin-to-pin latency in the specifications counts cycles inside the tile; the pads add about 10 ns (about half a cycle) on top |
| O6 | flow settings at 20.83 ns: setup margins, post-route repair, fanout and wire-length limits, macro halos | open; moves to the skeleton step, which is the first realistic load. Carried in from the macro probe: maximum-capacitance violations on macro data outputs, hold cells in front of macro inputs |
| O7 | where hardening runs execute | closed 2026-11-14: this repository, public, standard runners |
| O8 | whether the shuttle submission requires a public repository | closed 2026-11-15: the competition's rules ask for an open-source submission and a link to a public repository with a passing GDS and precheck. The same page allows running the flow locally and submitting through Tiny Tapeout's custom GDS action if a run would exceed the 6-hour limit of the hosted runners; the precheck must still pass |

## 10. SRAM macros through the flow (O1)

Run 43581583299, branch `probe-macros`, commit c4ab62f, 2026-11-14: a probe with one 512x32 and one
1024x16 macro, a shift-register harness and a cocotb test that writes and reads one word per macro.
Read from that run's logs and reports:

| check | result |
|---|---|
| jobs | gds, precheck, gate-level test, viewer all pass; gds job 77.5 min, of which Magic DRC 49.9 min |
| power stripes onto the macros | 24 stripes extended (16 program, 8 data), 0 violations of the column, polarity and full-height pin checks; all VPWR and VGND shapes connected after routing |
| LVS, antenna, detailed routing | match, 0 violating nets, 0 violations |
| precheck KLayout deck (333 rules) | 0 violations with the macros in the layout |
| Magic DRC | 230,585 violation boxes, every one completely inside a macro outline, none outside |
| Magic illegal overlaps | 25, all where the extended stripes cross the macro's obstruction between its two supply pin rectangles, which the macro GDS shows to be free of metal |
| timing, slow corner, 20.83 ns | clock to data out 6.79 ns (512x32) and 7.55 ns (1024x16); worst setup slack 12.27 ns; no setup or hold violations in any corner |
| maximum capacitance | 4 violations in the sign-off timing report of every corner, all on data outputs of the 1024x16 macro (0.071 to 0.099 pF against 0.064 pF); open. The repair step after global routing counted 3 on estimated wire loads and changed no cell; its log does not name the nets |
| gate-level test | write and read of one word per macro passes with the PDK's functional models |

Consequences:

- The total Magic DRC count cannot gate the flow once a macro is placed. Magic DRC stays on; a step
  after it (`Tile.MagicDRCOutsideMacros`, on the probe branch) stops the flow on any violation that is
  not completely inside a macro. Its first run in the flow, 43661669934 (commit 3be5674, all four jobs
  passed), counted 230,585 inside and 0 outside; the other results of the table were identical.
- A hardening run costs about 80 minutes while Magic DRC is on.
- The macro data outputs need a buffer or the capture register at the pin.

