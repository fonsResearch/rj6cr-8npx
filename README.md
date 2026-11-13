# Protocol emulator, 8x4

A reprogrammable protocol emulator for a Tiny Tapeout 8x4 tile on IHP SG13CMOS5L, written in Hardcaml and
emitted as Verilog. Status: architecture proposed, no RTL yet.

| where | what |
|---|---|
| `doc/decisions/arch_selection.md` | the proposed architecture and the reasons for each choice |
| `log/ground_truth.md` | verified facts the design relies on, and the open items |
| `probe/` | small experiments that settle a ground-truth question |
| `tools/` | environment setup and scripts |
| `src/`, `test/`, `docs/`, `info.yaml` | Tiny Tapeout project files (placeholder top module for now) |

Setup: `source tools/env.sh`, then `dune build` and `dune test`.
