"""Compile the Lux film shader in a real engine and grade what it renders.

    python lux/tools/film_render_probe.py

WHY THIS EXISTS SEPARATELY FROM film_math_probe.py. That one evaluates the film
math in numpy and proves the MODEL. This compiles the actual `.gdshader` in
Godot, renders known patches through it, and compares the result to the model.
Where they agree the model can be trusted for cases too expensive to render;
where they disagree one of them is wrong. A model alone can be a correct
description of a shader that does not compile.

WHY IT BUILDS ITS OWN PROJECT. The shader is standalone GLSL -- it references no
Lux class -- so the smallest thing that can compile it is two shaders, one PNG
and a `project.godot`. Running it inside the Lux project instead would drag in
presets, the sample scene and the plugin, any of which can fail for reasons that
have nothing to do with the shader and would be reported as if they did.
`film_precision_probe.py` is the tool that asks about the real project.

WHY IT RUNS TWICE. `rendering/viewport/hdr_2d` decides the render target format,
and the format decides whether section 45's acceptance metric means anything at
all. Both passes are run and both are reported, because the interesting result
is the DIFFERENCE: the baseline shader's grain is chroma-free by construction,
so whatever chroma noise it measures is the floor the output format imposes.

WHAT `--perf` ADDS. Section 41 budgets film emulsion at about 2% of the frame
and section 50 asks for a resolution matrix; neither had ever been measured.
`--perf` times three configurations at each resolution -- no post pass, the
baseline shader, the film shader -- using the engine's own per-viewport GPU
timer rather than a wall clock, because a CPU-side clock around a draw call
measures submission and not execution. Only the DIFFERENCE is meaningful: the
scene is empty, so the absolute number is the cost of one ColorRect, while
`film - baseline` is the thing section 41 is written against and is
scene-independent to first order because the pass is full-screen.

It also prices `hdr_2d` in milliseconds, which is a different question from
whether film is affordable and deserves its own answer.

NEEDS A DISPLAY. `--headless` disables rendering. On a Linux box without one
this wraps in xvfb-run, which means llvmpipe -- fine for arithmetic and for the
render target format, and REFUSED for speed: a software adapter is detected and
the section 41 grading is reported as n/a rather than as four alarming failures.
"""
import argparse
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
PROBE = os.path.join(HERE, "film_render_probe.gd")
MARK_BEGIN = "<<<FILM_RENDER_JSON"
MARK_END = "FILM_RENDER_JSON>>>"

ASSETS = [
    "addons/lux/shaders/post/lux_ordered_dither_film.gdshader",
    "addons/lux/shaders/post/lux_ordered_dither.gdshader",
    "addons/lux/resources/film/grain_balanced.png",
    "addons/lux/resources/film/grain_balanced.png.import",
]

PROJECT = '''config_version=5

[application]
config/name="Lux Film Render Probe"
config/features=PackedStringArray("4.7", "Forward Plus")

[display]
window/size/viewport_width=512
window/size/viewport_height=512

[rendering]
renderer/rendering_method="forward_plus"
environment/defaults/default_environment=""
'''

#: NO {int: name} MAP HERE, DELIBERATELY. There was one, and it was wrong: it
#: had 11 as RGBH, when 11 is RGBAF and 14 is RGBH. It reported llvmpipe's
#: 32-bit float target as 16-bit and the error survived into three documents
#: before an RTX 2060 returned a format id the table did not contain at all.
#: The probe now names the format from the engine's own constants and this side
#: just prints what it is told.
def _fmt(d):
    return d.get("readback_format_name") or ("format id %s" % d["readback_format"])


#: TDD section 41. Film emulsion may use ~2% of the target frame budget.
SECTION_41 = [(30, 33.33, 0.67), (60, 16.67, 0.33),
              (90, 11.11, 0.22), (120, 8.33, 0.17)]

#: TDD section 50's resolution matrix, minus 1280x800 which differs from
#: 1280x720 by 11% of the pixels and would not separate anything.
PERF_RESOLUTIONS = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]


