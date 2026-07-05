# Lux — Preset Authoring

A **LuxPreset** is a single resource holding a complete look: sky, sun, ambient,
tonemap/grade, fog, glow, dithering, post finish, palette, and basic material
response. Presets are the primary unit of art direction in Lux.

## Create a new preset

1. In the FileSystem dock, right-click `addons/lux/presets/` (or your own folder)
   → **New Resource → LuxPreset**.
2. Fill in `preset_name` (this is the name used by `blend_to_preset()` and the
   dock list) and a short `description`.
3. Author the grouped fields in the Inspector. Sensible starting points:
   - **Sky**: top/horizon/ground colors + energy.
   - **Sun / Moon**: elevation and azimuth in degrees, color, energy, shadows.
   - **Tonemap & Grade**: Filmic or ACES for most scenes; `warmth` is the fastest
     knob for mood (positive = orange, negative = blue).
   - **Fog**: keep density low (0.003–0.012); raise `fog_sky_affect` for haze.
   - **Dithering**: leave `dither_strength` subtle (0.2–0.35) and
     `color_levels` ≥ 20 to stay readable.
   - **Palette**: assign a `LuxPalette` for shadow/mid/highlight tints.
4. Drop it into the dock list by saving it under `addons/lux/presets/`, or
   register it at runtime with `lux_root.register_preset(my_preset)`.

## Palettes

A **LuxPalette** defines color families authored around mid-gray (0.5 = neutral).
`highlight`, `midtone`, and `shadow` tint the post stack's luminance zones;
`shadow` and `highlight` also drive the stylized material's shaded/lit tinting.
`accent` is a convenience color for signage and alarms. Keep values near 0.5 for
subtle grading; push further for stylized, faction-coded looks.

## Naming presets

Per the design pillars, name presets as **scene moods**, not technical settings:
*Wawa Parking Lot*, *Gas Station Fluorescent*, *Row Home Interior*,
*Mission Goes Hot*. This keeps the dock readable for level designers.

## Level overrides

Never edit a shared library preset for one level. Instead:

- Tune the dock's art sliders (Lux auto-creates a `local_override` for you), or
- Call `preset.make_override(name)` in code for a deep copy, or
- Press **Save Level Override** to serialize it next to the scene.

`LuxRoot.local_override`, when set, is applied instead of `active_preset`.

## Blending

Any apply can blend. `apply_preset(preset, blend_time)` and
`blend_to_preset(name, blend_time)` interpolate all numeric and color fields over
`blend_time` seconds; discrete toggles (sun on/off, tonemap mode) snap at the
midpoint. Use this for weather changes, day/night nudges, and mission escalation.

## The stricter UI-safe post path (optional)

The MVP post pass reads the screen on a low CanvasLayer, which keeps UI untouched
for typical HUDs. For a hard guarantee that *nothing* but the 3D world is
quantized:

1. Put your 3D scene under a `SubViewport`.
2. Show it via a `SubViewportContainer` / `TextureRect`.
3. Assign the Lux dither material to that display node and bind its
   `screen_tex`/`depth_tex` to the SubViewport's texture and depth.
4. Draw UI on a separate CanvasLayer above it.

This is the recommended setup for split-screen co-op (a post-MVP roadmap item),
where each player's viewport gets its own Lux pass.
