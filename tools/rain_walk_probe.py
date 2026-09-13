"""Measure rain in a built level: pixels inside buildings, and frame cost.

    python lux/tools/rain_walk_probe.py <project_dir> --out <dir>
        --station name:ex,ey,ez,tx,ty,tz [--station ...]
        [--variant name:preprocess=0,fixed_fps=60] [--times 0.5,3]
        [--cost-frames 240] [--cost-rounds 2] [--scene res://_walk.tscn]

Runs `rain_walk_probe.gd` as an autoload in a MIRROR of the project, through
the factory's `tools/godot_probe.py`, so the project under test is never
edited. Needs a window. vsync is turned off in the mirror so wall-clock frame
time is not pinned to the display's refresh.

Prints the JSON the probe emits and writes it to `<out>.json`. Numbers only.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY_TOOLS = os.path.normpath(os.path.join(HERE, "..", "..", "tools"))


def _station(spec):
    name, _, nums = spec.partition(":")
    vals = [float(v) for v in nums.split(",")]
    if not name or len(vals) != 6:
        raise SystemExit(f"--station wants name:ex,ey,ez,tx,ty,tz, got {spec!r}")
    return {"name": name, "eye": vals[:3], "target": vals[3:]}


def _variant(spec):
    """`name:key=value,...` for numbers, or a JSON object for tree edits
    (`{"name": "tall", "box_top": {"Rain_b1": 60}}`; see the .gd)."""
    if spec.lstrip().startswith("{"):
        return json.loads(spec)
    name, _, kv = spec.partition(":")
    out = {"name": name}
    for pair in filter(None, kv.split(",")):
        k, _, v = pair.partition("=")
        out[k] = float(v) if "." in v else int(v)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--out", required=True)
    ap.add_argument("--station", action="append", default=[])
    ap.add_argument("--variant", action="append", default=[])
    ap.add_argument("--times", default="0.5,3")
    ap.add_argument("--threshold", type=int, default=30)
    ap.add_argument("--cost-frames", type=int, default=240)
    ap.add_argument("--cost-rounds", type=int, default=2)
    ap.add_argument("--cost-amounts", default="",
                    help="comma-separated drop counts to time against off; "
                         "default the level's own count")
    ap.add_argument("--scene", default="res://_walk.tscn")
    ap.add_argument("--factory-tools", default=FACTORY_TOOLS,
                    help="directory holding godot_probe.py (default: %(default)s)")
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=900)
    ap.add_argument("--timeout", type=int, default=1200)
    a = ap.parse_args(argv)

    sys.path.insert(0, a.factory_tools)
    from godot_probe import ProbeFailed, run_probe, require_godot  # noqa: E402

    out_dir = os.path.abspath(a.out)
    os.makedirs(out_dir, exist_ok=True)
    settings = {
        "rain_walk": {
            "out_dir": out_dir.replace("\\", "/"),
            "threshold": a.threshold,
            "stations": json.dumps([_station(s) for s in a.station]),
            "variants": json.dumps([_variant(v) for v in a.variant] or [{"name": "as_built"}]),
            "times": json.dumps([float(t) for t in a.times.split(",")]),
            "cost_frames": a.cost_frames,
            "cost_rounds": a.cost_rounds,
            "cost_amounts": json.dumps([int(x) for x in a.cost_amounts.split(",") if x]),
        },
        "display": {
            "window/size/viewport_width": a.width,
            "window/size/viewport_height": a.height,
            "window/vsync/vsync_mode": 0,
        },
    }
    try:
        payload, _raw, _m = run_probe(
            project_dir=a.project, script_src=os.path.join(HERE, "rain_walk_probe.gd"),
            autoload_name="RainWalkProbe", scene=a.scene,
            begin="<<<RAIN_WALK_JSON", end="RAIN_WALK_JSON>>>",
            godot=require_godot(), settings=settings, headless=False,
            timeout=a.timeout)
    except ProbeFailed as e:
        print("[rain_walk_probe] NOT MEASURED: " + str(e))
        return 1
    payload["project"] = os.path.abspath(a.project)
    with open(out_dir.rstrip("/\\") + ".json", "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1)
    print(json.dumps(payload, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