def build_project(dest, hdr_2d, size=(512, 512), cost=None):
    for rel in ASSETS:
        src = os.path.join(LUX, rel)
        if not os.path.isfile(src):
            raise ProbeFailed("missing asset: " + src)
        dst = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    shutil.copy2(PROBE, os.path.join(dest, "film_render_probe.gd"))
    text = PROJECT
    if hdr_2d:
        text = text.replace('renderer/rendering_method="forward_plus"',
                            'renderer/rendering_method="forward_plus"\n'
                            'viewport/hdr_2d=true')
    text = text.replace("window/size/viewport_width=512",
                        "window/size/viewport_width=%d" % size[0])
    text = text.replace("window/size/viewport_height=512",
                        "window/size/viewport_height=%d" % size[1])
    if cost:
        warmup, frames = cost
        text += ("\n[film_probe]\n\nmeasure_cost=true\n"
                 "warmup_frames=%d\ntimed_frames=%d\n" % (warmup, frames))
    with open(os.path.join(dest, "project.godot"), "w", encoding="utf-8") as f:
        f.write(text)


def run(godot, hdr_2d, timeout, verbose, size=(512, 512), cost=None):
    dest = tempfile.mkdtemp(prefix="film_render_")
    try:
        build_project(dest, hdr_2d, size, cost)
        subprocess.run([godot, "--headless", "--path", dest, "--import"],
                       capture_output=True, text=True, timeout=timeout)
        cmd = _display_wrapper() + [
            godot, "--path", dest, "-s", "res://film_render_probe.gd"]
        if verbose:
            print("  [probe] " + " ".join(cmd))
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(re.escape(MARK_BEGIN) + r"\s*(.*?)\s*" + re.escape(MARK_END),
                      out, re.S)
        if not m:
            tail = "\n".join(out.strip().splitlines()[-25:])
            raise ProbeFailed(
                "the probe never printed its result fence, so nothing was "
                "measured. Godot exited " + str(r.returncode) + ".\n"
                "  Last of its output:\n" + tail)
        return json.loads(m.group(1)), out
    finally:
        shutil.rmtree(dest, ignore_errors=True)


def ratio(case):
    return (case["chroma_noise"] / case["luma_noise"]
            if case["luma_noise"] else float("nan"))


def span(case):
    mid = (case["sat_min"] + case["sat_max"]) / 2.0
    return (case["sat_max"] - case["sat_min"]) / mid if mid else 0.0


