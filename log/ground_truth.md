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

## 7. Continuous integration (checked 2026-11-13)

- The hardening workflow of the earlier 6x4 design took a median of 240 minutes wall time per run (12
  runs, GitHub API run timing).
- This repository is private and its organisation is on the free plan: 2,000 included runner minutes per
  month (GitHub plan documentation). The hardening workflow here is therefore manual-trigger only.
- First push, 2026-11-13: the test workflow's cocotb test passed, but its artifact upload failed with
  "Artifact storage quota has been hit". The quota is per account, so a hardening run in this repository
  would fail to upload its results as well until storage is freed or the repository is public. The docs
  workflow failed on the unfilled pinout and `docs/info.md`. With provisional content in both (push of
  2026-11-14) its checks and the document build pass, and it fails at the artifact upload for the same
  quota reason.

## 8. Local tools

Checked 2026-11-13 by running the tools: Yosys 0.69 (git 9f75ca1f) and Icarus Verilog 13.0 under
`.toolchain/eda`; dune 3.24.2; hardcaml and ppx_hardcaml v0.17.1, hardcaml_verify v0.17.0, ppx_expect
v0.17.3, core v0.17.2. SymbiYosys is installed there but was not exercised today. `test/requirements.txt`
pins cocotb 2.0.1 and pytest 8.4.2.

## 9. Open items

| # | item | state |
|---|---|---|
| O1 | 512x32 and 1024x16 macros through this flow and the precheck (only 256x16 has been) | open |
| O2 | how to verify falling-edge registers, given the Cyclesim result above. Options: no falling-edge registers at all; a two-phase model in Cyclesim at twice the clock with a proof against the emitted Verilog; Verilog-level simulation and formal only for that block | open, decision needed before the both-edge front end is designed |
| O3 | latch storage from an instantiated cell: simulation model, emitted Verilog, equivalence method | open |
| O4 | core area from a real 8x4 floorplan report (1,208,173 um^2 is used in the budget; not re-derived here) | open |
| O5 | pad and clock frequency limits on this shuttle (the published 33 / 66 MHz figures are for another process) | open |
| O6 | flow settings at 20.83 ns: setup margins, post-route repair, fanout and wire-length limits, macro halos | open |
| O7 | where hardening runs execute, given section 7 | decided 2026-11-13: the repository will be made public later; no hardening run before that |
| O8 | whether the shuttle submission requires a public repository | open, to be checked in the official submission guide |
