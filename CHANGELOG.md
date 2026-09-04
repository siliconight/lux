# Changelog

All notable changes to Lux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Lux uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While Lux is pre-1.0, minor versions may include breaking changes to resources
and the API; these are called out under **Changed** / **Breaking**.

## [0.29.0] - grain with a crystal size, and the walk walked

The goal was never "add grain". It is the organic movement of different
patterns of silver halide crystals over the light -- and stating it that way is
what produced everything below, because it named two things the feature did not
have.

### Added
- **`film_base_fog`** -- additive shadow grain, the emulsion's base-plus-fog
  floor. The multiplicative density is silent on pure black by construction
  (`col *= exp2(-d)` is zero wherever col is zero), so it left a night frame's
  void perfectly flat where real film is grainiest. Measured, frozen viewpoint:

  | state | fizz | pure black |
  |---|---|---|
  | film, base_fog 0.000 | 0.00406 | 88.3% |
  | film, base_fog 0.020 | 0.00548 | 77.4% |
  | film, base_fog 0.040 | 0.00720 | 63.7% |
  | baseline, legacy grain 0.05 | 0.01014 | 56.4% |

  **The obvious implementation was checked first and does not work.** Lifting
  the black floor and letting the existing density modulate it gives amplitude
  `f * ln2 * strength` -- 0.00035 at a floor of 0.02, against 0.025 for the
  legacy grain. Matching would need a floor of **1.44**, black as light grey.

  It reuses the density's own `neutral_noise`, so it is monochrome by
  construction and cannot reintroduce the rainbow, and its `exposure_mask`, so
  it is a shadow grain rather than an overlay. It does not inherit the legacy
  grain's defects: that one washes colour out of the shadows as it rises (dark
  saturation 0.0428 -> 0.0411 across its range, §3a) where base fog does not
  (0.0433 -> 0.0448), it is applied before the quantize rather than after
  (§3b), and its frequency does not drift with playtime (§3c).

- **`film_grain_ref_width`** -- **grain size relative to frame width, not to
  pixels.** A crystal is a physical object on a strip of film; how many pixels
  it covers depends on how finely that strip was scanned. Lux pinned one grain
  texel to one PIXEL, so the shipped asset's fine band is 1.42 px across at
  every resolution -- against grain sized as a fraction of the frame that is
  about 2x too coarse at 720p and 1.45x too fine at 4K. **Too fine is the one
  that hurts: it lands near Nyquist and fizzes.** The reference is 2048, which
  is where the asset already sits, so the authored look holds at ~1440p and is
  corrected everywhere else; 0.0 restores the old behaviour.

- **`film_grain_octaves`** (plus `film_grain_lacunarity`,
  `film_grain_persistence`) -- more scales summed. **The claim first made for
  this was wrong and is withdrawn:** Lux was NOT sampling grain at one scale.
  The shipped asset is built from four band-limited streams, and the neutral
  signal is `R_fine * 0.68 + G_coarse * 0.32` -- R_fine at 28-62 cycles/tile
  (radius 1.42 px), G_coarse at 6-20 (radius 4.92 px). That is already a
  two-scale crystal distribution, and its weights are the SAME 0.68/0.32 the
  filmify photochemical profile derives for its own two crystal scales, at a
  scale ratio of 3.46 against filmify's 2.91. Two implementations arrived at
  the same model independently. This uniform stacks further octaves on top of
  a distribution that already existed, which is why it measurably helps but
  is not the missing piece it was described as. At base_fog 0.060:

  | octaves | fizz (3x3) | body (7x7) | body/fizz |
  |---|---|---|---|
  | 1 | 0.01024 | 0.01601 | 1.56 |
  | 2 | 0.00843 | 0.01565 | 1.86 |
  | 3 | 0.00766 | 0.01508 | **1.97** |

  Three octaves removes 25% of the fine fizz while keeping 94% of the grain
  body. Default 1 is the previous behaviour bit for bit.

- `tools/film_walk_live.py` + `.gd` -- **the walk, walked.** First person on the
  staged night strip with the treatment on a key, because
  `film_walk_probe.py` opens Godot, shoots sixteen stills and quits, and grain
  is temporal: a frozen frame cannot show either the good half of it or the bad
  half. Carries a gamma null test in the HUD (see Unresolved) and a
  `LUX_WALK_SELFTEST` path that freezes the viewpoint and sweeps every knob.

### Rejected, and recorded rather than quietly dropped
- **Coarse crystals persisting across frames while fine ones scintillate.**
  Built, then removed. Wrong physically -- every frame of motion picture film
  is a different piece of emulsion, so the crystals in frame 2 are not frame
  1's crystals moved, they are different crystals -- and wrong empirically:
  coarse turnover against fine measured **1.07 at one octave, 1.02 at three**,
  i.e. every scale still turned over together. The offsets come from a hash of
  the frame number, so consecutive frames are fully decorrelated by
  construction. The organic quality is spatial structure turning over
  completely at §24's cadence, not temporal persistence.

### Fixed
- `film_base_fog` was inside a guard on `film_grain_strength`, so a preset
  asking for shadow grit with the density off would have got nothing, silently.
  Guard widened to either term, with a permanent self-test case.
- `LuxRoot._load_default_library()` scans the presets directory instead of
  carrying a hardcoded list of six while **nine** ship. `Gothic Street Night`,
  `PS1 Storm Night` and `SoF PC2000` could not be loaded by name at all.

### SECTION 41, BISECTED: THE DENSITY MODEL IS THE BUDGET

The cost was traced by removing each film term in turn at the failing cell
(3840x2160, hdr_2d=true, RTX 2060). Every variant is the shipped configuration
with ONE term changed, so `full - variant` is that term and nothing else:

| configuration | gpu ms | vs full |
|---|---|---|
| baseline shader (no film) | 0.4203 | -- |
| **film, shipped defaults** | **0.6807** | |
| film block branched over | 0.4272 | -0.2534 |
| without the resolution lock | 0.6765 | -0.0041 |
| without the chroma dye term | 0.6689 | -0.0118 |
| 2 crystal octaves | 0.7002 | +0.0196 |
| 3 crystal octaves | 0.8840 | +0.2034 |

**The second shader is free: +0.0069 ms over the baseline with its whole block
branched over.** Every previous theory about the cost -- the octave loop, the
shader swap, the resolution lock -- is now measured and none of them is it.
The entire +0.2534 ms is the film arithmetic itself: the grain fetch, the
dihedral tile coordinate, the exp2 transmission.

**And it cannot be tuned away.** Removing BOTH removable terms saves 0.0159 ms,
6.1% of the film cost. 4K needs to shed 0.0380 ms for 90 fps and 0.0880 for
120. There is no combination of parameter changes that gets there -- the
density model IS the budget, and that is the answer to a question that had been
guessed at four times.

### The shippable envelope, measured

| resolution | film ms | 30 fps | 60 fps | 90 fps | 120 fps |
|---|---|---|---|---|---|
| 1280x720 | 0.0450 | ok | ok | ok | ok |
| 1920x1080 | 0.0990 | ok | ok | ok | ok |
| 2560x1440 | 0.1760 | ok | ok | ok | **OVER** |
| 3840x2160 | 0.2580 | ok | ok | **OVER** | **OVER** |

**Film Mode is inside §41 everywhere except 4K above 60 fps and 1440p at 120.**
That is a scope, not a failure, and it is now documented rather than discovered
by whoever ships a 4K120 build. Both figures are FLOORS on an empty scene, so
treat the two ok cells nearest a boundary (1440p at 90, 4K at 60) as thin.

**The unbuilt option, named rather than assumed:** running the film pass at
half resolution and upsampling would cut the arithmetic roughly fourfold and is
plausible for a treatment whose finest structure is a 1.42 px crystal. That is
a redesign, it is unmeasured, and it is not in this release.

### The old section 41 finding, superseded

Measured on an RTX 2060, Godot 4.7 forward_plus, the engine's own viewport
timer, at the shipped settings:

| resolution | hdr_2d | no post | baseline | film | film - baseline |
|---|---|---|---|---|---|
| 1280x720 | false | 0.0540 | 0.0650 | 0.1080 | 0.0430 |
| 1920x1080 | false | 0.0850 | 0.1290 | 0.2240 | 0.0950 |
| 2560x1440 | false | 0.1390 | 0.2140 | 0.3830 | 0.1690 |
| 3840x2160 | false | 0.1980 | 0.3080 | 0.5620 | **0.2540** |
| 3840x2160 | true | 0.2790 | 0.4180 | 0.6790 | 0.2580 |

Against §41's ~2% of frame, graded at the worst cell:

| frame rate | budget | film uses | |
|---|---|---|---|
| 30 fps | 0.67 ms | 0.78% | ok |
| 60 fps | 0.33 ms | 1.57% | ok |
| 90 fps | 0.22 ms | **2.32%** | **OVER** |
| 120 fps | 0.17 ms | **3.10%** | **OVER** |

**0.28.0 met every cell in this matrix.** It measured 0.0240 ms at 720p and
0.1340 ms at 4K; this release measures 0.0430 and 0.2540. The cost roughly
DOUBLED, and the only structural change in the hot path large enough to explain
it is the octave loop -- a `for` bounded by a UNIFORM cannot be unrolled, so it
becomes a real per-fragment branch on a full-screen pass.

**THE LOOP WAS NOT THE COST, AND THAT ATTRIBUTION IS WITHDRAWN.** A
single-octave fast path was added on the reasoning above and measured on the
same hardware: film at 4K went 0.2610 -> **0.2580 ms**, and §41 went from 2.35%
/ 3.13% of frame at 90/120 fps to 2.32% / 3.10%. **Three microseconds.** The
fast path is kept because it is free and arithmetically identical at the
default, but it fixes nothing and the explanation it was based on was a guess
that measurement rejected.

**AND THE REGRESSION ITSELF IS NOT ESTABLISHED.** The comparison was 0.28.0's
0.1340 ms against today's 0.2540, with no control: 0.28.0's `no post` column is
not recorded, so a machine that is simply slower today -- thermals, driver,
background load -- produces the same apparent doubling. Today's `no post` at 4K
is 0.1980 ms and there is nothing to compare it to. **What is actually known is
the absolute figure and its verdict**, which do not depend on any of that:

- film costs 0.2580 ms at 4K on an RTX 2060, and that is OVER §41's budget at
  90 and 120 fps
- it is a FLOOR on an empty scene, so a real level can only be worse

Finding what costs it needs a bisect -- disable each film term in turn and time
each -- not another hypothesis.

### §45 at 8 bits: inside the hard bar, outside the preferred one
`film_manage_hdr_2d` now defaults false, so the shipped path is 8-bit -- and
that is where §45's chroma-to-luma ratio reads **0.3365** (hard bar 0.40,
preferred 0.20). At float it reads 0.1914 and clears both.

The probe's own noise-floor control says most of that is the FORMAT, not the
grain: the baseline grain is chroma-free by construction, and it still measures
chroma noise of 0.000412 (orange) and 0.000618 (shadow) at 8 bits against
0.000091 and 0.000009 at float. So this is the 8-bit target's quantization
showing up in a chroma metric, not the film's dye term -- and it is NOT fixed
by lowering `film_chroma_ratio`, which the probe says explicitly.

### And the rainbow claim, on a flat patch, exactly
Saturation spread from quantization alone, grain off, so nothing else can vary:
per-channel **0.082397**, shared **0.000000**. Not "smaller" -- zero. One
multiplier applied to three channels leaves hue and saturation untouched by
construction. The coherent quantizer also costs almost nothing: 0.0010 to
0.0120 ms across the whole resolution matrix.

### Added
- **`LuxRoot.film_mode` -- Lux Film Mode, the whole treatment as one switch.**
  `set_film_mode(true)` / `false`, or the exported flag, so a Level Factory
  export can turn the look on or off per level without touching a preset.

  It works because the shipped presets store **no `film_*` fields at all** (only
  the legacy `grain_strength`), so every film value comes from the LuxPreset
  script defaults -- which are now the settled ones. That leaves two flags to
  flip: the master on LuxRoot, and `film_emulsion_enabled` + `grain_mode` on
  whatever preset is being applied, via `make_override` so the shipped resource
  is never mutated.

  **It is an override, not nine edited .tres files.** Film is a treatment OF a
  look, not a look. Baking it into the shipped presets would make it
  unavailable to any preset a project authors itself, and impossible to switch
  off per-export.

  All four `_post.apply` call sites now route through one `_post_apply` choke
  point, so the mode cannot be bypassed by whichever path happens to run. With
  film mode off, `_film_view` returns the preset object itself -- no copy, no
  allocation, and a pure pass-through to the previous behaviour.

  Measured, driven by `set_film_mode()` alone with the preset untouched:
  `active` false -> true, pure black 55.6% -> 87.1%.

  **A TESTING CONSTRAINT WORTH RECORDING.** "Film mode off is byte-identical to
  the build before it existed" could not be measured, and not because it is
  false. The baseline's legacy grain scales its noise FREQUENCY with `time_seed`
  (§3c), so two runs that reach the same frame at different elapsed timesdiffer by
  far more than any code change: same build twice, same selftest length, 0.0071
  mean absolute difference; the same frame against a build whose selftest was
  longer, 0.0304. Cross-build pixel comparison is only valid with the legacy
  grain at zero. The equivalence claim here rests on the pass-through being
  three readable lines, not on a pixel diff.

