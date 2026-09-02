"""Run the film emulsion TDD's numeric acceptance tests against the real asset.

    python lux/tools/film_math_probe.py

WHAT THIS PROVES, AND WHAT IT DOES NOT. It evaluates the film shader's fragment
math -- the same constants, the same order, reading the same shipped PNG -- on
synthetic patches, and checks the results against sections 43, 45, 46 and 47.
That makes the MATH falsifiable before a GPU is involved.

It is not a GPU test. It says nothing about frame time, VRAM, shader stalls, or
how any of it reads on real geometry. Sections 50 and 51 remain entirely open
and this file must never be quoted as if it closed them.

WHY IT RE-IMPLEMENTS RATHER THAN CAPTURES. A capture harness would be the
better instrument and is the eventual one. But it needs a display, a GPU, and a
scene, and it answers "did this build look right" rather than "is the model
correct" -- and when a capture disagrees with intent there is no way to tell a
bad model from a bad binding. This isolates the model. `check_shader_constants`
below is what stops the two drifting: every literal this file assumes is grepped
out of the .gdshader, and a mismatch is a failure, not a warning.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SHADER = os.path.normpath(os.path.join(
    HERE, "..", "addons", "lux", "shaders", "post",
    "lux_ordered_dither_film.gdshader"))
GRAIN = os.path.normpath(os.path.join(
    HERE, "..", "addons", "lux", "resources", "film", "grain_balanced.png"))

REC709 = np.array([0.2126, 0.7152, 0.0722])
RED_GREEN_AXIS = np.array([0.7071, -0.7071, 0.0])
BLUE_YELLOW_AXIS = np.array([-0.4082, -0.4082, 0.8165])
LN2 = 0.69314718

#: Every literal below is also asserted to appear in the shader source, so the
#: two cannot drift apart silently. The strings are the shader's own spelling.
SHADER_CONSTANTS = [
    "vec3(0.2126, 0.7152, 0.0722)",
    "RED_GREEN_AXIS = vec3(0.7071, -0.7071, 0.0)",
    "BLUE_YELLOW_AXIS = vec3(-0.4082, -0.4082, 0.8165)",
    "LN2 = 0.69314718",
    "clamp(1.0 - 0.92 * lum + 0.20 * lum * lum, 0.28, 1.0)",
    "noise.r * 0.68 + noise.g * 0.32",
    "col *= exp2(-neutral_density);",
    "max(vec3(1.0) - LN2 * chroma, vec3(0.90))",
    # The quantization block. Added when the audit's first reading -- that the
    # rainbow was not Lux's problem -- turned out to be half a measurement.
    "vec3 per_channel = floor((col + threshold / levels) * levels + 0.5) / levels;",
    "float ll = levels * max(dither_luma_scale, 1.0);",
    "float lq = floor((l + threshold / ll) * ll + 0.5) / ll;",
    "vec3 coherent = col * (lq / max(l, 0.0001));",
    "result = mix(per_channel, coherent, dither_chroma_coherence);",
]

DEFAULT_STRENGTH = 0.025
DEFAULT_CHROMA = 0.10      # LuxPreset.film_chroma_ratio default
LEGACY_GRAIN_STRENGTH = 0.03      # LuxPreset.grain_strength default


class Fail(Exception):
    pass


def check_shader_constants():
    if not os.path.isfile(SHADER):
        raise Fail("shader not found: " + SHADER)
    src = open(SHADER, encoding="utf-8").read()
    missing = [c for c in SHADER_CONSTANTS if c not in src]
    if missing:
        raise Fail(
            "this harness models constants the shader no longer contains, so "
            "its results describe nothing that ships:\n    "
            + "\n    ".join(missing))
    return len(SHADER_CONSTANTS)


def load_grain():
    if not os.path.isfile(GRAIN):
        raise Fail("grain texture not found: " + GRAIN
                   + "\n  run tools/make_film_grain.py first")
    a = np.asarray(Image.open(GRAIN).convert("RGBA")).astype(np.float64)
    return a / 255.0 * 2.0 - 1.0          # exactly what the shader decodes


def film(col, noise, strength=DEFAULT_STRENGTH, chroma_ratio=DEFAULT_CHROMA):
    """The FILM EMULSION block of lux_ordered_dither_film.gdshader.

    `col` is (..., 3) and `noise` is (..., 4), broadcast together.
    """
    col = np.asarray(col, dtype=np.float64)
    lum = col @ REC709
    mask = np.clip(1.0 - 0.92 * lum + 0.20 * lum * lum, 0.28, 1.0)

    neutral = noise[..., 0] * 0.68 + noise[..., 1] * 0.32
    density = neutral * strength * mask
    out = col * np.exp2(-density)[..., None]

    if chroma_ratio > 0.0:
        chroma = ((noise[..., 2][..., None] * RED_GREEN_AXIS
                   + noise[..., 3][..., None] * BLUE_YELLOW_AXIS)
                  * chroma_ratio * strength * mask[..., None])
        out = out * np.maximum(1.0 - LN2 * chroma, 0.90)
    return out


#: The Bayer 4x4 table both shaders carry, already centred on zero the way
#: `bayer4()` returns it.
BAYER4 = (np.array([0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5],
                   dtype=np.float64).reshape(4, 4) / 16.0 - 0.5)

DEFAULT_LEVELS = 24               # LuxPreset.color_levels
DEFAULT_DITHER = 0.3              # LuxPreset.dither_strength
DEFAULT_COHERENCE = 1.0           # LuxPreset.dither_chroma_coherence
DEFAULT_LUMA_SCALE = 3.0          # LuxPreset.dither_luma_scale


def quantize(col, levels=DEFAULT_LEVELS, strength=DEFAULT_DITHER,
             coherence=DEFAULT_COHERENCE, luma_scale=DEFAULT_LUMA_SCALE):
    """The film shader's dither + quantize block.

    THIS IS WHERE THE RAINBOW COMES FROM, and the first version of this harness
    did not model it at all -- it measured the grain, found it chroma-free, and
    the audit generalised that to the whole pipeline. Quantizing R, G and B
    independently lets one channel cross a level boundary on its own, and a
    channel that dithers alone is pure chroma noise.
    """
    col = np.asarray(col, dtype=np.float64)
    h, w = col.shape[0], col.shape[1]
    ys, xs = np.mgrid[0:h, 0:w]
    threshold = BAYER4[ys % 4, xs % 4] * strength

    per_channel = np.floor((col + (threshold / levels)[..., None]) * levels
                           + 0.5) / levels
    if coherence <= 0.0:
        return np.clip(per_channel, 0.0, 1.0)

    ll = levels * max(luma_scale, 1.0)
    lum = col @ REC709
    lq = np.floor((lum + threshold / ll) * ll + 0.5) / ll
    coherent = col * (lq / np.maximum(lum, 0.0001))[..., None]
    return np.clip(per_channel * (1.0 - coherence) + coherent * coherence,
                   0.0, 1.0)


def saturation(rgb):
    rgb = np.clip(rgb, 0.0, 1.0)
    mx = rgb.max(axis=-1)
    return np.where(mx > 0, (mx - rgb.min(axis=-1)) / np.where(mx > 0, mx, 1.0), 0.0)


def legacy(col, scalar, strength=LEGACY_GRAIN_STRENGTH):
    """The baseline shader's Simple grain: one scalar, added to all channels."""
    return np.asarray(col, dtype=np.float64) + (scalar - 0.5)[..., None] * strength


