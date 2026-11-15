# SPDX-License-Identifier: MIT
"""Split a Magic DRC report into violations inside placed SRAM macros and violations elsewhere.

Why: the Magic rule deck flags geometry inside the foundry SRAM macros (the macro layouts use
memory-cell rules that the deck does not model), so the total count cannot gate the flow once a
macro is placed. The foundry KLayout deck, run by the precheck, is the check that covers the
macro interiors. This script keeps Magic as a gate for everything else: a violation box counts
as "inside" only if it lies completely within the placed bounding box of one macro; anything
outside, or crossing a macro edge, is "outside" and fails the check.

usage: magic_outside_macros.py <drc.magic.rpt> <design.def> <macro.lef>... [--prefix RM_IHPSG13_]
                               [--json out.json]
Exit status 0 if no violation is outside the macros, 1 otherwise, 2 on unusable input.
"""
import argparse
import collections
import json
import re
import sys

_BOX = re.compile(r"^\s*(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um\s*$")


def parse_report(lines):
    """Yield (rule, (x0, y0, x1, y1)) in microns. A rule name is a text line directly followed by
    a dashed line; the report's first line (the cell name) is replaced by the first real rule
    before any box is read."""
    rule = None
    candidate = None
    for raw in lines:
        line = raw.rstrip("\n")
        m = _BOX.match(line)
        if m:
            if rule is None:
                raise ValueError("violation box before any rule name")
            x0, y0, x1, y1 = (float(v) for v in m.groups())
            yield rule, (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
            candidate = None
        elif line.startswith("---"):
            if candidate is not None:
                rule = candidate
            candidate = None
        else:
            candidate = line.strip() or None


def lef_sizes(lef_paths):
    """Map macro name -> (width, height) in microns from LEF MACRO ... SIZE w BY h."""
    sizes = {}
    for path in lef_paths:
        name = None
        with open(path, encoding="utf8", errors="replace") as f:
            for line in f:
                t = line.split()
                if len(t) >= 2 and t[0] == "MACRO":
                    name = t[1]
                elif name and len(t) >= 4 and t[0] == "SIZE" and t[2] == "BY":
                    sizes[name] = (float(t[1]), float(t[3].rstrip(";")))
    return sizes


def macro_boxes(def_path, sizes, prefix):
    """Placed bounding boxes {instance: (x0, y0, x1, y1)} in microns for components whose master
    starts with `prefix`. Orientations that swap width and height are handled."""
    text = open(def_path, encoding="utf8", errors="replace").read()
    m = re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", text)
    if not m:
        raise ValueError("no UNITS DISTANCE MICRONS in DEF")
    dbu = float(m.group(1))
    start = text.find("\nCOMPONENTS ")
    end = text.find("END COMPONENTS")
    if start < 0 or end < 0:
        raise ValueError("no COMPONENTS section in DEF")
    boxes = {}
    comp = re.compile(
        r"-\s+(\S+)\s+(\S+)\s[^;]*?\+\s+(?:FIXED|PLACED|COVER)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)"
    )
    for inst, master, x, y, orient in comp.findall(text[start:end]):
        if not master.startswith(prefix):
            continue
        if master not in sizes:
            raise ValueError("no LEF SIZE for macro master %s" % master)
        w, h = sizes[master]
        if orient in ("E", "W", "FE", "FW"):
            w, h = h, w
        x0, y0 = int(x) / dbu, int(y) / dbu
        boxes[inst.replace("\\", "")] = (x0, y0, x0 + w, y0 + h)
    return boxes


def classify(violations, boxes, eps=1e-6):
    """Return (per_rule, outside_examples): per_rule[rule][where] counts with where an instance name
    or 'outside'."""
    per_rule = collections.defaultdict(collections.Counter)
    outside = []
    for rule, (x0, y0, x1, y1) in violations:
        where = "outside"
        for inst, (a, b, c, d) in boxes.items():
            if x0 >= a - eps and y0 >= b - eps and x1 <= c + eps and y1 <= d + eps:
                where = inst
                break
        per_rule[rule][where] += 1
        if where == "outside" and len(outside) < 50:
            outside.append({"rule": rule, "box_um": [x0, y0, x1, y1]})
    return per_rule, outside


def summarise(report_path, def_path, lef_paths, prefix):
    boxes = macro_boxes(def_path, lef_sizes(lef_paths), prefix)
    with open(report_path, encoding="utf8", errors="replace") as f:
        per_rule, outside = classify(parse_report(f), boxes)
    n_out = sum(c["outside"] for c in per_rule.values())
    n_all = sum(sum(c.values()) for c in per_rule.values())
    return {
        "macros": {k: list(v) for k, v in boxes.items()},
        "total": n_all,
        "inside_macros": n_all - n_out,
        "outside_macros": n_out,
        "per_rule": {r: dict(c) for r, c in sorted(per_rule.items(), key=lambda kv: -sum(kv[1].values()))},
        "outside_examples": outside,
    }


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("def_file")
    ap.add_argument("lef", nargs="+")
    ap.add_argument("--prefix", default="RM_IHPSG13_")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    try:
        s = summarise(a.report, a.def_file, a.lef, a.prefix)
    except (OSError, ValueError) as e:
        print("magic_outside_macros: %s" % e, file=sys.stderr)
        return 2
    if a.json:
        with open(a.json, "w", encoding="utf8") as f:
            json.dump(s, f, indent=1)
    print("Magic DRC: %d violations, %d inside %d macro(s), %d outside"
          % (s["total"], s["inside_macros"], len(s["macros"]), s["outside_macros"]))
    for rule, c in s["per_rule"].items():
        print("  %7d  %s  %s" % (sum(c.values()), rule, dict(c)))
    for e in s["outside_examples"][:10]:
        print("  outside: %s at %s" % (e["rule"], e["box_um"]))
    return 1 if s["outside_macros"] else 0


if __name__ == "__main__":
    sys.exit(main())
