# SkyMint + Lux

How SkyMint (dynamic sky) and Lux (look framework) share one scene. Godot allows
one active `WorldEnvironment` per viewport, and both tools are built to be it —
so the rule is: **SkyMint owns the sky, Lux owns the grade, on one shared
environment.**

## The seam

- **SkyMint** `extends WorldEnvironment`. It builds the `Environment`, sets the
  sky to its cloud/panorama `ShaderMaterial`, drives `time_of_day`, and moves a
  `DirectionalLight3D` sun.
- **Lux** is the look authority. On ready it *adopts* an existing
  `WorldEnvironment` instead of making its own (`ensure_world_environment` now
  searches the scene, not just its children). When the adopted environment is a
  sky provider, Lux **defers the sky** — it skips authoring the sky and writes
  only its grade (tonemap, exposure, fog, glow, brightness/contrast/saturation)
  onto SkyMint's environment.
- Lux already **borrows SkyMint's sun** (`auto_find_skymint`), so the day/night
  sun relights the vertex-lit world and stays multiplayer-consistent.

Detection is dependency-free and duck-typed: Lux treats an environment as
sky-provided when its sky material isn't a `ProceduralSkyMaterial` (SkyMint uses
a `ShaderMaterial`), or when the adopted `WorldEnvironment` carries a `sun_light`
property (SkyMint's signature). No `class_name` coupling; Lux runs fine with no
SkyMint present (it authors its own procedural sky as before).

## Setup

1. Both addons enabled in Project Settings → Plugins.
2. Add a **SkyMint** node to the scene. Assign a `DirectionalLight3D` to its
   **Sun Light** slot.
3. Add a **LuxRoot** with `auto_find_skymint = true` (the default). On play,
   LuxRoot finds SkyMint, borrows its sun, adopts its environment, and defers
   the sky.
4. Pick a Lux preset for the grade and a SkyMint `day_sky`/`time_of_day` for the
   sky. Tune each independently — they compose on the one environment.

To force the behaviour regardless of detection, set `LuxEnvironment.defer_sky =
true` (or `auto_find_skymint = false` to make Lux author its own sky again).

## Who sets what (on the shared Environment)

| Property | Owner |
| --- | --- |
| `sky` / `sky_material` (panorama, clouds) | **SkyMint** |
| `background_mode = BG_SKY` | SkyMint |
| sun direction / energy / day-night | SkyMint (Lux borrows the sun) |
| `tonemap_mode` / `tonemap_exposure` / `tonemap_white` | **Lux** |
| `fog_*` | Lux |
| `glow_*` | Lux |
| `adjustment_*` (brightness/contrast/saturation) | Lux |
| `ambient_light_*` | Lux |

## Notes

- Order matters: SkyMint sets the sky, Lux writes the grade after and never
  touches the sky material when deferring — so neither clobbers the other.
- `fog_sky_affect` on the Lux preset controls how much Lux's fog tints
  SkyMint's sky; keep it low if you want the panorama crisp, raise it to blend
  the horizon into the fog for depth.
- The arcade separation still works: SkyMint's sky is the far backdrop, Lux fog
  + Patina depth wash push the mid-distance toward it, the subject stays punchy.
