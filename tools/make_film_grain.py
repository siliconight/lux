"""Generate the packed film grain texture (film emulsion TDD sections 21-22).

    python lux/tools/make_film_grain.py

Writes `addons/lux/resources/film/grain_balanced.png` -- 128x128 RGBA8:

    R  fine neutral grain
    G  coarse neutral grain
    B  red-green dye variation
    A  blue-yellow dye variation

and prints the measured statistics of what it wrote. The shader's behaviour is
derived from those numbers, so they are printed rather than assumed: a change to
the bands below changes the effective grain amplitude, and the acceptance
harness reads the same PNG rather than a model of it.

WHY THE FREQUENCY DOMAIN. Section 22 requires the tile to be seamless. Noise
generated per-texel and then blurred is not -- the blur runs off the edge and
has to be faked back. Building each channel as a band-limited signal on a
periodic grid (an inverse FFT of a masked spectrum) makes it periodic BY
CONSTRUCTION: every channel tiles exactly, with no wrap seam to hide.

WHY FOUR SEPARATE STREAMS. The four channels are combined pairwise in the
shader -- R with G into one neutral signal, B and A onto two opponent color
axes. Correlation between any pair would show up as structure: correlated R/G
turns the neutral signal into single-band noise, and correlated B/A collapses
the two dye axes onto one, which is the "channels move together enough to see
a hue" failure section 4 describes. Each channel gets its own RNG stream and
the measured cross-correlations are printed so the claim is checkable.

WHY sqrt-NORMALISED TO SIGMA = 1/3. The shader reads the texture as
`value * 2 - 1`, so the storable range is [-1, +1]. Three standard deviations
at 1/3 fills that range and clips about 0.27% of texels, which is invisible in
grain and is measured below rather than assumed. A larger sigma would clip
visibly; a smaller one wastes 8-bit levels the grain is already short of.

NOT REGENERATED AT RUNTIME. Section 22: the asset is built offline and shipped.
This script exists so the asset is reproducible, not so anything calls it.
"""
import os
import sys

import numpy as np
from PIL import Image

SIZE = 128
SIGMA = 1.0 / 3.0

#: Radial frequency bands, in cycles per tile. Fine sits near Nyquist (64) so
#: it reads as film grain rather than as blobs; coarse stops at 6 rather than
#: going lower because a feature coarser than about a fifth of the tile makes
#: the tile itself visible when it repeats across a screen.
BANDS = {
    "R_fine":   (28.0, 62.0),
    "G_coarse": (6.0, 20.0),
    "B_redgrn": (10.0, 40.0),
    "A_bluyel": (10.0, 40.0),
}

#: Distinct streams, so the four channels are independent by construction.
SEEDS = {"R_fine": 1_000_003, "G_coarse": 1_000_033, "B_redgrn": 1_000_037,
         "A_bluyel": 1_000_039}


def band_limited(size, lo, hi, seed):
    """Periodic zero-mean noise whose energy lies in [lo, hi) cycles/tile."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((size, size))
    spec = np.fft.fft2(white)

    fy = np.fft.fftfreq(size) * size          # cycles per tile, signed
    fx = np.fft.fftfreq(size) * size
    radius = np.hypot(fy[:, None], fx[None, :])

    mask = ((radius >= lo) & (radius < hi)).astype(float)
    # Soften the band edges by one bin. A hard brick wall in the spectrum rings
    # in the image -- visible as faint concentric texture in a flat field.
    soft = np.exp(-((radius - np.clip(radius, lo, hi)) ** 2) / 2.0)
    mask = np.maximum(mask, soft * ((radius >= lo - 3) & (radius < hi + 3)))

    out = np.real(np.fft.ifft2(spec * mask))
    out -= out.mean()
    std = out.std()
    if std <= 0:
        raise SystemExit("band %s-%s produced a flat field" % (lo, hi))
    return out / std                          # unit variance, zero mean


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "..", "addons", "lux", "resources", "film")
    out_dir = os.path.normpath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    out_png = os.path.join(out_dir, "grain_balanced.png")

    planes = {}
    for name, (lo, hi) in BANDS.items():
        planes[name] = band_limited(SIZE, lo, hi, SEEDS[name])

    order = ["R_fine", "G_coarse", "B_redgrn", "A_bluyel"]
    stacked = np.stack([planes[n] for n in order], axis=-1)   # unit variance

    # Encode: 0.5 is zero, sigma = SIGMA of the [-1, 1] range.
    encoded = 0.5 + stacked * SIGMA * 0.5
    clipped = int(np.count_nonzero((encoded < 0.0) | (encoded > 1.0)))
    encoded = np.clip(encoded, 0.0, 1.0)
    quantised = np.round(encoded * 255.0).astype(np.uint8)

    Image.fromarray(quantised, mode="RGBA").save(out_png, optimize=True)

    # --- measure what was actually written, from the file, not the array ---
    back = np.asarray(Image.open(out_png).convert("RGBA")).astype(np.float64)
    signed = back / 255.0 * 2.0 - 1.0                  # what the shader sees

    print("wrote %s (%d x %d RGBA8, %d bytes on disk)"
          % (out_png, SIZE, SIZE, os.path.getsize(out_png)))
    print("raw texture memory: %d bytes (%.1f KiB)"
          % (SIZE * SIZE * 4, SIZE * SIZE * 4 / 1024.0))
    print("")
    print("  channel     band (cyc/tile)   mean       std")
    for i, n in enumerate(order):
        lo, hi = BANDS[n]
        print("  %-10s  %5.1f - %5.1f     %+.5f   %.5f"
              % (n, lo, hi, signed[..., i].mean(), signed[..., i].std()))
    print("")
    print("  texels clipped by encoding: %d of %d (%.3f%%)"
          % (clipped, SIZE * SIZE * 4, 100.0 * clipped / (SIZE * SIZE * 4)))
    print("")
    print("  cross-correlation (want all near zero):")
    for i in range(4):
        for j in range(i + 1, 4):
            r = float(np.corrcoef(signed[..., i].ravel(),
                                  signed[..., j].ravel())[0, 1])
            print("    %-10s x %-10s  %+.4f" % (order[i], order[j], r))
    print("")

    # The combination the shader performs, section 30. Printed here because the
    # effective grain amplitude follows from it and nothing else.
    neutral = signed[..., 0] * 0.68 + signed[..., 1] * 0.32
    print("  neutral signal (R*0.68 + G*0.32): mean %+.5f  std %.5f"
          % (neutral.mean(), neutral.std()))
    print("  at film_grain_strength = 0.025 and exposure_mask = 1.0 that is")
    print("    density std   %.5f stops" % (neutral.std() * 0.025))
    print("    transmission  %.4f%% (1 sigma), %.4f%% (3 sigma)"
          % (100.0 * (1.0 - 2.0 ** (-neutral.std() * 0.025)),
             100.0 * (1.0 - 2.0 ** (-3.0 * neutral.std() * 0.025))))

    # Seamlessness: the tile is periodic by construction, so the difference
    # across the wrap must be statistically the same as any interior step.
    interior = np.abs(np.diff(signed[..., 0], axis=1)).mean()
    wrap = np.abs(signed[:, 0, 0] - signed[:, -1, 0]).mean()
    print("")
    print("  seam check (R): mean |step| interior %.5f, across the wrap %.5f"
          % (interior, wrap))
    print("    ratio %.3f -- 1.0 means the wrap is indistinguishable from the"
          % (wrap / interior if interior else float("nan")))
    print("    interior, which is what 'tiles seamlessly' means for noise.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