def hsv(rgb):
    """Vectorised RGB -> (hue degrees, saturation), matching colorsys."""
    rgb = np.clip(rgb, 0.0, 1.0)
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    d = mx - mn
    sat = np.where(mx > 0, d / np.where(mx > 0, mx, 1.0), 0.0)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    h = np.zeros_like(mx)
    nz = d > 0
    with np.errstate(invalid="ignore", divide="ignore"):
        h = np.where(nz & (mx == r), ((g - b) / np.where(nz, d, 1.0)) % 6.0, h)
        h = np.where(nz & (mx == g), (b - r) / np.where(nz, d, 1.0) + 2.0, h)
        h = np.where(nz & (mx == b), (r - g) / np.where(nz, d, 1.0) + 4.0, h)
    return (h * 60.0) % 360.0, sat


class Report:
    def __init__(self):
        self.fails = 0
        self.checks = 0

    def check(self, ok, label, detail=""):
        self.checks += 1
        if not ok:
            self.fails += 1
        print("    %s %s%s" % ("ok  " if ok else "FAIL", label,
                               ("   " + detail) if detail else ""))

    def note(self, text):
        print("         " + text)


def test_rainbow_speckle(noise, rep):
    """Section 45. chroma_noise < 0.4 x luma_noise (hard), < 0.2 (preferred)."""
    print("  section 45 -- rainbow speckle, on a constant neutral patch")
    patch = np.full(noise.shape[:2] + (3,), 0.5)
    out = film(patch, noise)
    luma_noise = out.mean(axis=-1).std()
    chroma_noise = 0.5 * ((out[..., 0] - out[..., 1]).std()
                          + (out[..., 2] - out[..., 1]).std())
    ratio = chroma_noise / luma_noise if luma_noise else float("inf")
    rep.note("luma %.6f  chroma %.6f  ratio %.4f" % (luma_noise, chroma_noise, ratio))
    rep.check(ratio < 0.4, "hard requirement  chroma < 0.40 x luma",
              "(%.4f)" % ratio)
    rep.check(ratio < 0.2, "preferred         chroma < 0.20 x luma",
              "(%.4f)" % ratio)

    # The same metric on the baseline's Simple grain, for the record: a single
    # scalar added to three channels has no chroma component at all. Film
    # emulsion does not fix a speckle problem, because there was not one.
    leg = legacy(patch, (noise[..., 0] + 1.0) / 2.0)
    lch = 0.5 * ((leg[..., 0] - leg[..., 1]).std() + (leg[..., 2] - leg[..., 1]).std())
    rep.note("for comparison, the baseline Simple grain scores chroma %.6f" % lch)


