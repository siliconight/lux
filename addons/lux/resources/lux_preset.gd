@tool
class_name LuxPreset
extends Resource
## A complete Lux render look: environment, sun, grade, fog, glow, dithering,
## post finish, palette, and basic material response. Apply through LuxRoot.

@export var preset_name: StringName = &"Untitled"
@export_multiline var description: String = ""

@export_group("Sky")
@export var sky_top_color: Color = Color(0.28, 0.46, 0.72)
@export var sky_horizon_color: Color = Color(0.78, 0.72, 0.62)
@export var ground_color: Color = Color(0.28, 0.24, 0.2)
@export_range(0.0, 2.0) var sky_energy: float = 1.0

@export_group("Sun / Moon")
@export var sun_enabled: bool = true
@export_range(-10.0, 90.0) var sun_elevation_deg: float = 35.0
@export_range(0.0, 360.0) var sun_azimuth_deg: float = 200.0
@export var sun_color: Color = Color(1.0, 0.95, 0.85)
@export_range(0.0, 8.0) var sun_energy: float = 1.2
@export var sun_shadows: bool = true

@export_group("Ambient")
## Sky = gather ambient from the sky (softer, modern). Flat Color = a single
## uniform ambient fill with no directional/GI cues — the honest PS2-era look,
## where scenes were lit by a key light plus flat ambient. Disabled = no ambient.
@export_enum("Sky", "Flat Color", "Disabled") var ambient_mode: int = 0
@export var ambient_color: Color = Color(0.55, 0.55, 0.6)
@export_range(0.0, 4.0) var ambient_energy: float = 1.0
## How much the sky contributes when ambient_mode is Sky (0 = pure color).
@export_range(0.0, 1.0) var ambient_sky_contribution: float = 0.5

@export_group("Tonemap & Grade")
@export_enum("Linear", "Reinhard", "Filmic", "ACES") var tonemap_mode: int = 2
@export_range(0.25, 4.0) var exposure: float = 1.0
@export_range(1.0, 16.0) var tonemap_white: float = 6.0
@export_range(0.5, 2.0) var brightness: float = 1.0
@export_range(0.5, 2.0) var contrast: float = 1.0
@export_range(0.0, 2.0) var saturation: float = 1.0
## Positive = warm (orange), negative = cool (blue). Applied by the post stack.
@export_range(-1.0, 1.0) var warmth: float = 0.0

@export_group("Fog")
@export var fog_enabled: bool = true
@export var fog_color: Color = Color(0.7, 0.68, 0.65)
@export_range(0.0, 0.05, 0.0001) var fog_density: float = 0.004
@export_range(0.0, 1.0) var fog_sky_affect: float = 0.25
@export var fog_height: float = 0.0
@export var fog_height_density: float = 0.0

@export_group("Glow")
@export var glow_enabled: bool = true
@export_range(0.0, 2.0) var glow_intensity: float = 0.4
@export_range(0.0, 1.0) var glow_bloom: float = 0.05
@export_range(0.0, 4.0) var glow_hdr_threshold: float = 1.0

@export_group("Dithering")
@export var dither_enabled: bool = true
@export_range(0.0, 1.0) var dither_strength: float = 0.3
@export_range(2, 64) var color_levels: int = 24
@export_range(1, 8) var dither_cell_size: int = 1
@export var dither_distance_fade: bool = true
@export var dither_fade_start: float = 25.0
@export var dither_fade_end: float = 70.0

@export_group("Retro Scaling")
## Render 3D at a reduced internal resolution for a chunkier, lower-fidelity
## look and cheaper fill (Godot 4.7 viewport 3D scale). 1.0 = native.
@export_range(0.25, 1.0, 0.05) var render_scale: float = 1.0
## Use nearest-neighbor upscaling (Godot 4.7) instead of bilinear, for crisp
## PS1/PS2-style pixels. Only applied when render_scale < 1.0.
@export var nearest_neighbor_scaling: bool = true

@export_group("CRT Mask")
## Simulate a CRT phosphor layout — the "played on a TV in 2002" finish.
## Off / Aperture Grille (Trinitron vertical RGB stripes) / Shadow Mask (dot triads).
@export_enum("Off", "Aperture Grille", "Shadow Mask") var crt_mask_type: int = 0
@export_range(0.0, 1.0) var crt_mask_strength: float = 0.0
@export_range(1.0, 8.0) var crt_mask_scale: float = 3.0
@export_range(0.0, 1.0) var scanline_strength: float = 0.0

@export_group("HDR Output")
## When the display/window is in HDR output mode, dithering and 8-bit-style
## quantization read differently. Enable to let Lux keep the SDR-tuned retro
## look consistent by clamping the post stack's effective range.
@export var force_sdr_retro_on_hdr: bool = true

