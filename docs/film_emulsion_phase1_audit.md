# Film Emulsion — Phase 1: Color Pipeline Audit

Satisfies the exit requirement of `film_emulsion_tdd.md` §55 Phase 1:

> The team knows exactly where color information is currently lost.

Audited: `addons/lux/shaders/post/lux_ordered_dither.gdshader`,
`addons/lux/runtime/lux_post_fx.gd`, `addons/lux/runtime/lux_root.gd`,
`project.godot`. Line numbers are against the shader as audited (126 lines).

## 1. The pipeline as it actually runs

`LuxPostFX.ensure_pass()` builds ONE `CanvasLayer` at layer `-1` holding two
stacked passes, each a `BackBufferCopy` + full-rect `ColorRect`:

    3D scene (Forward+, tonemapped)
        -> viewport render target
        -> BackBufferCopy
        -> LuxPostRect      : lux_ordered_dither.gdshader
        -> LuxCRTBackBuffer
        -> LuxCRTRect       : lux_crt_mask.gdshader
        -> display

Inside `lux_ordered_dither.gdshader::fragment()`, in execution order:

| Step | Lines | Operation | Precision effect |
|---|---|---|---|
| Sample | 67 | `texture(screen_tex, uv)` | see §2 — this is the ceiling |
| Grade | 70-76 | brightness, contrast, saturation, warmth | none (linear ops) |
| **Clamp** | **77** | `clamp(col, 0.0, 1.0)` | **first hard loss: everything >1.0 flattens** |
| Palette zones | 80-88 | per-luma tint, then clamp again (87) | loss only where tint pushes >1.0 |
| **Dither + quantize** | **95-102** | `floor(col*levels + 0.5)/levels` | **deliberate loss to `color_levels` steps** |
| Vignette | 105-109 | multiply | none (multiplicative) |
| **Grain** | **112-115** | `col += (n - 0.5) * grain_strength` | **applied AFTER quantization** |
| Final clamp | 120-124 | clamp, or `max(col, 0)` under `hdr_passthrough` | — |

## 2. The ceiling: the post pass never sees high-precision color

`project.godot` sets `renderer/rendering_method="forward_plus"` and does **not**
set `rendering/viewport/hdr_2d`. `Viewport.use_hdr_2d` therefore sits at the
engine default, which the class reference gives as `false`. With it false the
viewport's render target is LDR 8-bit-per-channel; the 3D scene is tonemapped
into it before any canvas_item pass runs.

**Consequence: by the time `screen_tex` is sampled at line 67, scene color is
already RGB8.** TDD §20 requires:

> The system must not convert scene color to RGB8 before processing.

The current architecture already does — not in the shader, but in the render
target format the shader reads from.

This puts two TDD requirements in tension:

- §7 requires film emulsion to live inside the existing Lux post shader, and
  §8 prohibits allocating a film framebuffer.
- §20 requires film math to operate on high-precision color.

Both cannot hold while `use_hdr_2d` is false. The resolution is a viewport
format change, not a new pass — but it is not free, and it is not film's to
spend silently:

| Option | §20 | §7/§8 | Cost |
|---|---|---|---|
| (a) `use_hdr_2d = true` while film is active | met | met — same pass count | 2D target RGBA8 -> RGBA16F. At 1080p that is 8.3 MiB -> 15.8 MiB, **+7.5 MiB**, against §38's stated 0.25 MiB deterministic budget |
| (b) run film math on the 8-bit input | **not met** | met | free |
| (c) film-specific HDR target | met | **violates §8** | a second full-resolution buffer |

**This is a decision for the human, not for the implementation.** §38's budget
was written for the grain asset; it does not anticipate a format change to a
buffer that already exists. Option (a) is the only one that satisfies §20, and
whether +7.5 MiB is "film's cost" or "the cost of Lux having an HDR 2D path at
all" is an art/budget call.

Nothing in this audit's downstream work depends on the answer: the film math is
correct at either precision. Option (b) simply cannot claim §20.

**MEASURED 2026-09-02 on two rasterisers, and the doc was right.** Godot
4.7.stable.official (5b4e0cb0f), Forward+, reading back the root viewport after
a canvas pass:

