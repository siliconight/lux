"""What a half-resolution film pass does to the grain, measured not asserted.

The screen is what matters, not the tile. So: synthesise the grain field AS IT
LANDS ON SCREEN at each case -- the shipped 0.68/0.32 blend, stretched by the
resolution lock -- then run it through the half-res path (evaluated once per
half-res fragment, bilinear back up) and compare radial power spectra.

Aliasing and softening are different failures and the spectrum tells them
apart: softening REMOVES energy above the new Nyquist, aliasing MOVES it down
into frequencies that were not there before. A single "grain got weaker"
number cannot distinguish them, and they look nothing alike.
"""
import os
import sys

import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_film_grain import band_limited, BANDS, SEEDS, SIZE  # noqa: E402

REF = 2048.0
W_FINE, W_COARSE = 0.68, 0.32
N = 1024                      # screen patch, px


def screen_field(width, n=N, tile_px=None):
    """The blended grain sampled on an n x n grid, one tile every `tile_px`."""
    if tile_px is None:
        tile_px = SIZE * (width / REF)    # the resolution lock
    f = band_limited(SIZE, BANDS["R_fine"][0], BANDS["R_fine"][1], SEEDS["R_fine"])
    c = band_limited(SIZE, BANDS["G_coarse"][0], BANDS["G_coarse"][1], SEEDS["G_coarse"])
    tile = W_FINE * f + W_COARSE * c
    # Sample the tile at the screen grid, wrapping -- what the shader does.
    u = (np.arange(n) / tile_px * SIZE) % SIZE
    iu = np.floor(u).astype(int) % SIZE
    fu = u - np.floor(u)
    # bilinear, separable, periodic -- the sampler's own filter
    a = tile[np.ix_(iu, iu)]
    b = tile[np.ix_((iu + 1) % SIZE, iu)]
    c2 = tile[np.ix_(iu, (iu + 1) % SIZE)]
    d = tile[np.ix_((iu + 1) % SIZE, (iu + 1) % SIZE)]
    fy = fu[:, None]; fx = fu[None, :]
    return (a * (1 - fy) * (1 - fx) + b * fy * (1 - fx)
            + c2 * (1 - fy) * fx + d * fy * fx)


