# Changelog

All notable changes to Lux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Lux uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While Lux is pre-1.0, minor versions may include breaking changes to resources
and the API; these are called out under **Changed** / **Breaking**.

## [Unreleased]

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

[Unreleased]: https://github.com/siliconight/lux/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/siliconight/lux/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/siliconight/lux/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/siliconight/lux/releases/tag/v0.1.0