| `rendering/viewport/hdr_2d` | llvmpipe (Mesa) | NVIDIA GeForce RTX 2060 |
|---|---|---|
| unset (as shipped) | RGBA8 | **RGB8** |
| `true` | RGBAF (32-bit float) | **RGBH (16-bit float)** |

So the post pass reads 8-bit integer colour as shipped on both, and the setting
name is correct for 4.7 -- option (a) is available and is one line. Run by
`lux/tools/film_render_probe.py`; `tools/film_precision_probe.py` asks the same
question of the real Lux project rather than a synthetic one.

**The exact format differs by driver, and the first version of this table got
it wrong.** It read "RGBA8 / RGBH" for llvmpipe, from a hand-written
`{int: name}` table in the Python driver that had 11 as RGBH -- 11 is RGBAF and
14 is RGBH. The error survived into three documents and was caught only when an
RTX 2060 returned a format id the table did not contain. The probe now names the
format from `Image.FORMAT_*` inside Godot and the driver prints what it is told;
there is no table left to be wrong. What the mistake did NOT change is the
conclusion -- both drivers give 8-bit integer when the setting is off and
floating point when it is on -- but a measured fact was misreported, and the
correction is recorded rather than quietly patched.

### 2a. The cost of 8-bit is not theoretical -- it breaks the TDD's own test

Section 45 grades `chroma_noise` against `luma_noise`. Rendered, at default
`grain_strength`:

| | hdr_2d off (8-bit) | hdr_2d on (float) |
|---|---|---|
| film, neutral patch, section 45 ratio | 0.3340 | **0.1901** |
| **baseline** grain, orange patch | 0.001359 | 0.000091 |
| **baseline** grain, deep shadow | 0.001811 | **0.000009** |

The baseline's Simple grain is chroma-free **by construction** -- one scalar
added to three channels -- so its true chroma noise is zero and anything
measured is the floor the output format imposes. At 8 bits that floor is
0.0018; at 16 it is 0.000009, two hundred times smaller. **The entire chroma
signal measured at 8-bit output was per-channel rounding.**

That floor is not far below film's own signal. At default strength on an 8-bit
target the grain spans **3 distinct codes** on a neutral patch -- it is close to
sub-LSB, and most of it is rounded away before it reaches the display. Film
emulsion at 8 bits is a subtler effect than its parameters say it is, and
section 45's metric there is measuring the format rather than the model.

This makes the `hdr_2d` decision sharper than section 2 alone suggests: it is
not only that section 20 is unclaimable at 8 bits, it is that **section 45's
preferred bar is only reachable in float** (0.1901 against 0.20).

### 2b. At 8 bits the acceptance test is not reproducible across hardware

The same probe, same build, same patches, on llvmpipe and on an RTX 2060:

| metric | llvmpipe | RTX 2060 | difference |
|---|---|---|---|
| **hdr_2d off** | | | |
| §45 ratio, neutral patch | 0.333965 | 0.338605 | 1.4% |
| baseline chroma floor, orange | 0.001359 | 0.000412 | **70%** |
| baseline chroma floor, shadow | 0.001811 | 0.000618 | **66%** |
| film saturation span, orange | 0.929% | 0.767% | 17% |
| baseline saturation span, shadow | 54.10% | 58.82% | 8.7% |
| **hdr_2d on** | | | |
| §45 ratio, neutral patch | 0.190112 | 0.190116 | 0.002% |
| baseline chroma floor, orange | 0.000091 | 0.000091 | 0.009% |
| baseline chroma floor, shadow | 0.000009 | 0.000009 | 0.20% |
| film saturation span, orange | 0.147169% | 0.147169% | 0.000% |
| baseline saturation span, shadow | 50.019272% | 50.019272% | 0.000% |

**Worst disagreement: 70% at 8 bits, 0.20% in float.** And the float column is
not two runs of one thing -- llvmpipe rendered into a 32-bit float target and
the RTX 2060 into a 16-bit one. Two different rasterisers at two different
precisions agree to two parts in a thousand.

Two conclusions follow, and the first is the stronger argument for `hdr_2d`
than either §20 or the preferred bar:

