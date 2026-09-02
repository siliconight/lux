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

## Bind Zoo's fixture lit-face materials (M_*_Lens / _Diffuser / _Face) when
## this node is ready, so `set_fixtures_powered` drives the GLOW as well as the
## rig lights. Off means the level keeps its emissive faces lit through a power
## cut, which is the pre-0.27.0 behaviour and is almost never what anyone wants
## -- it exists so a project doing its own emissive management can say so.
@export var bind_emissives_on_ready: bool = true

@export_group("Sun Link")
## Track a live DirectionalLight3D as the key light instead of the preset's
## static sun. When set, Lux reads this light's world direction, color, and
## energy every frame and feeds them to the PS2/vertex lighting path — so a
## driven sun (e.g. a SkyMint day/night cycle) relights the vertex-lit world as
## it moves. Leave empty to use the preset sun. See also auto_find_skymint.
@export var sun_light: DirectionalLight3D:
	set(value):
		sun_light = value
		_sun_link_resolved = value != null
## If no sun_light is assigned, look for a SkyMint node in the scene on ready and
## borrow its sun. SkyMint syncs time-of-day across clients, so the borrowed sun
## is automatically consistent in multiplayer. No hard dependency — if SkyMint
## isn't present, Lux falls back to the preset sun.
@export var auto_find_skymint: bool = true

@export_group("Optional Rendering Features")
## Global film emulsion switch -- the player-facing key of TDD section 10.
## Defaults ON so a preset that asks for film gets it; presets ship with
## film_emulsion_enabled false, so this alone changes nothing. Toggling it
## re-applies the current preset and nothing else: no scene reload, no
## WorldEnvironment rebuild, no material or lighting change (section 14).
##
## Placed last in the export list deliberately: it is the only property
## here that is a PLAYER setting rather than an authoring one, and a new
## group inserted mid-list would silently re-parent the property that
## follows it into the wrong inspector section.
@export var film_emulsion_enabled: bool = true:
	set(value):
		film_emulsion_enabled = value
		_push_film_master()

## Raise the viewport to a floating-point 2D render target while film
## emulsion is actually running, and put it back afterwards.
##
## WHY THIS IS NOT JUST A PROJECT SETTING. `rendering/viewport/hdr_2d`
## belongs to the consuming project, and Lux is an addon -- it cannot
## edit the project.godot of every game that installs it. Doing it here
## also scopes the cost to the case that needs it: film is off in every
## shipped preset, so by default this changes nothing at all.
##
## MEASURED BEFORE IT WAS WIRED (2026-09-02, tools/film_render_probe.py):
##   - the target goes 8-bit integer -> floating point, and back, at
##     runtime, in both directions, with no reload;
##   - a 3D scene resolved into it still lands on the SAME values, only
##     more precisely (0.25098/0.50196/0.74902 at 8 bits against
##     0.24915/0.50098/0.74951), NOT on their linearised equivalents
##     (0.05088/0.21404/0.52252). That is the fact this switch depends
##     on: the post stack keys its contrast pivot, palette zones and
##     quantization levels off 0.5, and if the target had gone linear,
##     every one of those thresholds would have moved and every preset
##     would need retuning. They do not move.
##   - it costs +0.043 ms on the post pass at 1080p on an RTX 2060 --
##     0.26% of a 60 fps frame -- and about 7.5 MiB at that resolution.
##
## What it buys is in docs/film_emulsion_phase1_audit.md: at 8-bit output
## the default grain spans three codes, and the TDD's own section 45
## acceptance metric moves 70% between one GPU and another because what
## it measures there is per-channel rounding.
@export var film_manage_hdr_2d: bool = true

# Modules
var _env: LuxEnvironment
var _lighting: LuxLighting
var _post: LuxPostFX

var _quality: LuxQualityProfile
var _current: LuxPreset
var _initialized: bool = false

# Sun link
var _sun_link_resolved: bool = false
var _last_sun_dir := Vector3.ZERO
var _last_sun_col := Color.BLACK
var _last_sun_energy := -1.0

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
	# Resolve the sun link BEFORE building modules. _build_modules() decides
	# whether to manufacture a sun, and it cannot honour a link that has not
	# been worked out yet.
	_resolve_sun_link()
	_build_modules()
	_load_default_library()
	_initialized = true
	set_process(true)
	if apply_on_ready:
		var start := local_override if local_override != null else active_preset
		if start != null:
			apply_preset(start)
	# BINDING HAS TO HAPPEN AT LOAD, WHICH IS WHY IT IS HERE AND NOT IN A
	# PIPELINE DRIVER. Neither half of a bind survives `PackedScene.pack`: the
	# registration is runtime state on this node, and the base energy is
	# `set_meta` on a material owned by an imported GLB, an external resource
	# the packed scene only references. A driver that bound before packing
	# would report a success the shipped scene does not contain.
	#
	# AFTER `_build_modules`, not before: that call REPLACES `_lighting`, and
	# `_emissives` lives on it. Binding first would register into the module
	# that is about to be thrown away -- so an editor script reload, which
	# re-runs this whole function, must re-bind too. It is safe to: the binder
	# only stamps `BASE_META` when it is absent, and `register_emissive`
	# ignores a material it already holds.
	if bind_emissives_on_ready:
		var bound: Dictionary = bind_fixture_emissives()
		print("[lux] %s (searched %s)" % [String(bound.get("msg", "")),
			String(bound.get("search_root", "?"))])