### Changed (breaking, and it is the point)
- **`film_grain_strength` range 0.0-0.10 -> 0.0-0.30, default 0.025 -> 0.20.**
  At 0.025 the density modulation is about +/-0.75% of transmission --
  invisible. Anyone who enabled film saw nothing and would reasonably conclude
  it was broken; a default nobody can see is not conservative, it is broken.
  0.20 is where the first person to walk a level and look at it put the knob.
  One judgement, one night scene, and the only look judgement this feature has
  ever had, so it is the default -- a daylight preset may want less.

  **`film_grain_scale` stays at 1.0, also by eye.** The tooling advice was to
  raise it for clumps -- coarsening to 3.0 measurably removes 55% of the fine
  high-frequency energy while keeping 93% of the grain body. The same operator
  tried it and went back to 1.0. Both results stand: that fizz measurement was
  taken when the density was 8x too low to see, so it described the texture of
  something nobody could make out. At a visible density the fine grain reads as
  silver rather than sparkle and the clumps are not wanted.

  The old ceiling also made that value unauthorable: `@export_range(0.0, 0.10)`
  meant the inspector clamped at half of it.

  **§45 is unaffected at any amplitude.** It measures chroma-to-luma noise, and
  `film_chroma_ratio` is a fraction OF the neutral signal, so both scale
  together: ratio 0.1881 at 0.025, 0.1882 at 0.200, 0.1884 at 0.300 -- inside
  the hard 0.40 bar and the preferred 0.20 bar throughout.

- **`LuxRoot.film_manage_hdr_2d` now defaults to FALSE.** Turning film on used
  to switch the viewport to a floating-point 2D target, and that is a tone
  change, not a film one -- larger than the grain it was meant to serve and
  different on every rasteriser. llvmpipe takes a pixel at [0,0,0] to
  [0.0118, 0.0118, 0.0118] on the raise with film still OFF; an RTX 2060 turns
  the whole frame into its linear form (exponent 2.265, mean luminance halved).

  With the target held identical and film the only variable: mean 0.0301 ->
  0.0253, pure black **55.6% -> 87.1%**, 99.7% of black pixels staying black.
  **Film deepens the blacks; it never lifted them.** Every figure in 0.28.1 and
  earlier that showed film raising black levels was comparing film-off at 8-bit
  against film-on at float.

  Precision (§20) is still available by setting it true deliberately, on a look
  you have checked on your own hardware.

### Optionality is now proven by EXACT EQUALITY, and a false positive is gone
The probe used to compare against a "floor" -- how far two runs of the SAME
build move each other -- because the baseline's legacy grain is driven by
`time_seed`, which accumulates wall clock. That floor produced a real false
alarm on an RTX 2060: **`Heavy Rain` was reported as moving 0.013314 against a
same-build floor of 0.000000, flagged as a genuine optionality violation.** It
was the clock. The film-DELETED mirror has fewer assets to import, so it always
reaches the same frame at a different elapsed time and renders different noise.

The tell was in the table the whole time: the two presets that ship with
`grain_strength 0` came back `0.000000 identical` in every run.

So the probe now silences the legacy grain for the comparison. The render is
deterministic and the bar is exact equality -- **all nine shipped presets,
A1 vs A2 and A1 vs B both 0.000000, bit-identical.** The floor column is kept
as evidence that the determinism holds: a non-zero entry means the render is
moving on its own and no verdict below it can be trusted.

That is a stronger statement than the floor ever made, and it came from
chasing a failure that turned out not to be one.

### Confirmed against an independent implementation
Cross-checked against the filmify photochemical profile, which models the same
physics from measured film data. Two agreements worth recording because they
were arrived at separately:

- **Exposure weighting.** Lux's mask runs 1.000 / 0.866 / 0.664 / 0.454 /
  0.280 across the range; filmify's `density_amplitude_curve` runs 1.00 / 0.95
  / 0.70 / 0.45 / 0.28. Same endpoints, same shape, one independent derivation
  each. Lux falls off slightly faster in the deepest shadow (0.866 against 0.95
  at 15%), which is the only place they differ meaningfully.
- **Chroma restraint.** filmify's `chroma_weight` is 0.12, exactly the TDD
  §31 default Lux diverged from; Lux ships 0.10 because 0.12 missed §45's
  preferred bar. The two land either side of the same number.

Not modelled in Lux, and now known to be modelled elsewhere: **per-layer grain
amplitude.** filmify carries RMS granularity [9.0, 10.0, 13.0] for R/G/B --
blue is grainiest because its crystals are the largest. Lux's chroma term is
symmetric on two opponent axes and has no per-channel amplitude at all.

### Unresolved, and it gates §8b
On an RTX 2060 the raised render target is **not tonally neutral**: `film_off`
and `hdr_only` differ only in `use_hdr_2d`, film OFF in both, and mean
luminance halves (0.2046 -> 0.1004) with 45% of pixels moving more than 0.15.
Best-fit exponent 2.265 -- the frame is the LINEAR form of the unraised one.
Whether that is only the readback path or the presented image is what the
walk's gamma null test asks; if it is the presented image, the post stack's
0.5-keyed thresholds all land wrong whenever film is on and
`film_manage_hdr_2d = true` is wrong as a shipped default.

Also unmeasured: the extra texture fetch per octave against §41's budget, and
every figure in this release is llvmpipe's except where it says otherwise.

### §50's other columns, and the one that changed a decision

`tools/film_render_probe.py --perf --power` closes three of the five columns
§50 asks for. Full detail in the audit's §9.

**Power was not one of the four things being looked for and is the most useful
number in the release.** Film costs **+7.6 W at 720p to +12.1 W at 4K**, from
`nvidia-smi` attributed to each configuration's OWN timed window -- warmup
excluded, because shader compilation and the clock ramp both move watts and
neither is the feature. On a desktop that is inside the noise. A Steam Deck's
entire budget is 15 W, so the handheld class is now the row §51 should fill
first, and no frame-time column could have said so.

Power also independently supports §41's `hdr_2d` reading: the film delta gets
SMALLER with the float target on (7.0 vs 10.3 W at 1440p, 8.8 vs 12.1 W at 4K),
the same direction the frame times went. Two instruments, one hypothesis, still
not a profile. `hdr_2d` itself: +35.9% on the baseline pass at 4K, and ~6-7 W.

**VRAM reads +0.000M at every resolution and that is a flaw in the
measurement, not a finding.** All five materials including the grain texture
are built before any timing runs, so the texture is resident in the baseline
row too and the delta cancels. What the row does prove is that nothing about
film's VRAM scales with resolution. The absolute -- one 128x128 RGBA8 texture,
**64 KiB, once** -- comes from the asset, not the instrument. RAM +0.006M.

Bandwidth and shader stalls are left EMPTY rather than estimated: no engine
counter reports either, deriving bandwidth from resolution x format x taps is
arithmetic dressed as a measurement, and stalls need Nsight, RGP or PIX.

### §51's sweep is now a file rather than a plan

`tools/film_hw_sweep.py` appends one record per machine to
`docs/data/film_hw_sweep.jsonl`. The section stayed untouched for as long as it
did because a sweep written as a single invocation cannot be started until the
last card arrives. Records are never overwritten -- re-measuring appends and
the report prints the movement, which is most of what a sweep is for -- and
sample counts are a constant rather than a flag, because two rows measured
differently cannot be compared. First row: RTX 2060, worst cell 0.2590 ms at
4K/`hdr_2d` true, reproducing 0.2580 across a separate harness. **Six of seven
classes open, and the report names them.**

### The half-resolution pass: priced, and deliberately not built

`tools/film_halfres_probe.py`. It closes every failing §41 cell -- a half-res
pass at 4K renders the same fragments as a full-res pass at 1080p, so its cost
is a cell already measured -- leaving 0.1232, 0.0677 and 0.1217 ms for the
upscale blit at 4K@90, 4K@120 and 1440p@120.

What it costs is the grain, and **two predictions were wrong before the
measurement stood up**: a Nyquist argument said the fine band would alias at
1440p-half (it does not), and the first probe box-downsampled a full-res render
-- a fair low-pass -- and reported 0.0% aliasing everywhere, which should have
been the tell. A half-res pass point-samples once per half-res fragment.

| case | amplitude retained | fine band | aliased down |
|---|---|---|---|
| 4K half-res | 74.3% | 31.5% -> 13.5% | 0.0% |
| 1440p half-res | 65.6% | 23.4% -> 12.6% | 0.0% |
| 1080p half-res | 64.1% | 25.9% -> 22.6% | 10.2% |

It **softens** rather than aliases, and what it softens is the fine band -- 68%
of the blend, placed near Nyquist on purpose so the grain reads as crystals
rather than blobs. So half-res is not a quality setting, it is a **second
stock**. That is a look decision and this release does not make it.

### §54's film-mode edge case, closed -- and it was never the feature

**RETRACTED: "the film-mode test segfaults llvmpipe at
`is_film_emulsion_active()`."** It was the probe. The viewport-cleanup test
above it frees the LuxRoot by design, and the film-mode test then called into a
freed node; the free landed during an `await`, so there was no catchable error
and the blamed line drifted onto a two-term getter that cannot abort anything.
A freed Node still answers `!= null` in GDScript, which is what kept it hidden.

**The fix then broke the test below it** -- `set_film_mode()` moves the film
master, so the reordered cleanup test inherited it off. Same defect one pair
along. Fixed from both sides and asserted, because either alone would fix the
symptom and leave the coupling. It was caught only because the cleanup test
refuses to pass itself when it did not observe what it was measuring; that is
luck, not coverage.

Green on both builds: film present ON->active, OFF->inactive; film DELETED
ON->inactive, OFF->inactive; shipped preset unmutated in both; viewport raised
and restored on both paths.

## [0.28.1] - the optional feature was not optional, and the demo found it

0.28.0 claimed film emulsion was "opt-in by construction" and listed the
reasons. One of them was false, and the first real run of `tools/film_demo.gd`
on a machine other than the one that wrote it found the false one in about
thirty seconds. The lesson is in the fix: **optionality that has not been
tested by REMOVING the thing is a claim, not a property.** It is now tested
that way -- delete `grain_balanced.png` and Lux renders normally with one
warning -- and that test is the reason to believe the rest of the list.

### Fixed
- **A `preload` of the film assets made an optional feature a hard dependency
  of the entire post stack.** `LuxPostFX` held
  `const FILM_GRAIN_TEX := preload(...)`; a preload resolves when the SCRIPT
  loads, so on a project whose `.godot/` predated the grain texture the script
  itself failed to load, `LuxPostFX.new()` returned null, and `_post` was null
  -- no post processing at all, and
  `Nonexistent function 'apply' in base 'Nil'` from `LuxRoot._process` every
  frame. Found on the first real run of the demo, which is exactly what it was
  for. The assets are now loaded on demand behind `ResourceLoader.exists`, film
  reports itself unavailable once, and `_film_active` requires the material to
  exist. Verified by deleting `grain_balanced.png` outright: one warning, the
  post stack unaffected, frames render, film inactive. That is TDD section 54,
  which a class-scope preload cannot honour because it fails before any Lux
  code gets a say.
- `LuxRoot._process` and `_apply_immediate` guard each module before calling
  `apply()`. The blend branch called all three bare, so a null module threw
  BEFORE `_blending = false` and the blend never finished -- turning one error
  into an unbounded per-frame loop. `process()` two lines above already guarded
  for the same case.
- `tools/film_demo.py` always runs the import pass instead of only when
  `.godot/` is absent. An already-imported project plus a newly added asset is
  precisely the state that produced the above, and skipping an idempotent
  import saved nothing worth having.

- `tools/film_demo.gd`: the HUD panel was anchored to the window BOTTOM with a
  hand-guessed offset smaller than its own content, so every line below
  `strength` -- including `[N]`, the chroma-coherence switch that is the whole
  point of the feature -- rendered off-screen. An operator could not see that
  the control existed. Anchored top-left below the sample scene's own HUD, it
  grows downward into empty space and cannot clip itself.
- `tools/film_demo.gd` says WHY film is not running rather than only that it is
  not: master off, grain mode, preset, quality tier, or assets unavailable. The
  old readout said "no grain" and left five causes indistinguishable -- and one
  of those causes was the preload bug above, whose only visible evidence was
  that line saying nothing useful.

