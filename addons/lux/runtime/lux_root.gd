@tool
@icon("res://addons/lux/editor/icons/lux_root.svg")
class_name LuxRoot
extends Node3D
## Primary Lux scene node. Coordinates the environment, lighting, and post-FX
## modules; holds the active preset and quality tier; and exposes the runtime
## API (TDD §11) that gameplay code calls to drive visual state.
##
## Drop one LuxRoot into a level, assign an active_preset (or pick one in the
## dock), and Lux configures the WorldEnvironment, sun, and post stack.

signal preset_applied(preset_name: StringName)
signal blend_finished(preset_name: StringName)

@export_group("Look")
## The preset applied on ready and by the "Apply" dock button.
@export var active_preset: LuxPreset:
	set(value):
		active_preset = value
		if _initialized:
			apply_preset(active_preset)

## Optional level-local override. When set, this is applied instead of
## active_preset, letting a scene tune the shared library preset without
## editing the library resource (TDD §12 "Save a local preset override").
@export var local_override: LuxPreset

@export_group("Quality")
@export_enum("High", "Medium", "Low", "Compatibility") var quality_tier: int = 0:
	set(value):
		quality_tier = value
		_quality = LuxQualityProfile.make_tier(value)
		if _initialized and _current != null:
			apply_preset(_current)

@export_group("Startup")
@export var apply_on_ready: bool = true

# Modules
var _env: LuxEnvironment
var _lighting: LuxLighting
var _post: LuxPostFX

var _quality: LuxQualityProfile
var _current: LuxPreset
var _initialized: bool = false

# Blend state
var _blending: bool = false
var _blend_from: LuxPreset
var _blend_to: LuxPreset
var _blend_t: float = 0.0
var _blend_dur: float = 0.0
var _blend_scratch: LuxPreset

# Mission phase → preset name mapping (overridable by projects).
var mission_phase_presets := {
	&"calm": &"Delco Summer Afternoon",
	&"alert": &"Police Arrival",
	&"combat": &"Mission Goes Hot",
	&"escape": &"Escape Timer",
}

# Registry of named presets available at runtime (library + local).
var _preset_library := {}


func _ready() -> void:
	add_to_group(&"lux_root")
	_quality = LuxQualityProfile.make_tier(quality_tier)
	_build_modules()
	_load_default_library()
	_initialized = true
	set_process(true)
	if apply_on_ready:
		var start := local_override if local_override != null else active_preset
		if start != null:
			apply_preset(start)


func _build_modules() -> void:
	_env = LuxEnvironment.new()
	_env.name = &"LuxEnvironment"
	add_child(_env)
	_env.ensure_world_environment(self)

	_lighting = LuxLighting.new()
	_lighting.name = &"LuxLighting"
	add_child(_lighting)
	_lighting.ensure_sun(self)

	_post = LuxPostFX.new()
	_post.name = &"LuxPostFX"
	add_child(_post)
	_post.ensure_pass(self)


func _load_default_library() -> void:
	# Register the shipped presets so blend_to_preset() / set_mission_phase()
	# can resolve them by name. Missing files are skipped silently.
	var dir := "res://addons/lux/presets/"
	var files := [
		"delco_summer_afternoon.tres",
		"gas_station_fluorescent.tres",
		"blue_hour.tres",
		"heavy_rain.tres",
		"mission_goes_hot.tres",
	]
	for f in files:
		var res := ResourceLoader.load(dir + f)
		if res is LuxPreset:
			_preset_library[String(res.preset_name)] = res
	if active_preset != null:
		_preset_library[String(active_preset.preset_name)] = active_preset
	if local_override != null:
		_preset_library[String(local_override.preset_name)] = local_override


func register_preset(preset: LuxPreset) -> void:
	if preset != null:
		_preset_library[String(preset.preset_name)] = preset


# ---------------------------------------------------------------------------
# Runtime API (TDD §11)
# ---------------------------------------------------------------------------


func apply_preset(preset: LuxPreset, blend_time: float = 0.0) -> void:
	if preset == null:
		return
	if not _initialized:
		# Called from the setter before _ready; defer.
		active_preset = preset
		return
	if blend_time <= 0.0:
		_apply_immediate(preset)
	else:
		_start_blend(_current if _current != null else preset, preset, blend_time)


func blend_to_preset(preset_name: StringName, blend_time: float) -> void:
	var p := _preset_library.get(String(preset_name))
	if p == null:
		push_warning("Lux: preset '%s' not found in library." % preset_name)
		return
	apply_preset(p, blend_time)


func set_mission_phase(phase: StringName, blend_time: float = 1.0) -> void:
	var target_name = mission_phase_presets.get(phase)
	if target_name == null:
		push_warning("Lux: no preset mapped for mission phase '%s'." % phase)
		return
	blend_to_preset(target_name, blend_time)