## Resolves which DirectionalLight3D drives the vertex-lighting key. Priority:
## an explicitly assigned sun_light, else (if auto_find_skymint) a SkyMint node's
## sun, else the preset's static sun. No hard dependency on SkyMint — it's found
## duck-typed by class name so Lux compiles and runs without the addon present.
func _resolve_sun_link() -> void:
	if sun_light != null:
		_sun_link_resolved = true
		return
	if not auto_find_skymint:
		_sun_link_resolved = false
		return
	var skymint: Node = _find_skymint()
	if skymint != null and skymint.get(&"sun_light") is DirectionalLight3D:
		sun_light = skymint.get(&"sun_light")
		_sun_link_resolved = sun_light != null


func _find_skymint() -> Node:
	# Duck-typed: match any node that carries a `sun_light` property holding a
	# DirectionalLight3D (SkyMint's public field). We don't check the class name,
	# because get_class() returns the native base ("WorldEnvironment") for script
	# classes — the property is the reliable, dependency-free signal.
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == null:
			continue
		if n != self and "sun_light" in n and n.get(&"sun_light") is DirectionalLight3D:
			return n
		stack.append_array(n.get_children())
	return null


## Assign a sun to track at runtime (e.g. after spawning a SkyMint). Pass null to
## fall back to the preset sun.
func set_sun_light(light: DirectionalLight3D) -> void:
	sun_light = light
	_sun_link_resolved = light != null
	if _current != null:
		_push_material_state(_current)


## Build Lux's module nodes. IDEMPOTENT BY CONSTRUCTION: lux_root is @tool, so
## _ready() -- and therefore this -- runs again on every script reload and scene
## reopen. The module objects below are replaced each time, but the nodes they
## parent onto this LuxRoot are not: they outlive the object that made them, and
## every per-module guard (`if sun != null`, and friends) is an instance
## variable on the object that was just replaced, so it is always null exactly
## when it needed to be set.
##
## Left alone, one LuxRoot accumulated three DirectionalLight3D and three CRT
## post stacks -- three times the preset's key light, and three shadow casters
## whose self-shadowing cross-hatched into a jagged band along every grazing
## surface.
##
## Clearing first is what makes running this N times equal running it once.
## Only DIRECT children of the LuxRoot are touched, and only the node types
## Lux's own modules create. The level's own sun and WorldEnvironment are
## siblings of this node, never children, so Sun Link stays safe.
func _build_modules() -> void:
	for child in get_children():
		if child is DirectionalLight3D or child is CanvasLayer \
				or child is WorldEnvironment or child is LuxEnvironment \
				or child is LuxLighting or child is LuxPostFX:
			remove_child(child)
			child.queue_free()

	_env = LuxEnvironment.new()
	_env.name = &"LuxEnvironment"
	add_child(_env)
	_env.ensure_world_environment(self)
	# If the environment Lux adopted is a sky provider (SkyMint — duck-typed on
	# its sun_light property), defer the sky to it: Lux writes only the grade,
	# SkyMint keeps the panorama/clouds/day-night. auto_find_skymint gates it.
	if auto_find_skymint and _env.world_env != null \
			and "sun_light" in _env.world_env:
		_env.defer_sky = true

	_lighting = LuxLighting.new()
	_lighting.name = &"LuxLighting"
	add_child(_lighting)
	# SUN LINK MEANS DRIVE THE LEVEL'S SUN, NOT ADD ONE BESIDE IT. Without this
	# assignment ensure_sun() manufactures a LuxSun regardless, leaving two
	# DirectionalLight3D in the scene: the one Lot emits and the one Lux adds.
	# Two suns is twice the preset's energy, and two shadow casters at different
	# angles cross-hatch their self-shadowing into a jagged band along every
	# wall-to-floor junction. ensure_sun() already returns early when `sun` is
	# valid, so this is the whole fix.
	if sun_light != null:
		_lighting.sun = sun_light
	_lighting.ensure_sun(self)

	_post = LuxPostFX.new()
	_post.name = &"LuxPostFX"
	add_child(_post)
	_post.ensure_pass(self)
	_post.set_film_emulsion_master_enabled(film_emulsion_enabled)


