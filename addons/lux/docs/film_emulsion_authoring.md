# Lux — Where to Use Film Emulsion

Film emulsion is off in every shipped preset and costs nothing until a preset
asks for it. This page is about the more interesting question: **where it is
worth asking for.**

For what it is and how it works, see `docs/film_emulsion_tdd.md` (the
specification) and `docs/film_emulsion_phase1_audit.md` (what was measured, and
one thing the audit got wrong first). For the API, see `runtime_api.md`.

## What it costs, and where it fits

Measured on an RTX 2060, Godot 4.7 forward_plus, the engine's own viewport
timer, at the shipped settings. §41 budgets the treatment at about 2% of the
frame:

| resolution | film ms | film watts | 30 fps | 60 fps | 90 fps | 120 fps |
|---|---|---|---|---|---|---|
| 1280x720 | 0.0450 | +7.6 W | ok | ok | ok | ok |
| 1920x1080 | 0.0990 | +11.0 W | ok | ok | ok | ok |
| 2560x1440 | 0.1760 | +7.0 W | ok | ok | ok | **over** |
| 3840x2160 | 0.2580 | +8.8 W | ok | ok | **over** | **over** |

**Film Mode fits everywhere except 4K above 60 fps and 1440p at 120.** If your
target is one of those two cells, do not ship it on -- the cost is the density
model itself and no parameter recovers it. A bisect at the failing cell showed
the removable terms (the resolution lock, the chroma dye term) are together
6.1% of the film cost, against the 15% to 34% that would be needed.

Two honest qualifications. These are FLOORS taken on an empty scene, so a real
level can only be worse -- treat 1440p at 90 and 4K at 60 as thin rather than
comfortable. And they are one GPU: §51's hardware sweep has one machine in it,
and two rasterisers have already disagreed about this shader in opposite
directions.

**The watts column matters more than the milliseconds on a handheld.** Film
costs 7 to 12 W, sampled with `nvidia-smi` and attributed to each
configuration's own timed window. On a desktop that is inside the noise you
should care about. A Steam Deck's entire power budget is 15 W, so on that class
of machine this is not a rounding error and nobody has measured it there --
`tools/film_hw_sweep.py` is where that row goes when somebody does.

Two other columns §50 asks for are deliberately absent rather than estimated.
Bandwidth has no engine counter and deriving it from resolution x format x taps
would be arithmetic wearing a measurement's clothes; shader stalls need Nsight,
RGP or PIX. VRAM is flat -- the grain texture is one 128x128 RGBA8 asset, 64
KiB, sampled at a locked reference width, so nothing about it scales with
resolution.

### If you need 4K above 60, or 1440p at 120

A half-resolution film pass closes every failing cell -- its cost is just the
row above it in this table, since it renders that many fragments of the same
shader. It is priced in `tools/film_halfres_probe.py` and **not built**,
because what it costs is not time:

| | grain retained | fine band | aliasing |
|---|---|---|---|
| 4K half-res | 74.3% | 31.5% -> 13.5% | 0.0% |
| 1440p half-res | 65.6% | 23.4% -> 12.6% | 0.0% |

It softens rather than aliases, and what it softens is the fine band -- 68% of
the blend, and the band deliberately placed near Nyquist so the grain reads as
crystals rather than blobs. **Half-res is not a quality slider. It is a second
stock:** the same emulsion, coarser, because half the pixels is half the
pixels. Whether that is the look you want is not a decision this page can make
for you.

Worth saying next to all of it: 4K at 120 fps is chasing motion clarity, and
film emulsion is a 24 fps aesthetic -- the grain advances at 24 fps no matter
how fast the renderer runs. Half-res makes the cell fit. It does not make it a
thing anyone wants.

## What it is imitating, and why that shapes the parameters

Analog motion picture film is coated with an emulsion of light-sensitive silver
halide crystals. Exposure and development turn those microscopic crystals into
metallic silver, and that physical deposit IS the grain -- it is not an overlay
on the image, it is the substance the image is made of. Projected at the
industry standard 24 frames per second, the result is the organic, flickering,
immersive quality people mean by "the cinematic look".

Three things in this feature follow directly from that description, and they
are worth knowing because they explain parameters that otherwise look arbitrary:

- **`film_grain_fps` defaults to 24, not to the frame rate.** Grain is a
  property of each exposed FRAME of film, so it changes 24 times a second no
  matter how fast the projector -- or the renderer -- runs. TDD §24: at 120 fps
  the grain uniform is written every fifth frame, not every frame. Grain that
  advances per rendered frame is video noise, not film.
- **The density is MULTIPLICATIVE, not additive.** `col *= exp2(-neutral_density)`
  models silver blocking light rather than noise being added on top, which is
  why it preserves hue and saturation where an additive grain modulates them
  (audit §3a). It is also why the effect is loud in shadow and quiet in
  highlight without any mask -- the table below is that physics, measured.
- **One shared density, not three.** Silver is not red, green and blue crystals
  independently; one deposit attenuates all wavelengths together. That is the
  same reasoning that produced the shared quantization decision, which turned
  out to be the thing that removes the RGB breakup (audit §8b).

An observation from the walk that this predicts: **the effect is easiest to see
against blacks.** That is the exposure weighting below, seen rather than
measured, and the two agree.

## It is already area-selective, and that is the whole design

Two selectivities are built into the effect. Neither is a mask, and both are
free.

