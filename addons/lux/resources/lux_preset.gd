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

@export_group("Post Finish")
@export_range(0.0, 1.0) var vignette_strength: float = 0.15
@export_range(0.0, 0.3) var grain_strength: float = 0.03
@export_range(0.0, 1.0) var palette_influence: float = 0.3

@export_group("Palette")
@export var palette: LuxPalette

@export_group("Materials")
## Pushed to Lux stylized materials registered in the "lux_materials" group.
@export_range(0.0, 1.0) var default_wetness: float = 0.0

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