func set_weather(profile: LuxWeatherProfile, blend_time: float = 5.0) -> void:
	if profile == null or _current == null:
		return
	var target: LuxPreset = _current.make_override(_current.preset_name)
	if profile.override_fog:
		target.fog_enabled = true
		target.fog_color = profile.fog_color
		target.fog_density = profile.fog_density
	if profile.override_grade:
		target.saturation *= profile.saturation_scale
		target.brightness *= profile.brightness_scale
	target.default_wetness = profile.surface_wetness
	apply_preset(target, blend_time)


func set_time_of_day(normalized_time: float) -> void:
	# MVP: nudges sun elevation/warmth on the current preset. Full time-of-day
	# blending across presets is post-MVP (TDD §17).
	if _current == null:
		return
	var t := clampf(normalized_time, 0.0, 1.0)
	var target: LuxPreset = _current.make_override(_current.preset_name)
	# Map 0..1 to a sunrise→noon→sunset→night arc.
	target.sun_elevation_deg = sin(t * PI) * 70.0 - 5.0
	target.warmth = cos(t * TAU) * 0.4
	apply_preset(target, 0.0)


func pulse_alarm_lights(intensity: float, duration: float) -> void:
	if _lighting != null:
		_lighting.pulse_alarm(intensity, duration)


func set_player_damage_intensity(value: float) -> void:
	# Drives a red-shifted, desaturated low-health look on top of the current
	# grade without replacing the preset.
	if _current == null or _post == null:
		return
	var v := clampf(value, 0.0, 1.0)
	var override: LuxPreset = _current.make_override(_current.preset_name)
	override.saturation = lerpf(_current.saturation, 0.35, v)
	override.warmth = lerpf(_current.warmth, 0.5, v)
	override.vignette_strength = lerpf(_current.vignette_strength, 0.55, v)
	_current = override
	_post.apply(override, _quality)


func set_quality_profile(profile: LuxQualityProfile) -> void:
	if profile == null:
		return
	_quality = profile
	quality_tier = profile.tier
	if _current != null:
		_apply_immediate(_current)


func register_lux_light(light: Node3D) -> void:
	if _lighting != null:
		_lighting.register_light(light)


func unregister_lux_light(light: Node3D) -> void:
	if _lighting != null:
		_lighting.unregister_light(light)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


func _apply_immediate(preset: LuxPreset) -> void:
	_current = preset
	_env.apply(preset, _quality)
	_lighting.apply(preset, _quality)
	_post.apply(preset, _quality)
	_apply_retro_scaling(preset)
	_push_material_state(preset)
	_sync_camera_planes()
	preset_applied.emit(preset.preset_name)


## Applies Godot 4.7 viewport 3D scaling + nearest-neighbor upscaling for the
## retro look, and reports HDR-output state so the post stack can stay SDR-tuned.
## These are viewport-wide, non-interpolatable settings, so they snap on apply
## rather than blending. Guarded with has_method/property checks so the addon
## still loads on engines older than 4.7.
func _apply_retro_scaling(preset: LuxPreset) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	# 3D render scale (available since 4.0 as scaling_3d_scale).
	if _quality.allow_post_fx and preset.render_scale < 1.0:
		vp.set(&"scaling_3d_scale", preset.render_scale)
		# Nearest-neighbor 3D scaling mode is Godot 4.7+. The enum value for
		# SCALING_3D_MODE_NEAREST is looked up defensively.
		if preset.nearest_neighbor_scaling:
			var nearest := _nearest_scaling_mode()
			if nearest >= 0:
				vp.set(&"scaling_3d_mode", nearest)
	else:
		vp.set(&"scaling_3d_scale", 1.0)

	# HDR-output awareness: if the window is presenting HDR, keep the SDR-tuned
	# retro grade by telling the post pass to clamp to the SDR range.
	var hdr_active := _is_hdr_output_active()
	if _post != null and _post.has_method(&"set_hdr_output"):
		_post.set_hdr_output(hdr_active and not preset.force_sdr_retro_on_hdr)


func _nearest_scaling_mode() -> int:
	# Viewport.SCALING_3D_MODE_NEAREST — enum on the Viewport class in 4.7.
	# class_get_enum_constants returns [] if the enum/engine build lacks it,
	# so this degrades gracefully on pre-4.7 engines.
	var vals := ClassDB.class_get_enum_constants(&"Viewport", &"Scaling3DMode")
	for const_name in vals:
		if String(const_name).to_upper().ends_with("NEAREST"):
			return ClassDB.class_get_integer_constant(&"Viewport", const_name)
	return -1


