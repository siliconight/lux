# pc2000 Bake Runbook — LightmapGI spike on gs_corner_station

Goal of the spike: decide whether the **SoF PC2000** family (premium PC
shooter, 1999–2002) lands, using assets you already have. The identity move is
**hard baked light pools with crisp lightmap shadow edges** on the existing
angular geometry — the thing per-vertex lighting can't give you on big planar
walls.

Contract for this family: **the lightmap owns light, Lux owns grade.** Level
materials stay imported per-pixel `StandardMaterial3D` (bilinear + mipmaps —
this is *not* the PS1 family). No stylized role apply on LEVEL.

## Steps (Godot 4.7, in order)

1. **Reimport the building with UV2.** The shipped
   `walk/gs.patina.glb.import` already flips `meshes/light_baking` to `2`
   (Static Lightmaps), so opening the project should reimport automatically.
   Verify: select `walk/gs.patina.glb` → Import dock → **Light Baking =
   Static Lightmaps**, **Lightmap Texel Size = 0.2**. If it shows anything
   else, set it and **Reimport**.
   - Texel 0.2 is the starting value. Blotchy/blocky shadow edges → 0.1
     (4x bake time). Bake too slow → 0.3 for iteration, tighten at the end.

2. **Open `addons/lux/lookdev/pc2000_bake.tscn`.** It ships with the building
   instanced editor-time as `Building`, a `LuxRoot` on the SoF PC2000 preset,
   a `LightmapGI` node (quality Medium, 3 bounces, probes subdiv 8), and the
   pc2000 look-dev camera/script. If Godot complains about the scene's uid on
   first open, let it re-save; nothing else should need touching.

3. **Bake the light rigs, static.** Lux dock → Level Lights → Browse →
   `res://walk/gs.lights.json` → tick **Lightmap static (pc2000)** → **Bake
   Lights**. Status should read `[lightmap static]`. This spawns the usual
   DC-anchor rigs, but every spawned light carries `BAKE_STATIC` and flicker
   is zeroed (a frozen lightmap can't flicker).

4. **Save the scene**, then select the `LightmapGI` node → **Bake Lightmaps**
   (toolbar button). Medium quality on the 2060 should be minutes, not hours,
   at this scale. The bake writes a `.lmbake` next to the scene.

5. **Run the scene.** Same controls as the delco harness: orbit by default,
   Tab to walk, Space toggles the grade on/off (your A/B against raw bake),
   `[` / `]` before/after PNGs, F5 dumps grade values, Z/X exposure.

6. **Judge from a stable framed camera** — orbit mode or an editor preview
   camera, not noclip drift. (Same lesson as the delco milestone: outside the
   building everything reads as flat lit planes.)

## What "landed" looks like

- Crisp shadow edges where walls meet floors and under fixtures — not
  per-vertex gradients.
- Each room reads as one dominant pool + darker corners that stay legible.
- Image is sharp and game-like: no bloom halos, no dither grain, no vignette.
- Fluorescent rooms hold their brightness without blowing to white (the bake
  integrates properly; the old realtime energy-summing problem doesn't apply
  the same way).

## Known gotchas / expected retunes

- **Interior brightness will need a retune.** Rig energies (fluoro 1.0 /
  range 8) were tuned for *realtime summing*. Baked GI integrates
  differently — if interiors read dim, raise the fluorescent energy in the
  spawned rigs and RE-BAKE. Dock sliders and preset edits do NOT touch baked
  output; only a re-bake does. Grade knobs (exposure etc.) still work live.
- **Window/sign anchors use AreaLight3D.** Whether 4.7's lightmapper bakes
  AreaLight3D is unverified here — first thing to check on the walk. If those
  panels contribute nothing to the bake, they'll still light dynamically;
  decide then whether to sub a baked Omni/Spot behind each panel.
- **The preset sun stays realtime** (LuxRoot owns it). Realtime directional +
  baked interiors is a normal mix and period-appropriate. If you later want
  baked sun pools through windows, that's a follow-up (static sun rig).
- **Corner double-darkening.** Patina's vertex-colour form bake multiplies
  *under* the lightmap's own corner occlusion. Mild double-AO in crevices is
  expected — read it as grime for the spike. If it's too heavy, the fix is a
  Patina flat-light bake variant, not a Lux change.
- **Ambient stays low.** The preset's flat ambient (0.35) exists so dynamic
  objects aren't black. Raising it washes the bake's authored darkness — tune
  contrast/exposure instead.

## If the look lands

The productized path is: UV2 + lightmap flags move upstream into the Zoo/DC
GLB export (deterministic Blender-side unwrap instead of import-time
generation), plus a `pc2000` skin profile in Pixelcoat (higher colour counts,
no dither, bilinear in Zoo's skin stage). Lux-side, this spike's pieces —
`apply_role_lightmapped`, rig `bake_mode`, the static loader path, this
preset — are already the runtime contract.
