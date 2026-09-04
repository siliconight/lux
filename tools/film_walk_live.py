#!/usr/bin/env python3
"""Walk the night strip with the film treatment on a key -- windowed, first
person, the thing `film_walk_probe.py` is not.

The probe opens Godot, points four fixed cameras at the level, saves sixteen
PNGs and quits. That is a screenshot run, and roadmap item 61 names the WALK as
its closing condition. Grain is temporal and screen-space: a frozen frame
cannot show either the good half of that (it moves, the banding does not) or
the bad half (it crawls). So this launches the same staged site with a player
in it.

  WASD move   SHIFT sprint   SPACE jump   mouse look   ESC release   F8 quit
  F cycle film   V toggle use_hdr_2d      N coherence
  G cycle preset [ ] grain strength       P screenshot + calibration readback

WHY THERE IS A CALIBRATION STRIP IN THE HUD. The walk's stills showed that with
`use_hdr_2d` raised the saved frame is the LINEAR form of the unraised one
(best-fit exponent 2.265 over 746k mid-tone pixels, residual 0.239 -> 0.046).
Two different defects produce that and they need opposite fixes -- a linear
READBACK is cosmetic, a linear PRESENTED IMAGE means the post stack's 0.5-keyed
thresholds are all landing wrong whenever film is on. The strip draws 0.50
directly above 0.214 (= linear(0.50)). Press V: if they converge ON SCREEN it
is the second, and `film_manage_hdr_2d = true` is wrong as a shipped default.
P prints the readback, so half of it is automatic and the other half is your
eyes -- which is the correct division of labour for a walk.
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_FACTORY_TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
if os.path.isdir(_FACTORY_TOOLS):
    sys.path.insert(0, _FACTORY_TOOLS)

from godot_probe import ProbeFailed, require_godot  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LUX = os.path.normpath(os.path.join(HERE, ".."))
PROBE = os.path.join(HERE, "film_walk_live.gd")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project", default=LUX)
    ap.add_argument("--godot", default=None)
    ap.add_argument("--out", default=None,
                    help="where P writes its screenshots")
    ap.add_argument("--resolution", default=None,
                    help="window size, e.g. 1280x720 -- the resolution lock "
                         "is a no-op at ~1440p by design, so seeing it work "
                         "means running at a different one")
    ap.add_argument("--base-fog", type=float, default=None,
                    help="starting film_base_fog for this walk (the SHIPPED "
                         "preset default is 0.0; this only seeds the demo)")
    a = ap.parse_args(argv)

    project = os.path.abspath(a.project)
    out_dir = os.path.abspath(a.out or os.path.join(os.getcwd(),
                                                    "film_walk_live"))
    os.makedirs(out_dir, exist_ok=True)
    try:
        godot = require_godot(a.godot)
    except ProbeFailed as e:
        print("NOTHING RAN: " + str(e))
        return 2

    env = dict(os.environ)
    env["LUX_WALK_OUT"] = out_dir.replace("\\", "/")
    # filmify's projection flare is 0.004 and its black floor 0.002; this is
    # the same order, not the 0.06 an earlier version of this tool seeded.
    if a.base_fog is not None:
        env["LUX_WALK_BASE_FOG"] = "%.4f" % a.base_fog

    print("film walk -- windowed, first person")
    print("  project: %s" % project)
    print("  shots:   %s" % out_dir)
    print("")
    print("  WASD move  SHIFT sprint  SPACE jump  mouse look  ESC release")
    print("  F film     V hdr_2d      N coherence  G preset")
    print("  [ ] grain  P shot        F8 quit")
    print("")
    print("  THE QUESTION THIS WALK IS FOR: press V and watch the 0.50 swatch")
    print("  against the 0.214 one below it. If they converge ON SCREEN, the")
    print("  presented image goes linear when the render target is raised, and")
    print("  the post stack's 0.5-keyed thresholds are landing wrong whenever")
    print("  film is on. If they stay clearly different, only the capture path")
    print("  is affected -- and the walk's PNG statistics are what need fixing.")
    print("")

    # An already-imported project plus a newly added script is exactly the
    # state that produced the preload bug in 0.28.1, and an idempotent import
    # pass costs seconds. Always run it.
    subprocess.run([godot, "--headless", "--path", project, "--import"],
                   capture_output=True, text=True, timeout=900)
    try:
        script = _res(project)
    except ProbeFailed as e:
        print("NOTHING RAN: " + str(e))
        return 2
    # NOT --headless: the walk is the point.
    cmd = [godot, "--path", project]
    if a.resolution:
        cmd += ["--resolution", a.resolution]
    cmd += ["--script", script]
    r = subprocess.run(cmd, env=env)
    return r.returncode


def _res(project):
    """The .gd has to live inside the project to be addressable as res://."""
    dest = os.path.join(project, "tools", "film_walk_live.gd")
    if not os.path.isfile(dest):
        raise ProbeFailed("film_walk_live.gd is not in %s -- it must live "
                          "inside the project to be a res:// path" % dest)
    return "res://tools/film_walk_live.gd"


if __name__ == "__main__":
    sys.exit(main())
