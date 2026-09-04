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
  120 fps, 1.79% against a 2% allowance, 12% of budget to spare). The
  frame-time figure is a FLOOR -- an empty scene, nothing else competing for
  bandwidth.
- ~~No claim is made about how film response reads on real geometry~~ --
  **closed 2026-09-03** by §8, the walk.
- ~~§50 wants VRAM, RAM, bandwidth, power and shader stalls and only frame
  time is measured~~ -- **three of five closed 2026-09-04** (§9), and the two
  that are not are named with the tool each needs rather than estimated.
  **Power is the one that changed a decision**: film costs +7.6 W at 720p to
  +12.1 W at 4K, which is nothing on a desktop and a sixth of a Steam Deck's
  entire budget -- so the handheld class is the row §51 should fill first, and
  no frame-time column could have said that.
- ~~§51's hardware sweep is untouched~~ -- **partly closed 2026-09-04**: it has
  a harness, an accumulating file and one machine in it (§10). Six of seven
  classes remain open, which is the same amount of unmeasured hardware stated
  more usefully. One RTX 2060 is still nobody's minimum spec.
- **The half-resolution pass is priced but not built** (§11). It closes every
  failing §41 cell and costs the fine grain band; that is a look decision, and
  nothing here makes it.
- **VRAM's absolute cost is asserted from the asset, not measured.** The probe
  reads +0.000M at every resolution because it builds all five materials --
  the grain texture included -- before the baseline row runs, so the texture is
  resident on both sides and the delta cancels. What the row does prove is that
  nothing about film's VRAM scales with resolution. The 64 KiB figure comes
  from the asset being one 128x128 RGBA8 texture, which is arithmetic on a file
  and not an instrument reading. Seeing it would mean building the film
  material after the baseline row.

---

## 8. The walk: real pipeline geometry, with a control

`tools/film_walk_probe.py`. The staged night strip as `walk_night_strip.gd`
composes it -- three Patina store shells with their dressing, the fixtures
GLB, 59 site light rigs baked through `LuxLightLoader`, 147 fixtures spawned
from 147 markers, `Gothic Street Night` -- shot from four cameras, four times.

### 8a. Why there are four states and not three

The film states raise `use_hdr_2d`. So every earlier three-state comparison
(`film_off` against a film state) measured **film or the render target, one of
the two, and could not say which**. This is the same error the optionality
probe made before it got a control, in the same week.