### Added
- `tools/film_optional_probe.py` + `.gd`: **proves optionality by deleting the
  feature.** Mirrors the project twice, removes the film shader and grain asset
  from the second copy, renders every shipped preset in both, and compares. It
  also reports each preset's `asks_for_film` and `film_active`, because a
  preset whose flag drifted would not crash -- it would quietly render
  differently from what its author approved.

  **It runs the same build twice as a control, and that is the whole reason it
  can be believed.** The baseline Simple grain is driven by `time_seed`, which
  accumulates wall-clock inside the process, so two launches of the SAME build
  do not produce identical frames. The first version of this probe had no
  control and reported all seven shipped presets as "not optional" -- a test
  without a control is a claim too.

  Result on an RTX 2060, all nine shipped presets, mean absolute pixel
  difference:

  | preset | same build, twice (the floor) | film DELETED |
  |---|---|---|
  | Blue Hour | 0.009988 | 0.009992 |
  | Delco Arcade | 0.008323 | 0.008301 |
  | Delco Summer Afternoon | 0.008332 | 0.008348 |
  | Gas Station Fluorescent | 0.009856 | 0.009845 |
  | Gothic Street Night | 0.010768 | 0.010755 |
  | Heavy Rain | 0.013320 | 0.013320 |
  | Mission Goes Hot | 0.010431 | 0.010445 |
  | **PS1 Storm Night** | **0.000000** | **0.000000** |
  | **SoF PC2000** | **0.000000** | **0.000000** |

  None asks for film, none activated it, and removing the feature moves none of
  them further than the build's own nondeterminism already does. **0.28.0's
  optionality claim is now a measured property.**

  The probe checks the other two 0.28.0 claims as well, which were also
  assertions until now:

  - **Does the feature put the viewport back?** `film_manage_hdr_2d` raising
    the 2D target is the easy half; restoring it is the half worth testing.
    Measured: `use_hdr_2d` False before, **True while film runs** (so the raise
    is actually exercised and the restore is not vacuous), False again on
    disable, and False again after the LuxRoot leaves the tree with film still
    ON -- the path a level unload takes, where nothing calls anything.
  - **Does anything else reference it?** No code file outside the feature's own
    six mentions any of its eighteen symbols. Docs and tools are excluded on
    purpose: describing or exercising a feature is not a dangling reference to
    it.

  **The last two rows are the control validating itself.** They are BIT-identical
  in both columns, and the reason is in their `.tres`: `ps1_storm_night` and
  `sof_pc2000` both set `grain_strength = 0.0`. The floor is non-zero exactly
  where the legacy grain runs and exactly zero where it does not -- so the
  control is measuring grain nondeterminism and nothing else, which is what
  makes "within floor" mean something on the other seven.

### Measured
The rainbow, on the rings around a light pool, which is where it is most
visible on real geometry. Counting neighbouring pixels whose hue jumps more
than 15 degrees along one horizontal scanline through the pool:

| scanline | as shipped | film, per-channel | film, **shared** |
|---|---|---|---|
| y=300 | 149 | 171 | **4** |
| y=340 | 116 | 126 | **5** |
| y=380 | 114 | 114 | **7** |

About 97% of the hue edges gone. Note the middle column: film grain WITH
per-channel quantization is slightly WORSE than the baseline, because film
removes the luma noise that was camouflaging the hue steps. Turning film on by
itself makes the rainbow easier to see; it is the shared quantization decision
that removes it.

### Added
- `tools/film_walk_probe.py` + `.gd`: **the walk** -- item 61's closing
  condition. Film emulsion on the staged night strip as `walk_night_strip.gd`
  composes it: three Patina store shells with dressing, the fixtures GLB, 59
  site light rigs baked, 147 fixtures spawned, `Gothic Street Night`. Four
  cameras, four states. Everything measured before this ran on a blockout of
  untextured boxes, which can only show that the arithmetic is right -- which
  was already known.

  **`hdr_only` is a control and it is not optional.** The film states raise
  `use_hdr_2d`, so every three-state comparison measured film or the render
  target and could not say which. `hdr_only` is film OFF at the film states'
  target: `film_off -> hdr_only` is the target alone, `hdr_only -> film_shared`
  is the film alone. Same shape of correction the optionality probe needed, in
  the same week.

  On an RTX 2060, hue edges per lit scanline, and the two ratios the control
  exists to separate:

  | shot | film_off | hdr_only | film per-chan | film SHARED | target | quantizer |
  |---|---|---|---|---|---|---|
  | 01_strip | 32.9 | 16.3 | 15.4 | **8.7** | 2.02x | 1.87x |
  | 02_pawn_front | 33.5 | 11.4 | 9.6 | **5.7** | 2.94x | 2.00x |
  | 03_facade_raking | 28.8 | 7.0 | 8.0 | **6.6** | 4.11x | 1.06x |
  | 04_pool | 10.9 | 5.3 | 4.9 | **3.0** | 2.06x | 1.77x |

  Both changes matter and on three of four shots the render target matters
  more. Grain alone still does nothing (16.3 -> 15.4 with film fully on and
  per-channel quantization) -- two rasterisers agree on that. The shared
  quantizer is worth 1.06x to 2.00x on top of the target.

  The probe **asserts each state rendered in the configuration its column
  claims** and aborts otherwise. That check earned itself on its first run:
  `film_shared` silently rendered at `hdr_2d = false`, because the control's
  own reset cleared a raise that `_sync_film_precision` triggers on an edge and
  therefore never restored.

- `film_walk_probe.py` reports a **detection rate** -- the fraction of lit rows
  carrying a real interior autocorrelation bump -- alongside prominence.
  `argmax` always returns something, so a shot with no module reports the
  search floor and that number then gets compared across states as though it
  meant something. Prominence is only readable where detection is high.

### Measured (hardware)
**`film_manage_hdr_2d` is not tonally neutral on real hardware, and nothing
before this had looked.** `film_off` and `hdr_only` differ only in
`use_hdr_2d`, with film OFF in both. On an RTX 2060, `04_pool`: mean luminance
**0.2046 -> 0.1004**, half, with 45% of pixels differing by more than 0.15.
Not a readback encoding artifact -- applying the sRGB transfer function to
`hdr_only` does not recover `film_off` (0.114 raw, 0.086 encoded, and the
encoded mean overshoots). The `hdr_2d` decision rests on a patch-level
measurement that the raised target lands on the same values only more
precisely; end to end through the post stack that does not hold. Since
`film_manage_hdr_2d` defaults to true, **turning film on halves the brightness
of this scene before any film arithmetic runs.** Hypothesis, untested: the
float target no longer clamps at 1.0 before post, so the grade pivot, palette
zones and quantizer all see a different input range. This is the most
consequential open question in the feature.

### Fixed
- `LuxRoot._load_default_library()` scans the presets directory instead of
  carrying a hardcoded list of six while **nine** ship. `Gothic Street Night`,
  `PS1 Storm Night` and `SoF PC2000` could not be loaded by name from the
  default library -- including by the walk, which needs the first of them.

### Retracted
- **Every "repetition" figure this project printed before 2026-09-03 is void.**
  `repetition_peak` reported `max(autocorrelation[8 : w/3])` and called it
  periodicity. Autocorrelation of any low-pass signal falls monotonically from
  lag 0, so that maximum is almost always the value at lag 8 -- a smoothness
  measure wearing a periodicity label, and it ranks backwards: on a synthetic
  blob with NO periodicity it reads 0.976, and adding a real 40 px module DROPS
  it to 0.916. Replaced by the prominence of the strongest local bump above the
  autocorrelation's own decay envelope. **The tool now proves the metric on
  signals with known answers before it measures anything** and refuses to print
  the column if that fails -- because nothing caught the first metric, having
  never asked it to measure something whose answer was known.

- **The llvmpipe attribution published earlier the same day is also retracted**,
  on two counts, both corrected by the first hardware run:

  - "The render target is not the fix (47.9 -> 42.7, not even consistent in
    sign)." On an RTX 2060 it is 2.0x to 4.1x, and does MORE than the quantizer
    on three of four shots. §2b already said the 8-bit figures do not agree
    across rasterisers; `film_off` is the 8-bit column, so every ratio taken
    against it was exposed to that.
  - "Film emulsion is not a treatment for item 57 and mildly works against it
    on raking facades", claiming +12% on the raking shot. On hardware that shot
    goes the other way: -14% by prominence, 85% -> 71% by detection rate. That
    conclusion rested on prominence figures from shots with no module to
    measure.

  **A control tells you THAT two causes are separable. It does not tell you
  their sizes on hardware you did not run, and it does not make a wrong
  statistic right.**

### Item 57, re-walked on hardware
Detection rate, fraction of lit rows with a real interior bump (`p8` is the
search floor -- nothing found):

| shot | film_off | hdr_only | film per-chan | film SHARED |
|---|---|---|---|---|
| 01_strip | 31% p8 | 44% p8 | 47% p8 | 47% p8 |
| 02_pawn_front | 72% p128 | 78% p26 | 77% p27 | 79% p26 |
| 03_facade_raking | 82% p50 | 85% p94 | 71% p49 | **71% p50** |
| 04_pool | 25% p8 | 81% p53 | 8% p8 | **3% p8** |

`03_facade_raking` is the real item-57 shot -- a raking facade at 50 px pitch --
and film loosens it modestly: 85% -> 71% detection, prominence 0.1171 -> 0.1008.
`02_pawn_front` does not move. `04_pool` collapses 81% -> 3%, but what is
periodic in a light pool at pitch 53 is the concentric banding of the falloff,
not a wall module -- that is the rainbow finding appearing in a second
statistic, which is a good consistency check and a bad item-57 datum.
`01_strip` has no module in any state and cannot answer the question.

**A modest real loosening on the one genuine facade shot.** The original
hypothesis survives weakly, having been wrongly declared dead a few hours
earlier off llvmpipe.

- Walk statistics were being averaged over black sky: two shots framed 5-8% lit
  pixels and the per-row guard was `std > 1e-4`, which a black row passes on
  noise alone. Rows now need mean luminance >= 0.02, sample size is printed per
  shot, a thin sample is labelled, and the two worst cameras were tightened --
  on hardware they measure 20% and 14% lit.

## [0.28.0] - film emulsion, and the problem it was written to solve is not the one Lux had

Roadmap item 61. TDD phases 1, 3, 4 and 5-7 of `docs/film_emulsion_tdd.md`;
phase 2's reordering is folded into the shader variant rather than done as a
separate step. The feature is off in every shipped preset and the baseline
render path is unchanged.

**OPTIONAL BY CONSTRUCTION, AND HERE IS HOW TO CHECK RATHER THAN TRUST IT.**
Nothing in this release changes any existing scene. That is not a claim about
intent, it is a property with receipts:

- **The one place this was NOT true has been fixed**: a `preload` of the film
  assets in `LuxPostFX` took out the whole post stack when the grain texture
  was not imported. Optionality that has not been tested by REMOVING the thing
  is a claim, not a property -- so it now is tested that way, and the list
  below is what holds after it.
- `lux_ordered_dither.gdshader` is **byte-identical** to the shipped version
  (md5 `ab1ee8c5f476b65ef9fb07448e972b7e`, verified both before and after).
  The film variant is a SEPARATE file, so the disabled path runs code that did
  not change.
- All nine shipped presets keep `film_emulsion_enabled = false`, which is the
  script default. Nothing was edited in `presets/`.
- The film material is never bound unless all three keys open. Until then the
  ColorRect holds the same material it always did.
- `film_manage_hdr_2d` only acts while film is actually running, restores what
  it found rather than assuming a default, and restores on `_exit_tree` too.
- `grain_mode` and the chroma-coherence dial **have no vote on the baseline
  path**. An earlier draft let `grain_mode` gate the legacy grain; that was
  backed out precisely because it would let a film property change a scene that
  never asked for film. `grain_strength` still does that job and always did.
- To remove the feature entirely: delete the film shader, the grain asset and
  the film properties. Nothing else references them.

The point of the thing is that it is a look you can reach for, not a look you
are given.

**THE AUDIT REFUTED THE TDD'S PREMISE, IN LUX'S FAVOUR.** The TDD's section 1
names the problem as "digital-looking noise applied independently to RGB
channels" and "grain that creates unrelated red, green, or blue pixels." The
baseline shader does not do that. Line 113 computes ONE scalar and line 114 adds
it to all three channels, so on section 45's own metric, over 200 000 samples at
the default strength, Lux scores `chroma_noise 0.000000` against a hard bar of
`< 0.4 x luma` and a preferred bar of `< 0.2 x luma`. **Lux has never had a
rainbow-speckle problem and film emulsion has not fixed one.**

**THE REAL DEFECT IS SATURATION, AND IT IS WORST IN SHADOW.** Adding a constant
to three channels leaves HSV hue exactly alone -- the channel differences do not
move -- but it changes the max/min ratio, so saturation does. Because the shift
is absolute rather than proportional, its relative size grows as the pixel
darkens. On one orange swatch at four exposures, at the default
`grain_strength = 0.03`:

| swatch | luma | saturation swing |
|---|---|---|
| bright orange 0.72,0.41,0.19 | 0.460 | +4.2% |
| mid orange 0.36,0.20,0.10 | 0.227 | +8.3% |
| dark orange 0.14,0.08,0.04 | 0.090 | +21.7% |
| deep shadow 0.06,0.035,0.02 | 0.039 | **+53.3%** |

The density model moves value alone and leaves hue AND saturation exactly where
they were. Measured under the same grain on the same swatches, film's worst
saturation swing is **0.36%**, against the baseline's 53.3%. That is the
argument for the feature, and it is a different and better one than the TDD
makes.

**TWO MORE FINDINGS FROM THE AUDIT, BOTH INDEPENDENT OF FILM EMULSION.** Grain
is applied AFTER quantization -- line 114 runs after line 100 -- so it undoes
the level snapping the final clamp's own comment says exists to be preserved;
that is the ordering section 2 forbids. And the grain hash multiplies `uv` by
`time_seed`, which is seconds of playtime: it is a FREQUENCY scale, not a
reseed, so grain frequency climbs continuously for the first ~16.7 minutes of
play (to 1000x, a `sin()` argument near 91 000, where fp32 evaluation is
hardware-dependent) and then snaps back. Both are fixed by construction on the
film path and both remain on the baseline path.