**By exposure.** The grain is weighted by an exposure mask (TDD §29), so it does
almost all of its work in shadow. Measured on the Lux sample scene, relative
difference by luminance band:

| luminance band | relative change |
|---|---|
| 0.00 – 0.05 | **0.320** |
| 0.05 – 0.10 | 0.104 |
| 0.10 – 0.20 | 0.053 |
| 0.20 – 0.35 | 0.030 |
| 0.35 – 0.55 | 0.018 |
| 0.55 – 1.00 | **0.011** |

That is a **30:1 spread inside a single frame**. Film is not a uniform overlay;
it is loud in the dark and nearly silent in the light.

**By colour.** The chroma-coherent quantizer only changes anything where R, G
and B differ. On a neutral wall all three channels quantize identically and it
is invisible; on a coloured surface it is the difference between speckle and a
continuous surface. Measured over 2183 flat coloured blocks, saturation
variation falls from **0.04178 to 0.01509**.

So the effect concentrates itself in **dark, coloured** regions — which in a Lux
scene means interiors, night exteriors, and anything lit by a coloured
practical. That is where the fixture rigs put light.

## Where it earns its keep

- **Interiors and night exteriors.** Shadow-dominated, so the exposure weighting
  has something to bite on.
- **Coloured practicals** — sodium streetlight, neon, fluorescent green,
  emergency red. Both selectivities line up here.
- **Basements, back rooms, anywhere the key light is a single fixture.**

## Where it is wasted

- **Bright daylight.** The shipped *Delco Summer Afternoon* preset has **zero
  pixels below 0.15 luminance**. There is nothing for the exposure mask to find,
  and you would be paying about 0.05 ms at 1080p for it.
- **Neutral palettes.** If the look is essentially greyscale, the coherent
  quantizer has nothing to preserve.

Leaving it off in those looks is not only a saving. It is what makes it
**mean** something when the player walks into a room where it is on.

## Switching it by area — already supported, no new code

Film emulsion is a **preset property**, so everything Lux already does with
presets applies to it unchanged:

```gdscript
# A doorway trigger, or a GOOL indoor/outdoor zone event.
func _on_entered_interior() -> void:
    LuxRuntimeAPI.preset(get_tree(), &"Row Home Interior", 1.2)
```

Author two presets for the level, set `film_emulsion_enabled` and
`grain_mode = Film Emulsion` on the interior one only, and crossing the
threshold blends into it over 1.2 s. `runtime_api.md` documents GOOL's
indoor/outdoor zone events driving exactly this call.

The blend carries the film parameters too — `LuxRoot._lerp_preset` interpolates
`film_grain_strength`, `film_chroma_ratio` and the coherence dial, and snaps the
enable flags at the midpoint the way every other switch does. So a blend into a
film preset ramps the grain in rather than popping it.

## It self-modulates, which is the best dramatic use of it

Because the grain is weighted by exposure, **it gets stronger when the scene
gets darker, with nothing scripted.**

```gdscript
LuxRuntimeAPI.fixtures_powered(get_tree(), false)   # the lights go out
```

The room drops into the 0.00–0.10 luminance bands, where the relative response
is 0.32 and 0.10 rather than 0.011. The grain comes up because the room went
dark — not because anything asked it to. No parameter change, no timeline, no
second preset.

That is the single best use of the feature: pair it with a power cut, an
emergency-lighting state, or a storm rolling in, and the photographic response
intensifies exactly when the drama does.

Other registers worth trying:

- **Flashback / security footage.** Film emulsion plus the CRT mask Lux already
  has. Two deliberately different registers — one photographic, one electronic.
- **Mission phase.** `set_mission_phase(&"combat")` into a film-enabled preset.
  Or the reverse: film as the normal state, and its *removal* as the shock.

## One gotcha, and it is unmeasured

`LuxRoot.film_manage_hdr_2d` raises the viewport to a floating-point render
target while film runs. **That rebuilds the render target.** The flip has been
verified to work at runtime in both directions and to restore what it found —
but **whether it hitches has not been measured**, and a render-target rebuild is
exactly the kind of thing that does.

So if film is on in some zones and off in others, prefer raising the target once
for the whole level rather than letting it toggle at every doorway:

- leave `film_manage_hdr_2d` **on** for the level's LuxRoot, and
- give the exterior preset `film_emulsion_enabled = true` with
  `film_grain_strength = 0.0` — the film path stays selected, so the target is
  never rebuilt, and the grain costs nothing because the shader branches over it.

Measure it before relying on either arrangement. `tools/film_render_probe.py
--perf` times the pass; it does not currently time a target rebuild.

## What is NOT available: masking inside a frame

There is no way to confine film to part of the screen today, and the obvious
route is closed. The post pass is a `canvas_item` shader, and canvas_item
shaders cannot read the depth buffer in Godot 4.7 — which is why the existing
`distance_fade_*` uniforms in both post shaders are inert and documented as
such. Getting depth means a spatial post pass, which is the architecture TDD §8
prohibits for this feature.

A screen-space radial mask would be free and is probably a bad idea: it keys off
the centre of the screen rather than off the level, so it fights the camera
instead of following the geometry. A per-zone preset is also free and respects
what the player actually walked into.

If frame-local masking ever becomes necessary, the honest options are a spatial
pass (violates §8) or per-zone render targets (violates §8 harder). Neither is
worth it for an effect that already varies 30:1 across the frame on its own.
