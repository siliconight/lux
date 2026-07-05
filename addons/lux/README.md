# Lux

**A warm, sixth-gen-console rendering framework for Godot 4.7.**

Drop `LuxRoot` into a level, pick a look preset, nudge a few art sliders, and the
scene gets a cohesive, inviting, PS2/Dreamcast/GameCube-era identity — banded
diffuse lighting with warm, readable shadows; palette-tinted grading; subtle
ordered dithering; optional CRT phosphor masks; and a mission-state-aware post
stack that can blend the whole level from calm to alarm in a configurable window.

Lux isn't a single shader. It's a full pipeline addon — environment, lighting,
materials, atmosphere, post FX, palettes, presets, a runtime API, and editor
tooling — that packages Godot 4.7's rendering systems into a repeatable look.

> **The promise:** cohesive retro-modern visuals in minutes, tuned through
> presets and sliders instead of hand-authored lights and shader code.

Forward+ is the primary target; Mobile and Compatibility run as reduced-feature
tiers with explicit fallbacks. No paid external tools.

---

## Quick start

1. Copy `addons/lux/` into your project and enable **Lux** in
   *Project Settings → Plugins*.
2. Add a **LuxRoot** node to your level (it's in the Create Node dialog, sun icon).
3. Open the **Lux** dock, pick a preset, and hit **Apply / Preview** — the
   WorldEnvironment, sun, and post stack update live in the editor.
4. Tune the art sliders, **Save Level Override**, and **Validate Scene**.

Run `samples/lux_sample_scene.tscn` for a zero-asset demo. In it: **Space**
toggles Lux on/off (before/after), **1–5** switch presets, **H/C** go hot/calm,
**A** pulses the alarm, **D** ramps the low-health look, and **P** flips into
PS2 stylized lighting.

---

## What's in the box

### Look presets
Complete, blendable looks in one resource — sky, sun, ambient, tonemap/grade,
fog, glow, dithering, CRT mask, palette, and material response. Five ship ready
to use, named as scene moods:

*Delco Summer Afternoon* · *Gas Station Fluorescent* · *Blue Hour* ·
*Heavy Rain* · *Mission Goes Hot*

Any apply can blend (`blend_to_preset(name, seconds)`), interpolating the whole
look over time for weather shifts and mission escalation.

### The retro toolbox
- **Stylized material** — banded diffuse with a lifted, tinted shadow floor,
  stylized specular and rim, palette pull, plus vertex-snap and affine-UV toggles.
- **Ordered dithering** — Bayer 4×4 + colour quantization with distance fade,
  kept subtle and off the UI.
- **CRT mask** — aperture-grille (Trinitron stripes) or shadow-mask (dot triads)
  phosphor patterns with scanlines.
- **Nearest-neighbor 3D scaling** — Godot 4.7's low-res render path for chunky
  pixels.
- **Flat ambient** — GI-free uniform fill, the honest way PS2-era scenes were lit.

### Vertex (PSX) lighting — two paths
- **Native Engine** *(recommended)* — Godot 4.4+ per-vertex shading on
  StandardMaterial3D surfaces: real multi-light vertex lighting (every rig
  contributes), clustering-aware, with pixel shadows from the key directional.
- **Lux Stylized Gouraud** — Lux's own per-vertex shader path, for keeping the
  banding, palette, and Mach-band character on stylized surfaces.

**Sun Link.** Point LuxRoot at a live `DirectionalLight3D` (or let it borrow a
[SkyMint](https://github.com/siliconight/skymint) sun automatically) and the
vertex-lit world relights as the sun moves — multiplayer-consistent, since the
look is a pure function of the already-synced light, and near-free, since Lux
only pushes uniforms when the sun actually changes.

### Lighting rigs
Four drop-in, self-registering rigs with physically-grounded colour temperatures
(via `LuxColorTemp`): **sun/moon**, **fluorescent interior** (cool-white ~4100K
with the mercury-spike green cast), **streetlight row** (~2000K sodium amber),
and **AreaLight3D panel** (Godot 4.7 rectangular light for screens, signage, and
windows — with an omni fallback on Compatibility).

### Runtime API
Drive visuals from gameplay through `LuxRoot` or the static `LuxRuntimeAPI`
facade: `set_mission_phase`, `blend_to_preset`, `set_weather`, `set_time_of_day`,
`pulse_alarm_lights`, `set_player_damage_intensity`, `set_quality_profile`.

### Editor tooling
A dock for applying and previewing presets, tuning art sliders against a
non-destructive level override, saving that override next to the scene, and a
validation panel that flags missing nodes, over-budget lights, and expensive
tier combinations.

---

## Project layout

```
addons/lux/
  editor/      dock + editor plugin
  runtime/     LuxRoot, environment/lighting/post modules, rigs, validator
  resources/   preset, palette, material profile, light rig, quality, color temp
  shaders/     stylized spatial shader; dither / CRT / grade post passes
  presets/     the five shipped .tres looks
  samples/     zero-asset before/after demo scene
  docs/        getting started · preset authoring · runtime API
```

See **`docs/getting_started.md`** to go deeper, **`docs/preset_authoring.md`** to
build your own looks, and **`docs/runtime_api.md`** to wire Lux into gameplay.

---

## Quality tiers

Set `quality_tier` on LuxRoot or call `set_quality_profile()`: **High** (full
stack), **Medium** (reduced shadows/post), **Low** (no post FX or glow), and
**Compatibility** (material-level stylization only). The core art direction —
banded diffuse, warm shadows, palette — survives every tier.

## Roadmap

Weather profiles + wet-surface response, time-of-day blending, an emergency-light
system, material batch tools, a palette authoring UI, lightmap/AO helpers,
split-screen co-op passes, generated-level auto-tagging, and a capture mode for
trailers.

---

GabagoolStudios · v0.6.0 · [CHANGELOG](../../CHANGELOG.md)