func _load_default_library() -> void:
	# Register the shipped presets so blend_to_preset() / set_mission_phase()
	# can resolve them by name. Missing files are skipped silently.
	var dir := "res://addons/lux/presets/"
	var files := [
		"delco_summer_afternoon.tres",
		"delco_arcade.tres",
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
	# Typed, not inferred: Dictionary.get returns Variant, and engine-DEFAULT
	# warning config escalates inference-on-Variant to a load-killing parse
	# error — this one line failed the whole script (plus two dependents as
	# compile knock-ons) in Level Factory's clean-project portability check.
	var p: LuxPreset = _preset_library.get(String(preset_name))
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


## TDD section 14/15. Changing this must not reload the scene, the
## WorldEnvironment, materials, the preset, lighting, or gameplay state --
## it re-applies the post stack and stops there.
func set_film_emulsion_enabled(enabled: bool) -> void:
	film_emulsion_enabled = enabled  # the setter does the work


## Set only while THIS node has raised the target, so the restore puts back
## what was there rather than assuming it was off. A project that already
## renders 2D in HDR must not be switched out of it by a preset change.
var _hdr_2d_saved: bool = false
var _hdr_2d_raised: bool = false


## Follows film activity. Called after every post apply, including each
## frame of a blend, so it is written to be idempotent and cheap.
func _sync_film_precision() -> void:
	var vp := get_viewport()
	if vp == null or not ("use_hdr_2d" in vp):
		return  # older engine, or no viewport yet
	var want: bool = (
		film_manage_hdr_2d and _post != null and _post.is_film_active()
	)
	if want and not _hdr_2d_raised:
		_hdr_2d_saved = bool(vp.use_hdr_2d)
		_hdr_2d_raised = true
		if not _hdr_2d_saved:
			vp.use_hdr_2d = true
	elif not want and _hdr_2d_raised:
		_hdr_2d_raised = false
		vp.use_hdr_2d = _hdr_2d_saved


## Leaving a raised target behind would outlive the node that raised it --
## a level that unloads its LuxRoot would keep paying for a format it no
## longer uses, and nothing left in the tree would know to put it back.
func _exit_tree() -> void:
	if _hdr_2d_raised:
		var vp := get_viewport()
		if vp != null and "use_hdr_2d" in vp:
			vp.use_hdr_2d = _hdr_2d_saved
		_hdr_2d_raised = false


func _push_film_master() -> void:
	if _post == null:
		return  # pre-_ready: _build_modules pushes the value when it builds
	if not _post.set_film_emulsion_master_enabled(film_emulsion_enabled):
		return  # unchanged, so there is nothing to re-apply
	if _current != null:
		_post.apply(_current, _quality)
		_sync_film_precision()


func is_film_emulsion_active() -> bool:
	return _post != null and _post.is_film_active()


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


func register_fixture_emissive(mat: BaseMaterial3D) -> void:
	if _lighting != null:
		_lighting.register_emissive(mat)


## Building power on/off: kills every non-alarm rig light and the fixture
## glow bound by bind_fixture_emissives(). Alarm-group lights stay (battery
## strobes). The classic heist beat — cut the power, the block goes dark.
func set_fixtures_powered(on: bool) -> void:
	if _lighting != null:
		_lighting.set_fixtures_powered(on)


## Scan for Zoo fixture lit-face materials (M_*_Lens / _Diffuser / _Face)
## and bind them so set_fixtures_powered drives them. Call once after the
## level (and its fixtures GLBs) loads; safe to call again after re-imports.
## ROOT RESOLUTION IS THE WHOLE RISK IN THIS FUNCTION. It used to fall back to
## `get_tree().current_scene` and then to `self`. In a `godot --headless -s
## driver.gd` run there IS no current scene -- nothing was ever loaded as one --
## so an unqualified call landed on `self`: a LuxRoot with no mesh children,
## zero materials found, `ok: true`, and a level whose glow nothing drives.
## Both of Level Factory's drivers run exactly that way.
##
## `owner` first (the scene this node was saved into), then the parent, then
## current_scene. Every one of those actually contains the fixtures, and the
## chosen root comes back in the result so a count of zero can be told apart
## from a search of nothing -- which is the difference between "this GLB has no
## lit faces" and "we looked in the wrong place".
func bind_fixture_emissives(search_root: Node = null) -> Dictionary:
	var root := search_root
	if root == null:
		root = owner
	if root == null:
		root = get_parent()
	if root == null and get_tree() != null:
		root = get_tree().current_scene
	if root == null:
		root = self
	var res: Dictionary = LuxEmissiveBinder.bind(root, self)
	res["search_root"] = String(root.name)
	return res


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


func _apply_immediate(preset: LuxPreset) -> void:
	_current = preset
	_env.apply(preset, _quality)
	_lighting.apply(preset, _quality)
	_post.apply(preset, _quality)
	_sync_film_precision()
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
	_track_sun_light()
	if _blending:
		_blend_t += delta / _blend_dur
		var k := clampf(_blend_t, 0.0, 1.0)
		var mid := _lerp_preset(_blend_from, _blend_to, k)
		_current = mid
		_env.apply(mid, _quality)
		_lighting.apply(mid, _quality)
		_post.apply(mid, _quality)
		_sync_film_precision()
		_apply_retro_scaling(mid)
		if k >= 1.0:
			_blending = false
			_current = _blend_to
			_push_material_state(_blend_to)
			blend_finished.emit(_blend_to.preset_name)


## Reads the tracked sun each frame and, only when it actually changed, pushes the
## new key direction/color/energy to Lux vertex materials. A static sun costs one
## transform read + three compares per frame and zero uniform writes, so this is
## cheap enough for multiplayer. The look is a pure function of the (already
## synced) light state, so clients stay consistent without any Lux networking.
func _track_sun_light() -> void:
	if not _sun_link_resolved or sun_light == null or not is_instance_valid(sun_light):
		return
	# DirectionalLight3D emits along -Z; direction TO the light is +Z of its basis.
	var dir := sun_light.global_transform.basis.z.normalized()
	var col := sun_light.light_color
	var energy := sun_light.light_energy
	if (
		dir.is_equal_approx(_last_sun_dir)
		and col.is_equal_approx(_last_sun_col)
		and is_equal_approx(energy, _last_sun_energy)
	):
		return
	_last_sun_dir = dir
	_last_sun_col = col
	_last_sun_energy = energy
	_push_sun_to_materials(dir, Vector3(col.r, col.g, col.b) * energy)


func _push_sun_to_materials(key_dir: Vector3, key_col: Vector3) -> void:
	for mi in get_tree().get_nodes_in_group(&"lux_materials"):
		if mi is MeshInstance3D:
			for s in (mi as MeshInstance3D).get_surface_override_material_count():
				var mat := (mi as MeshInstance3D).get_surface_override_material(s)
				if mat is ShaderMaterial:
					var sm := mat as ShaderMaterial
					sm.set_shader_parameter(&"ps2_key_dir", key_dir)
					sm.set_shader_parameter(&"ps2_key_color", key_col)


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

	# Film emulsion. Enablement and mode are switches, not curves, so they
	# snap at the midpoint the way every other switch in this function does;
	# the amplitudes interpolate. Omitting them here is how a blend silently
	# reverts to the script defaults -- this function is exhaustive by
	# contract, and a new preset field that is not listed is a bug.
	p.film_emulsion_enabled = b.film_emulsion_enabled if k >= 0.5 else a.film_emulsion_enabled
	p.grain_mode = b.grain_mode if k >= 0.5 else a.grain_mode
	p.film_grain_strength = lerpf(a.film_grain_strength, b.film_grain_strength, k)
	p.film_chroma_ratio = lerpf(a.film_chroma_ratio, b.film_chroma_ratio, k)
	p.film_grain_fps = lerpf(a.film_grain_fps, b.film_grain_fps, k)
	p.film_grain_scale = lerpf(a.film_grain_scale, b.film_grain_scale, k)
	p.dither_chroma_coherence = lerpf(
		a.dither_chroma_coherence, b.dither_chroma_coherence, k)
	p.dither_luma_scale = lerpf(a.dither_luma_scale, b.dither_luma_scale, k)

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
	# When a live sun is linked (e.g. SkyMint), it owns the key light — use its
	# current direction/color so preset applies and blends don't stomp a moving
	# sun. Otherwise fall back to the preset's static sun.
	var key_dir := _preset_key_dir(preset)
	var key_col := (
		Vector3(preset.sun_color.r, preset.sun_color.g, preset.sun_color.b) * preset.sun_energy
	)
	if _sun_link_resolved and sun_light != null and is_instance_valid(sun_light):
		key_dir = sun_light.global_transform.basis.z.normalized()
		key_col = (
			Vector3(sun_light.light_color.r, sun_light.light_color.g, sun_light.light_color.b)
			* sun_light.light_energy
		)
		_last_sun_dir = key_dir
		_last_sun_col = sun_light.light_color
		_last_sun_energy = sun_light.light_energy
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
			for s in (mi as MeshInstance3D).get_surface_override_material_count():
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
