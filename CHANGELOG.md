# Changelog

All notable changes to Lux are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Lux uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While Lux is pre-1.0, minor versions may include breaking changes to resources
and the API; these are called out under **Changed** / **Breaking**.

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