func _is_hdr_output_active() -> bool:
	# DisplayServer/Window may expose HDR output state in 4.7; probe defensively.
	var win := get_window()
	if win != null and win.has_method(&"is_hdr_output_enabled"):
		return bool(win.call(&"is_hdr_output_enabled"))
	return false


func _start_blend(from: LuxPreset, to: LuxPreset, dur: float) -> void:
	_blend_from = from
	_blend_to = to
	_blend_dur = maxf(dur, 0.0001)
	_blend_t = 0.0
	_blending = true
	_blend_scratch = LuxPreset.new()


func _process(delta: float) -> void:
	if _lighting != null:
		_lighting.process(delta)
	if _post != null:
		_post.process(delta)
	if _blending:
		_blend_t += delta / _blend_dur
		var k := clampf(_blend_t, 0.0, 1.0)
		var mid := _lerp_preset(_blend_from, _blend_to, k)
		_current = mid
		_env.apply(mid, _quality)
		_lighting.apply(mid, _quality)
		_post.apply(mid, _quality)
		_apply_retro_scaling(mid)
		if k >= 1.0:
			_blending = false
			_current = _blend_to
			_push_material_state(_blend_to)
			blend_finished.emit(_blend_to.preset_name)


# Interpolates the numeric/color look fields between two presets for smooth
# transitions (alarm ramp-ups, weather changes). Discrete fields snap at k>=0.5.
func _lerp_preset(a: LuxPreset, b: LuxPreset, k: float) -> LuxPreset:
	var p := _blend_scratch
	p.preset_name = b.preset_name

	p.sky_top_color = a.sky_top_color.lerp(b.sky_top_color, k)
	p.sky_horizon_color = a.sky_horizon_color.lerp(b.sky_horizon_color, k)
	p.ground_color = a.ground_color.lerp(b.ground_color, k)
	p.sky_energy = lerpf(a.sky_energy, b.sky_energy, k)

	p.sun_enabled = b.sun_enabled if k >= 0.5 else a.sun_enabled
	p.sun_elevation_deg = lerpf(a.sun_elevation_deg, b.sun_elevation_deg, k)
	p.sun_azimuth_deg = lerpf(a.sun_azimuth_deg, b.sun_azimuth_deg, k)
	p.sun_color = a.sun_color.lerp(b.sun_color, k)
	p.sun_energy = lerpf(a.sun_energy, b.sun_energy, k)
	p.sun_shadows = b.sun_shadows if k >= 0.5 else a.sun_shadows

	p.ambient_mode = b.ambient_mode if k >= 0.5 else a.ambient_mode
	p.ambient_color = a.ambient_color.lerp(b.ambient_color, k)
	p.ambient_energy = lerpf(a.ambient_energy, b.ambient_energy, k)
	p.ambient_sky_contribution = lerpf(a.ambient_sky_contribution, b.ambient_sky_contribution, k)

	p.tonemap_mode = b.tonemap_mode if k >= 0.5 else a.tonemap_mode
	p.exposure = lerpf(a.exposure, b.exposure, k)
	p.tonemap_white = lerpf(a.tonemap_white, b.tonemap_white, k)
	p.brightness = lerpf(a.brightness, b.brightness, k)
	p.contrast = lerpf(a.contrast, b.contrast, k)
	p.saturation = lerpf(a.saturation, b.saturation, k)
	p.warmth = lerpf(a.warmth, b.warmth, k)

	p.fog_enabled = b.fog_enabled if k >= 0.5 else a.fog_enabled
	p.fog_color = a.fog_color.lerp(b.fog_color, k)
	p.fog_density = lerpf(a.fog_density, b.fog_density, k)
	p.fog_sky_affect = lerpf(a.fog_sky_affect, b.fog_sky_affect, k)

	p.glow_enabled = b.glow_enabled if k >= 0.5 else a.glow_enabled
	p.glow_intensity = lerpf(a.glow_intensity, b.glow_intensity, k)
	p.glow_bloom = lerpf(a.glow_bloom, b.glow_bloom, k)
	p.glow_hdr_threshold = lerpf(a.glow_hdr_threshold, b.glow_hdr_threshold, k)

	p.dither_enabled = b.dither_enabled if k >= 0.5 else a.dither_enabled
	p.dither_strength = lerpf(a.dither_strength, b.dither_strength, k)
	p.color_levels = int(round(lerpf(a.color_levels, b.color_levels, k)))
	p.dither_cell_size = b.dither_cell_size if k >= 0.5 else a.dither_cell_size
	p.dither_distance_fade = b.dither_distance_fade if k >= 0.5 else a.dither_distance_fade
	p.dither_fade_start = lerpf(a.dither_fade_start, b.dither_fade_start, k)
	p.dither_fade_end = lerpf(a.dither_fade_end, b.dither_fade_end, k)

	p.vignette_strength = lerpf(a.vignette_strength, b.vignette_strength, k)
	p.grain_strength = lerpf(a.grain_strength, b.grain_strength, k)
	p.palette_influence = lerpf(a.palette_influence, b.palette_influence, k)
	p.palette = b.palette if k >= 0.5 else a.palette

	p.crt_mask_type = b.crt_mask_type if k >= 0.5 else a.crt_mask_type
	p.crt_mask_strength = lerpf(a.crt_mask_strength, b.crt_mask_strength, k)
	p.crt_mask_scale = lerpf(a.crt_mask_scale, b.crt_mask_scale, k)
	p.scanline_strength = lerpf(a.scanline_strength, b.scanline_strength, k)

	# Viewport-wide settings can't interpolate — snap them at the midpoint.
	p.render_scale = b.render_scale if k >= 0.5 else a.render_scale
	p.nearest_neighbor_scaling = (
		b.nearest_neighbor_scaling if k >= 0.5 else a.nearest_neighbor_scaling
	)
	p.force_sdr_retro_on_hdr = b.force_sdr_retro_on_hdr if k >= 0.5 else a.force_sdr_retro_on_hdr

	p.default_wetness = lerpf(a.default_wetness, b.default_wetness, k)
	p.vertex_shading_mode = b.vertex_shading_mode if k >= 0.5 else a.vertex_shading_mode
	p.ps2_lighting_global = (b.ps2_lighting_global if k >= 0.5 else a.ps2_lighting_global)
	p.alarm_color = a.alarm_color.lerp(b.alarm_color, k)
	return p


