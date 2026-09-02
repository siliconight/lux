"""Launch the film emulsion demo.

    python lux/tools/film_demo.py

WHY THIS EXISTS RATHER THAN A DOCUMENTED COMMAND LINE. The obvious instruction
is `& $env:LOT_GODOT --path lux -s res://tools/film_demo.gd`, and it fails on a
shell where LOT_GODOT is not set -- with `The expression after '&' ... produced
an object that was not valid`, which names PowerShell syntax rather than the
missing variable. Every other tool here resolves Godot through
`godot_probe.require_godot`: --godot, then $LOT_GODOT, then $DC_GODOT, then the
usual install paths, then PATH. A demo that resolves it differently from its
neighbours is a demo that works on one machine.

It also runs the import pass when the project has never been imported, because
the film shader `preload`s the grain texture and an unimported project cannot
supply it -- the failure there is a load error about a missing resource, which
says nothing about the actual problem.
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
from godot_probe import ProbeFailed, require_godot, _display_wrapper  # noqa: E402

LUX = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--godot", default=None)
    ap.add_argument("--project", default=LUX)
    ap.add_argument("--capture", default=None, metavar="DIR",
                    help="run headfully but non-interactively: capture the "
                         "four comparison states into DIR and exit")
    ap.add_argument("--preset", default=None,
                    help="preset to capture on (default Blue Hour -- a look "
                         "with shadows, which the default preset has none of)")
    a = ap.parse_args(argv)

    try:
        godot = require_godot(a.godot)
    except ProbeFailed as e:
        print("NOTHING RAN: " + str(e))
        return 2
    print("godot:   " + godot)
    print("project: " + a.project)

    if not os.path.isdir(os.path.join(a.project, ".godot")):
        print("first run -- importing (the film shader preloads the grain "
              "texture, which an unimported project cannot supply)")
        subprocess.run([godot, "--headless", "--path", a.project, "--import"],
                       check=False)

    # Passed as environment, not as a project setting. ProjectSettings cannot
    # be set from the command line, and the alternatives both mutate the user's
    # project on disk -- writing project.godot, or dropping an override.cfg
    # that a crashed run would leave behind. An env var reaches the child and
    # nothing else, and a crash cleans up by itself.
    env = dict(os.environ)
    if a.capture:
        os.makedirs(a.capture, exist_ok=True)
        env["LUX_FILM_CAPTURE"] = os.path.abspath(a.capture)
    if a.preset:
        env["LUX_FILM_CAPTURE_PRESET"] = a.preset

    cmd = _display_wrapper() + [godot, "--path", a.project]
    cmd += ["-s", "res://tools/film_demo.gd"]
    print("running: " + " ".join(cmd))
    return subprocess.run(cmd, check=False, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