1. **At 8-bit output, section 45 is not an acceptance test.** A test whose
   result moves 70% with the graphics card measures the card. The floor it is
   reading is per-channel rounding, and rounding behaviour in the driver's
   blend-and-store path is not something Lux specifies or controls.
2. **16-bit float is enough.** It was not obvious that RGBH had the headroom
   for a density model working in thousandths; matching a 32-bit target to
   0.2% says it does, so nothing here argues for RGBAF.

## 3. What the existing "Simple" grain actually does — the TDD's premise is
   right, but it is pointing at the wrong stage

> **CORRECTION, 2026-09-02.** The first version of this section ended with
> *"Lux has never had a rainbow-speckle problem, and film emulsion will not fix
> one that does not exist."* **That was wrong.** The measurement below is
> correct and the grain really is innocent — but the conclusion was generalised
> from the grain to the whole pipeline without measuring the other half of it.
> The rainbow is real and it is the ordered dither. See §3d, which is the
> section that should have existed here from the start.

The TDD's §1 lists the problem as "grain that creates unrelated red, green, or
blue pixels" and "digital-looking noise applied independently to RGB channels."

**The grain does not do that.** Line 113 computes ONE scalar `n` and line 114
adds it to all three channels equally. Measured against §45's own metric on
200 000 samples at the default `grain_strength = 0.03`:

    luma_noise    0.008648
    chroma_noise  0.000000
    ratio         0.0000

§45's hard requirement is `chroma < 0.4 x luma`; its preferred bar is
`< 0.2 x luma`. The existing grain scores **exactly zero**.

So the TDD describes a real defect and attributes it to the wrong stage. The
grain's actual failing is different (§3a), and the defect the TDD names lives
one stage later (§3d).

### 3a. Additive grain modulates SATURATION, and does so worst in shadow

Adding a constant to all three channels leaves HSV *hue* exactly unchanged — the
channel differences are preserved — but it changes the max/min ratio, so
*saturation* moves. Because the shift is absolute rather than proportional, its
relative size grows as the pixel gets darker. Measured on one orange swatch at
four exposures, `grain_strength = 0.03` (so delta = +/-0.015):

| Swatch | Luma | Saturation | Range under grain | Swing |
|---|---|---|---|---|
| bright orange `0.72,0.41,0.19` | 0.460 | 0.7361 | 0.7211 - 0.7518 | **+4.2%** |
| mid orange `0.36,0.20,0.10` | 0.227 | 0.7222 | 0.6933 - 0.7536 | **+8.3%** |
| dark orange `0.14,0.08,0.04` | 0.090 | 0.7143 | 0.6452 - 0.8000 | **+21.7%** |
| deep shadow `0.06,0.035,0.02` | 0.039 | 0.6667 | 0.5333 - 0.8889 | **+53.3%** |

The density model of §27 (`col *= exp2(-density)`) preserves hue AND saturation
exactly at every luminance — it moves value alone. Verified on the same swatches:
saturation `0.7361` before and after, at both grain polarities.

This is a *stronger* argument for the density model than the one the TDD makes,
and it is the one worth quoting: the defect is not colour confetti, it is that
shadows breathe in and out of saturation.

### 3b. Grain is applied after quantization

Line 114 runs after line 100. The dither pass snaps colour to `color_levels`
steps precisely so those steps are what reaches the display — the final clamp's
own comment (117-119) says so — and then grain adds an unquantized offset on top,
undoing it. This is exactly the ordering §2 forbids:

> Once color information has been removed through quantization, clipping, or
> palette reduction, Film Emulsion cannot recover it.

§16's required order puts film response *before* palette reduction and dither.
The current order is the reverse.

### 3c. The grain hash scales its own frequency with playtime

Line 113:

    fract(sin(dot(uv * (time_seed + 1.0), vec2(12.9898, 78.233))) * 43758.5453)

`time_seed` is `fmod(_time, 1000.0)` — seconds of playtime — and it multiplies
`uv`. It is therefore a *frequency* scale, not a reseed:

| `time_seed` | UV scale | `sin()` argument magnitude |
|---|---|---|
| 0 | 1x | ~91 |
| 1 | 2x | ~182 |
| 60 | 61x | ~5 559 |
| 999 | 1000x | ~91 123 |

Grain frequency therefore climbs continuously for the first ~16.7 minutes of
play and then snaps back to 1x. At the top of that range the `sin()` argument is
large enough that fp32 evaluation is precision-limited and hardware-dependent,
so the pattern is not reproducible across GPUs. It also updates every rendered
frame, which is what §24 rules out:

> The grain must not change continuously every rendered frame.

This is a defect independent of film emulsion and would be worth fixing even if
item 61 were dropped.

### 3d. The rainbow is the ORDERED DITHER, and it is the defect §1 describes

The dither block quantizes R, G and B **independently** — line 100,
`floor(dithered * levels + 0.5) / levels`, applied to a `vec3`. On a coloured
surface the three channels sit at different fractional positions between
levels, so the Bayer threshold pushes them across their boundaries at different
screen positions. **A channel that crosses a boundary on its own is pure chroma
noise**, and that is exactly §1's "unrelated red, green, or blue pixels."

Measured on flat patches, where nothing varies before the quantizer so
everything after it was put there by the quantizer:

| patch | §45 ratio | saturation spread |
|---|---|---|
| neutral 0.50 | 0.0000 (no variation at all) | 0.000000 |
| orange `0.72,0.41,0.19` | **1.500** | 0.027265 |
| blue shadow `0.09,0.11,0.18` | **3.000** | — |
| the Simple grain, for comparison | 0.0000 | — |

**A neutral patch cannot show this.** When `R == G == B` all three channels
quantize identically and the chroma is exactly zero — which is why §45, whose
test is specified on "a constant neutral patch", **is structurally blind to the
defect the TDD's own §1 complains about.** That is the sharpest thing in this
audit: the TDD's acceptance test cannot fail on its stated problem.

**And film emulsion as specified makes it more visible, not less.** §16 puts
film before the dither, so the quantizer is unchanged; and removing the
baseline's additive grain removes the *luma* noise that was camouflaging the
chroma. Measured on flat coloured patches in a rendered frame, the §45 ratio
goes **0.225 with the legacy grain to 1.687 with film**.

**The fix is the density model's own idea, one stage later.** Quantize
luminance, then scale the colour by the ratio — one shared decision instead of
three, so hue and saturation survive exactly, for the same reason a shared
transmission multiplier does in §27. Shipped as `LuxPreset.dither_chroma_
coherence`, on the film shader only.

A shared decision is coarser at the same level count, which is what
`dither_luma_scale` pays back. On a coloured gradient at 24 levels:

| | luminance steps | max step | saturation spread |
|---|---|---|---|
| per-channel (classic) | 36 | 0.0417 | 0.0797 |
| shared, luma scale 1x | 13 | 0.0417 | **0.000000** |
| shared, luma scale 3x (default) | **38** | **0.0139** | **0.000000** |

At the default it bands *more finely* than per-channel and moves saturation by
nothing, so it is not a trade. Confirmed on the GPU by
`tools/film_render_probe.py`: per-channel spreads saturation by up to 0.0824 on
a flat orange patch, shared by **exactly 0.000000**, at both precisions. And on
the rendered sample scene across 2183 flat coloured blocks, saturation
variation falls from **0.04178 as shipped to 0.01509** — the grain accounts for
very little of that and the quantizer for nearly all of it.

Both probes carry this: `film_math_probe.py` asserts both halves (that
per-channel *does* move saturation, so a fix that did nothing could not pass,
and that shared moves it by nothing), and `film_render_probe.py` measures it on
hardware.

## 4. Where a natural (non-quantizing) path already exists

Quantization at lines 96-101 sits *inside* `if (amt > 0.0001)`, and `amt` is
`strength`, which `LuxPostFX.apply()` sets to `0.0` whenever
`preset.dither_enabled` is false or `quality.allow_dithering` is false.

So `dither_strength = 0` already yields **no quantization at all** — §17's
"Natural Mode" is reachable today without new code. Film emulsion does not need
to build that path, only to sit correctly within it.