**SECTION 20 CANNOT BE CLAIMED ON THE SHIPPED CONFIGURATION, AND THAT IS A
DECISION FOR A HUMAN.** `project.godot` does not set `rendering/viewport/hdr_2d`,
so the viewport render target is 8-bit and scene color is already RGB8 before
any canvas_item post pass samples it. Section 7 (film inside the existing pass)
and section 20 (no RGB8 before film math) cannot both hold while that is true.
The only resolution that satisfies both costs the 2D target RGBA8 -> RGBA16F,
about +7.5 MiB at 1080p, against section 38's stated 0.25 MiB budget -- a budget
written for the grain asset, which does not anticipate a format change to a
buffer that already exists. **MEASURED ON TWO RASTERISERS, not argued**: on Godot 4.7.stable.official the
target is 8-bit integer as shipped (RGBA8 on llvmpipe, RGB8 on an RTX 2060) and
floating point with `rendering/viewport/hdr_2d = true` (RGBAF and RGBH
respectively), so the setting name is right for 4.7 and the option is one line.

And the 8-bit cost is not theoretical. The baseline's Simple grain is
chroma-free BY CONSTRUCTION, so any chroma it measures is the floor the output
format imposes -- rendered, that floor is **0.001811 at 8 bits and 0.000009 at
16**, two hundred times smaller. The entire chroma signal measured at 8-bit
output is per-channel rounding. Section 45's ratio on the neutral patch follows
it: **0.3340 at 8 bits, 0.1901 in float**, so the TDD's preferred bar of 0.20 is
only reachable in float. At 8 bits the default grain spans **three distinct
codes** -- close to sub-LSB, most of it rounded away before it reaches the
display.

**AND AT 8 BITS THE TEST IS NOT REPRODUCIBLE ACROSS HARDWARE, WHICH IS THE REAL
ARGUMENT.** Same build, same probe, same patches, llvmpipe against an RTX 2060:
with `hdr_2d` off the two disagree by up to **70%** (the baseline chroma floor
is 0.001359 against 0.000412 on orange); with it on they agree to **0.20% worst
case** -- and that is a 32-bit float target against a 16-bit one, not two runs
of the same thing. A test whose result moves 70% with the graphics card is
measuring the card. It also settles a question nobody had asked: 16-bit float
has the headroom, so nothing here argues for RGBAF.

**TWO DELIBERATE DIVERGENCES FROM THE TDD, BOTH MEASURED.**

- `grain_mode` defaults to **Simple**, not Off. Section 12 writes `= 0` (Off)
  and, three lines later, "existing presets must remain unchanged"; section 34
  says they "continue using Simple grain unless explicitly migrated." A `.tres`
  written before the property existed loads with the script default, so Off
  would silently strip grain from all nine shipped presets. The enum ORDER is
  the TDD's; only the default differs.
- `film_chroma_ratio` defaults to **0.10**, not 0.12. Section 31 gives
  "approximately 12%"; measured on the shipped grain asset, 0.12 scores 0.2251
  on section 45's metric -- inside the hard bar, outside the preferred one.
  0.10 scores 0.1876 and clears both. An explicit acceptance threshold outranks
  an approximate default. The range still reaches 0.25.

**SECTION 45'S METRIC IS NOT A CHROMA MEASUREMENT ON A COLOURED PATCH, AND
THAT IS WORTH KNOWING BEFORE SOMEBODY "FIXES" IT.** With the chroma term
switched off entirely, the metric still reads **0.6023 on orange and 0.9894 on
red** -- because `std(R-G)` on a coloured patch is driven by the shared
transmission multiplying a non-zero `R - G`, which is the one part of the design
that is provably hue- and saturation-preserving. The chroma term contributes
0.02 to 0.03 of those figures. This is why section 45 specifies a CONSTANT
NEUTRAL PATCH; on that patch, with no chroma term, the metric reads exactly
zero. Both probes now run the control on every invocation so the comparison is
always in front of whoever reads the numbers.

**SECTION 47 IS INTERNALLY INCONSISTENT AND THE RESOLUTION IS RECORDED.** It
requires "Dark Grain RMS > Midtone > Highlight". Absolute RMS of a
multiplicative model is value x mask and necessarily RISES with brightness --
that requirement is only satisfiable by an additive model, which section 27
forbids. Relative RMS, grain as a fraction of the signal it sits on, falls
monotonically (0.004135 at 5% luminance to 0.001213 at 100%), and that is the
reading this implementation meets.

### Added
- `LuxRoot.film_manage_hdr_2d` (default true): raises the viewport to a
  floating-point 2D render target while film emulsion is actually running, and
  puts back whatever was there when it stops. **The hdr_2d decision, taken.**
  Not a project setting, because Lux is an addon and cannot edit the
  `project.godot` of every game that installs it; and scoped to film, so with
  film off in every shipped preset it changes nothing at all.

  Three things were measured before it was wired, and the second is the one it
  depends on. (1) `use_hdr_2d` flips at runtime in both directions, no reload.
  (2) **A 3D scene resolved into the raised target lands on the SAME values,
  only more precisely** -- 0.25098/0.50196/0.74902 at 8 bits against
  0.24915/0.50098/0.74951 -- and NOT on their linearised equivalents
  (0.05088/0.21404/0.52252). The post stack keys its contrast pivot, palette
  zones and quantization levels off 0.5; had the target gone linear, every one
  of those thresholds would have moved and all nine presets would need
  retuning. They do not move. (3) It costs +0.043 ms on the post pass at 1080p
  and about 7.5 MiB, and the film pass itself gets ~10% cheaper in exchange.
- `LuxPreset.dither_chroma_coherence` and `dither_luma_scale`, **film path
  only**: THE RAINBOW IS THE DITHER, NOT THE GRAIN, and this is the switch that
  removes it. Ordered dithering quantizes R, G and B independently, so on a
  coloured surface the three channels cross their level boundaries at different
  screen positions -- a channel that dithers alone is pure chroma noise, and
  that is the "unrelated red, green, or blue pixels" of TDD section 1.
  Measured on a flat orange patch, where nothing else can vary: per-channel
  quantization scores **1.500** on section 45's own metric and moves saturation
  by **0.0797**; the Simple grain it was blamed on scores **0.0000**.

  The fix is the density model's own idea one stage later -- make ONE decision
  and share it. Quantize luminance, scale the colour by the ratio, and hue and
  saturation come through untouched. `dither_luma_scale` compensates for a
  shared decision being coarser: on a coloured gradient, per-channel at 24
  levels gives 36 luminance steps, coherent gives 13 at 1x and **38 at 3x**,
  with a finer maximum step (0.0139 against 0.0417) and saturation variation of
  **exactly zero**. At the default 3x it is not a trade.

  Measured on the rendered sample scene over 2183 flat coloured blocks,
  saturation variation: as shipped **0.04178**, with the float target 0.03906,
  with film grain but per-channel dither 0.03402, with shared quantization
  **0.01509** -- 64% lower. The grain accounts for very little of it; the
  quantization accounts for nearly all of it.
- `tools/film_demo.py`: launches the demo, resolving Godot the way every other
  tool here does (--godot, $LOT_GODOT, $DC_GODOT, the usual paths, PATH) and
  running the import pass on a project that has never had one. The documented
  `& $env:LOT_GODOT ...` command line fails on a shell where that variable is
  not set, with a PowerShell syntax error that names the wrong problem.
- `tools/film_demo.gd`: film emulsion running in the Lux sample scene, toggled
  at runtime. `F` film on/off, `G` grain mode, `[` `]` strength, `;` `'`
  chroma, `V` hdr_2d management, `P` screenshot. The sample scene's own preset
  keys still work and film is re-applied on top of whatever they select, so the
  response can be seen on five different looks rather than one. It only ever
  writes a `make_override` copy, so a demo can never be the reason a shipped
  `.tres` changed. `film_demo/auto_capture` makes it self-testing: three states
  captured in one run, with every CanvasLayer hidden first, because a HUD that
  says which state it is in differs between the two frames by up to 0.84 -- two
  orders of magnitude more than the grain being compared.
- `shaders/post/lux_ordered_dither_film.gdshader`: the film variant. A separate
  shader rather than a branch, because section 36 makes the disabled cost an
  acceptance test and a branch cannot promise zero texture reads when the
  sampler is still bound. Film runs BEFORE palette zones and dither (section
  16), the grade's trailing clamp is deferred past it so film sees whatever
  precision the target carries, and the baseline's Simple grain is ABSENT
  rather than disabled -- section 11 by construction.
- `resources/film/grain_balanced.png`: 128x128 RGBA8 packed grain, 64 KiB of
  VRAM. R fine neutral, G coarse neutral, B red-green, A blue-yellow, each
  band-limited in the frequency domain so the tile is periodic BY CONSTRUCTION
  rather than blurred and patched. Measured: all four channels sigma 0.3326,
  every cross-correlation within 0.015 of zero, 0.261% of texels clipped by the
  encoding, wrap step 0.985 of the interior step.
- `tools/make_film_grain.py`: generates that asset and prints the statistics the
  shader's behaviour follows from. Offline only -- section 22 and section 39
  both forbid generating grain at runtime.
- `LuxPreset`: `film_emulsion_enabled`, `grain_mode`, `film_grain_strength`,
  `film_chroma_ratio`, `film_grain_fps`, `film_grain_scale`.
- `LuxQualityProfile.allow_film_emulsion` -- allowed on High and Medium,
  refused on Low and Compatibility.
- `LuxRoot.film_emulsion_enabled` (Optional Rendering Features, placed LAST in
  the export list so no existing group is split) and
  `set_film_emulsion_enabled` / `is_film_emulsion_active`. Toggling re-applies
  the post stack and nothing else: no scene, WorldEnvironment, material,
  lighting or gameplay change (section 14).
- `LuxRuntimeAPI.film_emulsion` and `is_film_emulsion_active`. A settings screen
  wants both, so a toggle that legitimately does nothing on this tier can say
  so instead of looking broken.
- `LuxPostFX`: the film material, the three-key decision, and the film-frame
  counter, which advances at `film_grain_fps` rather than once per rendered
  frame (section 24) and is not touched at all when film is inactive.
- `docs/film_emulsion_phase1_audit.md`: the phase 1 exit requirement, with every
  number above and what it does not establish.
- `addons/lux/docs/film_emulsion_authoring.md`: WHERE to use it, which is the
  question the TDD does not answer. The effect is already area-selective twice
  over and neither selectivity is a mask: by exposure (a **30:1 spread across a
  single frame**, 0.320 relative response in the darkest band against 0.011 in
  the brightest) and by colour (the coherent quantizer does nothing where R, G
  and B are equal). So it concentrates itself in dark coloured regions, which
  in a Lux scene means interiors, night, and coloured practicals -- and buys
  almost nothing on a daylight look, where the shipped Delco preset has zero
  pixels below 0.15 luminance.

  Zone switching needs no new code: film is a preset property, so a GOOL
  indoor/outdoor event calling `LuxRuntimeAPI.preset()` already carries it, and
  `_lerp_preset` ramps the parameters rather than popping them. The page's best
  finding is that the feature SELF-MODULATES -- because the grain is weighted by
  exposure, `fixtures_powered(false)` makes it louder with nothing scripted, so
  a power cut intensifies the photographic response for free.

  It also records one unmeasured gotcha: raising `hdr_2d` rebuilds the render
  target, and whether that hitches has NOT been measured. Prefer raising it once
  per level over toggling it at every doorway until it has been.
- `tools/film_math_probe.py`: runs sections 43, 45, 46 and 47 against the real
  shipped grain asset. It greps every constant it models out of the `.gdshader`
  and fails if one is missing, so the model and the shader cannot drift apart
  silently.
- `tools/film_render_probe.py` + `.gd`: builds a minimal project around the two
  post shaders and the grain asset, compiles them in Godot, and renders known
  patches through both at each `hdr_2d` setting. `--perf` adds section 41's
  budget and section 50's resolution matrix, timed with the engine's own
  per-viewport GPU counter rather than a wall clock -- a CPU-side clock around
  a draw measures submission, not execution. It refuses to grade a software
  adapter: on llvmpipe the film pass "costs" 12.8 ms and would print four
  alarming failures, which is how a guardrail teaches people to ignore it. This is the tool that answered
  the section 20 question and exposed the 8-bit noise floor; it also runs the
  chroma-off control every time, so section 45's numbers cannot be misread
  without the refutation on the same screen.

### Changed
- `docs/film_emulsion_phase1_audit.md` carries a **correction in place**, not a
  quiet patch. Its first version concluded "Lux has never had a rainbow-speckle
  problem"; the measurement behind that was right and the conclusion was not,
  because it generalised from the grain to the whole pipeline without measuring
  the other half. The retraction stands at the head of the section that made
  the claim, and the new section 3d is the one that should have been there.
- `LuxPostFX.set_camera_planes` and `set_hdr_output` now write to BOTH
  materials. They are called outside `apply()`, so setting only the live one
  leaves the other stale and the staleness surfaces as a one-frame pop the
  moment film is toggled.
- `LuxRoot._lerp_preset` carries the six new preset fields. That function is
  exhaustive by contract; a new field not listed there is silently reverted to
  its script default for the whole of a blend.

### Verification
**The film shader compiles and renders.** `tools/film_render_probe.py` builds a
minimal project around the two shaders and the grain asset, imports it, and
draws known patches through both -- twice, once at each `hdr_2d` setting. The
compile receipt is the identity case rather than a clean log: with film off and
every other stage neutral the pass returns its input exactly (`luma_noise
0.000000`, one distinct code, on two patches at both precisions). A shader that
failed to compile is replaced by a fallback, and the fallback does not reproduce
its input.

