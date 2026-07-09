# Look-dev harness — tune the PS2 pop live

A scene for sitting in the composite loop: load a real building, push Lux's
grade/post knobs in real time, screenshot A/B, and bake the values you like back
into a preset. This is how "it renders" becomes "it looks good" — the iteration
the Q2/PS2 artists did, on your building.

## Setup

1. Files live in `addons/lux/lookdev/` (`lookdev.gd`, `lookdev.tscn`).
2. Put a Patina-art-passed building at `res://walk/gs.patina.glb` (or edit
   `building_path` on the LookDev node). That's the output of `smoke_walk.ps1`.
3. Open `addons/lux/lookdev/lookdev.tscn` and hit **Play Scene** (F6).

If the building path is missing it still runs (empty stage) so you can confirm
the harness works, then point it at a real `.glb`.

## What it does

- Loads the building, applies the Lux **LEVEL** role (stylized material +
  vertex colour), and orbits a camera so you see it lit from all sides.
- Edits a **local copy** of the preset (`LuxRoot.local_override`) — the shipped
  `.tres` is never touched — and re-applies it every keypress so changes show
  instantly.
- Draws a HUD with every knob's current value and its hotkeys.

## Controls

| Keys | Knob | What it does for pop |
| --- | --- | --- |
| Q / A | saturation | the core "pop" dial — PS2 games ran hot |
| W / S | glow intensity | bloom on highlights; sells the warm afternoon |
| E / D | contrast | punch; too much crushes the banding |
| R / F | warmth | push the whole grade warm/cool |
| T / G | palette influence | how hard Lux pulls toward the palette |
| U / J | dither strength | the retro ordered-dither grain |
| I / K | vignette | frames the shot, focuses the eye |
| O / L | fog density | atmosphere / depth separation |
| Z / X | **exposure** | where the tonemap rolls off — how "bright is bright" (HDR pop) |
| C / V | **glow HDR threshold** | *what* blooms: raise it so only bright highlights bleed, not everything |
| 1–5 | jump preset | delco / blue hour / fluorescent / rain / hot |
| Space | Lux on/off | before/after vs the raw baked albedo |
| `[` | capture **before** | writes `lookdev_before.png` |
| `]` | capture **after** | writes `lookdev_after.png` |
| F5 | dump values | prints current pop values to console |
| \\ | reset | back to the preset's shipped values |

## The tuning loop

1. Hit `[` to grab a **before** at the shipped preset.
2. Push saturation (Q), glow (W), contrast (E) toward the pop you want. Watch
   the banding — if the shadows crush or the bands smear, back off contrast.
3. Hit `]` to grab an **after**. Both PNGs are in
   `user://lookdev/` (the console prints the real path).
4. When a look lands, hit **F5** — it dumps the values. Paste them into
   `delco_summer_afternoon.tres` (or a new preset) so the whole game gets the
   look, not just this scene.

## The Halo-3 pop recipe (bright subject vs hazy background)

That "white armor pops against the desert" look is a *grade + separation*
result, not a new feature. Bungie's own tech (HDR two-buffer, aggressive
tonemap, bloom on genuinely-bright highlights, atmospheric scattering for depth)
maps onto knobs you have here:

1. **Exposure (Z/X)** — set where bright rolls off. Nudge up until highlights
   feel like they're pushing past white, then back off a hair.
2. **Glow HDR threshold (C/V)** — raise it so *only* the bright bits bloom
   (armor sheen, sky), not the whole frame. This is the single knob that makes
   bloom read as "HDR pop" instead of "everything is foggy."
3. **Glow intensity (W)** — then dial how much those bright bits bleed.
4. **Contrast (E) + saturation (Q)** — punch and colour. PS2/Halo both ran hot;
   push until the banding is about to crush, then ease off.
5. **Separation** — the real trick: keep the *subject* warm and bright while the
   *background* goes cool and hazy. Push **fog (O)** and let Patina's depth
   recession desaturate distance. Warm-bright-near vs cool-hazy-far is what
   makes the foreground pop, more than any single grade value.

Skip spherical-harmonics baked GI (Halo 3's costly lightmaps) — PS2 had none,
and Lux's banding + baked ambient is the correct era substitute. Chasing SH GI
pulls *away* from the PS2 look toward a 360-era one.

## Baking a look into a preset

The dump looks like:

```
── look-dev pop values ──
  saturation = 1.25
  glow_intensity = 0.55
  contrast = 1.08
  ...
```

Open the target `.tres` in the Inspector and set those fields, or edit the
`.tres` text directly (the field names match). Re-run the harness on `Z` to
confirm the shipped preset now matches what you tuned.

## Notes / limits

- This tunes the **grade/post** pop (saturation, glow, contrast, warmth,
  palette, dither, vignette, fog) — the global look. `band_count` and per-role
  material response live on `LuxMaterialProfile`, tuned per material, not here.
- The "Lux off" toggle applies a neutral preset so you see the raw baked albedo
  (Patina/Zoo vertex colour × flat light) — useful for judging how much of the
  look is bake vs Lux.
- The black-roof question: if it's still black under `delco_summer_afternoon`
  here, it's a Patina roof-classify/normal issue, not a preset one — that's the
  signal to fix it on the Patina side. If the real sun lifts it, leave it.
