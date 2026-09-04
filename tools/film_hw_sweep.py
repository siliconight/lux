#!/usr/bin/env python3
"""TDD section 51's hardware sweep, one machine at a time.

WHY A FILE THAT ACCUMULATES RATHER THAN A RUN THAT SWEEPS.

Section 51 asks for the film pass measured across the hardware the game is
meant to ship on. Nobody has that hardware in one room, which is exactly why
this section has stayed untouched while everything around it closed: a sweep
written as a single invocation cannot be started until the last card arrives,
so it never gets started at all.

This inverts that. Every run appends ONE record for ONE machine to a shared
JSONL file. The sweep is the file, not the run. A machine can be measured the
afternoon somebody has access to it, months apart, by different people, and
the coverage report below says at any moment which classes are still empty --
so the gap is a list of named machines to find rather than a sentence in an
audit saying the whole section is untouched.

WHAT IS RECORDED AND WHY EACH FIELD IS THERE.

The adapter string alone is not an identity: the same card gives different
numbers on a different driver, a different Godot, a different rendering
method, and a laptop part throttles where a desktop part does not. A record
that cannot be told apart from a differently-configured run of the same card
is a record that cannot be trusted later, so all of it is stamped.

ONE RECORD IS NEVER OVERWRITTEN. Re-measuring the same machine appends a
second record; the report shows the newest and counts the rest. A sweep whose
history can be silently rewritten by the next run cannot answer "did this get
worse", which is most of what a sweep is for.

Usage:
    python film_hw_sweep.py                 # measure THIS machine, append
    python film_hw_sweep.py --report        # what the file holds, and the gaps
    python film_hw_sweep.py --label "Steam Deck OLED"
"""

import argparse
import json
import os
import platform
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import film_render_probe as frp  # noqa: E402
from godot_probe import ProbeFailed, require_godot  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LUX = os.path.normpath(os.path.join(HERE, ".."))
DEFAULT_STORE = os.path.join(LUX, "docs", "data", "film_hw_sweep.jsonl")

#: The resolution matrix section 50 fixed. The sweep measures the SAME cells on
#: every machine or the machines cannot be compared -- which is the entire point
#: of running it on more than one.
RESOLUTIONS = frp.PERF_RESOLUTIONS

#: 120 discarded then 600 timed, the same as section 50's matrix. Held as a
#: constant here rather than exposed as a flag: two machines measured with
#: different sample counts are not comparable, and the whole value of this file
#: is that its rows can be put next to each other.
COST = (120, 600)

#: The classes section 51 actually cares about, and the reason each is named:
#: every one of them fails differently from a desktop discrete NVIDIA part, and
#: an RTX 2060 is evidence about none of them.
COVERAGE = [
    ("nvidia-discrete", "desktop NVIDIA -- the only class measured so far"),
    ("amd-discrete", "different driver, different shader compiler entirely"),
    ("intel-arc", "newest driver stack, least shipped-on"),
    ("integrated", "shares system bandwidth; a fill-bound pass is worst here"),
    ("handheld", "Deck-class: integrated AND power-capped AND at 800p"),
    ("apple", "Metal via MoltenVK, a different backend for the same code"),
    ("software", "llvmpipe -- the CI/no-GPU fallback, not a target"),
]


def classify(adapter, is_handheld=False):
    """Best guess at the coverage class, from the adapter string.

    A GUESS, AND LABELLED AS ONE. `--class` overrides it, because an adapter
    string cannot tell a desktop part from the same silicon in a laptop, and
    "integrated" in particular is a judgement about the memory system rather
    than about the name. The guess exists so the common cases need no flag,
    not so the field can be trusted without looking.
    """
    a = (adapter or "").lower()
    if is_handheld:
        return "handheld"
    if "llvmpipe" in a or "softwarerasterizer" in a or "swiftshader" in a:
        return "software"
    if "apple" in a or "metal" in a:
        return "apple"
    if "arc" in a or ("intel" in a and "arc" in a):
        return "intel-arc"
    if "intel" in a or "uhd" in a or "iris" in a:
        return "integrated"
    if "radeon" in a and ("vega" in a or "graphics" in a and "rx" not in a):
        return "integrated"
    if "amd" in a or "radeon" in a:
        return "amd-discrete"
    if "nvidia" in a or "geforce" in a or "rtx" in a or "gtx" in a:
        return "nvidia-discrete"
    return "unknown"


