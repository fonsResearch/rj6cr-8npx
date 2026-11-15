#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Plan SRAM macro placements against the tile's Metal4 power stripes.

For each placement it reports which stripes over the macro lie inside a power column of the
same polarity (these are extended over the macro by Tile.MacroColumnStripes), which do not
(these need a PDN_OBSTRUCTIONS entry), checks the planned result with the property C1-C3 of
macro_stripes_geom.py on a model of the stripes, and prints the VPWR footprints in macro
coordinates for check_sram_bar_gds.py.

usage: plan_macros.py <lef dir> <macro>:<x>:<y>:<orient> ...
       plan_macros.py <lef dir> --scan <macro>        # aligned stripe pairs for every site position

The stripe model (pitch 44.96, spacing 3.52, width 2.1, offset 6.15 from the core edge at x = 2.88)
is the configuration in src/config.json; the hardening step reads the real stripes.
"""
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macro_stripes_geom as G  # noqa: E402

DBU = 1000
CORE = (2.88, 3.78, 1721.28, 706.86)
PINS = {"VDD!": "P", "VDDARRAY!": "P", "VSS!": "G"}
NAMES = {"P": "VPWR", "G": "VGND"}
HALO = 10000


def stripes():
    return G.tile_stripes(CORE[0], CORE[2], CORE[1], CORE[3], 2.1, 3.52, 44.96, 6.15, DBU)


def plan(lef_text, x, y, orient, segs):
    w, h = G.lef_size(lef_text)
    cols = G.place(G.lef_power_rects(lef_text, PINS), (w, h), (x, y), orient, DBU)
    bbox = (round(x * DBU), round(y * DBU), round((x + w) * DBU), round((y + h) * DBU))
    p = G.plan(bbox, cols, G.carve(segs, bbox, HALO, HALO), NAMES, full_span=True, cross_gaps=True)
    return bbox, cols, p


def main():
    lef_dir, *args = sys.argv[1:]
    read = lambda m: (Path(lef_dir) / f"{m}.lef").read_text()
    if args and args[0] == "--scan":
        lef = read(args[1])
        w, _ = G.lef_size(lef)
        count = Counter()
        best = []
        for k in range(int((CORE[2] - CORE[0] - w) / 0.48) + 1):
            x = round(CORE[0] + 0.48 * k, 2)
            _, _, p = plan(lef, x, 300.0, "FS", stripes())
            n = min(sum(b[0] == "P" for b in p.bridged), sum(b[0] == "G" for b in p.bridged))
            count[n] += 1
            best.append((n, x))
        top = max(count)
        print(f"{args[1]}: aligned pairs -> number of site positions: {dict(sorted(count.items()))}")
        print(f"positions with {top} pairs: {[x for n, x in best if n == top]}")
        return 0
    segs = stripes()
    planned, obstruct = [], []
    for a in args:
        macro, x, y, orient = a.split(":")
        bbox, cols, p = plan(read(macro), float(x), float(y), orient, segs)
        planned.append((macro, float(x), bbox, cols, p))
        print(f"{macro} at ({x}, {y}) {orient}: x {bbox[0] / DBU}..{bbox[2] / DBU}, y {bbox[1] / DBU}..{bbox[3] / DBU}")
        print(f"  extended: VPWR {sum(b[0] == 'P' for b in p.bridged)}, VGND {sum(b[0] == 'G' for b in p.bridged)}")
        for pol, x0, x1, why in p.skipped:
            print(f"  to obstruct: {NAMES[pol]} {x0 / DBU}..{x1 / DBU} ({why})")
            obstruct.append([x0 / DBU, x1 / DBU])
        spans = " ".join(f"{b[1] / DBU - float(x):.2f}:{b[2] / DBU - float(x):.2f}" for b in p.bridged if b[0] == "P")
        print(f"  VPWR footprints for check_sram_bar_gds.py: {spans}")
    obstruct.sort()
    merged = []
    for a, b in obstruct:
        if merged and a - merged[-1][1] < 4.0:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    print("PDN_OBSTRUCTIONS:")
    for a, b in merged:
        print(f'    "Metal4 {a - 0.5:.2f} 0 {b + 0.5:.2f} 710.64",')
    shapes = [s for s in segs if not any(a - 0.5 < s.x1 / DBU and s.x0 / DBU < b + 0.5 for a, b in merged)]
    print(f"stripes: {len(segs)} in the model, {len(segs) - len(shapes)} removed by the obstructions")
    for _, _, bbox, _, _ in planned:
        shapes = G.carve(shapes, bbox, HALO, HALO)
    for _, _, _, _, p in planned:
        for pol, x0, x1, ylo, yhi in p.replace:
            shapes = [s for s in shapes if (s.pol, s.x0, s.x1) != (pol, x0, x1)]
            shapes.append(G.Rect(pol, NAMES[pol], x0, ylo, x1, yhi))
    bad = 0
    for macro, _, bbox, cols, _ in planned:
        v = G.check(bbox, cols, shapes, allow_pin_gaps=True)
        bad += len(v)
        print(f"{macro}: C1-C3 violations on the planned stripes: {len(v)}")
        for line in v[:5]:
            print("   ", line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
