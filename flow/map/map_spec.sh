#!/usr/bin/env bash
# Local SG13CMOS5L mapping of the specification circuit: an area estimate that approximates
# LibreLane's Yosys synthesis only (no placement, buffering or timing repair). Not the TT flow.
# usage: flow/map/map_spec.sh            (run from the repository root after `source tools/env.sh`)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PDK="$ROOT/.toolchain/pdk/ihp-sg13cmos5l"
LIB="$PDK/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
LT="$PDK/libs.tech/librelane/sg13cmos5l_stdcell"
DU=""; for c in $(cat "$LT/synth_exclude.cells"); do DU="$DU -dont_use $c"; done
OUT="$ROOT/flow/map/out/spec"; mkdir -p "$OUT"
(cd "$ROOT" && dune build ./spec/circuit/bin/emit_spec_circuit.exe && ./_build/default/spec/circuit/bin/emit_spec_circuit.exe > "$OUT/spec_chip.v")
cat > "$OUT/map.ys" <<YS
read_liberty -lib $LIB
read_verilog $OUT/spec_chip.v
hierarchy -check -top spec_chip
synth -top spec_chip -flatten -nofsm
techmap -map $LT/mux4_map.v
techmap -map $LT/mux2_map.v
techmap -map $LT/latch_map.v
simplemap
dfflibmap -liberty $LIB $DU
abc -liberty $LIB -D 20830 $DU
hilomap -singleton -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO
setundef -zero
opt_clean -purge
tee -o $OUT/stat.txt stat -liberty $LIB
YS
yosys -q -l "$OUT/yosys.log" -s "$OUT/map.ys"
grep -E 'Chip area|Number of cells' "$OUT/stat.txt" | head -3