def test_metric_scope(noise, rep):
    """Section 45's metric is only a chroma measurement on a NEUTRAL patch.

    This is a control, not a requirement. With the chroma term switched off
    entirely, the metric still scores 0.60 on orange and 0.99 on red, because
    `std(R-G)` on a coloured patch is driven by the shared transmission
    multiplying a non-zero R-G -- the one part of the design that is provably
    hue- and saturation-preserving. The obvious reading of those figures is
    "the chroma is too strong", and acting on it would delete the dye variation
    section 31 exists to add, for nothing. The control runs every time so the
    comparison is always in front of whoever reads the numbers.
    """
    print("  control -- section 45's metric with the chroma term OFF")

    def metric(col, chroma):
        patch = np.broadcast_to(np.array(col), noise.shape[:2] + (3,))
        out = film(patch, noise, strength=0.10, chroma_ratio=chroma)
        ln = out.mean(axis=-1).std()
        cn = 0.5 * ((out[..., 0] - out[..., 1]).std()
                    + (out[..., 2] - out[..., 1]).std())
        return cn / ln if ln else float("nan")

    swatches = [("neutral", (0.5, 0.5, 0.5)), ("orange", (0.72, 0.41, 0.19)),
                ("red", (0.72, 0.12, 0.10)), ("blue", (0.16, 0.26, 0.72))]
    print("      %-9s %-16s %s" % ("patch", "chroma OFF", "chroma at default"))
    off_neutral = None
    worst_off_colour = 0.0
    for name, c in swatches:
        o, n = metric(c, 0.0), metric(c, DEFAULT_CHROMA)
        print("      %-9s %-16.4f %.4f" % (name, o, n))
        if name == "neutral":
            off_neutral = o
        else:
            worst_off_colour = max(worst_off_colour, o)
    rep.check(off_neutral < 1e-9,
              "the metric reads ZERO on a neutral patch with no chroma term",
              "(%.2e)" % off_neutral)
    rep.check(worst_off_colour > 0.4,
              "and reads ABOVE the hard bar on coloured patches with no chroma "
              "term at all", "(worst %.4f)" % worst_off_colour)
    rep.note("Both of those are the point: the metric is meaningful only on the")
    rep.note("neutral patch section 45 specifies. A high score on a coloured")
    rep.note("patch is the NEUTRAL term being mismeasured -- do not 'fix' it by")
    rep.note("reducing film_chroma_ratio.")