def half_res(width, n=N):
    """What a HALF-RES PASS actually produces, which is not a downsample.

    THE FIRST VERSION OF THIS MODELLED THE WRONG THING and reported 0.0%
    aliasing everywhere, which should have been the tell. Box-downsampling a
    full-res render averages four samples per output pixel -- that is a
    low-pass filter, and a fair one. A half-res PASS does no such thing: it
    evaluates the grain function ONCE per half-res fragment, point-sampled.
    Frequencies above the half-res Nyquist are not attenuated by that, they
    are folded back down as something else.

    The distinction is the whole question, because a softened grain is a
    coarser stock and an aliased one is the crawling low-frequency mush that
    reads as digital.

    The resolution lock keeps apparent crystal size fixed, so one tile spans
    the same number of SCREEN pixels either way -- half as many buffer pixels.
    """
    tile_screen = SIZE * (width / REF)
    small = screen_field(width, n=n // 2, tile_px=tile_screen / 2.0)
    m = small.shape[0]
    idx = (np.arange(n) - 0.5) / 2.0
    i0 = np.floor(idx).astype(int)
    t = idx - i0
    i0 = np.clip(i0, 0, m - 1); i1 = np.clip(i0 + 1, 0, m - 1)
    rows = small[i0] * (1 - t)[:, None] + small[i1] * t[:, None]
    return rows[:, i0] * (1 - t)[None, :] + rows[:, i1] * t[None, :]


def radial_power(img, nbins=64):
    n = img.shape[0]
    F = np.fft.fftshift(np.abs(np.fft.fft2(img - img.mean())) ** 2)
    fy = np.fft.fftshift(np.fft.fftfreq(n)) * n
    r = np.hypot(fy[:, None], fy[None, :])
    rmax = n / 2.0
    bins = np.linspace(0, rmax, nbins + 1)
    idx = np.digitize(r.ravel(), bins) - 1
    out = np.zeros(nbins)
    for k in range(nbins):
        sel = idx == k
        if sel.any():
            out[k] = F.ravel()[sel].mean()
    # cycles per screen pixel at each bin centre -> px per cycle
    centres = 0.5 * (bins[:-1] + bins[1:]) / n
    return centres, out


CASES = [("4K   3840", 3840), ("1440p 2560", 2560), ("1080p 1920", 1920)]

print(__doc__)
print("  Total grain energy retained, and where it went:\n")
print("  %-12s %10s %10s %10s %10s" % ("case", "std full", "std half",
                                       "retained", "alias-in"))
for name, w in CASES:
    full = screen_field(w)
    half = half_res(w)
    c, pf = radial_power(full)
    _, ph = radial_power(half)
    # New Nyquist after halving: 0.25 cycles/px. Above it, half-res can hold
    # nothing -- so energy that APPEARS below it and was not there before is
    # aliased down, not merely lost.
    above = c > 0.25
    below = ~above
    lost_above = pf[above].sum() - ph[above].sum()
    gained_below = max(0.0, ph[below].sum() - pf[below].sum())
    print("  %-12s %10.4f %10.4f %9.1f%% %9.1f%%"
          % (name, full.std(), half.std(),
             100.0 * half.std() / full.std(),
             100.0 * gained_below / max(pf.sum(), 1e-12)))

print("\n  Energy by band, as a fraction of the full-res total:")
print("  %-12s %14s %14s %14s" % ("case", "coarse (>4px)", "fine (2-4px)",
                                  "above Nyquist"))
for name, w in CASES:
    full = screen_field(w)
    half = half_res(w)
    c, pf = radial_power(full)
    _, ph = radial_power(half)
    tot = pf.sum()
    def frac(p, sel):
        return 100.0 * p[sel].sum() / tot
    for tag, p in (("  full", pf), ("  half", ph)):
        print("  %-12s %13.1f%% %13.1f%% %13.1f%%"
              % (name + tag, frac(p, c < 1/8.), frac(p, (c >= 1/8.) & (c < 1/4.)),
                 frac(p, c >= 1/4.)))


# ---------------------------------------------------------------------------
# THE OTHER HALF OF THE ANSWER: WHAT IT BUYS.
#
# No new timing harness, on purpose. A half-res pass at 4K renders exactly as
# many fragments of exactly the same shader as a full-res pass at 1080p, and
# the resolution lock makes the per-fragment work identical too -- so its film
# cost IS the 1080p cell that section 50 already measured, on the same GPU, in
# the same run. Building a SubViewport harness to re-measure that would have
# added a new way to be wrong about a number already in hand.
#
# ONE TERM IS GENUINELY UNMEASURED and is called out rather than assumed: the
# upscale blit back to full resolution. It is one textured full-screen quad
# with no arithmetic, so it should be small against these margins, but "should
# be" is not a measurement and the margin column below says exactly how much
# it would have to cost to matter.
FILM_MS = {720: 0.0450, 1080: 0.0990, 1440: 0.1760, 2160: 0.2580}
BUDGET_FRACTION = 0.02          # TDD section 41
PAIRS = [(2160, 1080), (1440, 720)]


def report_cost():
    print("\n  WHAT IT BUYS -- RTX 2060, section 50's own matrix, shipped settings")
    print("  %-8s %4s %9s %9s %9s   %s"
          % ("target", "fps", "budget", "full-res", "half-res", "verdict"))
    for hi, lo in PAIRS:
        for fps in (30, 60, 90, 120):
            b = (1000.0 / fps) * BUDGET_FRACTION
            f, h = FILM_MS[hi], FILM_MS[lo]
            if f <= b:
                verdict = "full-res already fits"
            elif h <= b:
                verdict = ("HALF-RES FIXES IT -- blit has %.4f ms to spare"
                           % (b - h))
            else:
                verdict = "half-res does NOT fix it"
            print("  %-8s %4d %9.4f %9.4f %9.4f   %s"
                  % ("%dp" % hi, fps, b, f, h, verdict))
        print("")


report_cost()