def machine_facts():
    """Everything about this box that could move a number."""
    return {
        "os": platform.system(),
        "os_release": platform.release(),
        "os_version": platform.version(),
        "machine": platform.machine(),
        "cpu": platform.processor() or "?",
        "python": platform.python_version(),
        "host": platform.node(),
    }


def driver_version(adapter):
    """The driver, where a vendor tool will say. Empty is an honest answer."""
    a = (adapter or "").lower()
    if "nvidia" in a or "geforce" in a or "rtx" in a or "gtx" in a:
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=driver_version",
                 "--format=csv,noheader"],
                capture_output=True, text=True, timeout=15)
            if r.returncode == 0:
                return r.stdout.strip().splitlines()[0].strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return ""


def measure(godot, timeout, verbose, power, resolutions):
    """Both hdr_2d states at every resolution, exactly as section 50 does."""
    cells = {}
    adapter = ""
    godot_version = ""
    method = ""
    for (w, h) in resolutions:
        for hdr in (False, True):
            print("  timing %dx%d hdr_2d=%s ..." % (w, h, str(hdr).lower()))
            rep, _ = frp.run(godot, hdr, timeout, verbose, (w, h),
                             cost=COST, power=power)
            adapter = rep.get("adapter", adapter)
            godot_version = rep.get("godot", godot_version)
            method = rep.get("rendering_method", method)
            c = rep.get("cost") or {}
            cell = {}
            for name in ("no_post", "baseline", "film",
                         "quant_perchannel", "quant_shared"):
                d = c.get(name)
                if not isinstance(d, dict):
                    continue
                keep = {k: d[k] for k in
                        ("median_ms", "mean_ms", "p95_ms", "p99_ms",
                         "vram_total_bytes", "static_mem_bytes")
                        if k in d}
                if "power" in d:
                    keep["watts"] = d["power"]["watts"]
                cell[name] = keep
            cells["%dx%d/hdr_%s" % (w, h, str(hdr).lower())] = cell
    return cells, adapter, godot_version, method