**The model and the engine agree.** `film_math_probe.py` evaluates the same math
in numpy; against the rendered result at `hdr_2d = true`:

| patch | strength | model luma/chroma | engine luma/chroma | delta |
|---|---|---|---|---|
| neutral | 0.10 | 0.005112 / 0.000959 | 0.005064 / 0.000963 | -0.9% / +0.4% |
| orange | 0.10 | 0.004719 / 0.002968 | 0.004719 / 0.002970 | -0.0% / +0.1% |
| orange | 0.025 | 0.001180 / 0.000742 | 0.001180 / 0.000750 | +0.0% / +1.1% |

The one larger gap is chroma on the neutral patch at 0.025 (+15.6%), where the
signal is below RGBH's own precision at that value. Everywhere the signal
exceeds the storage, the two agree to about 1%.

**The result the feature exists for, rendered.** Saturation span under grain,
default strengths, `hdr_2d = true`:

| patch | film | baseline Simple grain |
|---|---|---|
| orange | **0.15%** | 4.16% |
| deep shadow | **0.33%** | **50.02%** |

`tools/film_math_probe.py`: **12 checks, 0 failed** -- including both halves of
the rainbow claim, which is what stops a fix that does nothing from passing:
that per-channel quantization DOES move saturation on flat colour (worst
0.027265), and that a shared decision moves it by exactly nothing (3.33e-16).
`film_render_probe.py` measures the same on hardware -- per-channel spreads
saturation by up to **0.082397** on a flat orange patch, shared by **exactly
0.000000**, at both precisions. The math probe's drift guard now covers the
quantization block too, so the model and the shader cannot part company there.
All changed GDScript files and
both probe scripts pass `tools/gdcheck.py`. Godot accepted the hand-authored
`.import` unchanged and resolved it to exactly the `.ctex` hash derived here,
adding only the engine-assigned `uid`; `fix_alpha_border=false` and
`detect_3d/compress_to=0` both survived the import.

**AND IT HAS BEEN SEEN RUNNING, IN A REAL LUX SCENE.** `tools/film_demo.gd`
against the sample scene on the Blue Hour preset, 1280x720, three states in one
run so nothing can drift between them:

| change | mean absolute difference |
|---|---|
| render target alone (8-bit -> float, film off) | 0.014127 |
| grain model alone (float, film off -> on) | 0.008058 |
| what a player actually toggles | 0.011991 |

**The precision change moves the image more than the grain model does**, which
is worth knowing before anyone attributes the whole before/after to the grain.
And the grain-model change is exposure-weighted on real geometry exactly as it
is on synthetic patches -- relative difference 0.320 in the darkest band,
falling monotonically through 0.104, 0.053, 0.030, 0.018 to 0.011 in the
brightest. That is section 29 confirmed somewhere other than a test patch.

**RUN ON REAL HARDWARE.** Everything above was first rendered on llvmpipe and
then re-run on an NVIDIA GeForce RTX 2060. The shader compiles on both; every
`hdr_2d = true` figure agrees to within 0.20%; the 8-bit figures do not, and
that disagreement is reported above as a finding rather than smoothed over.

**ONE ERROR IN THIS WORK, RECORDED RATHER THAN PATCHED.** The first version of
these notes reported llvmpipe's float target as RGBH. It is RGBAF. The driver
carried a hand-written `{int: name}` table with 11 as RGBH, when 11 is RGBAF and
14 is RGBH, and the mislabel survived into three documents before the RTX 2060
returned an id the table did not contain at all. The probe now names formats
from `Image.FORMAT_*` inside Godot and the Python side prints what it is told --
there is no table left to be wrong. The conclusion was unaffected; the reported
fact was not.

**SECTION 41 IS MEASURED AND MET, on an RTX 2060 across section 50's whole
resolution matrix.** GPU time from the engine's own per-viewport timer, 600
timed frames per configuration after 120 discarded, three configurations per
cell (no post pass / baseline shader / film shader) so the reported figure is
the film shader's ADDED cost rather than the pass's total:

| resolution | film adds (hdr_2d on) | % of frame at 60 fps | at 120 fps |
|---|---|---|---|
| 1280x720 | 0.0240 ms | 0.14% | 0.29% |
| 1920x1080 | 0.0510 ms | 0.31% | 0.61% |
| 2560x1440 | 0.0920 ms | 0.55% | 1.10% |
| 3840x2160 | 0.1340 ms | 0.80% | 1.61% |

Against section 41's 2% allowance, every cell passes. **The worst cell is 4K at
120 fps with `hdr_2d` off: 1.79%, which is 12% of the budget to spare** -- and
this is a FLOOR, measured on an empty scene where nothing competes for
bandwidth. That cell should be read as unproven rather than passed until a real
level is measured. The probe now grades the worst cell in the matrix rather than
the likeliest one, for exactly this reason.

**THE hdr_2d DECISION IS NOW PRICED IN TIME AS WELL AS MEMORY**, which was the
last thing missing from it. On the post pass: +0.0430 ms at 1080p (+33.6% of
the pass, but only **0.26% of a 60 fps frame**), rising to +0.1110 ms at 4K.
Note this is the post pass alone on an empty scene; `hdr_2d` also changes how
the 3D scene resolves into the 2D target, which is not measured here.

**AND FILM IS CHEAPER WITH `hdr_2d` ON -- at all four resolutions, 4 for 4.**
0.0580 -> 0.0510 ms at 1080p, 0.1490 -> 0.1340 at 4K, about 10% consistently.
The likely reading is that the float target makes the pass more
bandwidth-limited, so the film shader's extra arithmetic hides behind memory
traffic that the 8-bit pass does not have; that is a hypothesis from four
consistent measurements, not a profile. Either way `hdr_2d` partially pays for
itself on the pass film runs in.

**STILL NOT VERIFIED.** Two rasterisers is not every rasteriser, and one
RTX 2060 is not section 51's hardware sweep -- no integrated GPU, no AMD, no
Intel, no handheld, and a 2060 is not anybody's minimum spec. Section 50 asks
for VRAM, RAM, bandwidth, power and shader stalls as well as frame time, and
only frame time is measured. Nothing here measures a real level: sections 50 and 51's performance and hardware matrix --
frame time, VRAM, bandwidth, shader stalls, percentiles -- is entirely
unthe film cost above is a floor taken on an empty
scene. Nothing has been rendered on real geometry, so the walk item 61 names as its closing condition has not happened,
and neither has item 57's texture-rhythm re-walk.

## [0.27.0] - the glow was bound everywhere except where levels are built

Roadmap item 94. `LuxEmissiveBinder` has worked correctly since 0.14 and
every harness Lux ships calls it -- `tools/visual_pass.gd`,
`tools/walk_harness.gd`, both `walk/headless/` night-strip scripts, and the
dock's "Bind Emissives" button. Level Factory's two drivers,
`run_lux_apply.gd` and `run_fixture_gate.gd`, do not. So a level walked in
Lux's own harness has its lit faces bound to `set_fixtures_powered`, and a
level BUILT BY THE PIPELINE does not: `_emissives` is empty, the power cut
takes the rig lights, and every lens, diffuser and sign face keeps glowing.

The symptom was already written down, from the other end, in a Level Factory
flag's help text -- `--no-fixture-lights` explains itself by saying fixtures
are lit by the glow pass "whether or not any light is cast, so the eye cannot
separate a working fixture from a dead one." That is this, described by
somebody who did not have the binder in mind.

**WHY THE FIX IS HERE AND NOT IN THE DRIVER.** Adding a bind call to
`run_lux_apply.gd` would bind at apply time and then `PackedScene.pack` the
result, and neither half of a bind survives packing: the registration is
runtime state on a LuxRoot instance, and the base energy is `set_meta` on a
material owned by an imported GLB -- an external resource the packed scene
references rather than owns. The driver would report a success the shipped
scene does not contain. Binding has to happen at load, every load, which
makes it the level node's job.

**AND THE BIND ITSELF WAS AIMING AT NOTHING IN A HEADLESS RUN.**
`bind_fixture_emissives(null)` fell back to `get_tree().current_scene`, then
to `self`. In a `godot --headless -s driver.gd` run there is no current scene
-- nothing was ever loaded as one -- so the fallback landed on `self`, a
LuxRoot with no mesh children: zero materials, `ok: true`, no warning. Both
Level Factory drivers run exactly that way, so wiring the call without this
fix would have changed nothing and reported that it had.

### Added
- `LuxRoot.bind_emissives_on_ready` (default `true`, Startup group): binds
  Zoo's fixture lit-face materials when the node is ready, so
  `set_fixtures_powered` drives the glow as well as the lamps. Set it false
  only for a project managing emissives itself. The bind runs AFTER
  `_build_modules`, which replaces `_lighting` and therefore empties
  `_emissives` -- binding before it would register into the module about to
  be discarded, and an editor script reload re-runs both.
- `bind_fixture_emissives` returns `search_root`, the name of the node it
  actually walked, so a count of zero can be told apart from a search of
  nothing.

### Fixed
- `LuxRoot.bind_fixture_emissives` resolves its search root as `owner`, then
  the parent, then `get_tree().current_scene`, then `self`. Every one of the
  first three actually contains the fixtures in the contexts Lux is driven
  from; the old order reached `self` first in every headless run.

### Verification
Both changed scripts pass `tools/gdcheck.py` (gdparse plus the three traps).
NOT yet exercised in a Godot run: no engine was available to the session that
wrote this, so the bind count on a real fixtures GLB is unmeasured. The
Level Factory 0.52.0 gate is the instrument that measures it.

## [0.26.0] - the fixture gate stops measuring bracket-to-bulb

Roadmap item 71, which was filed as a Lux placement bug and is not one. The
lamps were always where they belong.

`check_fixture_colocation` measured from each `LuxEmit_*` marker to the
nearest `Light3D`, and back from each spawned `Light3D` to the nearest marker,
against a flat 0.10 m tolerance. But a spawned fluorescent is not supposed to
sit on its marker. `lux_light_loader.gd` gives that branch alone
`mount_height = -0.25`, under a comment from the 2026-08-23 walk: a lamp
sitting on the ceiling plane spends half its sphere grazing the ceiling, which
streaks at glancing angles and scorches a ring around the fixture. Real tubes
hang. `LuxFixtureSpawner` puts the rig ROOT on the marker; the rig then hangs
its bulb 0.25 m below. The check measured that drop and called it a floating
light.

Measured on two Level Factory cold runs, which is how it surfaced -- 37
markers and 20 flagged on one, 19 and 12 on the other, **worst 0.25 m on
both**, across two themes, two archetypes and two Zoo kits. A distance that
does not move when everything else does is a constant, not a defect. Pendant,
streetlight and wall_pack all set `mount_height = 0.0` and never tripped it.

The drop is not incidental: **0.20.0 shipped it deliberately**, from the same
2026-08-23 walk, and said so -- "Real tubes hang; ours do now." So the gate has
been wrong since 0.20.0, and removing the offset to satisfy it would have
re-introduced the streaking that walk was run to find.

It had been wrong for as long as fluorescents have hung, and nothing saw it:
Level Factory was discounting the blockers as belonging to an eliminated
candidate (LF 0.50.0 fixed that on 2026-08-27). A silent gate and a lying
aggregator cancel out and the run reports clean.

### Changed
- `runtime/lux_validator.gd`: `check_fixture_colocation` compares markers to
  RIG ROOTS. A light's anchor is its rig root when it was spawned into the
  `LuxFixtureLights` container, and the light itself otherwise -- so
  manifest-baked lamps still satisfy a marker, keeping "or Bake Lights for
  manifest scenes" a true answer to the dark-hardware finding. The floating
  half measures each spawned rig root rather than its bulbs. Where a bulb
  sits inside its own rig is this repo's business, tuned per type; the gate
  no longer has an opinion about it.

  A per-type tolerance would also have worked and is worse: it needs updating
  every time a mount height is tuned, which is the coupling that produced
  this.

### Added
- `tools/colocation_selftest.gd` -- `godot --headless --path . -s
  res://tools/colocation_selftest.gd`. Four cases, and the first one is the
  point: **case 0 asserts the 0.25 m drop is really there** before anything
  else runs, because a fix that makes the check stop complaining is
  indistinguishable from a fix that makes it stop working. Then a correctly
  hung fixture passes, a rig moved 5 m fails with BOTH findings and recovers
  when moved back, an unspawned scene reports dark hardware, and a
  manifest-baked lamp on a marker satisfies it.

## [0.25.0] - the four lights that hang on the envelope learn what a wall is

Roadmap 60's first tier, sized by its second sighting (2026-08-24):
arena_a03's interior ceiling carried the wash of the sign OUTSIDE its own
south wall. An area rig is mounted ON the building envelope at energy 3.0,
so half its range sphere is always inside the building -- and collision
never blocks light in GL Compatibility; a shadow map is the only occlusion
that exists. Shadowing everything is unaffordable (~128 interior fixtures,
each a cube map); shadowing THIS class is nearly free: lot_demo_001 ships
four area rigs, total. Doorway spill survives -- a shadow map blocks walls,
not openings.

### Changed
- The loader's `window`/`sign` arm sets `shadows_enabled = true` on its
  rig -- the machinery already existed end to end (`LuxLightRig` carried
  the field, `LuxAreaLightRig` applies it on both the AreaLight3D path and
  the Compatibility omni fallback); nothing had ever turned it on. These
  are the only shadowed lights in the package; interiors stay unshadowed
  pending item 60's quality-profile decision.