@export_group("Film Emulsion")
## Photographic film response (see docs/film_emulsion_tdd.md). One of the three
## keys that must all agree before film emulsion runs; the other two are
## LuxQualityProfile.allow_film_emulsion and LuxRoot.film_emulsion_enabled.
## Off by default so every existing preset renders exactly as it did.
@export var film_emulsion_enabled: bool = false
## Which grain the FILM path applies. This property has no effect at all unless
## film emulsion is running -- the baseline post shader keeps using
## `grain_strength` exactly as it always has, so a preset that never asked for
## film cannot be changed by anything in this group.
##
## Off = no grain on the film path. Simple = not available there (TDD section
## 11: never Simple and Film at once), so it reads as Film's own grain.
## Film Emulsion = the density model.
##
## DEFAULT DIVERGES FROM THE TDD ON PURPOSE. TDD section 12 writes
## `grain_mode: int = 0` (Off), but the same section requires "existing presets
## must remain unchanged" and section 34 requires they "continue using Simple
## grain unless explicitly migrated". A `.tres` written before this property
## existed loads with the script default, so Simple is the default that keeps
## the promise. The enum ORDER is the TDD's.
@export_enum("Off", "Simple", "Film Emulsion") var grain_mode: int = 1
## Density amplitude, in stops of transmission (TDD section 27). Much smaller
## than `grain_strength` because it multiplies rather than adds.
##
## RANGE AND DEFAULT BOTH RAISED ~8x. At 0.025 the modulation is about +/-0.75%
## of transmission -- invisible, so anyone enabling film saw nothing. 0.20 is
## where the first person to walk a level and look at it put the knob; one
## judgement, one night scene, and the only look judgement this feature has
## had. A daylight preset may want less.
##
## Section 45 holds throughout: it measures chroma-to-luma noise, and
## `film_chroma_ratio` is a fraction OF the neutral signal, so both scale
## together. Measured 0.1881 at 0.025, 0.1882 at 0.200, 0.1884 at 0.300 --
## inside the hard 0.40 bar and the preferred 0.20 bar at every value.
@export_range(0.0, 0.30, 0.005) var film_grain_strength: float = 0.20
## The emulsion's base-plus-fog floor: how far above pure black the film sits.
##
## THIS IS A LIFT, NOT A NOISE AMPLITUDE, and the first version had it wrong.
## It added noise symmetric about zero AFTER the transmission multiply, onto a
## channel that was already zero -- so the negative half clipped at black and
## only the positive half survived. That is half-wave rectified white noise:
## bright specks on pure black, salt noise, and it reads as digital because no
## emulsion can emit light.
##
## What film does is never be perfectly clear. Unexposed halide still develops
## to a minimum density, so print black is a very dark GREY, and the grain
## modulates that the same way it modulates everything else. So this is added
## BEFORE the density multiply and there is no additive term after it anywhere.
##
## Consequences worth knowing when dialling it:
##  * shadow grain and lifted blacks arrive TOGETHER, which is the coupling
##    real film has -- there is no shadow grain without base fog
##  * how much the lifted black BREATHES is `film_grain_strength`, not this.
##    This sets the level; the density sets the modulation depth. A lift with
##    the density near zero is just milky blacks.
##  * nothing downstream can brighten a pixel out of black, because every
##    operation after this point is a multiply
##  * THE RANGE IS TENTHS OF A PERCENT, NOT PERCENT. The filmify photochemical
##    profile puts projection flare at 0.004 and the black floor at 0.002. A
##    0.03 lift is not a film black, it is a washed one. The first version of
##    this shipped a 0.0-0.10 range and a walk default of 0.06, and it looked
##    exactly as wrong as those numbers are.
##  * the visible grain is NOT this. It is `film_grain_strength` acting on
##    everything that has light in it. This term only stops the void being a
##    dead flat hole in the middle of a grained picture.
@export_range(0.0, 0.02, 0.0005) var film_base_fog: float = 0.0
## How many grain scales are summed. Real emulsion is a DISTRIBUTION of
## crystal sizes -- many fine, fewer large -- and one scale gives every grain
## the same footprint, which is what reads as electronic fizz rather than
## silver. 1 is the original single-scale behaviour, bit for bit.
##
## 2 or 3 is where the field starts to look like crystals moving against each
## other, because each octave carries its own per-frame transform and they do
## not shuffle in lockstep.
## Frame width the grain size is defined against. A crystal is a physical
## object; how many pixels it covers depends on how finely the strip was
## scanned, so grain sized in PIXELS changes character with output resolution
## -- the shipped asset's fine band is 1.42 px across at every resolution,
## which is about 2x too coarse at 720p and 1.45x too fine at 4K against grain
## sized as a fraction of the frame. Too fine is the one that hurts: it lands
## near Nyquist and fizzes.
##
## 2048 matches where the asset already sits (its 1.42 px fine band against a
## real fine crystal's 1.38 px at 2.5K), so it preserves the authored look at
## ~1440p and corrects everywhere else. 0.0 restores pixel-locked grain.
@export var film_grain_ref_width: float = 2048.0
@export_range(1, 3) var film_grain_octaves: int = 1
## Scale step between octaves. 2.1 rather than 2.0 so the octaves do not land
## on a common multiple and beat into a visible lattice.
@export_range(1.5, 4.0, 0.1) var film_grain_lacunarity: float = 2.1
## How much each successive (coarser) octave contributes.
@export_range(0.1, 1.0, 0.05) var film_grain_persistence: float = 0.55
## Chromatic dye variation as a fraction of the neutral signal. Restrained on
## purpose: section 45 requires chroma noise under 0.4x luma noise and prefers
## under 0.2x.
##
## DEFAULT DIVERGES FROM THE TDD, AND THE TDD IS INCONSISTENT WITH ITSELF HERE.
## Section 31 gives the default as "approximately 12%". Measured on the shipped
## grain asset by tools/film_math_probe.py, 0.12 scores 0.2251 on section 45's
## metric -- inside the hard bar, OUTSIDE the preferred one. The relationship is
## very nearly linear (ratio ~= 1.876 x this value), so 0.10 scores about 0.188
## and clears both. An explicit acceptance threshold outranks an approximate
## default, so the shipped default is the one that passes the shipped test.
## The range still reaches 0.25 for anyone who wants the TDD's figure or more.
@export_range(0.0, 0.25, 0.01) var film_chroma_ratio: float = 0.10
## Grain states per second. Photographic cadence, deliberately below frame rate
## (TDD section 24); the grain must not reseed every rendered frame.
@export_range(1.0, 60.0, 1.0) var film_grain_fps: float = 24.0
## Grain tile scale. 1.0 samples the 128px tile at one screen pixel per texel.
## Crystal footprint multiplier, on top of the frame-width scaling.
##
## 1.0 IS NOT A PLACEHOLDER DEFAULT -- IT WAS CHOSEN BY EYE. The tooling
## advice used to be "raise this for clumps, it is usually the fizz knob",
## because coarsening measurably cuts fine high-frequency energy (55% less
## fizz at 3.0 while keeping 93% of the grain body). The one person to walk a
## level and judge it went back to 1.0 and preferred it, alongside a density
## of 0.20.
##
## Both can be true: the fizz measurement was taken when the density was 8x
## too low to see, so it was measuring the texture of something nobody could
## make out. With a visible density the fine grain reads as silver rather than
## sparkle, and the clumps are not needed. Treat the coarsening figures as
## real but as an answer to a question that no longer applies at the shipped
## amplitude.
@export_range(0.5, 3.0, 0.05) var film_grain_scale: float = 1.0
## How much of the quantization decision is SHARED across channels, on the film
## path only (the baseline shader is untouched). Ordered dithering quantizes R,
## G and B independently, and a channel that crosses a level boundary on its own
## is pure chroma noise -- that is the "rainbow" in the retro look, and it comes
## from here rather than from any grain. 1.0 quantizes luminance and scales the
## colour by the ratio, so hue and saturation survive exactly. 0.0 is the
## classic per-channel behaviour.
@export_range(0.0, 1.0, 0.01) var dither_chroma_coherence: float = 1.0
## Luminance level multiplier for the coherent path. One shared decision is
## coarser than three interleaved ones, so the luma levels are scaled up to
## match: measured on a coloured gradient, per-channel at 24 levels gives 36
## luminance steps, and coherent gives 13 at 1x, 26 at 2x, 38 at 3x.
@export_range(1.0, 4.0, 0.05) var dither_luma_scale: float = 3.0