def append_record(store, rec):
    os.makedirs(os.path.dirname(store), exist_ok=True)
    with open(store, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


def load_records(store):
    if not os.path.exists(store):
        return []
    out = []
    with open(store, "r", encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except ValueError:
                # A HALF-WRITTEN LINE IS NOT A REASON TO LOSE THE FILE. This
                # file is appended to from machines that may be interrupted,
                # and one torn record must not take the other twelve with it.
                continue
    return out


def worst_delta(rec):
    """film - baseline at the worst cell, in ms, or None.

    THE WORST CELL, NOT THE TYPICAL ONE, for the same reason section 41 is
    graded there: a sweep that reports each machine's average would pass every
    machine that fails only at 4K, which is the failure everyone cares about.
    """
    worst = None
    where = ""
    for key, cell in (rec.get("cells") or {}).items():
        f, b = cell.get("film"), cell.get("baseline")
        if not f or not b:
            continue
        d = f.get("median_ms", 0.0) - b.get("median_ms", 0.0)
        if worst is None or d > worst:
            worst, where = d, key
    return worst, where


def report(store):
    recs = load_records(store)
    print("")
    print("SECTION 51 -- THE HARDWARE SWEEP, AS FAR AS IT HAS GOT")
    print("  %s" % store)
    if not recs:
        print("")
        print("  EMPTY. Run this script on any machine to add the first row.")
        print("  That is not a failure state -- it is the state section 51 has")
        print("  been in since it was written, now with somewhere to put a row.")
        _gaps({})
        return 0

    # Newest per machine, with the older ones counted rather than hidden.
    by_key = {}
    for r in recs:
        k = (r.get("label") or r.get("adapter", "?"), r.get("godot", "?"),
             r.get("driver", ""))
        by_key.setdefault(k, []).append(r)

    print("  %d record%s across %d machine configuration%s"
          % (len(recs), "" if len(recs) == 1 else "s",
             len(by_key), "" if len(by_key) == 1 else "s"))
    print("")
    print("  %-28s %-16s %-9s %10s  %-18s %s"
          % ("machine", "class", "godot", "worst dms", "at", "runs"))
    seen_classes = {}
    for k, group in sorted(by_key.items()):
        group.sort(key=lambda r: r.get("when", ""))
        newest = group[-1]
        d, where = worst_delta(newest)
        cls = newest.get("class", "unknown")
        seen_classes.setdefault(cls, 0)
        seen_classes[cls] += 1
        print("  %-28s %-16s %-9s %10s  %-18s %d"
              % (k[0][:28], cls, newest.get("godot", "?")[:9],
                 ("%.4f" % d) if d is not None else "--", where, len(group)))
    print("")
    _gaps(seen_classes)

    # REGRESSION, WHICH IS THE OTHER HALF OF WHY RECORDS ARE NEVER OVERWRITTEN.
    for k, group in sorted(by_key.items()):
        if len(group) < 2:
            continue
        group.sort(key=lambda r: r.get("when", ""))
        old, new = worst_delta(group[-2])[0], worst_delta(group[-1])[0]
        if old is None or new is None or old <= 0:
            continue
        pct = 100.0 * (new / old - 1.0)
        if abs(pct) >= 5.0:
            print("  MOVED: %s worst cell %.4f -> %.4f ms (%+.1f%%)"
                  % (k[0][:40], old, new, pct))
    return 0


def _gaps(seen):
    print("  COVERAGE -- what section 51 asked for, and what is still missing")
    missing = 0
    for name, why in COVERAGE:
        n = seen.get(name, 0)
        if n:
            print("    have  %-16s %d machine%s" % (name, n, "" if n == 1 else "s"))
        else:
            missing += 1
            print("    GAP   %-16s %s" % (name, why))
    print("")
    if missing:
        print("  %d of %d classes unmeasured. Section 51 is OPEN, and this is"
              % (missing, len(COVERAGE)))
        print("  the list of machines to find -- which is a smaller and more")
        print("  actionable statement than the one it replaces.")
    else:
        print("  Every class has at least one machine. Section 51's condition")
        print("  is met at breadth; depth within a class is a separate question.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", default=None)
    ap.add_argument("--store", default=DEFAULT_STORE,
                    help="the accumulating JSONL sweep file")
    ap.add_argument("--report", action="store_true",
                    help="print what the file holds and what is missing; "
                         "measure nothing")
    ap.add_argument("--label", default=None,
                    help="how this machine should appear in the table. "
                         "Defaults to the adapter string.")
    ap.add_argument("--class", dest="cls", default=None,
                    choices=[c for c, _ in COVERAGE],
                    help="override the guessed coverage class. Do this for "
                         "anything the adapter string cannot reveal -- a "
                         "handheld, or a laptop part with a desktop name.")
    ap.add_argument("--note", default="",
                    help="anything about this run somebody will need later: "
                         "power profile, cooling, docked or handheld, TDP cap.")
    ap.add_argument("--power", action="store_true",
                    help="sample GPU power alongside (NVIDIA only)")
    ap.add_argument("--resolutions", default=None,
                    help="comma-separated WxH; default is section 50's matrix")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    if a.report:
        return report(a.store)

    godot = require_godot(a.godot)
    res = RESOLUTIONS
    if a.resolutions:
        res = [tuple(int(v) for v in r.lower().split("x"))
               for r in a.resolutions.split(",")]

    print("SECTION 51 -- measuring THIS machine and appending one record")
    try:
        cells, adapter, gv, method = measure(
            godot, a.timeout, a.verbose, a.power, res)
    except ProbeFailed as e:
        print("")
        print("  NOTHING MEASURED: %s" % e)
        print("  Nothing was appended. A sweep file with a half-measured row")
        print("  in it is worse than one row shorter.")
        return 2

    rec = {
        "when": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "label": a.label or adapter,
        "adapter": adapter,
        "class": a.cls or classify(adapter),
        "class_guessed": a.cls is None,
        "driver": driver_version(adapter),
        "godot": gv,
        "rendering_method": method,
        "note": a.note,
        "resolutions": ["%dx%d" % (w, h) for (w, h) in res],
        "cells": cells,
    }
    rec.update({"host_" + k: v for k, v in machine_facts().items()})
    append_record(a.store, rec)

    d, where = worst_delta(rec)
    print("")
    print("  APPENDED: %s (%s)" % (rec["label"], rec["class"]))
    if rec["class_guessed"]:
        print("  Class was GUESSED from the adapter string. If that is wrong,")
        print("  re-run with --class; the guess cannot see a laptop part or a")
        print("  handheld.")
    if d is not None:
        print("  Worst cell: film costs %.4f ms at %s" % (d, where))
    print("")
    return report(a.store)


if __name__ == "__main__":
    sys.exit(main())