func _push_material_state(preset: LuxPreset) -> void:
	# Push palette + wetness to every registered Lux stylized material so props,
	# characters, and level geometry share the current look (TDD §15 integration).
	# Also push the PS2-lighting key direction derived from the preset's sun, so
	# the per-vertex Gouraud path knows where the key light is.
	var pal := preset.get_palette_or_neutral()
	var key_dir := _preset_key_dir(preset)
	var key_col := (
		Vector3(preset.sun_color.r, preset.sun_color.g, preset.sun_color.b) * preset.sun_energy
	)
	var amb := (
		Vector3(preset.ambient_color.r, preset.ambient_color.g, preset.ambient_color.b)
		* preset.ambient_energy
	)
	# Resolve the effective stylized PS2 amount from the preset. In "Lux Stylized
	# Gouraud" mode a scene-wide value forces the shader path; otherwise leave it.
	var stylized_ps2 := preset.ps2_lighting_global
	if preset.vertex_shading_mode == 2 and stylized_ps2 < 0.0:
		stylized_ps2 = 1.0
	var want_native := preset.vertex_shading_mode == 1
	for mi in get_tree().get_nodes_in_group(&"lux_materials"):
		if mi is MeshInstance3D:
			for s in (mi as MeshInstance3D).get_surface_count():
				var mat := (mi as MeshInstance3D).get_surface_override_material(s)
				if mat is ShaderMaterial:
					var sm := mat as ShaderMaterial
					sm.set_shader_parameter(
						&"palette_shadow", Vector3(pal.shadow.r, pal.shadow.g, pal.shadow.b)
					)
					sm.set_shader_parameter(
						&"palette_highlight",
						Vector3(pal.highlight.r, pal.highlight.g, pal.highlight.b)
					)
					sm.set_shader_parameter(&"wetness", preset.default_wetness)
					sm.set_shader_parameter(&"ps2_key_dir", key_dir)
					sm.set_shader_parameter(&"ps2_key_color", key_col)
					sm.set_shader_parameter(&"ps2_ambient", amb)
					if stylized_ps2 >= 0.0:
						sm.set_shader_parameter(&"ps2_lighting", stylized_ps2)
				elif mat is BaseMaterial3D:
					# Native engine vertex shading (Godot 4.4+) for plain surfaces.
					LuxVertexShading.set_material_per_vertex(mat, want_native)


## World-space direction from surface toward the preset's sun/key light, matching
## LuxLighting's elevation/azimuth convention.
func _preset_key_dir(preset: LuxPreset) -> Vector3:
	var elev := deg_to_rad(preset.sun_elevation_deg)
	var azim := deg_to_rad(preset.sun_azimuth_deg)
	var basis := Basis.IDENTITY
	basis = basis.rotated(Vector3.UP, azim)
	basis = basis.rotated(basis.x, -elev)
	# A DirectionalLight3D emits along -Z of its basis; the direction TO the light
	# is therefore +Z of that basis.
	return basis.z.normalized()


func _sync_camera_planes() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and _post != null:
		_post.set_camera_planes(cam.near, cam.far)


func get_current_preset() -> LuxPreset:
	return _current


func get_quality_profile() -> LuxQualityProfile:
	return _quality