## [0.24.0] - a quarter metre, priced by the census

Census #7 (2026-08-24) ran with margin forensics: the census now names each
offending mesh's claimants and exactly how much range each would have to
lose. Verdict on the six meshes still over 8: building b0's three slab
tiles are over by fluorescents that bind with 0.17 m to spare -- a range
problem, payable; b1's two tiles (slimmest margins 0.44 and 0.69) and b2's
52 m parapet (1.59, on claimants whose formula has no 1.59 to give without
un-lighting their own floors) are geometry problems, and no honest range
number clears them. This release pays the payable one and leaves the
geometry bill where it belongs (roadmap 54: Deli Counter parapet tiling).

### Changed
- Fluorescent range: `clampf(drop + 0.75, 4.0, 7.5)` (was `drop + 1.0`).
  Sheds every 0.17 m claimant while the floor pool stays
  sqrt(1.5*drop + 0.5625) m -- arena 3.0 m against the 2.83 m a 4 m grid
  diagonal needs, office 2.4 m against 2.0 m rows.

## [0.23.0] - the fluorescent pays its range bill

Census #6 (2026-08-24, lot_demo_001) was the first with `drop` alive end to
end -- the range histogram finally spread (min 3.6, median 4.9, max 7.1,
zero twins) -- and the roadmap-54 gate still failed by a hair: 14 meshes at
9-10 claimants for 8 slots, every one a horizontal plate (slabs, floor
panels, a roof panel). Plates are where the lamps hang: every lamp within
range claims a slot on the tile above it, the next room's lamps included,
because the engine binds a range SPHERE against an AABB and walls are not
part of the question. With the geometry already budget-sized (0.49.0's
tiling) and the population already deduplicated (0.17.0), range is the one
knob left that pays this bill without rebuilding shells.

### Changed
- Fluorescent range: `clampf(drop + 1.0, 4.0, 7.5)`, fallback 4.0 (was
  `drop + 1.5`, 4.5..8.0, fallback 4.5). The floor pool under each lamp is
  sqrt(2*drop + 1) m -- arena 3.5 m, office 2.7 m, against Deli Counter's
  4.0 m row spacing -- so floors stay lit while each sphere stops claiming
  per-mesh slots on tiles it could not visibly brighten anyway
  (attenuation 2.0 is near zero at the rim).

## [0.22.0] - the payload was in a box named "extras" all along

The probe that settled it (2026-08-24, lot_demo_001's walk preview): 145
markers, 145 with metadata, 0 with a `lux_drop` key -- every marker carries
exactly ONE metadata entry, named `extras`, holding the whole placement
dictionary. Godot imports glTF node extras as that single dictionary, not
as flattened keys, so `get_meta("lux_type")` has returned null since v0.30
and the name-parse fallback silently carried the entire marker contract --
the type is also in the node name, so nothing ever noticed. Sun Link's
lesson again: the instrument that looks at the RUNNING tree is the only one
that can see this class of defect.

### Fixed
- `LuxFixtureSpawner.marker_payload`: reads a field out of the imported
  `extras` dictionary first, tolerates a flat metadata key (importers
  change), falls back last. `marker_type` and the spawn path's `drop` now
  go through it -- so for the first time since the marker contract was
  born, the payload Zoo writes is the payload Lux reads: type exact (no
  more trusting Blender's dedup-suffix name mangling), `lux_drop` live,
  and `lux_anchor_id` / `lux_slot` / `lux_reacts_to_alarm` finally
  reachable for whatever needs them next.

## [0.21.0] - the marker path finally tells the tuning table what it knows

0.19.0 taught the tuning table to derive range from an anchor's `drop`, and
the census then measured every fluorescent at the fallback anyway: the
manifest chain carried `drop` end to end, but the pipeline ships its
interior lights through `LuxFixtureSpawner` -- the MARKER path -- which
handed `rig_for_anchor` only `{type, id}`. Right rule, wrong door.

### Changed
- `LuxFixtureSpawner.spawn` passes `drop` from the marker's `lux_drop`
  metadata (Zoo >= 0.50 stamps it) into `rig_for_anchor`, so the drop rule
  fires on the path lights actually ship through. Markers without the key
  read 0.0 and keep the fallback -- older fixture GLBs light exactly as
  before.

## [0.20.0] - the 90s palette: bare bulbs below grade, and every third pole buzzes

Roadmap 57's first palette entries. One fixture type per world is how a
level reads as generated; 90s Philadelphia is sodium amber outside, tube
white in the front of house, and a bare filament over anything worth
stealing.

### Added
- `pendant` in the loader's tuning table (deli_counter >= 0.98 derives the
  type for basements and objective rooms): the fluorescent rig's machinery
  wearing an incandescent costume -- `LuxColorTemp.INCANDESCENT`, energy
  1.3, a TIGHTER drop clamp (`drop + 1.0`, 3.5..6.5 -- a pool, not a wash),
  and a slow shallow filament waver (0.06 @ 2.5) where a tube stutters.
- Buzzing poles: every third streetlight -- keyed on the anchor's own id,
  deterministic across builds and seeds -- gets the dying ballast
  (flicker 0.22 @ 7.0). Position would drift with layout; ids are the
  stable name for a place.

- `LuxLightRig.attenuation` (default 1.0 = engine default = byte-identical
  for every existing rig): the distance-falloff exponent, applied by the
  fluorescent and streetlight rigs. The near-linear default cuts to zero AT
  the range and rims every pool with a visible circle (walked 2026-08-23 on
  the zoo corridor ceiling); the loader now tunes fluorescents and pendants
  to 2.0 -- inverse-square, the pool fades out inside the range and the
  edge disappears.
- Fluorescent tubes hang 0.25 m below their anchor (`mount_height = -0.25`
  in the loader): a lamp sitting ON the ceiling plane spends half its
  sphere grazing the ceiling -- streaks at glancing angles and a scorched
  ring around the fixture, same walk. Real tubes hang; ours do now.
- `docs/film_emulsion_tdd.md`: the Optional Color-Preserving Film Emulsion
  TDD (roadmap 61) -- committed beside the code it specifies.

### Fixed
- `LuxStreetlightRig` never PROCESSED flicker: the rig resource always
  carried the fields and this rig ignored them, so a buzzing streetlight
  tuned anywhere was silently steady. It now runs the fluorescent rig's
  two-tone noise over its spotlights when tuned, and `set_process` accounts
  for flicker as well as cones.

## [0.19.0] - the range follows the room down to its floor

0.18.0's flat 4.5 fixed the budget grid and broke tall rooms the same hour:
the walk found the arena's ~5.7 m hall with a lit ceiling over a PITCH-BLACK
floor, because attenuation reaches hard zero at the range and no energy
value lights a floor the range does not reach. A flat number cannot serve a
3.3 m office and a 5.7 m hall; the room's height can, and Deli Counter is
the layer that knows it.

### Changed
- `LuxLightLoader`: a fluorescent anchor carrying `drop` (deli_counter >=
  0.97 stamps the lamp's distance to its own room's floor) gets
  `light_range = clamp(drop + 1.5, 4.5, 8.0)` -- a floor pool about
  sqrt(3 x drop) metres wide in every room, with the clamp keeping low
  rooms at the 0.18.0 trim and stopping tall halls from re-claiming the
  whole per-mesh budget. Anchors without a drop keep the flat 4.5.

## [0.18.0] - a light's range is a budget claim, and 8 metres claimed through walls

The walk that ruled on this (2026-08-23, lot_demo_001 at the engine's own
`max_lights_per_object=8`): hard-edged brightness quads gridding every
ceiling, floor and roof. The engine binds a light to every MESH whose AABB
its range touches -- through walls, occlusion never enters it -- and renders
at most 8 of them per mesh. With fluorescents at range 8.0, the worst ceiling
tile had 23 claimants for 8 slots, adjacent tiles bound DIFFERENT winning
sets, and the set difference drew the tile boundaries. Item 54 split the
room-spanning meshes; this trims the claims so the budget fits.

### Changed
- `LuxLightLoader` tuning table: fluorescent `light_range` 8.0 -> 4.5 (a
  fixture lights its own room and stops claiming slots two rooms away),
  wall_pack 7.0 -> 5.5 (stops stacking with streetlights on path tiles).
  Energy is deliberately untouched: if interiors read too dark between
  fixtures, raise `energy` -- range is a budget claim first and a look
  second, and the comment at the value now says so.

## [0.17.0] - every fixture light existed twice, and the census caught the twins

Measured 2026-08-23 by `tools/mesh_light_census.py` (factory root) on
lot_demo_001's walk preview: 272 positional lights visible against an
authored 136 -- exactly x2 -- and ALL 272 within 10 cm of another light. The
pairs named the mechanism: `Spawned_fluorescent_NNN/Fluoro_0` beside
`Spawned_fluorescent_NNN/@OmniLight3D@N`. Sun Link's disease, one rig down:
the bake SAVES each rig's built lamps into the scene (they are given an
owner, so they serialize), and a rig loaded from that scene arrives with its
lamps already as children while its fresh `_lights` array is empty -- so
`_rebuild()` freed nothing, built a second set beside the first, and the
name collision left the runtime copy @-renamed and unaddressable. Every
per-mesh light count in the level was doubled, and the package's
`max_renderable_lights=136` sat at HALF the real population (roadmap 56).

### Fixed
- `LuxFluorescentRig._rebuild`, `LuxStreetlightRig._rebuild`,
  `LuxAreaLightRig._build`: sweep every built CHILD by type (lamps; the
  streetlight's cones; the area rig's panel light and surface quad) before
  building, instead of trusting the instance's own bookkeeping arrays --
  which cannot know about children a scene file delivered. Immediate
  `free()`, not `queue_free()`: a deferred corpse holds its name for the
  rest of the frame, so the replacement would be renamed `@OmniLight3D@N`
  (item 55 documents what @-names cost downstream). Editor rebuilds get the
  same idempotence for free.

## [0.16.0] - Sun Link drives the level's sun instead of adding one beside it

### Fixed
- `lux_root.gd` `_build_modules`: when `sun_light` resolves, it is handed to
  `LuxLighting.sun` before `ensure_sun()`, which already early-returns on a
  valid sun. Without it `ensure_sun()` manufactured a `LuxSun` regardless of
  what `_resolve_sun_link()` found, leaving two DirectionalLight3D in any
  scene that ships its own -- measured on 4.7.stable at 1 degree apart in
  elevation, which cross-hatches two shadow maps into acne along every
  grazing surface rather than reading as a second sun. Measured: 2 visible
  DirectionalLight3D against 1, and the adopted sun carrying the preset's
  energy (1.500) instead of the level sun's untouched 1.000.

  The scene side of this is `tools/lux_inject.py` in the factory root: a
  Node-typed export is only resolved when the `[node]` header declares it in
  `node_paths`, so the NodePath it wrote was dropped on type with no error
  and `sun_light` was null at `_ready`. Both halves are required; this one
  alone changes nothing.

### Changed
- `_build_modules` clears the direct children it owns before rebuilding, so
  running it N times equals running it once. This is idempotence hygiene and
  is **not** the fix for editor-side accumulation: that is `owner`. Of the six
  children Lux parents onto a LuxRoot, exactly the three carrying
  `owner = edited_scene_root` are the three that survive into a saved scene.
  Nine assignment sites across the addon; tracked as roadmap item 24.

## [0.15.4] - Run artifacts land in _runs\

- `tools/headless_walk.ps1` + `tools/visual_pass.ps1` write run folders and results zips under the factory's `_runs\`
  directory instead of the factory root — tool repos and the coordination
  files stay alone at the top level. No behavior change.

## [0.15.3] - Strict-clean under engine defaults

### Fixed
- `lux_root.gd` blend_to_preset: `var p := _preset_library.get(...)` inferred
  from Variant — engine-DEFAULT GDScript warning config treats that as a
  load-killing parse error (the lux project's own config downgrades it, which
  is why it never fired at home). Failed the script + two dependents in
  Level Factory's clean-project portability check; now explicitly typed
  LuxPreset. Pairs with LF v0.10.3, whose exported project.godot also
  downgrades the warning as defense in depth.

## [0.15.2] - Spawned rigs no longer wear the marker prefix

### Fixed
- `LuxFixtureSpawner`: spawned rigs are named `Spawned_<type>...` instead of
  inheriting the marker's `LuxEmit_*` name via the anchor id — reusing the
  name made every prefix-based scan double-count (the co-location validator
  reported 40 "markers" for 20 on the first hardware run). Gates were
  unaffected (rigs sit exactly on their markers), but counts now tell the
  truth and re-scans can't mistake a rig for hardware.

## [0.15.1] - Runners homed in-repo

### Added
- `tools/headless_walk.ps1` (v4) and `tools/visual_pass.ps1`: the harness
  and screenshot-pass runners now live beside the scripts they drive and
  derive every path from the repo location — no factory-root copies. Both
  execute the repo-homed `res://tools/*.gd`; Godot capture rules
  (console exe preference, Start-Process redirect, handle caching,
  timeouts) unchanged.

## [0.15.0] - Emitter-marker spawning + co-location gate (pairs with Zoo v0.30.0)