def report(runs):
    fails = []
    a = runs[False]
    print("  Godot %s | %s | %s"
          % (a["godot"], a["rendering_method"], a["adapter"]))
    print("")
    for hdr, d in sorted(runs.items()):
        print("  hdr_2d=%-5s render target %s" % (str(hdr).lower(), _fmt(d)))
    print("")

    # --- 1. does it compile ---
    print("  COMPILE -- film off must return the input unchanged")
    for hdr, d in sorted(runs.items()):
        for key in ("identity_gray", "identity_orange"):
            c = d[key]
            ok = c["luma_noise"] == 0.0 and c["distinct_r_codes"] == 1
            print("    %s hdr_2d=%-5s %-16s luma_noise %.6f, %d distinct code(s)"
                  % ("ok  " if ok else "FAIL", str(hdr).lower(), key,
                     c["luma_noise"], c["distinct_r_codes"]))
            if not ok:
                fails.append("%s did not round-trip at hdr_2d=%s -- the film "
                             "shader did not compile, or a stage that should "
                             "be neutral is not." % (key, hdr))
    print("")

    # --- 2. section 45, on the neutral patch it is specified for ---
    print("  SECTION 45 -- on the CONSTANT NEUTRAL PATCH the section specifies")
    for hdr, d in sorted(runs.items()):
        r = ratio(d["film_max_gray"])
        print("    hdr_2d=%-5s chroma/luma %.4f   (hard < 0.40, preferred < 0.20)"
              % (str(hdr).lower(), r))
    if ratio(runs[True]["film_max_gray"]) >= 0.4:
        fails.append("section 45's hard bar is missed on the neutral patch even "
                     "at 16-bit output; that is the model, not the format.")
    print("")

    # --- 3. the floor the output format imposes ---
    print("  THE NOISE FLOOR -- the baseline grain is chroma-free BY")
    print("  CONSTRUCTION, so whatever chroma it measures is the format's")
    for hdr, d in sorted(runs.items()):
        print("    hdr_2d=%-5s baseline chroma_noise: gray %.6f  orange %.6f  shadow %.6f"
              % (str(hdr).lower(), d["baseline_gray"]["chroma_noise"],
                 d["baseline_orange"]["chroma_noise"],
                 d["baseline_shadow"]["chroma_noise"]))
    print("")

    # --- 4. the control that keeps the metric honest ---
    print("  CONTROL -- section 45's metric with the chroma term OFF entirely")
    for hdr, d in sorted(runs.items()):
        print("    hdr_2d=%-5s neutral %.4f   orange %.4f"
              % (str(hdr).lower(), ratio(d["chroma_off_gray"]),
                 ratio(d["chroma_off_orange"])))
    off = ratio(runs[True]["chroma_off_orange"])
    on = ratio(runs[True]["film_max_orange"])
    print("    On a coloured patch the metric reads %.2f with NO chroma term at"
          % off)
    print("    all, against %.2f with it. std(R-G) there is driven by the shared" % on)
    print("    transmission multiplying a non-zero R-G -- it is not a chroma")
    print("    measurement. Do not read it as a failure, and do not 'fix' it by")
    print("    reducing film_chroma_ratio.")
    print("")

    # --- the rainbow, which is the defect the feature is actually aimed at ---
    print("  THE RAINBOW -- quantization on a FLAT coloured patch, grain off,")
    print("  so everything measured was put there by the quantizer")
    print("    %-8s %-14s %14s %14s" % ("", "", "per-channel", "shared"))
    worst_per, worst_shared = 0.0, 0.0
    for hdr, d in sorted(runs.items()):
        for patch in ("orange", "red"):
            kp = "quantize_perchannel_%s" % patch
            ks = "quantize_shared_%s" % patch
            if kp not in d or ks not in d:
                continue
            sp, ss = span(d[kp]), span(d[ks])
            worst_per = max(worst_per, sp)
            worst_shared = max(worst_shared, ss)
            print("    hdr=%-5s %-14s %13.6f %14.6f"
                  % (str(hdr).lower(), patch, sp, ss))
    if worst_per > 0.0 or worst_shared > 0.0:
        if worst_per <= 1e-6:
            fails.append("per-channel quantization moved saturation by nothing "
                         "on any patch -- the defect this feature targets did "
                         "not reproduce, so the fix below proves nothing.")
        if worst_shared > 1e-4:
            fails.append("a SHARED quantization decision still moved saturation "
                         "by %.6f; it is a scalar multiplier and should move it "
                         "by nothing." % worst_shared)
        print("    saturation spread: per-channel up to %.6f, shared up to %.6f"
              % (worst_per, worst_shared))
        print("    A shared decision is one multiplier applied to three")
        print("    channels, so hue and saturation survive it exactly. The")
        print("    rainbow in the retro look is HERE, in the quantizer, and")
        print("    not in any grain.")
    print("")

    # --- 5. the result that is actually the point ---
    print("  SATURATION -- what the density model exists to preserve")
    print("    %-10s %-24s %-24s" % ("", "film (default strength)", "baseline Simple grain"))
    for hdr, d in sorted(runs.items()):
        for label, fk, bk in (("orange", "film_default_orange", "baseline_orange"),
                              ("shadow", "film_default_shadow", "baseline_shadow")):
            print("    hdr_2d=%-5s %-7s %8.2f%% span            %8.2f%% span"
                  % (str(hdr).lower(), label, 100 * span(d[fk]), 100 * span(d[bk])))
    print("")

    # --- 6. is the effect even representable ---
    print("  REPRESENTABILITY -- distinct 8-bit codes the grain produced")
    for hdr, d in sorted(runs.items()):
        print("    hdr_2d=%-5s film at default strength, neutral patch: %d code(s)"
              % (str(hdr).lower(), d["film_default_gray"]["distinct_r_codes"]))
    if runs[False]["film_default_gray"]["distinct_r_codes"] <= 3:
        print("    At 8-bit output the default grain is close to sub-LSB: it")
        print("    spans a couple of codes, so most of it is rounded away. That")
        print("    is an argument for hdr_2d that costs nothing to state.")
    print("")

    if fails:
        for f in fails:
            print("  FAILURE: " + f)
    return len(fails)


