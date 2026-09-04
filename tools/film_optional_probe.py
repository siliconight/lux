"""Prove film emulsion is optional by DELETING it and diffing the pixels.

    python lux/tools/film_optional_probe.py

WHY THIS EXISTS. Lux 0.28.0 claimed film emulsion was "opt-in by construction"
and gave four reasons. Every reason was true. The feature still took out the
entire post stack on the first machine that ran it, because a `preload` of its
grain texture resolved at script load and nothing in the reasoning covered that.

The lesson, and this file: **optionality that has not been tested by REMOVING
the thing is a claim, not a property.** So this removes it.

WHAT IT DOES. Mirrors the project twice. In the second copy it deletes the film
shader and the grain asset outright, then renders every shipped preset in both
and compares the PNGs byte for byte. If deleting the feature changes a single
pixel of a preset that never asked for it, the claim is false and this says so.

WHAT IT ALSO CATCHES. A preset whose film flag drifted to true would not crash
anything -- it would quietly render differently from what its author approved.
Each preset's `asks_for_film` and `film_active` are reported, and any shipped
preset that activates film is a failure regardless of what the pixels say.

NEEDS A DISPLAY. `--headless` disables rendering. On a Linux box without one
this wraps in xvfb-run.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_FACTORY_TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
if os.path.isdir(_FACTORY_TOOLS):
    sys.path.insert(0, _FACTORY_TOOLS)
from godot_probe import ProbeFailed, require_godot, _display_wrapper  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LUX = os.path.normpath(os.path.join(HERE, ".."))
PROBE = os.path.join(HERE, "film_optional_probe.gd")
MARK_BEGIN = "<<<FILM_OPTIONAL_JSON"
MARK_END = "FILM_OPTIONAL_JSON>>>"

#: Everything the feature owns. Deleting exactly these is the test.
FILM_FILES = [
    "addons/lux/shaders/post/lux_ordered_dither_film.gdshader",
    "addons/lux/shaders/post/lux_ordered_dither_film.gdshader.uid",
    "addons/lux/resources/film/grain_balanced.png",
    "addons/lux/resources/film/grain_balanced.png.import",
]


def mirror(src, dest, strip_film):
    shutil.copytree(src, dest, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".git", "walk", "_*"))
    removed = []
    if strip_film:
        for rel in FILM_FILES:
            p = os.path.join(dest, rel)
            if os.path.isfile(p):
                os.remove(p)
                removed.append(rel)
        # and the import cache entry, or Godot serves the deleted texture
        imported = os.path.join(dest, ".godot", "imported")
        if os.path.isdir(imported):
            for f in os.listdir(imported):
                if f.startswith("grain_balanced.png"):
                    os.remove(os.path.join(imported, f))
                    removed.append(".godot/imported/" + f)
    return removed


def run(godot, project, out_dir, timeout, verbose, film_mode_test=False):
    os.makedirs(out_dir, exist_ok=True)
    shutil.copy2(PROBE, os.path.join(project, "film_optional_probe.gd"))
    env = dict(os.environ)
    env["LUX_OPTIONAL_OUT"] = out_dir
    subprocess.run([godot, "--headless", "--path", project, "--import"],
                   capture_output=True, text=True, timeout=timeout)
    cmd = _display_wrapper() + [godot, "--path", project,
                                "-s", "res://film_optional_probe.gd"]
    if film_mode_test:
        # An ENV VAR, not a Godot user arg. `++ --film-mode-test` was accepted
        # silently and never reached OS.get_cmdline_user_args() on Windows --
        # the probe reported "not run" while the caller had asked for it, which
        # is the worst way for a flag to fail. LUX_OPTIONAL_OUT above already
        # proves this channel works.
        env["LUX_OPTIONAL_FILM_MODE"] = "1"
        # SAY SO, OUT LOUD. This flag has now failed silently twice -- once as
        # a Godot user arg that never arrived, once for a reason still unknown
        # -- and each time it reported "not run" while the caller had asked for
        # it. A flag that cannot be seen arriving cannot be debugged from the
        # other end, so both sides announce themselves now.

    if verbose:
        print("  [probe] " + " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                       env=env)
    out = (r.stdout or "") + (r.stderr or "")
    m = re.search(re.escape(MARK_BEGIN) + r"\s*(.*?)\s*" + re.escape(MARK_END),
                  out, re.S)
    if not m:
        tail = "\n".join(out.strip().splitlines()[-25:])
        # THE LOG ON DISK IS THE ONLY WITNESS TO AN ABORT. The fence is
        # printed at the end of _run(); a process that dies before then
        # prints nothing at all, and that is precisely the case this branch
        # handles. The GDScript side flushes one line per step to this file,
        # so the last line names the last statement that completed.
        steps = _read_steps(out_dir)
        where = ("\n  Died after: %s" % " -> ".join(steps)) if steps else ""
        raise ProbeFailed("the probe never printed its fence, so nothing was "
                          "measured. Godot exited %s.%s\n  Last output:\n%s"
                          % (r.returncode, where, tail))
    rep = json.loads(m.group(1))
    if "film_mode_steps" not in rep:
        disk = _read_steps(out_dir)
        if disk:
            rep["film_mode_steps"] = disk
    return rep, out


def _read_steps(out_dir):
    """The step markers the GDScript side flushed, or []."""
    path = os.path.join(out_dir, "film_mode_steps.log")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return []


#: Every symbol the film feature owns. "Delete the feature and nothing else
#: references it" is a claim about exactly this list, so the list is the test.
FILM_SYMBOLS = [
    "film_emulsion_enabled", "grain_mode", "film_grain_strength",
    "film_chroma_ratio", "film_grain_fps", "film_grain_scale",
    "dither_chroma_coherence", "dither_luma_scale", "allow_film_emulsion",
    "film_manage_hdr_2d", "FILM_SHADER_PATH", "FILM_GRAIN_PATH",
    "_film_mat", "_film_active", "_film_master", "is_film_active",
    "set_film_emulsion_enabled", "is_film_emulsion_active",
]

#: Where they are allowed to live. Anything else that mentions one is a
#: reference the "just delete it" instruction would leave dangling.
FILM_HOMES = {
    "addons/lux/resources/lux_preset.gd",
    "addons/lux/resources/lux_quality_profile.gd",
    "addons/lux/runtime/lux_post_fx.gd",
    "addons/lux/runtime/lux_root.gd",
    "addons/lux/runtime/lux_runtime_api.gd",
    "addons/lux/shaders/post/lux_ordered_dither_film.gdshader",
}


def check_references(root):
    """Which CODE files mention a film symbol, and are they only its homes?

    Docs are excluded on purpose -- a document that describes the feature is
    supposed to mention it, and deleting the feature is a documentation edit
    rather than a dangling reference. Tools are excluded for the same reason:
    they exist to exercise it.
    """
    strays = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", ".godot", "walk", "docs", "tools")]
        for fn in filenames:
            if not fn.endswith((".gd", ".gdshader", ".tres", ".tscn", ".cfg")):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            if rel in FILM_HOMES:
                continue
            # This probe's own file. `run()` copies it into each mirror's root
            # to be run with -s, so without this the check reliably finds
            # itself and reports the test as the defect.
            if os.path.basename(full) == os.path.basename(PROBE):
                continue
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            hits = sorted({sym for sym in FILM_SYMBOLS if sym in text})
            if hits:
                strays[rel] = hits
    return strays


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def mean_abs_diff(p1, p2):
    """Mean |difference| per channel between two PNGs, 0..1."""
    from PIL import Image
    import numpy as np
    a = np.asarray(Image.open(p1).convert("RGB")).astype(np.float64) / 255.0
    b = np.asarray(Image.open(p2).convert("RGB")).astype(np.float64) / 255.0
    if a.shape != b.shape:
        return float("inf")
    return float(np.abs(a - b).mean())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--godot", default=None)
    ap.add_argument("--project", default=LUX,
                    help="the Godot project to test (default: the lux repo). "
                         "Must be a COMPLETE project -- the class_name cache "
                         "lives in its .godot, and without it a -s script "
                         "cannot resolve LuxRoot or LuxPreset at all.")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--keep", action="store_true", help="keep the mirrors")
    ap.add_argument("--film-mode-test", action="store_true",
                    help="also exercise set_film_mode() in both builds. Off by "
                         "used to abort the engine -- that was this probe calling into "
                         "a freed LuxRoot, now reordered and guarded.")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    print("film optionality probe -- deletes the feature and diffs the pixels")
    print("  project: " + os.path.abspath(a.project))
    base = tempfile.mkdtemp(prefix="film_optional_")
    try:
        godot = require_godot(a.godot)
        print("  godot: " + godot)
        with_film = os.path.join(base, "with_film")
        without = os.path.join(base, "without_film")
        print("  mirroring the project twice ...")
        src = os.path.abspath(a.project)
        if not os.path.isfile(os.path.join(src, "project.godot")):
            raise ProbeFailed(
                "no project.godot in " + src + " -- that is not a Godot "
                "project. A -s script there cannot resolve `LuxRoot` or "
                "`LuxPreset`, and the failure reads as a missing type rather "
                "than a missing project.")
        mirror(src, with_film, strip_film=False)
        removed = mirror(src, without, strip_film=True)
        print("  deleted from the second copy:")
        for r in removed:
            print("    - " + r)
        print("")
        # THREE runs, not two, and the third is the whole reason this tool can
        # be believed. The baseline Simple grain is driven by `time_seed`,
        # which accumulates wall-clock inside the process -- so two launches
        # of the SAME build do not produce identical frames, and a naive A/B
        # reports every preset as "not optional" when nothing is wrong. A1 vs
        # A2 measures that floor; only a difference LARGER than it means
        # anything. Without this control the first run of this probe called
        # all seven shipped presets broken.
        print("  A1: film present")
        a_rep, _ = run(godot, with_film, os.path.join(base, "out_a1"),
                       a.timeout, a.verbose, film_mode_test=a.film_mode_test)
        print("  A2: film present, again -- the nondeterminism control")
        a2_rep, _ = run(godot, with_film, os.path.join(base, "out_a2"),
                        a.timeout, a.verbose, film_mode_test=a.film_mode_test)
        print("  B:  film DELETED")
        b_rep, _ = run(godot, without, os.path.join(base, "out_b"),
                       a.timeout, a.verbose, film_mode_test=a.film_mode_test)
    except ProbeFailed as e:
        print("")
        print("  NOTHING MEASURED: " + str(e))
        shutil.rmtree(base, ignore_errors=True)
        return 2

    fails = []
    print("")
    print("  %-26s %-9s %-11s %-13s %s"
          % ("shipped preset", "asks film", "film active",
             "A1 vs A2", "A1 vs B (film gone)"))
    print("  %-26s %-9s %-11s %-13s %s"
          % ("", "", "", "(must be 0)", ""))
    names = sorted(set(a_rep["presets"]) | set(b_rep["presets"]))
    for nm in names:
        ra = a_rep["presets"].get(nm)
        rb = b_rep["presets"].get(nm)
        if ra is None or rb is None:
            fails.append("%s rendered in only one of the two runs" % nm)
            continue
        if ra["asks_for_film"]:
            fails.append("shipped preset %r has film_emulsion_enabled = true; "
                         "the shipped set must not ask for film" % nm)
        if ra["film_active"]:
            fails.append("film ACTIVATED on shipped preset %r" % nm)
        r2 = a2_rep["presets"].get(nm)
        if r2 is None:
            fails.append("%s missing from the control run" % nm)
            continue
        floor = mean_abs_diff(ra["png"], r2["png"])
        test = mean_abs_diff(ra["png"], rb["png"])
        bit_identical = md5(ra["png"]) == md5(rb["png"])
        # Deleting the feature must not move the image further than two runs of
        # the SAME build already move it. A small margin because the floor is
        # itself a sample.
        # THE BAR IS EXACT EQUALITY NOW. The probe renders every preset with
        # the legacy grain silenced, so the frame is deterministic and there
        # is nothing left for a floor to absorb. The floor column is kept
        # because it is the evidence that the determinism actually holds: it
        # must read 0.000000 on every row, and a non-zero one means the render
        # is still moving on its own and no verdict below it can be trusted.
        if floor > 1e-9:
            fails.append("preset %r is not deterministic: two runs of the SAME "
                         "build differ by %.6f with the legacy grain silenced, "
                         "so nothing measured against it means anything"
                         % (nm, floor))
        ok = bit_identical
        if not ok:
            fails.append("preset %r moves %.6f when the film feature is "
                         "deleted, and the render is deterministic -- that is "
                         "the feature changing a preset that never asked for "
                         "it" % (nm, test))
        verdict = "identical" if bit_identical else "DIFFERS"
        print("  %-26s %-9s %-11s %-13.6f %.6f  %s"
              % (nm, ra["asks_for_film"], ra["film_active"], floor, test,
                 verdict))

    # --- "delete it and nothing else references it" ---
    print("")
    print("  REFERENCES -- the claim that the feature can just be deleted")
    strays = check_references(os.path.abspath(a.project))
    if strays:
        for rel, hits in sorted(strays.items()):
            print("    %s  ->  %s" % (rel, ", ".join(hits)))
            fails.append("%s references %s but is not one of the film "
                         "feature's own files -- deleting the feature would "
                         "leave that dangling"
                         % (rel, ", ".join(hits)))
    else:
        print("    no code file outside the feature's own %d files mentions "
              "any of" % len(FILM_HOMES))
        print("    its %d symbols. Docs and tools are excluded: describing or "
              "exercising" % len(FILM_SYMBOLS))
        print("    a feature is not a dangling reference to it.")

    # --- Lux Film Mode, including where the assets are gone ---
    print("")
    print("  LUX FILM MODE -- the new switch, and section 54 where the assets")
    print("  are gone. film_mode ON must ACTIVATE where they exist and must")
    print("  NOT where they do not -- section 54, on the new switch.")
    print("  It used to abort the engine on both rasterisers. That was this")
    print("  probe, not the feature: the teardown test above it frees the")
    print("  LuxRoot by design, and this test then called into a freed node.")
    print("  Reordered, and guarded with is_instance_valid. --film-mode-test")
    print("  runs it.")
    for tag, rep in (("film present", a_rep), ("film DELETED", b_rep)):
        raw = (rep or {}).get("film_mode", "__missing__")
        fm = raw if isinstance(raw, dict) else {}
        if raw is None:
            # The key exists and is null: the test was entered and its
            # coroutine did not return a dictionary. That is a THIRD outcome,
            # and collapsing it into "not run" is what sent the last round of
            # debugging at the flag instead of at the test.
            print("    %-14s the test RAN and returned nothing -- it errored "
                  "inside _test_film_mode" % tag)
            fails.append("_test_film_mode errored in the %s build" % tag)
            continue
        steps = (rep or {}).get("film_mode_steps") or []
        if steps and (not fm or (fm.get("entered") and len(fm) == 1)):
            print("    %-14s died after: %s" % (tag, " -> ".join(steps)))
        if fm.get("entered") and len(fm) == 1:
            print("    %-14s ENTERED _test_film_mode and never returned -- the "
                  "coroutine died inside it" % tag)
            fails.append("_test_film_mode entered and did not return in the "
                         "%s build" % tag)
            continue
        if not fm:
            # Report WHICH side dropped it. The env var is echoed back through
            # the JSON, so "python set it and Godot never saw it" and "Godot
            # saw it and the test did not run" are distinguishable instead of
            # both printing the same unhelpful line.
            seen = (rep or {}).get("film_mode_env")
            if not a.film_mode_test:
                # Not asked for. Not a failure, and saying so keeps the tool
                # from crying wolf on every ordinary run.
                print("    %-14s not run (pass --film-mode-test)" % tag)
                continue
            if seen:
                print("    %-14s Godot SAW the flag (=%s) and the test still "
                      "did not run -- look in _test_film_mode" % (tag, seen))
                fails.append("film mode test did not run in the %s build "
                             "despite the flag arriving" % tag)
            elif seen == "":
                print("    %-14s Godot did NOT see the flag -- the env var is "
                      "not crossing into the engine on this platform" % tag)
                fails.append("LUX_OPTIONAL_FILM_MODE did not reach Godot in "
                             "the %s build" % tag)
            else:
                print("    %-14s not run (pass --film-mode-test)" % tag)
            continue
        want = (tag == "film present")
        got = bool(fm.get("active_on"))
        print("    %-14s film_mode ON -> active=%-5s | OFF -> active=%-5s "
              "| preset left clean=%s"
              % (tag, got, fm.get("active_off"), fm.get("preset_unmutated")))
        if got != want:
            fails.append("film mode active=%s in the %s build, expected %s"
                         % (got, tag, want))
        # A TEST THAT LEAVES STATE BEHIND BREAKS ITS NEIGHBOURS SILENTLY, and
        # this one already did: set_film_mode() moves the film master, so the
        # first run of the reordered probe left the master off and the cleanup
        # test below reported that it "never got film running". That was found
        # by the cleanup test refusing to pass itself, which is luck, not
        # coverage. Asserted here so the next leak fails where it happens.
        if fm.get("master_restored") is False:
            fails.append("the film-mode test did not restore the film master "
                         "in the %s build -- every test after it is now "
                         "running against state it did not set" % tag)
        if not fm.get("preset_unmutated"):
            fails.append("film mode MUTATED the preset it was pointed at in "
                         "the %s build; it must apply an override so a "
                         "shipped resource is not left filmed" % tag)

    # --- does the feature put the viewport back when it is done? ---
    cu = a_rep.get("cleanup") or {}
    if cu:
        print("")
        print("  VIEWPORT CLEANUP -- film_manage_hdr_2d raises the 2D target;")
        print("  raising is the easy half, restoring is the half worth testing")
        print("    before          use_hdr_2d = %s" % cu.get("before"))
        print("    film running    use_hdr_2d = %s   (film_active=%s)"
              % (cu.get("during"), cu.get("film_active")))
        print("    film disabled   use_hdr_2d = %s" % cu.get("after_disable"))
        print("    after _exit_tree with film still ON: use_hdr_2d = %s"
              % cu.get("after_exit_tree"))
        if not cu.get("film_active"):
            fails.append("the cleanup test never got film running, so it "
                         "measured nothing -- raising was not exercised")
        elif cu.get("during") == cu.get("before"):
            fails.append("film ran but the viewport was never raised, so the "
                         "restore below proves nothing")
        else:
            if cu.get("after_disable") != cu.get("before"):
                fails.append("disabling film left use_hdr_2d at %s, not the %s "
                             "it found" % (cu.get("after_disable"),
                                           cu.get("before")))
            if cu.get("after_exit_tree") != cu.get("before"):
                fails.append("a LuxRoot leaving the tree with film still on "
                             "left use_hdr_2d at %s, not the %s it found -- a "
                             "level unload would leak the format"
                             % (cu.get("after_exit_tree"), cu.get("before")))

    print("")
    if fails:
        for f in fails:
            print("  FAILURE: " + f)
    else:
        print("  %d shipped presets. None asks for film, none activated it,"
              % len(names))
        print("  and deleting the film shader and grain asset moves none of")
        print("  them further than two runs of the SAME build already move")
        print("  each other. Optionality is a measured property here, not a")
        print("  claim, and the bar is EXACT EQUALITY: the legacy grain is")
        print("  silenced for the comparison, so the render is deterministic")
        print("  and there is no floor left for a difference to hide in.")
    if a.keep:
        print("")
        print("  mirrors kept at " + base)
    else:
        shutil.rmtree(base, ignore_errors=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
