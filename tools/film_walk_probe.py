"""The walk: film emulsion on real pipeline geometry, and what it does to it.

    python lux/tools/film_walk_probe.py

Roadmap item 61 names "the walk as the final judge", and everything measured
before this ran on a blockout of untextured boxes -- no Patina vertex bake, no
tiled trim, no modular repetition, no signage, no fixture hardware. Film
response is a treatment of what the lighting does, so an empty scene can only
show the arithmetic is right, which was already known.

This stages a real level (default: the night strip Lux ships in
`walk/headless/`), shoots it from four viewpoints derived from the scene's own
bounds, three times -- film off, film on with per-channel quantization, film on
with the shared decision -- and measures three things on the results:

  RAINBOW      hue edges per scanline, which is the defect the feature is for.
  EXPOSURE     response by luminance band, on real geometry rather than patches.
  REPETITION   roadmap item 57's question, and the reason it is here: film
               grain is SCREEN-space, so two identical wall modules no longer
               render identically. Whether that actually loosens the module
               grid is measurable as the strength of the periodic peak in the
               facade's autocorrelation, and nobody had measured it.

It writes the stills so a human can judge them, because the walk's verdict is
not a number.
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_FACTORY_TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
if os.path.isdir(_FACTORY_TOOLS):
    sys.path.insert(0, _FACTORY_TOOLS)
from godot_probe import ProbeFailed, require_godot, _display_wrapper  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LUX = os.path.normpath(os.path.join(HERE, ".."))
PROBE = os.path.join(HERE, "film_walk_probe.gd")
MARK_BEGIN = "<<<FILM_WALK_JSON"
MARK_END = "FILM_WALK_JSON>>>"

DEFAULT_LIGHTS = "res://walk/headless/night_strip.site.lights.json"

#: The night strip as walk/headless/walk_night_strip.gd composes it. A staged
#: site is a COMPOSITION: `night_strip_fixtures.glb` holds only the fixture
#: hardware, and the buildings are separate GLBs placed at these transforms.
#: Loading the fixtures alone renders lit lamp faces in a void -- which the
#: first version of this tool did, and then reported statistics off it.
#: Positions are lifted from that harness's own STORES table.
DEFAULT_SITE = [
    {"glb": "res://walk/headless/night_deli.patina.glb", "pos": [-34, 0, -21]},
    {"glb": "res://walk/headless/night_deli_dressing.glb", "pos": [-34, 0, -21]},
    {"glb": "res://walk/headless/night_pawn.patina.glb", "pos": [0, 0, -9]},
    {"glb": "res://walk/headless/night_pawn_dressing.glb", "pos": [0, 0, -9]},
    {"glb": "res://walk/headless/night_auto.patina.glb", "pos": [28, 0, -11]},
    {"glb": "res://walk/headless/night_auto_dressing.glb", "pos": [28, 0, -11]},
    # The fixtures GLB bakes its own world transforms, so it goes at origin.
    {"glb": "res://walk/headless/night_strip_fixtures.glb", "pos": [0, 0, 0]},
]

#: Cameras for that site. Explicit, because a camera derived from the AABB is a
#: guess about where the ground is and this site's bounds reach y = -8 -- which
#: put the derived eye underground and framed 105 m of street so the buildings
#: were a thin band in a black frame. Every statistic off that is measuring sky.
#: Buildings front onto the sidewalk at about z = -2 and stand ~11 m tall.
DEFAULT_CAMERAS = [
    # Pulled in from z=26. At 38 m of standoff this framed 8.5% lit pixels
    # and 91% night sky, and every whole-frame statistic off it was an
    # average of the level and a great deal of nothing.
    {"name": "01_strip", "eye": [-5, 2.2, 13], "at": [-4, 3.4, -10]},
    {"name": "02_pawn_front", "eye": [1, 1.7, 9], "at": [0, 3.2, -9]},
    # The raking angle is the shot item 57 is actually about, so it stays --
    # but at 52 m across the whole strip it was 5.4% lit. Same angle, run
    # along the deli->pawn facade line at a standoff that fills the frame.
    {"name": "03_facade_raking", "eye": [-30, 1.7, 4], "at": [2, 3.0, -4]},
    {"name": "04_pool", "eye": [28, 1.7, 4], "at": [28, 3.4, -11]},
]

REC709 = (0.2126, 0.7152, 0.0722)


def run(godot, project, site, cameras, lights, preset, out_dir, timeout,
        verbose):
    os.makedirs(out_dir, exist_ok=True)
    # Copied into the project ROOT so it is addressable as res://, then
    # REMOVED again. Leaving it behind put a stray film_walk_probe.gd outside
    # tools/, where the optionality probe's reference check correctly reported
    # it as a dangling reference to the film feature -- a real failure caused
    # entirely by this function not tidying up after itself.
    dst = os.path.join(project, "film_walk_probe.gd")
    made_copy = os.path.abspath(dst) != os.path.abspath(PROBE)
    if made_copy:
        import shutil
        shutil.copy2(PROBE, dst)
    env = dict(os.environ)
    env["LUX_WALK_SITE"] = json.dumps(site)
    env["LUX_WALK_CAMERAS"] = json.dumps(cameras)
    env["LUX_WALK_GLB"] = ""
    env["LUX_WALK_LIGHTS"] = lights
    env["LUX_WALK_OUT"] = os.path.abspath(out_dir).replace("\\", "/")
    env["LUX_WALK_PRESET"] = preset
    subprocess.run([godot, "--headless", "--path", project, "--import"],
                   capture_output=True, text=True, timeout=timeout)
    cmd = _display_wrapper() + [godot, "--path", project,
                                "-s", "res://film_walk_probe.gd"]
    if verbose:
        print("  [probe] " + " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                       env=env)
    if made_copy:
        for leftover in (dst, dst + ".uid"):
            try:
                os.remove(leftover)
            except OSError:
                pass
    out = (r.stdout or "") + (r.stderr or "")
    for line in out.splitlines():
        if line.startswith("[film_walk]") or line.startswith("[lux]"):
            print("  " + line)
    m = re.search(re.escape(MARK_BEGIN) + r"\s*(.*?)\s*" + re.escape(MARK_END),
                  out, re.S)
    if not m:
        tail = "\n".join(out.strip().splitlines()[-25:])
        raise ProbeFailed("the probe never printed its fence, so nothing was "
                          "measured. Godot exited %s.\n  Last output:\n%s"
                          % (r.returncode, tail))
    return json.loads(m.group(1))


def _load(path):
    import numpy as np
    from PIL import Image
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64) / 255.0


def hue(rgb):
    import numpy as np
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    d = mx - mn
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    h = np.zeros_like(mx)
    nz = d > 1e-9
    dd = np.where(nz, d, 1.0)
    h = np.where(nz & (mx == r), ((g - b) / dd) % 6.0, h)
    h = np.where(nz & (mx == g), (b - r) / dd + 2.0, h)
    h = np.where(nz & (mx == b), (r - g) / dd + 4.0, h)
    return np.where(nz, (h * 60.0) % 360.0, np.nan)


def hue_edges(img):
    """Neighbouring pixels whose hue jumps more than 15 degrees, per scanline.

    Averaged over the middle half of the rows: the top of a night frame is
    mostly sky and the bottom mostly ground, and neither carries the light
    pools this is asking about.
    """
    import numpy as np
    h, w, _ = img.shape
    lum = img @ np.array(REC709)
    counts = []
    for y in _lit_rows(lum, 8):
        hv = hue(img[y])
        v = hv[~np.isnan(hv)]
        if v.size < 32:
            continue
        d = np.abs(np.diff(v))
        d = np.minimum(d, 360.0 - d)
        counts.append(int((d > 15.0).sum()))
    return float(np.mean(counts)) if counts else float("nan")


#: A row must carry this much light before a statistic is taken off it. A
#: night frame is mostly sky, and `std > 1e-4` lets a black row through on
#: sensor noise alone -- so the old statistics were an average of the level
#: and a large number of rows of nothing, weighted by how much nothing.
ROW_LIGHT_FLOOR = 0.02


def _lit_rows(lum, step):
    """Row indices, over the middle third, carrying enough light to measure."""
    h = lum.shape[0]
    out = []
    for y in range(h // 3, 2 * h // 3, step):
        if lum[y].mean() >= ROW_LIGHT_FLOOR:
            out.append(y)
    return out


def _ac(row):
    """Normalised autocorrelation of a mean-subtracted row, lag 0 first."""
    import numpy as np
    row = row - row.mean()
    ac = np.correlate(row, row, mode="full")[len(row) - 1:]
    if ac[0] <= 0:
        return None
    return ac / ac[0]


def _prominence(row, w, lo=8):
    """Height of the strongest LOCAL bump in the autocorrelation above its
    own decay envelope.

    RETRACTION -- WHAT THIS REPLACES, AND WHY THE OLD NUMBERS ARE VOID.
    The first version of this reported ``ac[8:w/3].max()`` and called it a
    repetition measure. It is not one. Autocorrelation of any low-pass
    signal falls monotonically from lag 0, so that max is almost always the
    value at lag 8 -- a SMOOTHNESS measure wearing a periodicity label. It
    is worse than useless: on a synthetic blob with no periodicity at all it
    reads 0.976, and ADDING a real 40 px module DROPS it to 0.916, because
    the module's variance decorrelates the short lag. It ranked the wrong
    way round. Every "repetition" figure this tool printed before this
    change is void, including the reading that film raised the peak; that
    was the metric, not the film.

    A repeated module puts a BUMP at its pixel pitch standing above the
    smooth decay, so the honest statistic is the bump's height above a wide
    moving average of the autocorrelation itself. Validated by
    ``--self-test``, which is part of this tool because a metric that was
    wrong once should carry its own proof.

    Returns (prominence, lag, found) -- the lag is the module pitch in pixels
    and `found` is False when the bump sits on the search window's first lag,
    which means no interior peak exists.
    """
    import numpy as np
    ac = _ac(row)
    if ac is None:
        return None
    hi = max(lo + 8, min(w // 3, len(ac)))
    if hi - lo < 12:
        return None
    k = max(5, (hi - lo) // 8)
    if k % 2 == 0:
        k += 1
    # The envelope runs from lag 0, not from lo, so that lo sits INSIDE it.
    # Detrending only ac[lo:] put the moving average's padded edge exactly at
    # lo, where the autocorrelation is still falling steeply; the envelope
    # under-read there and every pitch came back as lo itself. The tail is
    # trimmed by the same half-window for the same reason.
    seg = ac[:hi]
    env = np.convolve(np.pad(seg, (k // 2, k // 2), mode="edge"),
                      np.ones(k) / k, mode="valid")
    d = (seg - env)[lo:hi - k // 2]
    if d.size == 0:
        return None
    i = int(d.argmax())
    # argmax ALWAYS returns something. When the strongest bump sits on the
    # first lag searched, there is no interior peak and what is being reported
    # is the edge of the search window, not a module -- the same failure as
    # the metric this replaced, one level down. Say so instead of returning a
    # number that looks like a measurement.
    return float(d[i]), lo + i, i > 0


def repetition_peak(img):
    """Strength of the strongest periodic structure along a facade scanline.

    Roadmap item 57/74: every wall is the same module and it reads as a grid.
    Film grain is SCREEN-space -- two identical modules get different grain --
    so if film loosens the grid at all, this prominence drops.

    Returns (mean prominence, median module pitch in px, fraction of rows
    where an INTERIOR bump was found -- below about 0.5 the shot carries no
    module periodicity and the prominence column is search-window floor).
    """
    import numpy as np
    h, w, _ = img.shape
    lum = img @ np.array(REC709)
    vals, lags, found = [], [], []
    for y in _lit_rows(lum, 6):
        row = lum[y]
        if row.std() < 1e-4:
            continue
        r = _prominence(row, w)
        if r is None:
            continue
        vals.append(r[0])
        lags.append(r[1])
        found.append(bool(r[2]))
    if not vals:
        return float("nan"), float("nan"), 0.0
    return (float(np.mean(vals)), float(np.median(lags)),
            float(np.mean(found)))


def measured_rows(img):
    """How many rows passed the light gate -- the sample size behind a cell."""
    import numpy as np
    return len(_lit_rows(img @ np.array(REC709), 6))


def self_test():
    """Prove the repetition metric ranks periodicity, not smoothness.

    Runs before the walk. If this fails, the walk's item-57 column is
    meaningless and the tool says so instead of printing numbers.
    """
    import numpy as np
    w = 640
    x = np.arange(w)
    blob = np.exp(-((x - w / 2.0) ** 2) / (2 * 120.0 ** 2))
    rng = np.random.default_rng(0)
    cases = [
        ("flat blob, no periodicity", blob),
        ("blob + grain, no periodicity", blob + rng.normal(0, 0.02, w)),
        ("blob + 40px module, weak", blob + 0.05 * np.sin(2 * np.pi * x / 40.0)),
        ("blob + 40px module, strong", blob + 0.15 * np.sin(2 * np.pi * x / 40.0)),
    ]
    got = []
    for name, sig in cases:
        r = _prominence(sig, w)
        got.append((name, r[0], r[1]))
    ok = True
    # 1. periodicity must outrank its absence
    floor = max(got[0][1], got[1][1])
    if not (got[2][1] > floor and got[3][1] > got[2][1]):
        ok = False
    # 2. grain alone must not be mistaken for a module
    if got[1][1] > got[0][1] * 1.5:
        ok = False
    # 3. the reported pitch must be the real one
    if not (36 <= got[3][2] <= 44):
        ok = False
    return ok, got


#: Every state the walk shoots, in the order it shoots them. hdr_only is the
#: control and is not optional -- see the note where it is printed.
STATES = ("film_off", "hdr_only", "film_perchannel", "film_shared")


def _table(states, shots, fn, fmt):
    """One row per shot, one column per state, same statistic across."""
    print("    %-18s" % "shot" + "".join("%16s" % s for s in STATES))
    for sh in shots:
        cells = []
        for st in STATES:
            d = states.get(st, {}).get("shots", {}).get(sh)
            p = d["path"] if d else None
            cells.append(fn(_load(p)) if p and os.path.isfile(p)
                         else float("nan"))
        print("    %-18s" % sh + "".join(("%16s" % (fmt % c)) for c in cells))


def band_response(a, b):
    """Mean |difference| by luminance band of the FILM-OFF frame."""
    import numpy as np
    lum = a @ np.array(REC709)
    d = np.abs(b - a)
    rows = []
    for lo, hi in [(0.0, 0.05), (0.05, 0.10), (0.10, 0.20), (0.20, 0.35),
                   (0.35, 0.55), (0.55, 1.01)]:
        m = (lum >= lo) & (lum < hi)
        if m.sum() < 200:
            continue
        mid = max((lo + hi) / 2.0, 1e-6)
        rows.append((lo, hi, int(m.sum()), float(d[m].mean()),
                     float(d[m].mean() / mid)))
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project", default=LUX)
    ap.add_argument("--site", default=None,
                    help="JSON file: [{glb, pos}] to compose. Default is the "
                         "night strip as walk_night_strip.gd places it.")
    ap.add_argument("--lights", default=DEFAULT_LIGHTS)
    ap.add_argument("--preset", default="Gothic Street Night")
    ap.add_argument("--out", default=None, help="where the stills go")
    ap.add_argument("--godot", default=None)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    site = DEFAULT_SITE
    cameras = DEFAULT_CAMERAS
    if a.site:
        with open(a.site, encoding="utf-8") as f:
            site = json.load(f)
    out_dir = a.out or os.path.join(os.getcwd(), "film_walk_shots")
    print("film walk probe -- film emulsion on real pipeline geometry")
    print("  project: %s" % os.path.abspath(a.project))
    print("  site:    %d pieces" % len(site))
    print("  preset:  %s" % a.preset)
    print("  shots:   %s" % os.path.abspath(out_dir))
    print("")
    # THE METRIC PROVES ITSELF BEFORE IT JUDGES ANYTHING. The previous
    # repetition statistic ranked backwards and nothing here caught it,
    # because nothing here asked it to measure something with a known answer.
    ok, cases = self_test()
    print("  METRIC SELF-TEST -- repetition measure on signals with known")
    print("  periodicity. Must rank a real module above its absence, must not")
    print("  mistake grain for one, and must report the true pitch.")
    for name, v, lag in cases:
        print("    %-32s prominence %.4f  pitch %d px" % (name, v, lag))
    if not ok:
        print("")
        print("  ABORTED: the repetition metric fails its own test, so its")
        print("  column would be noise. Nothing measured.")
        return 2
    print("    -> PASS")
    print("")
    try:
        godot = require_godot(a.godot)
        rep = run(godot, os.path.abspath(a.project), site, cameras, a.lights,
                  a.preset, out_dir, a.timeout, a.verbose)
    except ProbeFailed as e:
        print("")
        print("  NOTHING MEASURED: " + str(e))
        return 2

    states = rep["states"]
    # THE PROBE CHECKS ITS OWN STATES. The first run of the control silently
    # shot film_shared at hdr_2d=false -- the control's reset had clobbered a
    # raise that is edge-triggered and never came back. Every number in that
    # run compared two things neither of which was what its column said.
    # THE FILM STATES NOW EXPECT hdr_2d FALSE. `film_manage_hdr_2d` defaults
    # false as of 0.29.0 -- raising the target is a tone change larger than the
    # grain it serves and it moves differently per rasteriser, so film no
    # longer touches it. That makes film_off vs film_shared a SINGLE-VARIABLE
    # comparison at 8 bits, which is what actually ships and is a better
    # attribution than the four-state version needed.
    #
    # hdr_only stays as its own control: it is still the only way to see what
    # the render target does on its own, and that question is open (section
    # 8c). It is no longer on the path any preset takes.
    want_hdr = {"film_off": False, "hdr_only": True,
                "film_perchannel": False, "film_shared": False}
    want_film = {"film_off": False, "hdr_only": False,
                 "film_perchannel": True, "film_shared": True}
    bad = []
    for st in STATES:
        d = states.get(st)
        if d is None:
            bad.append("%s: never ran" % st)
            continue
        if bool(d.get("use_hdr_2d")) != want_hdr[st]:
            bad.append("%s: hdr_2d=%s, expected %s"
                       % (st, d.get("use_hdr_2d"), want_hdr[st]))
        if bool(d.get("film_active")) != want_film[st]:
            bad.append("%s: film_active=%s, expected %s"
                       % (st, d.get("film_active"), want_film[st]))
    if bad:
        print("")
        print("  ABORTED: a state did not render in the configuration its")
        print("  column claims, so no comparison below would mean anything.")
        for b in bad:
            print("    " + b)
        return 1
    if not states.get("film_shared", {}).get("film_active"):
        print("")
        print("  FAILURE: film never activated, so nothing below compares what")
        print("  it claims to. Check the project imported the grain asset.")
        return 1

    shots = sorted(states["film_off"]["shots"])
    print("")
    print("  LIT FRACTION -- how much of each frame is above 0.05 luminance.")
    print("  A statistic taken off a mostly-black frame describes the sky.")
    for sh in shots:
        print("    %-18s %.3f" % (sh, states["film_off"]["shots"][sh]["lit"]))
    print("")
    print("  THE CONTROL. hdr_only is film OFF at the film states' render")
    print("  target. film_off -> hdr_only is the render target's own effect;")
    print("  hdr_only -> film_shared is the film's. Reading film_off against")
    print("  a film state alone cannot tell the two apart.")
    for st in STATES:
        d = states.get(st, {})
        print("    %-16s film_active=%-6s hdr_2d=%s"
              % (st, d.get("film_active"), d.get("use_hdr_2d")))

    print("")
    print("  RAINBOW -- hue edges per scanline (lower is smoother colour)")
    _table(states, shots, hue_edges, "%10.1f")

    print("")
    print("  REPETITION -- item 57: does film loosen the module grid?")
    print("  prominence of the strongest periodic bump above the")
    print("  autocorrelation's own decay, and the pitch it sits at.")
    _table(states, shots, lambda im: repetition_peak(im)[0], "%10.4f")
    print("")
    print("  DETECTION RATE -- fraction of lit rows where an interior bump")
    print("  exists at all. THIS is the item-57 statistic, not prominence:")
    print("  prominence is only meaningful where something was found, and a")
    print("  shot whose rate collapses has lost its periodic structure even")
    print("  if the prominence number rises.")
    _table(states, shots, lambda im: repetition_peak(im)[2] * 100.0, "%9.0f%%")
    print("    %-18s %8s %8s %8s  (film off)"
          % ("", "pitch", "rows", "found"))
    undetected = []
    for sh in shots:
        fp = states["film_off"]["shots"][sh]["path"]
        if not os.path.isfile(fp):
            continue
        im = _load(fp)
        n = measured_rows(im)
        _, pitch, found = repetition_peak(im)
        note = ""
        if found < 0.5:
            note = "  <- NO module periodicity; row is floor, not a reading"
            undetected.append(sh)
        elif n < 8:
            note = "  <- thin sample, read with care"
        print("    %-18s %8.0f %8d %7.0f%%%s"
              % (sh, pitch, n, found * 100.0, note))
    if undetected:
        print("")
        print("    Item 57 can only be read off the shots that HAVE a module")
        print("    to measure. %d of %d do not: %s."
              % (len(undetected), len(shots), ", ".join(undetected)))
        print("    Their prominence numbers are the search window's own floor")
        print("    and must not be compared across states.")

    print("")
    print("  EXPOSURE -- film's response by luminance band, real geometry.")
    print("  Measured hdr_only -> film_shared, NOT film_off -> film_shared:")
    print("  against film_off this would be the film's response plus the")
    print("  render target's, and would overstate the film by the difference.")
    # The lit-fraction gate above picks the shot: band statistics off a
    # mostly-black frame describe the sky.
    sh = max(shots, key=lambda k: states["film_off"]["shots"][k]["lit"])
    print("  shot: %s (the most lit of the %d)" % (sh, len(shots)))
    a_img = _load(states["hdr_only"]["shots"][sh]["path"])
    b_img = _load(states["film_shared"]["shots"][sh]["path"])
    print("    %-12s %10s %12s %12s" % ("band", "pixels", "mean |d|",
                                        "relative"))
    for lo, hi, n, m, rel in band_response(a_img, b_img):
        print("    %-12s %10d %12.6f %12.4f"
              % ("%.2f-%.2f" % (lo, hi), n, m, rel))

    print("")
    print("  THE VERDICT IS NOT IN THIS OUTPUT. These numbers say the")
    print("  treatment behaves on real geometry the way it behaved on")
    print("  patches. Whether the level LOOKS better is the walk's question")
    print("  and a human's answer -- the stills are in:")
    print("    " + os.path.abspath(out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