def test_quantization_chroma(noise, rep):
    """The rainbow, measured -- and the shared-decision fix, measured.

    Run on FLAT coloured patches on purpose: a flat patch has no variation
    before quantization, so every difference measured afterwards was put there
    by the quantizer and by nothing else. Saturation spread is the statistic,
    not section 45's chroma metric, because that metric counts a shared
    multiplier as chroma on a coloured patch -- the trap test_metric_scope
    documents, and the one that would make the fix look like the defect.
    """
    print("  the rainbow -- per-channel quantization against a shared decision")
    swatches = [("orange", (0.72, 0.41, 0.19)), ("red", (0.72, 0.12, 0.10)),
                ("blue shadow", (0.09, 0.11, 0.18)), ("green", (0.18, 0.62, 0.24))]
    print("      %-13s %14s %14s" % ("patch", "per-channel", "shared"))
    worst_per, worst_shared = 0.0, 0.0
    for name, c in swatches:
        flat = np.broadcast_to(np.array(c), (128, 128, 3))
        sp = saturation(quantize(flat, coherence=0.0)).std()
        sc = saturation(quantize(flat, coherence=1.0)).std()
        worst_per = max(worst_per, sp)
        worst_shared = max(worst_shared, sc)
        print("      %-13s %14.6f %14.6f" % (name, sp, sc))

    # Both halves matter. Without the first, a fix that did nothing would pass
    # the second; without the second, the defect is only described.
    rep.check(worst_per > 1e-4,
              "per-channel quantization DOES move saturation on flat colour",
              "(worst %.6f)" % worst_per)
    rep.check(worst_shared < 1e-9,
              "a shared decision moves it by exactly nothing",
              "(worst %.2e)" % worst_shared)

    # And it must still do dither's job, or it is not a fix but a removal.
    print("      does the shared decision still break banding?")
    ramp = (np.array([0.85, 0.52, 0.28])
            * np.linspace(0.06, 0.95, 512)[None, :, None])
    ramp = np.broadcast_to(ramp, (64, 512, 3))
    def steps(x):
        return len(np.unique(np.round(x[32] @ REC709, 6)))
    per_steps = steps(quantize(ramp, coherence=0.0))
    coh_steps = steps(quantize(ramp, coherence=1.0))
    coh_1x = steps(quantize(ramp, coherence=1.0, luma_scale=1.0))
    print("        luminance steps on a coloured gradient: per-channel %d, "
          "shared %d (at 1x scale, %d)" % (per_steps, coh_steps, coh_1x))
    rep.check(coh_steps >= per_steps,
              "shared quantization at the default luma scale bands no more "
              "coarsely than per-channel", "(%d vs %d)" % (coh_steps, per_steps))
    rep.note("A shared decision IS coarser at the same level count -- %d steps "
             "at 1x." % coh_1x)
    rep.note("dither_luma_scale exists to pay that back, and at the default it")
    rep.note("more than does. That is why this is not a trade.")