### Added
- **`LuxFixtureSpawner`** (`runtime/lux_fixture_spawner.gd`): spawns one rig
  per `LuxEmit_<type>` emitter marker in Zoo v0.30+ fixture GLBs — markers
  are per-lamp (Zoo expanded rows once, at the source), type read from node
  metadata (glTF extras) with name-parse fallback, tuning reused from the
  loader's one table via the new `LuxLightLoader.rig_for_anchor()`. Drag a
  fixtures GLB anywhere — Level Factory or by hand — call
  `LuxFixtureSpawner.spawn(level_root)`, and the lamp lands inside the
  hardware. Daylight (window/sun) has no markers and stays on the manifest
  bake path, which also makes `set_fixtures_powered(false)` semantics exact:
  spawned lights are building power; window light survives a power cut.
- **Dock: "Spawn From Fixtures"** button beside Bind Emissives.
- **`LuxValidator.check_fixture_colocation()`**: dark-hardware (marker with
  no lamp within tolerance) and floating-light (spawned lamp off its marker)
  are ERROR findings; wired into `validate()`. This is the fixture-pass
  thesis as a permanent machine gate.
- **`tools/walk_harness.gd` + `tools/visual_pass.gd`** homed in-repo: the
  headless walkabout harness (Phase A manifest bake gates + Phase B marker
  gates; hardware-proven frame-wait/settle/LuxSun-exclusion rules encoded)
  and the windowed screenshot pass.

### Changed
- `LuxLightLoader`: new public `rig_for_anchor(a)` — the single rig tuning
  table now serves both the manifest bake and the marker spawner.


## [0.14.0] — 2026-07-14

### Added
- **LuxEmissiveBinder** (`runtime/lux_emissive_binder.gd`): binds Zoo
  fixture lit-face materials (`M_*_Lens` / `_Diffuser` / `_Face`, glTF
  emissive from `zoo --fixtures`) to the LuxRoot, stamping each base
  emission energy into resource meta (idempotent across re-imports).
- **Building power switch**: `LuxRoot.set_fixtures_powered(on)` /
  `LuxRuntimeAPI.fixtures_powered(tree, on)` — kills every registered
  non-alarm rig light AND the bound fixture glow; `lux_alarm`-group lights
  stay (battery strobes). `LuxRoot.bind_fixture_emissives()` /
  `LuxRuntimeAPI.bind_emissives(tree)` for after level load; dock gains a
  **Bind Emissives** button next to Bake Lights for editor verification.
- **`wall_pack` anchor type** in LuxLightLoader (DC lights.json 1.1): one
  downward warm (3000 K halogen) spot per exterior-door anchor, energy 2.5
  range 7 — a LuxStreetlightRig with count 1. The `sign` type already
  mapped to the area rig; DC now derives those anchors too.
- Pairs with **deli_counter v0.75.0** (derives `wall_pack` + storefront
  `sign` anchors, emitters proud of the wall) and **zoo v0.29.0**
  (`wall_pack` + `sign_box` hardware at the same anchors).

## [0.13.1] — 2026-07-14

### Fixed
- **LuxStreetlightRig rows now center on the rig node** (same
  `start = -(count-1)/2 * spacing` as LuxFluorescentRig). Lot writes
  path-MIDPOINT streetlight anchors, so the old from-the-node expansion lit
  only half the path and overshot the far end by ~half the row. Cone meshes
  (`cone_enabled`) follow their lamps. Behavior change is placement-only:
  any baked streetlight row shifts back by `(count-1)/2 * spacing` along
  its local X — re-run Bake Lights on site scenes. Fluorescent/area/sun
  rigs untouched.
- Pairs with **zoo v0.28.0**, whose fixture pass (`--fixtures
  <lights.json>`) expands rows with this exact math — every pole Zoo bakes
  sits under the lamp this rig spawns.

## [0.13.0] — 2026-07-10

### Added
- **SoF PC2000 look family** (fourth family alongside delco / gothic /
  ps1-storm): "premium PC shooter, 1999–2002" — hard LightmapGI baked light
  pools, imported per-pixel `StandardMaterial3D` on level geo (bilinear +
  mipmaps, explicitly NOT the PS1 look), Lux running **grade-only**.
- `presets/sof_pc2000.tres` — restrained Filmic, exposure 0.95, saturation
  0.9, contrast 1.06; glow/dither/CRT/vignette/grain all OFF, native res
  bilinear, low flat ambient (the lightmap owns darkness), light distance fog.
- `LuxLightRig.bake_mode` (Realtime / Static / Dynamic) +
  `apply_bake_mode()`; all four rigs (fluorescent, streetlight, area,
  sun/moon) apply it to spawned lights. Default Realtime leaves existing
  scenes byte-identical. Static zeroes flicker (frozen lightmaps can't
  flicker).
- `LuxLightLoader.bake(path, scene_root, lightmap_static := false)` — static
  mode flips every spawned rig to `BAKE_STATIC` before it enters the tree.
  Dock gained a **"Lightmap static (pc2000)"** checkbox in the Level Lights
  section.
- `LuxMaterialApplier.apply_role_lightmapped(root, role)` — pc2000 role path:
  keeps materials per-pixel engine-standard, sets `gi_mode` STATIC
  (LEVEL/PROP) or DYNAMIC (CHARACTER/GUN), skips the `lux_materials` group so
  presets can't restyle these surfaces.
- `lookdev/pc2000_bake.tscn` + `lookdev/pc2000_lookdev.gd` — bake/judge scene
  with gs.patina.glb instanced EDITOR-TIME (lightmaps only survive on meshes
  present at bake; the base harness's runtime-load path can't carry them),
  LuxRoot on the SoF preset, and a configured LightmapGI node.
- `docs/pc2000_bake_runbook.md` — exact 4.7 reimport/bake/judge steps, what
  "landed" looks like, and the known retunes (baked interior energies,
  AreaLight3D bake support unverified, Patina double-AO in corners).

### Changed
- `walk/gs.patina.glb.import`: `meshes/light_baking` 1 → 2 (Static
  Lightmaps) so the import generates UV2 for the bake (texel 0.2 unchanged).
- Synced the stale root `VERSION` marker (was still 0.11.0).

## [0.12.0] — 2026-07-10

### Added
- `presets/ps1_storm_night.tres` — first preset of the **PS1-chunk storm
  family** (third look family alongside delco + gothic): hard 0.25
  `render_scale` with nearest-neighbor upscale (480×270 at 1080p), sun off,
  flat teal-navy ambient, **Linear** tonemap (sixth-gen had none, and Filmic
  mutes the saturated storm palette), dither 0.7 / 12 colour levels /
  distance fade **off** so the sky dithers uniformly, `default_wetness` 0.5,
  "Storm Sodium" palette (teal shadows, sodium highlights, cyan accent).
  Pair with a SkyMint storm sky. Tune dither AT 0.25 scale — each dither
  pixel is 4× fatter than at native.
- **Light cones** on `LuxStreetlightRig` — fake-volumetric additive cone per
  lamp (`shaders/spatial/lux_light_cone.gdshader`): flat apex→ground alpha
  gradient (no fresnel), per-frame camera fade to zero when the player walks
  under the lamp (kills the full-screen additive wash). Cosmetic only —
  never touches the SpotLight3D energy. `cone_enabled` defaults **off** so
  existing scenes render byte-identical (same contract as the emission
  defaults). `cone_angle_deg` (default 25°) is deliberately tighter than
  `spot_angle` — a matching cone reads as a wall of light, not a beam.

## [0.11.0] — 2026-07-09

### Added
- **Emission path** in `lux_stylized_standard.gdshader` — `emissive_texture`
  (mask, white = lit) + `emissive_color` (tube/lightbox hue) +
  `emissive_energy`, output as `EMISSION` so it survives both the modern and
  PS2 paths and stays visible in graphic darkness. Deliberately ignores vertex
  colour: a lit sign must not dim under the Patina AO bake. Defaults are inert
  (black colour), so existing materials render byte-identical. First brick of
  the Source-era urban gothic direction — neon, signage, light boxes, vending
  fronts. Legibility rule: energy ~1.0 reads as a lit face; 1.5–3.0 clears a
  ~1.05 `glow_hdr_threshold` for bloom without blowing the sign to white.
  Rigs may animate `emissive_energy` per-frame for buzz/flicker.
- `LuxMaterialProfile` **Emission** export group (`emissive_color`,
  `emissive_texture`, `emissive_energy`), pushed by `apply_to_material`.
  The texture parameter is only set when non-null so `hint_default_white`
  survives colour-only tubes.
- `presets/gothic_street_night.tres` — first urban-gothic preset: sun off,
  dark green-gray **flat** ambient (0.55), crushed blacks (contrast 1.12),
  Filmic tonemap (ACES desaturates neon hues toward white),
  `glow_hdr_threshold` 1.05, thin ground fog, native resolution, no CRT,
  dither 0.08. Bruised-violet shadows / sodium-amber highlights / one neon
  magenta accent. `default_wetness` stays 0 — wetness is per-material
  (pavement only), per the selective-wetness rule.

### Changed
- `plugin.cfg` version synced to the release (was stale at 0.8.3).

## [0.10.4] — 2026-07-09

### Fixed
- Baked fluorescent rigs blew interiors to white: each light baked at
  `energy = 2.2`, but rooms pack 5+ overlapping fluorescents, so their
  contributions summed to ~10+ on nearby surfaces — clipping to white with the
  dither screaming over the lost tonal range. Dropped baked per-light energy to
  1.0 and range to 8.0 so a densely-lit room reads correctly. (Live exposure X/Z
  in the harness also pulls it back for tuning.)

## [0.10.3] — 2026-07-09

### Fixed
- Look-dev harness HUD showed a stale preset name after a preset jump (1-6): the
  lighting changed but the label kept saying the old preset. `blend_to_preset`
  applies a preset without updating `active_preset`, so the harness was reading
  the wrong source; now it reads `get_current_preset()` (the actually-applied
  preset) for the HUD and the tuning base.

## [0.10.2] — 2026-07-09

### Fixed
- `lux_dock.gd` and `lux_validator.gd` failed to compile under Godot 4.7's
  stricter type inference (method-return and dict-field `:=` inferences like
  `omni_spot`, `shadow_casters`, `clustered`, and the dock's `_get_selected_root`
  chain). Typed them explicitly. **This unblocks the LuxDock** — including the
  Bake Lights section that spawns interior light rigs from a `.lights.json`.

## [0.10.1] — 2026-07-09

### Added
- Look-dev harness **walk mode** (Tab to toggle): first-person WASD + mouselook
  through the building at eye level (1.7 m), so you can feel the space and judge
  walls/scale/mottle from a player's POV, not just orbit it. Shift sprints,
  Q/E drop/rise (noclip fly to inspect rooflines or floor). Esc frees the mouse;
  Tab returns to orbit. Preset jump (1-6), Lux on/off, and screenshots still work
  while walking; the grade-tuning hotkeys stay orbit-only (they reuse WASD).

## [0.10.0] — 2026-07-09

### Added
- **SkyMint integration** — Lux and SkyMint now share one WorldEnvironment:
  SkyMint owns the sky (panorama, clouds, day/night), Lux writes only its grade
  onto the same environment. Lux's `ensure_world_environment` searches the whole
  scene to adopt SkyMint's environment; `LuxEnvironment.defer_sky` (auto-set when
  a sky provider is detected) makes Lux skip authoring the sky. Combined with the
  existing `auto_find_skymint` sun-borrow, a SkyMint day/night sun relights the
  vertex-lit world while Lux drives the look. Duck-typed, no hard dependency —
  Lux authors its own procedural sky when no provider is present. See
  `docs/skymint_integration.md`.

### Fixed
- Strict-typed several method-return `:=` inferences in `lux_environment.gd` and
  `lux_root.gd` for Godot 4.7's stricter inference.

## [0.9.5] — 2026-07-09

### Fixed
- Look-dev harness: made every method-return `:=` inference explicit
  (`packed: Resource`, `aabb: AABB`, `world: AABB`, `img: Image`, etc.).
  Godot 4.7's stricter type inference rejected the `world` AABB inference at
  line 124; typing them explicitly parses cleanly. Literal-value inferences
  (bool/float/Vector3) are unchanged.

## [0.9.4] — 2026-07-09

### Fixed
- Look-dev harness camera now **frames the building**: computes the model's
  world-space AABB on load and orbits its centre at a fit distance, instead of
  circling the world origin at a fixed 14 m (which swept the camera *through*
  the inside of the building). Added mouse-wheel zoom, up/down height, and Home
  to reframe — so an off-centre or oversized building is still viewable.

## [0.9.3] — 2026-07-09

### Fixed
- Look-dev harness: `var idx := e.keycode - KEY_1` failed Godot's type inference
  (untyped event value) — declared `idx: int` explicitly so `lookdev.gd` parses
  and the scene runs.

## [0.9.2] — 2026-07-09

### Added
- **`delco_arcade` preset** — punchy saturated near vs washed-out far, the
  arcade/PS2 plane-separation look. Brighter HDR key (exposure 1.15, sun energy
  1.7, glow threshold 1.25 so only highlights bloom), punchy saturation 1.22 /
  contrast 1.1, and cooler denser distance fog (density 0.006, cool-light
  colour) so the background washes out with camera distance while the foreground
  stays saturated. This is the *camera-relative* half of the separation;
  Patina's `--depth punch` bakes the per-surface half. Registered in LuxRoot;
  reachable in the look-dev harness on preset key **6**.

## [0.9.1] — 2026-07-09

