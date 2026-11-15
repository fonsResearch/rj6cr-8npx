# SPDX-License-Identifier: MIT
"""Self-test for magic_outside_macros.py on a synthetic report. Run: python3 test_magic_outside_macros.py"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import magic_outside_macros as m  # noqa: E402

LEF = "MACRO RM_IHPSG13_T\n  SIZE 100.0 BY 50.0 ;\nEND RM_IHPSG13_T\n"
DEF = """UNITS DISTANCE MICRONS 1000 ;
COMPONENTS 3 ;
    - core.u_a RM_IHPSG13_T + FIXED ( 10000 20000 ) FS ;
    - core.u_b RM_IHPSG13_T + FIXED ( 200000 20000 ) E ;
    - _1_ sg13cmos5l_inv_1 + PLACED ( 5000 5000 ) N ;
END COMPONENTS
"""


def rpt(boxes_by_rule):
    out = ["top", "-" * 40]
    for rule, boxes in boxes_by_rule:
        out += [rule, "-" * 40] + [" %.3fum %.3fum %.3fum %.3fum" % b for b in boxes] + ["-" * 40]
    return "\n".join(out) + "\n"


def run(report_text):
    with tempfile.TemporaryDirectory() as d:
        paths = {}
        for name, text in (("r.rpt", report_text), ("d.def", DEF), ("m.lef", LEF)):
            paths[name] = os.path.join(d, name)
            with open(paths[name], "w") as f:
                f.write(text)
        s = m.summarise(paths["r.rpt"], paths["d.def"], [paths["m.lef"]], "RM_IHPSG13_")
        code = m.main([paths["r.rpt"], paths["d.def"], paths["m.lef"]])
    return s, code


# u_a occupies x 10..110, y 20..70; u_b is rotated: x 200..250, y 20..120.
s, code = run(rpt([("rule A", [(10.0, 20.0, 11.0, 21.0), (109.0, 69.0, 110.0, 70.0)]),
                   ("rule B", [(201.0, 100.0, 249.0, 119.0)])]))
assert (s["total"], s["outside_macros"], code) == (3, 0, 0), s
assert s["per_rule"]["rule A"] == {"core.u_a": 2} and s["per_rule"]["rule B"] == {"core.u_b": 1}, s
assert s["macros"]["core.u_b"] == [200.0, 20.0, 250.0, 120.0], s

# Controls: a box crossing a macro edge, a box in open area, and a box that would be inside u_b
# only if the rotation were ignored, must each count as outside.
for box in ((109.5, 30.0, 110.5, 31.0), (150.0, 30.0, 151.0, 31.0), (260.0, 30.0, 261.0, 31.0)):
    s, code = run(rpt([("rule A", [(10.0, 20.0, 11.0, 21.0), box])]))
    assert (s["outside_macros"], code) == (1, 1), (box, s)

# An empty report passes.
s, code = run("top\n" + "-" * 40 + "\n[INFO] COUNT: 0\n")
assert (s["total"], code) == (0, 0), s
print("ok")