def test_hue_preservation(noise, rep):
    """Section 46. Mean hue stable; no isolated opponent-colour pixels."""
    print("  section 46 -- hue preservation across the wheel")
    swatches = {
        "red": (0.72, 0.12, 0.10), "orange": (0.72, 0.41, 0.19),
        "yellow": (0.78, 0.72, 0.16), "green": (0.18, 0.62, 0.24),
        "cyan": (0.16, 0.66, 0.70), "blue": (0.16, 0.26, 0.72),
        "magenta": (0.66, 0.18, 0.62),
    }
    worst_mean, worst_max, worst_name = 0.0, 0.0, ""
    for name, c in swatches.items():
        base = np.array(c)
        h0, _ = hsv(base)
        out = film(np.broadcast_to(base, noise.shape[:2] + (3,)), noise)
        h1, _ = hsv(out)
        # Signed circular difference, so opposite drifts cannot cancel.
        d = (h1 - h0 + 180.0) % 360.0 - 180.0
        mean_shift, max_shift = abs(d.mean()), np.abs(d).max()
        if mean_shift > worst_mean:
            worst_mean, worst_name = mean_shift, name
        worst_max = max(worst_max, max_shift)
        print("      %-8s hue %6.2f deg   mean shift %+.4f   max |shift| %.4f"
              % (name, float(h0), d.mean(), max_shift))
    rep.check(worst_mean < 0.10, "mean hue stable within 0.10 deg",
              "(worst %.4f on %s)" % (worst_mean, worst_name))
    rep.check(worst_max < 2.0, "no isolated opponent-colour pixel beyond 2 deg",
              "(worst %.4f)" % worst_max)


def test_saturation(noise, rep):
    """Sections 28/43, and the Phase 1 audit's actual finding about the baseline.

    The density model's whole claim is that it moves VALUE and leaves hue and
    saturation alone. The baseline's additive grain does not, and gets worse the
    darker the pixel. Both are measured on the same swatches and the same noise.
    """
    print("  section 28/43 -- saturation under grain, film vs the baseline")
    swatches = [("bright orange", (0.72, 0.41, 0.19)),
                ("mid orange", (0.36, 0.20, 0.10)),
                ("dark orange", (0.14, 0.08, 0.04)),
                ("deep shadow", (0.06, 0.035, 0.02))]
    scalar = (noise[..., 0] + 1.0) / 2.0
    worst_film = 0.0
    print("      swatch          base sat   film sat range      baseline sat range")
    for name, c in swatches:
        base = np.array(c)
        _, s0 = hsv(base)
        tile = np.broadcast_to(base, noise.shape[:2] + (3,))
        _, sf = hsv(film(tile, noise))
        _, sl = hsv(legacy(tile, scalar))
        span_f = (sf.max() - sf.min()) / float(s0)
        span_l = (sl.max() - sl.min()) / float(s0)
        worst_film = max(worst_film, span_f)
        print("      %-14s %.4f     %.4f-%.4f (%5.2f%%)  %.4f-%.4f (%5.2f%%)"
              % (name, float(s0), sf.min(), sf.max(), 100 * span_f,
                 sl.min(), sl.max(), 100 * span_l))
    rep.check(worst_film < 0.01,
              "film moves saturation by under 1% of its own value at every exposure",
              "(worst %.4f%%)" % (100 * worst_film))


def test_exposure_response(noise, rep):
    """Section 47, both readings -- see the note this prints."""
    print("  section 47 -- exposure response")
    levels = [0.05, 0.20, 0.50, 0.80, 1.00]
    abs_rms, rel_rms = [], []
    for v in levels:
        base = np.full(noise.shape[:2] + (3,), v)
        out = film(base, noise, chroma_ratio=0.0)   # neutral term alone
        d = out.mean(axis=-1) - v
        abs_rms.append(float(np.sqrt((d ** 2).mean())))
        rel_rms.append(abs_rms[-1] / v)
    for v, a, r in zip(levels, abs_rms, rel_rms):
        print("      luminance %4.0f%%   absolute RMS %.6f   relative RMS %.6f"
              % (v * 100, a, r))

    strictly_down = all(rel_rms[i] > rel_rms[i + 1] for i in range(len(rel_rms) - 1))
    rep.check(strictly_down,
              "grain falls monotonically from shadow to highlight (relative)")

    rep.note("")
    rep.note("SECTION 47 IS AMBIGUOUS AND THE LITERAL READING CANNOT BE MET.")
    rep.note("It asks for 'Dark Grain RMS > Midtone > Highlight'. Absolute RMS")
    rep.note("of a MULTIPLICATIVE model is value x mask, which necessarily")
    rep.note("rises with brightness -- the numbers above show it doing so. The")
    rep.note("requirement is only satisfiable by an additive model, which is")
    rep.note("the one section 27 forbids. Relative RMS -- grain as a fraction")
    rep.note("of the signal it sits on, which is what an eye sees -- falls")
    rep.note("monotonically, and that is the reading this implementation meets.")
    rep.note("Sections 27 and 47 are in tension; this is the resolution taken.")