## 5. Findings, ordered by what they cost

1. **The post pass reads 8-bit color** (§2) -- MEASURED, not inferred. Blocks
   §20 outright, keeps §45's preferred bar out of reach (0.3340 against 0.20),
   and leaves the default grain spanning 3 codes -- and, worst, makes the whole
   measurement **hardware-dependent** (§2b). `hdr_2d = true` fixes all four. The
   decision is a human's: it costs about +7.5 MiB at 1080p.
2. **Grain runs after quantization** (§3b). The §16 ordering violation. Fixed by
   construction in the film shader variant, which places film before palette and
   dither.
3. **Additive grain modulates saturation, up to +53% in shadow** (§3a). This is
   the real photographic defect and what the density model fixes.
4. **The grain hash scales frequency with playtime and is GPU-dependent** (§3c).
   Independent bug; the film path replaces it with a tiled texture fetch on a
   24 fps cadence.
5. **The TDD's stated premise IS present — in the dither, not the grain**
   (§3d). Per-channel quantization scores 1.500 on §45's metric on flat orange
   and spreads saturation by 0.0824 on hardware; the grain scores 0.0000.
   §45's own neutral-patch test cannot see it. Fixed by a shared quantization
   decision, on the film path only.

## 6. A trap for whoever reads §45's numbers next

Applied to a **coloured** patch, section 45's metric is not a chroma
measurement. With the chroma term switched off entirely -- `film_chroma_ratio`
= 0, so the only thing running is the shared neutral transmission, which is
provably hue- and saturation-preserving -- the metric still reads:

| patch | chroma term OFF | chroma term at 0.10 |
|---|---|---|
| neutral | 0.0000 | 0.1876 |
| orange | **0.6027** | 0.6290 |
| red | **0.9894** | 1.0089 |
| blue | 0.7368 | 0.7603 |

On a coloured patch `R - G` is non-zero, so multiplying by a varying shared
transmission varies it -- and `std(R-G)` counts that as chroma noise. The
chroma term contributes only 0.02 to 0.03 of those figures; the rest is the
neutral term being mismeasured. **This is why section 45 specifies a constant
neutral patch**, and it is the only patch the metric means anything on.

Recorded here because the obvious reading of a 0.63 on orange is "the chroma is
too strong", and acting on it would reduce or delete the dye variation section
31 exists to add, for no gain.

**This does not mean the metric is useless and chroma is fine.** It means the
metric cannot separate a shared multiplier from independent channels, so it
needs the right statistic on the right patch. §3d uses *saturation spread* on
flat coloured patches instead, and on that statistic the quantizer's defect is
unmistakable and the shared-decision fix measures exactly zero. Two conclusions
that look contradictory — "ignore a 0.63" and "0.082 is the defect" — are the
same conclusion: measure hue and saturation directly, not through a proxy that
counts a shared multiplier as chroma. `film_render_probe` runs the chroma-off control
on every invocation so the comparison is always in front of whoever reads it.

## 7. What Phase 1 does NOT establish

- ~~Everything rendered here ran on llvmpipe~~ -- **closed 2026-09-02**: the
  same probe ran on an NVIDIA GeForce RTX 2060 and every `hdr_2d = true` figure
  agreed to within 0.2% (§2b). The 8-bit figures did not, which is itself the
  finding rather than a gap. Two rasterisers is not every rasteriser, but it is
  no longer an untested assumption.
- ~~Nothing here says anything about SPEED~~ -- **partly closed 2026-09-02**:
  §41's budget is measured and met on an RTX 2060 across §50's whole resolution
  matrix (film adds 0.0240 ms at 720p to 0.1340 ms at 4K; worst cell 4K at
  120 fps, 1.79% against a 2% allowance, 12% of budget to spare). What remains
  of §50 is VRAM, RAM, bandwidth, power and shader stalls; §51's hardware sweep
  is untouched, and one RTX 2060 is nobody's minimum spec. The frame-time
  figure is a FLOOR -- an empty scene, nothing else competing for bandwidth.
- No claim is made about how film response reads on real geometry. The walk is
  still the final judge, per item 61's closing condition.
