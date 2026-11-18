# Physical skeleton (branch probe-skeleton)

Test load for the skeleton gate of the 8x4 design: the chip's state, a logic volume close to the
chip's, both SRAM macros at the probed positions, and the chip's pins. It is not the chip and its
function is not the specification.

`core/` is a copy of `spec/circuit/` at commit 64916bc with two structural changes, chosen from the
area ablation of the specification circuit (local mapping, typical liberty):

| variant | area (um^2) | flip-flops (um^2) |
|---|---|---|
| specification circuit | 679,487 | 167,934 |
| one execute stage for all threads (`core/shared.ml`) | 564,631 | 167,836 |
| and one host register read multiplexer (`core/hostp.ml`) | 524,159 | 167,836 |

- `shared`: the execute stage is built once, fed by the thread record of the executing slot and
  written back to that thread; the specification circuit builds it once per thread.
- `peek1`: the host register read multiplexer is built once; the specification circuit builds it
  for each of its two read paths.

Both change the order of same-cycle updates, so the skeleton is not cycle-equal to the model.
Every register carries `(* fsm_encoding = "none" *)`: Yosys FSM extraction did not finish in
38 minutes on the specification circuit; with the attribute, mapping with FSM passes takes 49 s.

Regenerate the Verilog: `dune build ./probe/skeleton/emit_skeleton.exe &&
./_build/default/probe/skeleton/emit_skeleton.exe > src/skel_core.v`
