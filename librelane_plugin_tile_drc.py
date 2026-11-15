# SPDX-License-Identifier: MIT
"""LibreLane plugin: Tile.MagicDRCOutsideMacros.

Appended after Magic.DRC by `meta.substituting_steps` in src/config.json. Magic DRC keeps running
on the whole tile; this step fails the flow if any Magic violation lies outside the placed SRAM
macros (see flow/drc/magic_outside_macros.py for the rule and the reason). The total count is
still reported by Checker.MagicDRC, which is set not to stop the flow (ERROR_ON_MAGIC_DRC 0).
"""
import glob
import importlib.util
import json
import os
from typing import Tuple

from librelane.config import Variable
from librelane.logging import info
from librelane.state import DesignFormat, State
from librelane.steps import Step
from librelane.steps.step import MetricsUpdate, StepError, ViewsUpdate

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_checker():
    path = os.path.join(HERE, "flow", "drc", "magic_outside_macros.py")
    spec = importlib.util.spec_from_file_location("magic_outside_macros", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@Step.factory.register()
class MagicDRCOutsideMacros(Step):
    """Fail if the Magic DRC report has a violation that is not completely inside a placed SRAM macro."""

    id = "Tile.MagicDRCOutsideMacros"
    name = "Magic DRC outside macros"
    long_name = "Magic DRC violations outside SRAM macros"

    inputs = [DesignFormat.DEF]
    outputs = []

    config_vars = [
        Variable(
            "TILE_DRC_MASTER_PREFIX", str, "Master-name prefix of the macros whose interior is exempt.",
            default="RM_IHPSG13_",
        ),
        Variable(
            "TILE_DRC_ERROR_OUTSIDE_MACROS", bool,
            "Stop the flow if a Magic DRC violation lies outside the macros.",
            default=True,
        ),
    ]

    def run(self, state_in: State, **kwargs) -> Tuple[ViewsUpdate, MetricsUpdate]:
        run_dir = os.path.dirname(self.step_dir)
        reports = sorted(glob.glob(os.path.join(run_dir, "*-magic-drc", "reports", "drc.magic.rpt")))
        if not reports:
            self.warn("No Magic DRC report found in this run; nothing checked.")
            return {}, {}
        macros = self.config.get("MACROS") or {}
        lefs = [str(p) for macro in macros.values() for p in macro.lef]
        checker = _load_checker()
        summary = checker.summarise(
            reports[-1], str(state_in[DesignFormat.DEF]), lefs, self.config["TILE_DRC_MASTER_PREFIX"]
        )
        with open(os.path.join(self.step_dir, "magic_outside_macros.json"), "w", encoding="utf8") as f:
            json.dump(summary, f, indent=1)
        info(
            "tile-drc: Magic DRC: %d violations, %d inside %d macro(s), %d outside"
            % (summary["total"], summary["inside_macros"], len(summary["macros"]), summary["outside_macros"])
        )
        for example in summary["outside_examples"][:10]:
            info("tile-drc: outside: %s at %s" % (example["rule"], example["box_um"]))
        metrics = {
            "magic__drc_error_inside_macros__count": summary["inside_macros"],
            "magic__drc_error_outside_macros__count": summary["outside_macros"],
        }
        if summary["outside_macros"] and self.config["TILE_DRC_ERROR_OUTSIDE_MACROS"]:
            raise StepError(
                "%d Magic DRC violations outside the SRAM macros (report: %s)"
                % (summary["outside_macros"], reports[-1])
            )
        return {}, metrics