`hdr_only` is film OFF at the film states' render target. `film_off ->
hdr_only` is the target's own effect; `hdr_only -> film_shared` is the film's.

The probe now also **asserts** each state rendered in the configuration its
column claims, and aborts if not. That check earned itself on its first run:
`film_shared` silently rendered at `hdr_2d = false`, because the control's
reset cleared a raise that `_sync_film_precision` triggers on an EDGE and
therefore never restored. A whole run's numbers compared two things neither of
which was what its column said.

### 8b0. THE SHIPPED CONFIGURATION, RE-MEASURED (2026-09-04)

Everything in 8b and 8c below was measured while the film states raised
`use_hdr_2d`. **They no longer do** -- §8h defaulted that off -- so those tables
describe a configuration that does not ship, and this one supersedes them for
any claim about what film does.

With the render target held at 8 bits in every column, film is now the ONLY
variable. Hue edges per lit scanline, llvmpipe, four cameras, grain at the
shipped 0.20:

| shot | film OFF | film, per-channel | film, SHARED | off -> shared |
|---|---|---|---|---|
| 01_strip | 47.9 | 73.3 | **21.6** | 2.22x |
| 02_pawn_front | 45.4 | 69.7 | **22.8** | 1.99x |
| 03_facade_raking | 9.9 | 13.2 | **5.1** | 1.94x |
| 04_pool | 17.7 | 24.0 | **11.4** | 1.55x |

**The middle column is the whole argument, and it only became visible once the
grain was.** At a density of 0.20, film with PER-CHANNEL quantization makes the
rainbow 1.5x WORSE (47.9 -> 73.3): a grain that actually modulates the image
drives three channels across their quantization boundaries at different screen
positions, which is precisely the mechanism §3d named. The shared quantizer
does not merely undo that, it lands 2.2x below the baseline.

Earlier runs missed this because the grain was at 0.025, where it modulated
+/-0.75% of transmission and could not push anything across a boundary. The
per-channel column read as roughly neutral and the conclusion drawn from it --
"the grain does nothing to the rainbow" -- was true only of a grain nobody
could see.

**The honest headline for item 61 is 1.55x to 2.22x, not the 3.6x to 5.9x
recorded below.** The difference is the render target, which used to be
switched on underneath the comparison and is no longer part of the feature.

Item 57 in the same run, detection rate: 68/82/87/0% film off against
66/82/92/0% film shared. **No effect**, on the one honest statistic, in the
shipped configuration. `04_pool` has no module in any state and cannot answer.

### 8b. THE ATTRIBUTION IN THE FIRST VERSION OF THIS SECTION WAS WRONG

The walk was written and first run on llvmpipe. On 2026-09-03 it ran on an
NVIDIA GeForce RTX 2060, and the two rasterisers **do not agree about what the
render target does** -- which means the llvmpipe attribution, published in this
section for about an hour, is retracted.

Hue edges per lit scanline, RTX 2060, and the two ratios the control exists to
separate:

| shot | film_off | hdr_only | film per-chan | film SHARED | target | quantizer |
|---|---|---|---|---|---|---|
| 01_strip | 32.9 | 16.3 | 15.4 | **8.7** | 2.02x | 1.87x |
| 02_pawn_front | 33.5 | 11.4 | 9.6 | **5.7** | 2.94x | 2.00x |
| 03_facade_raking | 28.8 | 7.0 | 8.0 | **6.6** | 4.11x | 1.06x |
| 04_pool | 10.9 | 5.3 | 4.9 | **3.0** | 2.06x | 1.77x |

**Both changes matter, and on three of four shots the render target matters
more.** The retracted llvmpipe reading said "the render target is not the fix
(47.9 -> 42.7, not even consistent in sign)". On hardware it is 32.9 -> 16.3,
33.5 -> 11.4, 28.8 -> 7.0 and 10.9 -> 5.3 -- a 2.0x to 4.1x reduction before
the film shader runs at all.

What survives from the llvmpipe run, because hardware agrees with it:

- The **total** is the same order either way: 3.6x to 5.9x, film_off to
  film_shared, on both rasterisers.
- **Grain alone still does nothing.** `hdr_only -> film_perchannel` is film
  fully on with per-channel quantization: 16.3 -> 15.4, 11.4 -> 9.6, 7.0 -> 8.0,
  5.3 -> 4.9. Two rasterisers, both saying the grain is not what removes the
  rainbow.
- The shared quantizer is still worth 1.06x to 2.00x on top of the target.

**The general lesson, which is the one worth keeping: a control tells you THAT
two causes are separable. It does not tell you their sizes on hardware you did
not run.** Section 2b already said the 8-bit figures do not agree across
rasterisers; `film_off` IS the 8-bit column, so every ratio taken against it was
exposed to that and this section published them anyway.

### 8c. The render target is NOT tonally neutral on hardware, and that is new

`film_off` and `hdr_only` differ only in `use_hdr_2d`. Film is off in both. On
the RTX 2060, on `04_pool`:

- mean luminance **0.2046 -> 0.1004** -- half
- 45% of pixels differ by more than 0.15
- not a readback encoding artifact: applying the sRGB transfer function to
  `hdr_only` does not recover `film_off` (mean absolute difference 0.114 raw,
  0.086 sRGB-encoded, and the encoded mean overshoots at 0.227 against 0.182)

The `hdr_2d` decision recorded in roadmap item 61 rests on a measurement that a
3D scene resolved into the raised target lands on the SAME values, only more
precisely. That was a patch-level test on llvmpipe and may well still hold at
that level. **End to end through the whole post stack on real hardware it does
not**: `film_manage_hdr_2d` defaults to true, so turning film on halves the
brightness of this scene before any film arithmetic runs.

The likely mechanism -- untested, stated as a hypothesis -- is that the float
target no longer clamps at 1.0 before the post pass, so the grade's contrast
pivot, the palette zones and the quantizer all see a different input range.
**This is the next thing to investigate and it is more consequential than
anything else in this section**, because it means film emulsion is not tonally
free even where its own arithmetic is.

### 8d. Item 57: the answer depends on WHICH statistic, and the honest one is detection rate

Prominence is only meaningful where a bump was found. `argmax` always returns
something, so a shot with no module at all reports the first lag searched, and
that number then gets compared across states as though it meant anything -- the
same failure as the metric it replaced, one level down. The tool now reports
**detection rate**: the fraction of lit rows carrying a real interior bump.

| shot | film_off | hdr_only | film per-chan | film SHARED |
|---|---|---|---|---|
| 01_strip | 31% p8 | 44% p8 | 47% p8 | 47% p8 |
| 02_pawn_front | 72% p128 | 78% p26 | 77% p27 | 79% p26 |
| 03_facade_raking | 82% p50 | 85% p94 | 71% p49 | **71% p50** |
| 04_pool | 25% p8 | 81% p53 | 8% p8 | **3% p8** |

`p8` is the search floor -- no module found. `01_strip` never has one and cannot
answer this question at all; its prominence row is floor noise in every column.

On the shots that DO have structure, against the `hdr_only` control:

- **`03_facade_raking` is the real item-57 shot** -- a raking facade at a 50 px
  pitch. Film loosens it: detection 85% -> 71%, prominence 0.1171 -> 0.1008,
  about 14% down.
- **`02_pawn_front` does not move**: 78% -> 79%, pitch 26 either way.
- **`04_pool` collapses, 81% -> 3%** -- but this is NOT an item-57 result. What
  is periodic in a light pool at pitch 53 is the concentric banding of the
  falloff, not a wall module. Film erasing it is the rainbow finding of section
  8b showing up in a second statistic, which is a good consistency check and a
  bad item-57 datum.

**So: a modest real loosening on the one genuine facade shot, nothing on the
second, and the third is measuring something else.** The original hypothesis
survives weakly on hardware.

**RETRACTED, from the llvmpipe run of the same tool:** "film emulsion is not a
treatment for item 57 and mildly works against it on raking facades", with a
claimed +12% on the raking shot. On hardware that shot goes the other way, -14%
by prominence and 85% -> 71% by detection. That conclusion was built on
prominence figures from shots that had no module to measure, on a rasteriser
that disagrees with hardware about the render target. Both halves of the error
were avoidable and neither was caught by the control, because a control does not
make a wrong statistic right.

### 8e. Two more things the walk fixed about itself

- **Statistics were being averaged over black sky.** Two shots framed 5-8% lit
  pixels; the per-row guard was `std > 1e-4`, which a black row passes on
  noise. Rows now must carry mean luminance >= 0.02, sample size is printed per
  shot, and a thin sample is labelled. Camera framing was tightened on the two
  worst; on hardware they now measure 20% and 14% lit rather than 8% and 5%.
- **The exposure table is measured `hdr_only -> film_shared`**, not from
  `film_off`. Against `film_off` it would be the film's response plus the
  render target's, and would overstate the film by the difference.

Response by luminance band on the most-lit shot, film isolated, RTX 2060:
relative response falls monotonically **0.2518** (0.00-0.05) through 0.1631,
0.0795, 0.0469 and 0.0315 to **0.0227** (0.55-1.01) -- the shadow-weighted curve
§27 asks for, on real geometry. This is the one column of section 8 that
llvmpipe and hardware agree on closely (0.2385 -> 0.0176 there), which is
expected: it is measured between two states that share a render target, so it is
the only figure here the `film_off` 8-bit column never touched.

### 8f. The speckle in the blacks is the LEGACY grain, and film cannot reproduce it

Walking the level rather than shooting it produced the first aesthetic
objection this feature has had, and it is a useful one: **the operator liked
the speckle that film removes.**

High-frequency energy in the dark region of one night frame, and the fraction
of the frame sitting at pure black:

| state | grit | pure black |
|---|---|---|
| film OFF, legacy grain 0.05 (shipped baseline) | 0.00589 | 62% |
| film OFF, legacy grain 0.00 | 0.00018 | 98% |
| film OFF, legacy grain 0.08 | 0.00970 | 59% |
| film SHARED, film grain 0.025 | 0.00018 | 98% |
| film SHARED, film grain 0.100 | 0.00019 | 98% |

Three readings:

1. **The speckle is the legacy additive grain, entirely.** Set its strength to
   zero and the baseline's grit becomes 0.00018 -- identical to film's. It is
   not the dither, and §8d's `dither_luma_scale` has nothing to do with it
   (3.0 -> 0.00018, 1.0 -> 0.00017; a comment in the walk tool claimed
   otherwise and has been corrected).
2. **Film cannot reproduce it, and not because the strength is too low.** A 4x
   increase in `film_grain_strength` moves the dark grit from 0.00018 to
   0.00019. The density model is MULTIPLICATIVE -- `col *= exp2(-density)` is
   zero wherever `col` is zero -- so 98% of a night frame stays perfectly flat
   however far the knob is pushed. Additive grain LIFTS pixels off black, which
   is why only it puts texture in the void.
3. **The film grain is not inert, it is confined.** In the 0.05-0.15 band,
   where there is light to modulate, 0.025 -> 0.100 moves grit 0.00579 ->
   0.00678. It works exactly where the model says it can and nowhere else.

**THIS IS A MODELLING GAP, NOT A PREFERENCE.** Real emulsion is never perfectly
clear: unexposed silver halide still develops to a minimum density -- base plus
fog -- and shadow grain is one of the most characteristic things about pushed
film. A purely multiplicative density with no additive floor cannot represent
that, by construction. So the honest statement of the tradeoff as it stands is:

- **film ON** gives clean, flat, digital blacks and photographic response
  everywhere there is light
- **film OFF** gives grainy blacks from a grain model that also modulates
  saturation and is applied after quantization (§3a, §3b) -- the defects this
  feature was written to remove

**Nobody has to choose.** Adding a small additive base-fog term to the film
density would give shadow grain that IS chroma-coherent (one shared density,
§8b) and IS exposure-weighted -- the operator's speckle without the
saturation modulation. It is what silver halide actually does.

**BUILT AND MEASURED, 2026-09-03**, as `film_base_fog` (default 0.0, so nothing
changes until a preset asks):

| state | fizz (3x3) | pure black | dark saturation |
|---|---|---|---|
| film, base_fog 0.000 | 0.00406 | 88.3% | 0.0433 |
| film, base_fog 0.020 | 0.00548 | 77.4% | 0.0431 |
| film, base_fog 0.040 | 0.00720 | 63.7% | 0.0448 |
| baseline, legacy grain 0.00 | 0.00406 | 88.2% | 0.0428 |
| baseline, legacy grain 0.05 | 0.01014 | 56.4% | 0.0421 |
| baseline, legacy grain 0.08 | 0.01353 | 53.3% | 0.0411 |

**A FIRST VERSION OF THIS TABLE WAS TAKEN THROUGH A MOVING CAMERA AND IS
REPLACED.** The walk's player is a `CharacterBody3D` under gravity, so it
settles over the frames between captures and every shot in a sweep saw a
slightly different scene. The same nominal settings measured 0.00074 in one run
and 0.00406 in another, and the difference was the viewpoint, not the shader. A
sweep whose camera moves is not a sweep. `film_walk_live.gd` now freezes the
player for `LUX_WALK_SELFTEST` -- physics and input off, position pinned -- and
every figure in this section is from a frozen viewpoint. It was caught by a
"solved base_fog = 0.0000" that could not possibly be right.

The conclusion survived the correction, which is the only reason it is still
here: **film with base_fog 0 and the baseline with its grain at 0 measure
identically** (0.00406 against 0.00406, 88.3% against 88.2% pure black). The
speckle is the legacy grain and nothing else.

**GRAIN SIZE IS A BETTER FIZZ KNOB THAN AMPLITUDE.** `film_grain_scale` divides
`FRAGCOORD`, so at its 1.0 default one grain texel covers one PIXEL -- the
finest structure a screen can hold, which reads as electronic sparkle rather
than silver. At a fixed base_fog of 0.060:

| grain_scale | fizz (3x3) | % of fog contribution | grain body (7x7) |
|---|---|---|---|
| 1.0 | 0.00883 | 100% | 0.01350 |
| 2.0 | 0.00701 | 62% | 0.01315 |
| 3.0 | 0.00622 | 45% | 0.01255 |

Coarsening the grain removes **55% of the fizz while keeping 93% of the grain
body**. Dropping amplitude instead removes both together. So the first answer
to "too much fizz" is a bigger grain, not less of it -- which is also what the
silver-halide description implies, since real grain has a clump size and this
default has none.

**The obvious implementation was checked first and does not work.** Lifting the
black floor and letting the existing multiplicative density modulate it gives
amplitude `f * ln2 * strength` -- 0.00035 at a floor of 0.02, against 0.025 for
the legacy grain. Matching would need a floor of **1.44**, i.e. black rendered
as light grey. The floor has to be an ADDITIVE term, and that is what was
built: `col += neutral_noise * film_base_fog * exposure_mask`, reusing the
density's own shared noise and exposure mask.

Two things that follow from reusing them, and one correction:

- It is **monochrome by construction**. `neutral_noise` is the single shared
  signal §8b identified as the whole colour-preservation argument, so shadow
  grit cannot reintroduce hue breakup.
- It is a **shadow** grain, not an overlay -- `exposure_mask` is 1.0 at black
  and falls to 0.28 in the highlights.
- **A first estimate that 0.020 would match the legacy grain was wrong**;
  measured, it takes about 0.07. The shipped grain asset has a real grain SIZE
  where the legacy hash is uncorrelated white noise, so the same energy sits at
  lower frequencies. That is the difference between grain and static, and it is
  the reason to prefer this one.

And the defects it does not inherit, on the same frames: the legacy grain
**washes colour out of the shadows as it rises** (dark saturation 0.0078 at
0.05, 0.0067 at 0.08 -- §3a), where base fog does not (0.0080 -> 0.0082). It is
applied before the quantize rather than after (§3b), and its frequency does not
drift with playtime (§3c).

Still unmeasured: the frame-time cost of the extra term, and whether it holds
on hardware -- both of these figures are llvmpipe's.

### 8g. Multi-scale crystals, and a wrong idea about how grain moves

The goal was never "add grain" -- it is the organic movement of different
patterns of silver halide crystals over the light. Two things follow, one built
and one rejected.

**BUILT: a distribution of crystal sizes.** The grain was sampled at ONE scale,
so every grain had the same footprint, and a field of identically-sized specks
is what reads as electronic fizz. `film_grain_octaves` sums 1-3 scales, each
with its own offset into the tile. At base_fog 0.060, frozen viewpoint:

| octaves | fizz (3x3) | body (7x7) | body/fizz |
|---|---|---|---|
| 1 | 0.01024 | 0.01601 | 1.56 |
| 2 | 0.00843 | 0.01565 | 1.86 |
| 3 | 0.00766 | 0.01508 | 1.97 |

Three octaves removes **25% of the fine fizz while keeping 94% of the grain
body**, and moves the body-to-fizz ratio from 1.56 to 1.97 -- the texture stops
living at one frequency. Default is 1, which is the previous behaviour bit for
bit.

**REJECTED: coarse crystals persisting across frames.** The intuition was that
big clumps should hold while fine silver scintillates, so the field moves
against itself. It was implemented (`film_frame / (i + 1)` per octave) and it
is wrong twice.

- **Physically.** Every frame of motion picture film is a DIFFERENT PIECE OF
  EMULSION. The crystals in frame 2 are not the crystals of frame 1 moved
  slightly -- they are different crystals. Grain does not carry over, and
  making it carry over is a video effect, not a film one.
- **Empirically.** It changed nothing measurable. Consecutive grain frames,
  coarse turnover against fine: **1.07 at one octave, 1.02 at three.** Every
  scale still turned over together. The offsets in `film_grain_coord` come from
  a HASH of the frame number, so consecutive frames are fully decorrelated at
  every scale by construction and a slower counter only picks a different
  unrelated tile.

So the organic quality is **not temporal persistence**. It is spatial structure
-- a distribution of crystal sizes -- turning over completely at the projection
cadence, which is exactly what §24's 24 fps is for. The comment claiming
persistence was in the shader for about ten minutes and is recorded here
because it would otherwise read as a design decision rather than a refuted one.

Still unmeasured: everything in this subsection is llvmpipe, single-frame
except the turnover figures, and the extra texture fetches per octave have not
been priced against §41's budget.

### 8h. film_manage_hdr_2d now defaults FALSE, and every "film" tonal figure before this is void

An operator walked the level and said the film treatment felt like "just
adjusting the gamma or contrast". That is exactly what it was.

**THE PAIRED TEST.** One scene, one frozen viewpoint, the render target held
identical in both frames, every film parameter pinned and printed at capture,
film the only variable:

| | mean | p5 | pure black |
|---|---|---|---|
| film OFF | 0.0301 | 0.0000 | 55.6% |
| film ON | 0.0253 | 0.0000 | **87.1%** |

**Film does not lift the blacks. It deepens them** -- 99.7% of the pure-black
pixels stay pure black, and the void grows from 55.6% to 87.1% of the frame
because film drops the legacy additive grain that was lifting it. The 16% fall
in mean is that same removal.

Every figure in this document that showed film raising black levels was
comparing **film-off at 8-bit against film-on at float**, because
`film_manage_hdr_2d` silently switched the render target when film turned on.
Measured, film OFF in both states: llvmpipe takes a pixel at [0,0,0] to
[0.0118, 0.0118, 0.0118] on the raise; the RTX 2060 turns the whole frame into
its linear form (§8c). Two rasterisers, two large and opposite tonal shifts,
neither of them film, both far larger than the grain they were meant to serve.

So the default is now **false**. Film changes the grain and nothing else, which
is the only honest form of an optional treatment -- and it is what item 61's
own framing demanded from the first day: a modular optional choice, not
something hooked into the viewport. Raising the target stays available for
anyone who wants §20's precision and has checked what it costs their look on
their hardware. It is not free and it is not invisible.

**AND THE HARNESS THAT PRODUCED THE OLD NUMBERS IS GONE.** The selftest swept a
dozen configurations and reported figures that did not move when its parameters
did -- filenames recorded 0.025 for every density in a 0.025 to 0.200 sweep.
A harness that cannot be shown to be applying its own settings cannot attribute
anything, and several conclusions here were drawn through it before that was
noticed. It is replaced by the single paired A/B above, which prints every
parameter at the moment of capture.

### 8i. What the walk cannot tell you

Whether the level LOOKS better is a human's answer. The stills are the
deliverable; the numbers only say the treatment behaves on real geometry the
way it behaved on patches.

And one rasteriser is not an attribution. Section 8b's ratios are an RTX 2060's;
llvmpipe gives different ones from the same code and the same scene. §51's
hardware sweep is now load-bearing for this section and not only for §41's
budget -- **the split between render target and quantizer should be assumed
hardware-dependent until a third rasteriser says otherwise.**

---

## 9. §50's other columns: VRAM, RAM and power

Measured 2026-09-04 on the RTX 2060 by `tools/film_render_probe.py --perf
--power`. Three of the five columns §50 asks for. The other two are left empty
on purpose and named below, because a fabricated column is worse than a gap.

### 9a. Power, which is the one that changed a decision

`nvidia-smi` samples at 100 ms in a background thread while Godot runs, and
each configuration reports the wall-clock window of its own timed frames so the
two can be intersected afterwards. **Warmup is deliberately outside that
window**: shader compilation and the clock ramp both move watts, and neither is
the feature. Polling around the whole process instead would average import,
scene build, warmup and five configurations together and publish the mean as
"film", which is how a power column gets written without measuring anything.

| resolution | hdr_2d off | hdr_2d on |
|---|---|---|
| 1280x720 | +7.6 W | -- |
| 1920x1080 | +9.7 W | +11.0 W |
| 2560x1440 | +10.3 W | +7.0 W |
| 3840x2160 | +12.1 W | +8.8 W |

Read as a difference and at its own precision: board power on an idle desktop
wanders several watts, so this column can settle whether film moves power by
tens of watts and cannot settle whether it moves it by one.

**7 to 12 W is nothing on a desktop and a sixth of a Steam Deck.** That is the
finding, and it reorders §51: the handheld class stopped being one entry in a
list and became the one worth filling first. No frame-time column could have
produced it.

The second thing in the same data is a check on an existing hypothesis. §41
found film CHEAPER in time with `hdr_2d` on and read it as the float target
making the pass bandwidth-bound so the arithmetic hides behind memory traffic.
Power agrees: the film delta is smaller with the target raised at both 1440p
(7.0 vs 10.3 W) and 4K (8.8 vs 12.1 W). Two independent instruments now point
the same way. It is still a hypothesis and still not a profile.

`hdr_2d` also now has a price of its own: +35.9% on the baseline pass at 4K
(0.3090 -> 0.4200 ms) and roughly 6-7 W.

### 9b. VRAM, and why the number in the table is not the answer

The probe reports **+0.000M at every resolution**, and that figure does not
mean what the column implies. All five materials -- the grain texture included
-- are constructed before any timing runs, so the texture is resident during
the BASELINE row too and the delta cancels.

What the row honestly establishes is the prediction it was built to test:
**flat across all four resolutions**, so nothing about film's VRAM scales. A
delta that grew with the row would have been the render target rather than the
feature.

The absolute comes from the asset and not from the instrument: one 128x128
RGBA8 texture, **64 KiB, once**, sampled at a locked reference width. Seeing it
measured would mean building the film material after the baseline row, which
is a change to the probe and not to the feature. RAM is +0.006M, consistent
everywhere.

### 9c. What is deliberately still empty

- **Bandwidth.** No engine counter reports it. It is derivable from resolution
  x format x taps, but that is arithmetic dressed as a measurement and the
  cache is what actually decides the answer.
- **Shader stalls.** Needs Nsight, RGP or PIX. There is no substitute and a
  proxy would be worse than the gap.

---

## 10. §51: the sweep is a file, not a run

`tools/film_hw_sweep.py` appends ONE record for ONE machine to
`docs/data/film_hw_sweep.jsonl`.

**Why that shape.** This section stayed untouched while everything around it
closed, and the reason is structural: a sweep written as a single invocation
cannot be started until the last card arrives, so it never gets started at all.
Inverted, the sweep IS the file. A machine can be measured the afternoon
somebody has access to it, months apart, by different people.

Three properties are deliberate:

- **Records are never overwritten.** Re-measuring appends; the report shows the
  newest and prints the movement between runs. A sweep whose history the next
  run can silently rewrite cannot answer "did this get worse", which is most of
  what a sweep is for.
- **Sample counts are a constant, not a flag** -- 120 discarded then 600 timed
  on every machine. Two rows measured differently cannot be put next to each
  other, and being able to do that is the entire value of the file.
- **The coverage class is a guess, labelled as one** in the record. An adapter
  string cannot tell a desktop part from the same silicon in a laptop, and it
  certainly cannot see a handheld. `--class` overrides it.

First row: RTX 2060, worst cell 0.2590 ms at 4K/`hdr_2d` true -- reproducing
the 0.2580 in the authoring doc across a separate run and a separate harness.
**Six of seven classes remain open** (AMD discrete, Intel Arc, integrated,
handheld, Apple/Metal, software). That is the same quantity of unmeasured
hardware as before, stated as a list of machines to find rather than as a
sentence saying the section is untouched.

---

## 11. The half-resolution pass: priced, not built

### 11a. What it buys, without a new harness

A half-res pass at 4K renders exactly as many fragments of exactly the same
shader as a full-res pass at 1080p, and the resolution lock makes the
per-fragment work identical too -- so its film cost IS the 1080p cell §50
already measured, on the same GPU, in the same run. Building a SubViewport
harness to re-measure that would only have added a new way to be wrong about a
number already in hand.

| cell | budget | full-res | half-res | blit has |
|---|---|---|---|---|
| 4K @ 90 | 0.2222 | 0.2580 | 0.0990 | 0.1232 ms |
| 4K @ 120 | 0.1667 | 0.2580 | 0.0990 | 0.0677 ms |
| 1440p @ 120 | 0.1667 | 0.1760 | 0.0450 | 0.1217 ms |

Every failing §41 cell closes. The upscale blit is the one genuinely
unmeasured term -- one textured full-screen quad, no arithmetic -- and the last
column says how much it would have to cost to matter.

### 11b. What it costs, and two wrong answers first

`tools/film_halfres_probe.py` synthesises the shipped `R*0.68 + G*0.32` blend
as it lands ON SCREEN, runs it through the half-res path, and compares radial
power spectra. Aliasing and softening are different failures and only a
spectrum tells them apart: softening REMOVES energy above the new Nyquist,
aliasing MOVES it down into frequencies that were not there before. A single
"grain got weaker" number cannot distinguish them and they look nothing alike.

**Wrong answer one:** a Nyquist argument on the band edges predicted the fine
band would ALIAS at 1440p-half. It does not.

**Wrong answer two:** the first measurement box-downsampled a full-res render
and reported 0.0% aliasing everywhere, which should have been the tell. A box
downsample is a fair low-pass filter. A half-res PASS does no such thing -- it
evaluates the grain once per half-res fragment, point-sampled, and frequencies
above the new Nyquist fold rather than attenuate.

| case | amplitude retained | fine band | aliased down |
|---|---|---|---|
| 4K half-res | 74.3% | 31.5% -> 13.5% | 0.0% |
| 1440p half-res | 65.6% | 23.4% -> 12.6% | 0.0% |
| 1080p half-res | 64.1% | 25.9% -> 22.6% | 10.2% |

**At the resolutions that need it, half-res softens rather than aliases.** What
it softens is the fine band -- 68% of the blend, and the band
`make_film_grain.py` deliberately places near Nyquist "so it reads as film
grain rather than as blobs". Aliasing appears only at 1080p, so the technique
is viable exactly where it is needed and breaks where it is not.

### 11c. Why it is not built

A half-res film pass is not a quality setting. **It is a second stock** -- the
same emulsion, coarser and softer, because half the pixels is half the pixels.
Whether that reads as acceptable is a human's answer and this audit does not
make it.

And one thing worth saying next to the whole exercise: 4K at 120 fps is chasing
motion clarity, and film emulsion is a 24 fps aesthetic -- §24 advances the
grain at 24 fps no matter how fast the renderer runs. Half-res makes the cell
FIT. It does not make it a thing anyone wants.

---

## 12. §54's film-mode edge case, and a lesson about test order

`set_film_mode(true)` on a build where the shader and grain texture are DELETED
must leave the render alone rather than fail the frame. That test aborted the
engine on both rasterisers, and three rounds of debugging went at llvmpipe.

**RETRACTED: "it segfaults llvmpipe at `is_film_emulsion_active()`."** That
sentence was written into the probe's own comments and its report text, and it
was wrong twice over. The cause was the probe: the viewport-cleanup test above
it frees the LuxRoot BY DESIGN -- it is a test *of* teardown -- and the
film-mode test then called `set_film_mode()` on a freed node. The free landed
during an `await`, which is why there was no catchable error, an unsymbolised
C++ backtrace, and a reported line that drifted onto a two-term getter that
cannot abort anything. A freed Node still answers `!= null` in GDScript; only
`is_instance_valid()` tells the truth, and that is what kept it invisible.

**And the fix broke the test below it.** Reordering put the film-mode test
first; `set_film_mode()` moves the film MASTER as well as the mode flag (it has
to, against §10's three-key AND), so the cleanup test inherited the master off
and correctly reported that it never got film running. That is the SAME defect
one pair along -- one test mutating shared state on `_lux` and the next
inheriting it -- and the reorder only moved which pair it broke.

Fixed from both sides, because either alone would have fixed the symptom and
left the coupling: the film-mode test restores the master it found, the cleanup
test sets it explicitly instead of assuming, and `master_restored` is asserted
so the next leak fails where it happens. It was caught only because the cleanup
test refuses to pass itself when it did not observe what it was measuring.
**That is luck, not coverage**, and it is the argument for tests that report
"I measured nothing" rather than a value.

Green on both builds:

| build | mode ON | mode OFF | preset left clean |
|---|---|---|---|
| film present | active=True | active=False | yes |
| film DELETED | active=False | active=False | yes |

Viewport cleanup with the raise opted in: `False -> True (film_active=True) ->
False`, and `False` again after `_exit_tree` with film still on. Both restore
paths exercised.
