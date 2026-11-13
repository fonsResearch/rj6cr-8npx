#!/bin/sh
# Emit the probe circuit as Verilog and simulate it with Icarus Verilog.
# Usage: source tools/env.sh; probe/edges/run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/work/probe_edges"
mkdir -p "$out"
(cd "$root" && dune build probe/edges/emit.exe)
"$root/_build/default/probe/edges/emit.exe" > "$out/edges.v"
iverilog -g2012 -o "$out/tb.vvp" "$out/edges.v" "$here/tb.v"
vvp -n "$out/tb.vvp"