#: Adapters that are not GPUs. A timing number from one of these is a
#: measurement of a CPU pretending, and grading it against a frame budget
#: produces four alarming OVER lines that mean nothing -- which is how a
#: guardrail teaches people to ignore it.
SOFTWARE_ADAPTERS = ("llvmpipe", "softpipe", "swiftshader", "lavapipe",
                     "microsoft basic render")


def is_software(adapter):
    a = (adapter or "").lower()
    return any(k in a for k in SOFTWARE_ADAPTERS)


def report_cost(perf, adapter):
    """perf: {(w, h, hdr): payload}. Prints the section 41 comparison."""
    soft = is_software(adapter)
    print("  COST -- GPU time for the post pass, engine's own viewport timer")
    print("  Only the DIFFERENCE means anything: the absolute number is one")
    print("  ColorRect on an empty scene. `film - baseline` is what section 41")
    print("  budgets, and `baseline - none` is what the pass already cost.")
    print("")
    print("    %-11s %-7s %9s %9s %9s   %10s %10s"
          % ("resolution", "hdr_2d", "no post", "baseline", "film",
             "film-base", "p99 delta"))
    deltas = {}
    for (w, h, hdr), d in sorted(perf.items()):
        c = d.get("cost")
        if not c:
            continue
        none = c["no_post"]["median_ms"]
        base = c["baseline"]["median_ms"]
        film = c["film"]["median_ms"]
        delta = film - base
        p99 = c["film"]["p99_ms"] - c["baseline"]["p99_ms"]
        deltas[(w, h, hdr)] = (delta, p99)
        print("    %-11s %-7s %8.4f %8.4f %8.4f   %9.4f %10.4f"
              % ("%dx%d" % (w, h), str(hdr).lower(), none, base, film, delta, p99))
    print("")

    # The coherent quantizer, priced. It is the part of the feature most
    # likely to be switched on and was the last part never timed.
    have_q = any("quant_shared" in (d.get("cost") or {}) for d in perf.values())
    if have_q:
        print("  THE COHERENT QUANTIZER -- dither ON, per-channel against shared")
        print("    %-11s %-7s %10s %10s %10s"
              % ("resolution", "hdr_2d", "per-chan", "shared", "shared-per"))
        for (w, h, hdr), d in sorted(perf.items()):
            c = d.get("cost") or {}
            if "quant_shared" not in c:
                continue
            qp = c["quant_perchannel"]["median_ms"]
            qs = c["quant_shared"]["median_ms"]
            print("    %-11s %-7s %10.4f %10.4f %10.4f"
                  % ("%dx%d" % (w, h), str(hdr).lower(), qp, qs, qs - qp))
        print("")

    # The hdr_2d question, priced in time as well as in memory.
    print("  THE COST OF hdr_2d ITSELF, which is a separate question from film")
    for w, h in sorted({(w, h) for (w, h, _) in perf}):
        a = perf.get((w, h, False), {}).get("cost")
        b = perf.get((w, h, True), {}).get("cost")
        if not (a and b):
            continue
        print("    %-11s baseline pass %.4f -> %.4f ms  (%+.4f, %+.1f%%)"
              % ("%dx%d" % (w, h), a["baseline"]["median_ms"],
                 b["baseline"]["median_ms"],
                 b["baseline"]["median_ms"] - a["baseline"]["median_ms"],
                 100.0 * (b["baseline"]["median_ms"] / a["baseline"]["median_ms"] - 1.0)
                 if a["baseline"]["median_ms"] else 0.0))
    print("")

    # Section 41 is graded at the WORST cell in the matrix, not at the most
    # likely one. Grading 1920x1080 and printing four "ok" lines while
    # 3840x2160 sits at 1.79% of a 120 fps frame would be a guardrail that
    # passes the case nobody was worried about.
    if not deltas:
        return 0
    ref = max(deltas, key=lambda k: deltas[k][0])
    delta, p99 = deltas[ref]
    print("  SECTION 41 -- budget is ~2%% of the frame, graded at the WORST cell")
    print("  in the matrix: %dx%d hdr_2d=%s, film costs %.4f ms"
          % (ref[0], ref[1], str(ref[2]).lower(), delta))
    print("  Section 50 asks for 95th percentile; the p99 delta is shown too.")
    fails = 0
    for fps, frame_ms, budget in SECTION_41:
        ok = delta <= budget
        if soft:
            verdict = "n/a "
        elif ok:
            verdict = "ok  "
        else:
            verdict = "OVER"
            fails += 1
        print("    %s %3d fps  frame %6.2f ms  budget %.2f ms  film uses %5.2f%% "
              "of frame" % (verdict, fps, frame_ms, budget,
                            100.0 * delta / frame_ms))
    print("")
    if not soft:
        tightest = min((budget - delta) / budget for _, _, budget in SECTION_41)
        print("  Tightest margin across the four frame rates: %.0f%% of budget"
              " to spare." % (100.0 * tightest))
        if tightest < 0.25:
            print("  That is thin. The measurement is a FLOOR (empty scene), so")
            print("  a real level can only be worse -- treat this cell as")
            print("  unproven rather than passed until a level is measured.")
        print("")
    if soft:
        print("  NOT GRADED: the adapter is %s, a software rasteriser." % adapter)
        print("  These timings measure a CPU pretending to be a GPU and are")
        print("  reported so the plumbing can be checked, not so they can be")
        print("  quoted. Section 41 is UNMEASURED until this runs on real")
        print("  hardware; nothing above is a pass and nothing is a failure.")
        print("")
        return 0
    print("  THIS IS A FLOOR, NOT A VERDICT. The pass is measured over an empty")
    print("  scene, so there is no other GPU work competing for bandwidth with")
    print("  it -- on a real level the same shader can cost more. It is a full-")
    print("  screen pass, so the cost is scene-independent to first order, which")
    print("  is why the number is worth having; but section 50's matrix also")
    print("  wants VRAM, RAM, bandwidth, power and shader stalls, and none of")
    print("  those are measured here. Section 51's hardware sweep is untouched.")
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--godot", default=None)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--json", default=None)
    ap.add_argument("--perf", action="store_true",
                    help="also measure GPU cost across section 50's resolutions")
    ap.add_argument("--perf-frames", type=int, default=600,
                    help="timed frames per configuration (default 600)")
    ap.add_argument("--perf-warmup", type=int, default=120,
                    help="frames rendered and discarded first (default 120)")
    ap.add_argument("--perf-resolutions", default=None,
                    help="comma-separated WxH list; default is section 50's "
                         "matrix. A software rasteriser cannot finish 4K in "
                         "any sensible time -- narrow it there.")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    print("film render probe -- compiles the shader and grades what it draws")
    try:
        godot = require_godot(a.godot)
        runs = {}
        for hdr in (False, True):
            runs[hdr], raw = run(godot, hdr, a.timeout, a.verbose)
            if a.verbose:
                for line in raw.splitlines():
                    if "ERROR" in line or "error" in line:
                        print("  | " + line)
        perf = {}
        if a.perf:
            cost = (a.perf_warmup, a.perf_frames)
            res = PERF_RESOLUTIONS
            if a.perf_resolutions:
                res = [tuple(int(v) for v in r.lower().split("x"))
                       for r in a.perf_resolutions.split(",")]
            for (w, h) in res:
                for hdr in (False, True):
                    print("  timing %dx%d hdr_2d=%s ..."
                          % (w, h, str(hdr).lower()))
                    perf[(w, h, hdr)], _ = run(godot, hdr, a.timeout,
                                               a.verbose, (w, h), cost)
    except ProbeFailed as e:
        print("")
        print("  NOTHING MEASURED: " + str(e))
        return 2

    print("")
    n = report(runs)
    if perf:
        n += report_cost(perf, runs[False].get("adapter"))
    if a.json:
        out = {str(k).lower(): v for k, v in runs.items()}
        if perf:
            out["cost"] = {"%dx%d_hdr_%s" % (w, h, str(hdr).lower()): v
                           for (w, h, hdr), v in perf.items()}
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=2)
        print("  wrote " + a.json)
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
