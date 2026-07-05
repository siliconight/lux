# Lux — Godot 4.7 Rendering Framework

Warm, inviting, sixth-generation-console-inspired worlds for Godot 4.7. Drop
**LuxRoot** into a level, pick a look preset, tune a few art sliders, and the
scene gets a cohesive stylized identity — banded diffuse lighting with warm,
readable shadows, palette-tinted grading, subtle ordered dithering, and a
mission-state-aware post stack.

Built for any Godot 4.7 game that wants a cohesive retro-modern look. Forward+ primary; Mobile
and Compatibility supported as reduced tiers. No paid external tools.

## MVP contents (TDD §16)

| Deliverable | Where |
| --- | --- |
| LuxRoot node + active preset support | `runtime/lux_root.gd` |
| LuxPreset resource (env, palette, fog, dither, bloom, materials) | `resources/lux_preset.gd` |
| Editor dock — apply, preview, tune, save override, validate | `editor/lux_dock.gd` |
| WorldEnvironment integration | `runtime/lux_environment.gd` |
| 3 light rigs — sun/moon, fluorescent interior, streetlight row | `runtime/rigs/` |
| 5 production presets | `presets/*.tres` |
| 1 stylized spatial shader | `shaders/spatial/lux_stylized_standard.gdshader` |
| 1 ordered dithering post pass | `shaders/post/lux_ordered_dither.gdshader` |
| Runtime API for mission-phase changes | `runtime/lux_root.gd`, `runtime/lux_runtime_api.gd` |
| Validation panel with warnings | `runtime/lux_validator.gd` |
| Before/after sample scene | `samples/lux_sample_scene.tscn` |
| Docs | `docs/` |

## Quick start

1. Copy `addons/lux/` into your project and enable **Lux** in Project Settings →
   Plugins.
2. Add a **LuxRoot** node to a level.
3. In the **Lux** dock, pick a preset → **Apply / Preview**.
4. Tune sliders, **Save Level Override**, **Validate Scene**.

Run `samples/lux_sample_scene.tscn` for a zero-asset demo. See `docs/` for
getting started, preset authoring, and the runtime API.

## The five shipped presets

*Delco Summer Afternoon* · *Gas Station Fluorescent* · *Blue Hour* ·
*Heavy Rain* · *Mission Goes Hot*

## Post-MVP roadmap (TDD §17)

Weather profiles + wet-surface response, time-of-day blending, emergency-light
system, material batch tools, palette authoring UI, lightmap/AO helpers,
compatibility fallbacks, split-screen co-op passes, generated-level auto-tagging,
and a capture mode for trailers.

---
GabagoolStudios · v0.4.1 · see [CHANGELOG](../../CHANGELOG.md)
