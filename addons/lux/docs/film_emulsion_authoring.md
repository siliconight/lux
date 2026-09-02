# Lux — Where to Use Film Emulsion

Film emulsion is off in every shipped preset and costs nothing until a preset
asks for it. This page is about the more interesting question: **where it is
worth asking for.**

For what it is and how it works, see `docs/film_emulsion_tdd.md` (the
specification) and `docs/film_emulsion_phase1_audit.md` (what was measured, and
one thing the audit got wrong first). For the API, see `runtime_api.md`.

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