### Added
- Look-dev harness: **exposure** (Z/X) and **glow HDR threshold** (C/V) knobs —
  the two controls behind the "HDR pop" (bright subject against dark/hazy
  background, à la Halo 3). Exposure sets where the tonemap rolls off; the glow
  threshold decides *what* blooms, so only genuinely-bright highlights bleed.
  Both are LuxPreset fields applied via the environment; `apply_preset(_,0)`
  already re-runs env, so they push live. Doc adds the Halo-pop recipe.

## [0.9.0] — 2026-07-09

### Added
- **Look-dev harness** (`addons/lux/lookdev/`) — a scene for tuning the PS2 pop
  live on a real building. Loads a Patina-art-passed `.glb`, applies the LEVEL
  role, and drives the grade/post knobs (saturation, glow, contrast, warmth,
  palette influence, dither, vignette, fog) in real time via hotkeys with an
  on-screen readout. Edits a local preset copy (`LuxRoot.local_override`) so the
  shipped `.tres` is untouched; `[`/`]` capture before/after PNGs and **F5**
  dumps the tuned values to paste back into a preset. This is the composite
  iteration loop — "it renders" → "it looks good." See `lookdev/lookdev.md`.

## [0.8.3] - IP-neutral sample lights

### Changed
- Replaced the DELCO-specific `samples/foundry_heist_vertical.lights.json`
  (shipped in 0.8.0) with a generic `samples/sample_building.lights.json`
  (5 anchors: 3 fluorescent rooms + 2 windows), keeping Lux IP-neutral while
  still shipping something to bake against and demonstrate the loader format.

## [0.8.2] - Fix: same get_surface_count crash in the sample scene ([P] key)

### Fixed
- lux_sample_scene.gd `_set_ps2_lighting` had the same nonexistent
  `MeshInstance3D.get_surface_count()` call fixed in 0.8.1 elsewhere, so pressing
  [P] (PS2 Gouraud toggle) crashed. Now `get_surface_override_material_count()`.
  (The `mi.mesh.get_surface_count()` calls in the material applier/profile are
  correct -- Mesh has that method -- and were left as-is.)

## [0.8.1] - Fixes: preset-apply crash + post-FX shader compile

### Fixed
- `LuxRoot._push_material_state` called `MeshInstance3D.get_surface_count()`,
  which doesn't exist -> preset apply threw "Invalid call" and aborted mid-walk
  of the lux_materials group. Now uses `get_surface_override_material_count()`
  (two sites). This was the "Parameter 'version' is null" cascade's root.
- The ordered-dither post-FX shader declared `hint_depth_texture`, which Godot
  4.7 rejects in `canvas_item` shaders -> the shader failed to compile and any
  scene with a LuxRoot flooded the log with null-shader errors every frame.
  Removed the depth path; dither now applies uniformly (the distance-fade
  falloff would need a spatial post pass -- tracked as future work). Fade
  uniforms are kept for compatibility. Both pre-existing, unrelated to 0.8.0's
  light loader.

## [0.8.0] - Light loader: bake a Deli Counter .lights.json into Lux rigs

### Added
- `LuxLightLoader` (runtime/lux_light_loader.gd): reads a Deli Counter
  `<name>.lights.json` and bakes one Lux rig per light anchor into the open
  scene -- `fluorescent` -> LuxFluorescentRig, `window`/`sign` ->
  LuxAreaLightRig, `streetlight` -> LuxStreetlightRig. Fluorescent rows use the
  anchor's count/spacing; windows use the anchor's size. `sun` is left to the
  preset. Rigs self-register with a LuxRoot, so presets and the alarm pulse
  drive the baked lights.
- Coordinate conversion: Deli Counter emits Blender Z-up; the level GLB imports
  as Godot Y-up, so anchor positions are swapped `(x, y, z_up) -> (x, z_up, -y)`
  to align with the imported level.
- Lux dock "Level Lights" section: Browse a `.lights.json`, Bake, and Clear.
  Editor-time -- lights are baked into the scene so they save and can be hand-
  tweaked.
- samples/foundry_heist_vertical.lights.json (26 anchors) to bake against.

### Notes
- MVP is light-only (emission, no fixture geometry). Visible tubes/poles/frames
  are a later Zoo-prop pass co-located with the anchors.
- If a bake looks mirrored/rotated, the axis swap and yaw sign in
  `LuxLightLoader._place` are the two flip points.

## [Unreleased]

## [0.7.0] — 2026-07-05
### Added
- **Role-based material applier** — one-click PS2 material setup by object type.
  Tell Lux what something is (Level / Character / Gun / Prop / Unlit) and it picks
  the right vertex-lighting path and quality:
  - **Level / Character / Prop** → native engine vertex shading (cheapest,
    multi-light, shadows) — the bulk of a scene stays on the fast path.
  - **Gun** → Lux Stylized Gouraud (nicer banding/palette; only one viewmodel is
    ever on screen).
  - **Unlit** → unshaded, for decals/screens.
  This performance split is deliberate: keeping level/character/prop on the cheap
  native path is what makes the look viable in multiplayer.
- **`LuxRole`** (role definitions + pre-tuned profile factory) and
  **`LuxMaterialApplier`** (`apply_role(node, role)` / `apply_role_name`) walk a
  subtree, set up each surface, and register it in `lux_materials` so palette,
  wetness, and the live Sun Link key light flow to it.
- **`LuxRoleTag`** node — drop it under an object, pick a role in the inspector,
  and it applies to the parent's mesh subtree on ready (zero code). Registered as
  a custom node type.
- **Dock role buttons** — select mesh nodes, click Level / Character / Gun / Prop
  / Unlit to apply.
- Sample scene now uses `apply_role(..., LEVEL)` and its **P** toggle flips the
  level's native per-vertex shading.

## [0.6.0] — 2026-07-05
### Added
- **Sun Link** — LuxRoot can track a live `DirectionalLight3D` and feed its world
  direction, color, and energy into the vertex/PS2 lighting path every frame, so
  a moving or driven sun relights the vertex-lit world. Set it explicitly
  (`sun_light`), let `auto_find_skymint` borrow a [SkyMint](https://github.com/siliconight/skymint)
  sun automatically, or call `set_sun_light()` at runtime.
  - No hard dependency on SkyMint: the sun is found by duck-typing a `sun_light`
    field, so Lux runs with or without the addon and with a hand-placed light.
  - Multiplayer-safe and cheap: the look is a pure function of the (already
    synced) light state — no Lux networking — and uniforms are pushed only when
    the sun actually changes, so a static sun costs one transform read plus three
    compares per frame. When a link is active it owns the key light, so preset
    applies/blends don't stomp a moving sun.
- Validator reports Sun Link status when a vertex-lighting mode is active.

## [0.5.1] — 2026-07-05
### Changed
- README facelift: rewritten to present Lux as the shipped framework it now is —
  feature sections for the retro toolbox, the two vertex-lighting paths, the four
  light rigs, runtime API, and editor tooling — replacing the original MVP
  deliverable checklist. Docs and behavior unchanged.

## [0.5.0] — 2026-07-05
### Added
- **Native engine vertex shading** integration (Godot 4.4+, PR #83360). A preset
  `vertex_shading_mode` now chooses between:
  - **Off** — per-pixel (modern).
  - **Native Engine** — Godot's built-in per-vertex shading on StandardMaterial3D
    surfaces. This is the authentic multi-light PSX path: it sees every real-time
    light (so Lux's omni/spot/area rigs all contribute), integrates with
    clustering, and casts pixel shadows from the first DirectionalLight3D. LuxRoot
    flips `SHADING_MODE_PER_VERTEX` on plain surfaces in the `lux_materials` group.
  - **Lux Stylized Gouraud** — the v0.4.0 shader path, for keeping Lux's
    banding/palette/Mach-bands on top of a vertex-lit feel (approximated from the
    key light only, since the engine forces Lambertian for native vertex shading
    and ignores custom `light()`).
- **`LuxVertexShading`** helper with a 4.4+ availability guard, per-material
  `SHADING_MODE_PER_VERTEX` toggling, and the
  `rendering/shading/overrides/force_vertex_shading` project override.
- Validator notes the native-vertex-shading shadow limitation (first
  DirectionalLight3D only) and the stylized-path key-light approximation, and
  warns if Native Engine mode is selected on a pre-4.4 build.

### Notes
- The native path is recommended for true multi-light vertex lighting; the Lux
  Stylized path (v0.4.0) remains for stylized surfaces that need Lux's look, which
  the engine's Lambertian-only vertex mode can't reproduce.

## [0.4.1] — 2026-07-05
### Changed
- Removed the direct project title reference from the README so the addon reads
  as a standalone, reusable framework. Scene-mood preset names are unchanged.

## [0.4.0] — 2026-07-05
### Added
- **PS2 per-vertex (Gouraud) lighting path** in the stylized shader. A
  `ps2_lighting` blend (0 = modern per-pixel, 1 = full PS2 feel) switches the
  material from clean per-fragment banded shading to lighting evaluated at
  vertices and interpolated affinely — the soft, slightly-wrong gradients real
  PS2 hardware produced (it had no pixel shaders; only textures were
  perspective-correct). Includes `ps2_skip_ndl` for the flat, angle-blind
  world-geo look and clamped additive accumulation, mirroring VU lighting.
- **Mach-band emphasis** (`mach_band_emphasis`) — sharpens gradient edges so the
  perceptual banding at polygon boundaries reads as intentional retro character
  instead of being smoothed away.
- **Scene-wide PS2 override** — `LuxPreset.ps2_lighting_global` (-1 = per-material,
  0..1 = force all Lux materials), plus a dock slider, so a whole level can flip
  into the PS2 hardware look from one preset. LuxRoot pushes the key light
  direction/color/ambient (derived from the preset's sun) into all Lux materials
  so the Gouraud path is lit correctly.
- Sample scene: **[P]** toggles scene-wide PS2 Gouraud lighting for a direct
  before/after against the default per-pixel shading.

### Changed
- `LuxMaterialProfile` gained a **PS2 Lighting** group (`ps2_lighting`,
  `ps2_skip_ndl`, `mach_band_emphasis`).

### Notes
- Deliberately skipped from the shared references: spherical-harmonics ambient +
  HDR (opposite of the PS2 look; flat ambient added in 0.3.0 is the period-correct
  answer) and the engine-specific Unity forum thread.

## [0.3.0] — 2026-07-05
### Added
- **CRT mask post pass** (`shaders/post/lux_crt_mask.gdshader`) — an optional
  "displayed on a CRT" layer with aperture-grille (Trinitron vertical RGB
  stripes) and shadow-mask (dot-triad) phosphor patterns plus soft scanlines.
  Runs as a second pass above the dither pass on the same low CanvasLayer, so UI
  stays untouched. Exposed on `LuxPreset` as `crt_mask_type`,
  `crt_mask_strength`, `crt_mask_scale`, `scanline_strength`, and as two dock
  sliders.
- **Flat ambient mode** — `LuxPreset.ambient_mode` (Sky / Flat Color / Disabled)
  and `ambient_sky_contribution`, for the honest GI-free PS2-era look where a key
  light plus a single uniform ambient fill does the lighting.
- **`LuxColorTemp`** — Kelvin→RGB helper with named constants for real fixtures
  (sodium vapor ~2000K, cool-white fluorescent ~4100K with mercury-spike green
  cast, mercury vapor ~5000K, etc.), plus a fluorescent-cast tint helper.

### Changed
- Light rigs now use physically-grounded colors: the streetlight rig defaults to
  ~2000K sodium amber and the fluorescent rig to a cool-white tube tint with the
  characteristic green cast, instead of eyeballed RGB.
- *Gas Station Fluorescent* preset retuned to flat ambient with a subtle
  aperture-grille mask and faint scanlines on top of its existing low-res look.

## [0.2.0] — 2026-07-05
### Added
- **Godot 4.7 AreaLight3D** support via `LuxAreaLightRig` — rectangular area
  panels for screens, signage, deli cases, and window light, with an emissive
  preview quad. Falls back to an omni approximation on the Compatibility tier.
- **Nearest-neighbor 3D scaling** — `LuxPreset.render_scale` +
  `nearest_neighbor_scaling` drive Godot 4.7's viewport 3D nearest scaling for a
  chunky low-res retro look. *Gas Station Fluorescent* ships at `render_scale
  = 0.75`.
- **HDR-output awareness** — `force_sdr_retro_on_hdr` + a `hdr_passthrough`
  shader uniform keep dithering/quantization SDR-tuned on HDR displays.

### Changed
- Validator now counts `AreaLight3D`, warns on the Forward+ clustered-element
  budget, and notes the Compatibility-tier fallback.

## [0.1.0] — 2026-07-05
### Added
- Initial MVP per TDD §16: `LuxRoot` coordinator + runtime API (mission phases,
  alarm pulse, weather, time-of-day, damage look, quality tiers) with a
  field-by-field preset blender.
- Environment / lighting / post-FX modules; stylized spatial shader; ordered
  Bayer dither + grade post pass (UI-safe on a low CanvasLayer).
- Three light rigs (sun/moon, fluorescent, streetlight); five scene-mood
  presets; material profiles, palettes, and quality profiles.
- Editor dock (apply/preview, art sliders, save level override, validate),
  validation panel, before/after sample scene, and docs.

[Unreleased]: https://github.com/siliconight/lux/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/siliconight/lux/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/siliconight/lux/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/siliconight/lux/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/siliconight/lux/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/siliconight/lux/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/siliconight/lux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/siliconight/lux/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/siliconight/lux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/siliconight/lux/releases/tag/v0.1.0
