# Lux — Getting Started

Lux is a drop-in rendering framework for Godot 4.7. Pick a preset, tune a few
sliders, and a level gets a cohesive, warm, sixth-gen-console-inspired look
without hand-authoring lights, shaders, and a post stack per scene.

## Install

1. Copy the `addons/lux/` folder into your project.
2. **Project → Project Settings → Plugins**, enable **Lux**.
3. A **Lux** dock appears on the right side of the editor.

Lux targets the **Forward+** renderer. Mobile and Compatibility work as reduced
tiers (see Quality below).

## Add Lux to a level

1. Add a **LuxRoot** node to your level scene (it shows up in the Create Node
   dialog with a sun icon).
2. In the **Lux dock**, choose a preset (e.g. *Delco Summer Afternoon*) and press
   **Apply / Preview**. The scene's WorldEnvironment, sun, and post stack update
   live in the editor.
3. Tune the **art sliders** — warmth, fog, dither strength, palette influence,
   glow, contrast, saturation, exposure, sun energy. Changes apply immediately to
   a *level-local override* so the shared preset resource is never mutated.
4. Press **Save Level Override** to write the tuned look next to your scene as
   `<scene>_lux.tres`. Lux reloads it as the active override.

If the level already has a `WorldEnvironment`, Lux reuses it; otherwise it creates
one under LuxRoot at runtime.

## Give surfaces the Lux look

Materials respond to Lux through **LuxMaterialProfile**. From code:

```gdscript
var profile := LuxMaterialProfile.new()
profile.band_count = 3.0
profile.apply_to_mesh_instance(mesh_instance, albedo_texture, preset.palette)
```

`apply_to_mesh_instance()` swaps in the stylized shader and registers the mesh in
the `lux_materials` group, so LuxRoot pushes palette and wetness updates to it
whenever the look changes.

## Light rigs

Four reusable rigs ship in the MVP:

- **LuxSunMoonRig** — an explicit celestial light (e.g. a fixed moon).
- **LuxFluorescentRig** — a flickering cool omni row for interiors.
- **LuxStreetlightRig** — a warm sodium-vapor spot row for lots and streets.
- **LuxAreaLightRig** — a Godot 4.7 AreaLight3D panel for screens, signage, and
  windows (see Godot 4.7 features below).

Drop a rig node in, assign an optional `LuxLightRig` resource to tune
count/spacing/color/flicker, and it self-registers with LuxRoot.

## Quality tiers

Set `quality_tier` on LuxRoot (High / Medium / Low / Compatibility) or call
`set_quality_profile()`. Low disables post FX and glow; Compatibility additionally
disables dithering and falls back to material-level stylization. The core art
direction (banded diffuse, warm shadows, palette) survives every tier.

## UI stays crisp

The post pass runs on a low `CanvasLayer` (`layer = -1`). Draw your HUD on the
default layer (0) or higher and dithering/grade never touch it. For a stricter
separation, route the 3D world through a `SubViewport` and put the Lux
`ColorRect` over only that viewport's texture — see `preset_authoring.md`.

## Godot 4.7 features

Lux takes advantage of three things new in Godot 4.7:

- **AreaLight3D panels.** `LuxAreaLightRig` emits real rectangular area light —
  glowing screens, illuminated signage, deli display cases, canopy panels, light
  through a frosted window — instead of faking it with an emissive material plus
  GI. Assign a `panel_size` (and optionally a `panel_texture`); Lux spawns a
  matching emissive quad so the surface reads visually too. AreaLight3D is a
  Forward+/Mobile feature and a clustered element (it counts against the
  renderer's 512-element budget). On the Compatibility tier the rig automatically
  falls back to an omni approximation, since AreaLight3D isn't supported there.

- **Nearest-neighbor 3D scaling.** A preset can set `render_scale` below 1.0 to
  render 3D at a lower internal resolution for a chunky, low-fidelity look and
  cheaper fill, with `nearest_neighbor_scaling` giving crisp PS1/PS2-style pixels
  via Godot 4.7's nearest 3D scaling mode. *Gas Station Fluorescent* ships tuned
  this way (`render_scale = 0.75`). This is applied to the viewport and is skipped
  on the Low/Compatibility tiers where post FX is off.

- **HDR output awareness.** Godot 4.7 can present true HDR on supported displays,
  which changes how 8-bit-style quantization and dithering read. By default a
  preset keeps `force_sdr_retro_on_hdr = true`, so Lux hard-clamps the post stack
  to the SDR range and the dithered levels reach the screen exactly as authored.
  Turn it off if you want a preset's highlights to use the display's HDR range.

## PS2 hardware lighting (two paths)

Godot 4.4 added native per-vertex shading (the real thing PS2 did), and Lux uses
it. A preset's `vertex_shading_mode` picks how surfaces get their vertex-lit look:

**Native Engine (recommended for authentic multi-light).** Godot shades
StandardMaterial3D surfaces per vertex with the simplified light model. It sees
*every* real-time light, so Lux's fluorescent/streetlight/area rigs all
contribute, integrates with clustering, and casts pixel shadows from the first
DirectionalLight3D. LuxRoot flips `SHADING_MODE_PER_VERTEX` on plain surfaces in
the `lux_materials` group. The trade-off: native vertex shading forces the
engine's Lambertian model and ignores a ShaderMaterial's custom `light()`, so it
can't carry Lux's banding/palette.

**Lux Stylized Gouraud.** Lux's own stylized shader has a `ps2_lighting` path
(added in 0.4.0) that evaluates lighting per vertex *and* keeps the banding,
palette tinting, and Mach-band emphasis. Because a fragment shader can't do true
per-vertex, per-light accumulation, it approximates from the key light Lux pushes
in (the preset's sun). Use this when you want the vertex feel *plus* Lux's
stylization on the same surface.

Controls, on `LuxMaterialProfile` (per surface) or the preset:

- `LuxPreset.vertex_shading_mode` — Off / Native Engine / Lux Stylized Gouraud.
- `ps2_lighting` / `ps2_lighting_global` — Lux stylized blend (0 = per-pixel,
  1 = full Gouraud). `-1` scene-wide leaves each material's own value.
- `ps2_skip_ndl` — flat, angle-blind term for the Lux stylized path.
- `mach_band_emphasis` — sharpen polygon-edge gradients on the Lux stylized path.

In the sample scene, **P** flips the blockout's Lux materials into the stylized
Gouraud path. (Native mode applies to StandardMaterial3D surfaces; the sample's
meshes use Lux ShaderMaterials, so they demonstrate the stylized path.)

## The PS2/CRT look

Beyond dithering and low-res scaling, Lux has two levers aimed squarely at the
sixth-gen console aesthetic:

- **CRT mask.** `crt_mask_type` (Off / Aperture Grille / Shadow Mask) plus
  `crt_mask_strength`, `crt_mask_scale`, and `scanline_strength` simulate a CRT
  phosphor layout — Trinitron-style vertical RGB stripes or staggered dot triads,
  with optional soft scanlines. It runs as a second post pass above the dither
  pass and stays off the UI. Keep strength subtle (0.15–0.25); the point is a
  "played on a TV in 2002" texture, not an eye chart. *Gas Station Fluorescent*
  ships with a light aperture-grille mask and faint scanlines.
- **Flat ambient.** `ambient_mode` (Sky / Flat Color / Disabled) lets a preset
  drop Godot's sky-sampled ambient for a single uniform fill — the honest way
  PS2-era scenes were lit (a key light plus flat ambient, no GI). Flat Color is
  the natural choice for tight interiors like the gas-station and row-home
  presets.

Light-rig colors are grounded in real color temperatures via `LuxColorTemp`
(sodium vapor ~2000K amber, cool-white fluorescent ~4100K with the mercury-spike
green cast, mercury vapor ~5000K), so a scene's fixtures read as the real thing.

## Validate

Press **Validate Scene** in the dock to check for a missing WorldEnvironment,
over-budget dynamic lights or shadow casters, expensive post combinations for the
current tier, and AreaLight3D clustered-element / Compatibility-tier notes.

## The sample scene

`addons/lux/samples/lux_sample_scene.tscn` builds a small blockout with no
external assets. Run it and use:

- **Space** — toggle Lux on/off (before / after)
- **1–5** — jump between the five shipped presets
- **H** — blend to *Mission Goes Hot*
- **C** — back to calm
- **A** — pulse alarm lights
- **D** — ramp the low-health look