@export_group("Post Finish")
@export_range(0.0, 1.0) var vignette_strength: float = 0.15
@export_range(0.0, 0.3) var grain_strength: float = 0.03
@export_range(0.0, 1.0) var palette_influence: float = 0.3

@export_group("Palette")
@export var palette: LuxPalette

@export_group("Materials")
## Pushed to Lux stylized materials registered in the "lux_materials" group.
@export_range(0.0, 1.0) var default_wetness: float = 0.0
## How surfaces get their vertex-lit PSX look:
##   Off               — per-pixel shading (modern).
##   Native Engine     — Godot 4.4+ native per-vertex shading on StandardMaterial3D
##                       surfaces: real multi-light + shadows, no Lux stylization.
##   Lux Stylized Gouraud — Lux's shader ps2_lighting path: keeps banding/palette,
##                       approximates from the key light only.
## Native is the authentic multi-light path; Stylized keeps Lux's look.
@export_enum("Off", "Native Engine", "Lux Stylized Gouraud") var vertex_shading_mode: int = 0
## Scene-wide PS2 per-vertex (Gouraud) lighting blend for the Lux stylized path.
## -1 = leave each material's own ps2_lighting alone; 0..1 = force all Lux
## materials to this amount. Applied when vertex_shading_mode is Lux Stylized.
@export_range(-1.0, 1.0, 0.01) var ps2_lighting_global: float = -1.0

@export_group("Gameplay")
## Used by pulse_alarm_lights() and the "Mission Goes Hot" family.
@export var alarm_color: Color = Color(1.0, 0.15, 0.22)


func get_palette_or_neutral() -> LuxPalette:
	if palette != null:
		return palette
	var neutral := LuxPalette.new()
	return neutral


## Deep-duplicates this preset so a level can save a local override
## without touching the shared library resource.
func make_override(override_name: StringName) -> LuxPreset:
	var copy: LuxPreset = duplicate(true)
	copy.preset_name = override_name
	return copy
