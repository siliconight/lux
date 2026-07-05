# Changelog

All notable changes to Lux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Lux uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While Lux is pre-1.0, minor versions may include breaking changes to resources
and the API; these are called out under **Changed** / **Breaking**.

## [Unreleased]

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

[Unreleased]: https://github.com/siliconight/lux/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/siliconight/lux/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/siliconight/lux/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/siliconight/lux/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/siliconight/lux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/siliconight/lux/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/siliconight/lux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/siliconight/lux/releases/tag/v0.1.0
