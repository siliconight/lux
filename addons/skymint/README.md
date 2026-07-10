<p align="center">
  <img src="logo.png" width="180" alt="SkyMint logo">
</p>

<h1 align="center">SkyMint</h1>

<p align="center">Drop-in dynamic skybox for Godot 4 — retro panoramas, fake-volumetric
clouds, a day/night cycle, and client-side multiplayer sync, in one node.</p>

> Full docs, screenshots, and roadmap: **https://github.com/siliconight/skymint**

## Quick start

1. This folder lives at `res://addons/skymint/`. Enable **SkyMint** under
   *Project Settings → Plugins*.
2. Add a **SkyMint** node to your 3D scene — you instantly have a sky.
3. Drag a **DirectionalLight3D** into the node's **Sun Light** slot so your scene
   lighting follows the sun. Press play.
4. Open `examples/demo.tscn` to scrub time of day and swap skyboxes live.

The whole look is driven by `time_of_day` (0–24). Pick `day_sky` / `night_sky`
from 20 retro skyboxes; tune colors via a `SkyMintProfile` or the override
toggles. Leave the profile empty to use the built-in day/night default.

## Multiplayer (client-side, non-deterministic)

The look is a pure function of `time_of_day` + the shared profile, so syncing the
time syncs the whole sky. Clouds drift per client by design.

```gdscript
# automatic:
$SkyMint.sync_enabled = true
$SkyMint.sync_is_server_authority = true

# or manual, through your own netcode:
var state := sky.get_sync_state()   # small Dictionary
sky.apply_sync_state(state)         # eases in smoothly
```

`get_sync_state()` / `apply_sync_state(state, smooth)` ·
`get_sync_bytes()` / `apply_sync_bytes(bytes)` ·
signals `time_changed(time_of_day)`, `state_applied(state)`.

## Credits & licenses

- Cloud shader: **Velvet Katana Studios** (godotshaders.com, *AAA Fake Volumetric Clouds*).
- Retro skyboxes: **Vladislav Zhukov** — CC0, https://vladislavzh.net. The
  `panoramas/` here are baked from that CC0 pack.
- SkyMint glue code: MIT.