def test_continuity(noise, rep):
    """Section 43. A smooth gradient must survive film with no new banding."""
    print("  section 43 -- colour continuity on smooth gradients")
    h = noise.shape[0]
    width = 512
    ramps = {"red": (0.72, 0.12, 0.10), "orange": (0.72, 0.41, 0.19),
             "blue": (0.16, 0.26, 0.72), "green": (0.18, 0.62, 0.24),
             "neutral": (0.6, 0.6, 0.6)}
    worst_extra, worst_name = 0.0, ""
    for name, top in ramps.items():
        t = np.linspace(0.05, 1.0, width)[None, :, None]
        base = np.array(top)[None, None, :] * t          # colour -> dark colour
        base = np.broadcast_to(base, (h, width, 3))
        tile = noise[:, :width % noise.shape[1] or noise.shape[1]]
        tile = np.resize(noise, (h, width, 4))
        out = film(base, tile)

        # Banding shows up as a step: neighbours that should differ by the
        # ramp's own slope differing by much more. Compare the largest
        # horizontal step before and after; film must not introduce a bigger one
        # than the grain amplitude itself accounts for.
        step_before = np.abs(np.diff(base.mean(axis=-1), axis=1)).max()
        step_after = np.abs(np.diff(out.mean(axis=-1), axis=1)).max()
        extra = step_after - step_before
        if extra > worst_extra:
            worst_extra, worst_name = extra, name
        print("      %-8s max neighbour step  before %.6f  after %.6f  (+%.6f)"
              % (name, step_before, step_after, extra))
    # The bound: a grain step can be at most twice the 3-sigma transmission
    # swing, and 3 sigma of the neutral signal at default strength is about
    # 1.29% of the value, so on a value of at most 1.0 that is 0.026.
    rep.check(worst_extra < 0.03,
              "film adds no step larger than its own 3-sigma swing",
              "(worst +%.6f on %s)" % (worst_extra, worst_name))


def main(argv=None):
    print("film emulsion math probe")
    print("  shader %s" % SHADER)
    print("  grain  %s" % GRAIN)
    try:
        n = check_shader_constants()
        noise = load_grain()
    except Fail as e:
        print("")
        print("  NOTHING MEASURED: %s" % e)
        return 2
    print("  %d shader constants matched; grain %dx%d" % (n, noise.shape[0], noise.shape[1]))
    print("")

    rep = Report()
    test_rainbow_speckle(noise, rep)
    print("")
    test_metric_scope(noise, rep)
    print("")
    test_quantization_chroma(noise, rep)
    print("")
    test_hue_preservation(noise, rep)
    print("")
    test_saturation(noise, rep)
    print("")
    test_exposure_response(noise, rep)
    print("")
    test_continuity(noise, rep)
    print("")
    print("  %d checks, %d failed" % (rep.checks, rep.fails))
    print("")
    print("  THIS IS A MODEL, NOT A CAPTURE. It proves the film math against")
    print("  sections 43, 45, 46 and 47 on the shipped grain asset. It proves")
    print("  nothing about frame time, VRAM, or how any of it looks on real")
    print("  geometry -- sections 50 and 51 are untouched by a green run here.")
    print("")
    print("  film_render_probe.py compiles the real shader and renders these")
    print("  same patches; it agreed with this model to within 1.1% wherever")
    print("  the signal exceeded the render target's own precision. Run both:")
    print("  a model can correctly describe a shader that does not compile.")
    return 1 if rep.fails else 0


if __name__ == "__main__":
    sys.exit(main())
