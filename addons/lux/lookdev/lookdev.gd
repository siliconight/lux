extends Node3D
## Lux look-dev harness — tune the PS2 pop live on a real building.
##
## Loads a Patina-art-passed building .glb, drops a LuxRoot with a starting
## preset, and lets you push the *grade/pop* knobs in real time: saturation,
## glow/bloom, contrast, warmth, palette influence, banding, dither, vignette,
## fog. The point is to sit in the loop the way the Q2/PS2 artists did —
## nudge a value, see the composite change instantly, screenshot A/B.
##
## This edits a LOCAL COPY of the preset (LuxRoot.local_override), so the
## shipped .tres is never touched. When a look lands, read the values off the
## HUD and write them into your preset .tres (or hit F5 to dump them to console).
##
## SETUP
##   1. Save this as addons/lux/lookdev/lookdev.gd
##   2. Make a scene: Node3D root with this script, a Camera3D, a LuxRoot.
##      (or just run make_lookdev_scene() notes in lookdev.md)
##   3. Set building_path to your gs.patina.glb, run.
##
## CONTROLS  (also drawn on screen)
##   Q/A  saturation      W/S  glow intensity    E/D  contrast
##   R/F  warmth          T/G  palette influence  Y/H  band count
##   U/J  dither strength  I/K  vignette          O/L  fog density
##   1-5  jump preset      Space  Lux on/off (before/after)
##   [    A: capture "before"      ]    B: capture "after" (writes both PNGs)
##   F5   dump current pop values to console      Z  reset to preset defaults

@export_file("*.glb") var building_path: String = "res://walk/gs.patina.glb"
@export var start_preset_name: StringName = &"Delco Summer Afternoon"
@export var screenshot_dir: String = "user://lookdev"

@onready var _cam: Camera3D = $Camera3D
var _lux: LuxRoot
var _building: Node3D
var _hud: Label
var _lux_on := true
var _base: LuxPreset          # pristine copy of the starting preset
var _live: LuxPreset          # the edited copy we push each frame
var _orbit := 0.0
var _center := Vector3.ZERO
var _dist := 14.0
var _height := 6.0

# walk mode: WASD + mouselook first-person, to feel the space at eye level.
var _walking := false
var _walk_pos := Vector3.ZERO
var _walk_yaw := 0.0
var _walk_pitch := 0.0
var _walk_speed := 4.0            # m/s, ~human walk
const _EYE_HEIGHT := 1.7          # metres — player eye level
const _MOUSE_SENS := 0.003

const PRESETS := [
	&"Delco Summer Afternoon", &"Delco Arcade", &"Blue Hour",
	&"Gas Station Fluorescent", &"Heavy Rain", &"Mission Goes Hot",
]

# knob -> (min, max, step) for clamping + HUD; keeps edits inside shader ranges.
# All are LuxPreset fields that post_fx.apply() pushes live. (band_count is a
# LuxMaterialProfile field, not a preset field, so it's tuned per-material, not
# here — this harness is for the grade/post pop that reads globally.)
const KNOBS := {
	"saturation": [0.0, 2.0, 0.05], "glow_intensity": [0.0, 2.0, 0.05],
	"contrast": [0.5, 2.0, 0.02], "warmth": [-1.0, 1.0, 0.03],
	"palette_influence": [0.0, 1.0, 0.03],
	"dither_strength": [0.0, 1.0, 0.03], "vignette_strength": [0.0, 1.0, 0.03],
	"fog_density": [0.0, 0.05, 0.001],
	"exposure": [0.25, 4.0, 0.05], "glow_hdr_threshold": [0.0, 4.0, 0.05],
}


func _ready() -> void:
	_find_or_make_lux()
	_load_building()
	_setup_hud()
	DirAccess.make_dir_recursive_absolute(screenshot_dir)

	if _lux.active_preset:
		_base = _lux.active_preset.duplicate(true)
	else:
		_base = LuxPreset.new()
	_live = _base.duplicate(true)
	_lux.local_override = _live
	_push()


func _find_or_make_lux() -> void:
	_lux = get_node_or_null("LuxRoot") as LuxRoot
	if _lux == null:
		# tolerate a scene that forgot the node — make one so the harness runs.
		_lux = LuxRoot.new()
		_lux.name = &"LuxRoot"
		add_child(_lux)
	if _lux.active_preset == null:
		_lux.blend_to_preset(start_preset_name, 0.0)


func _load_building() -> void:
	if not ResourceLoader.exists(building_path):
		push_warning("look-dev: building not found at %s — showing empty stage."
			% building_path)
		return
	var packed: Resource = load(building_path)
	_building = packed.instantiate() if packed is PackedScene else null
	if _building == null and packed is Mesh:
		var mi: MeshInstance3D = MeshInstance3D.new(); mi.mesh = packed; _building = mi
	if _building:
		add_child(_building)
		# apply the Lux LEVEL role so the stylized material + vertex colour show.
		if ClassDB.class_exists("LuxMaterialApplier") or true:
			LuxMaterialApplier.apply_role(_building, LuxRole.Role.LEVEL,
				_lux.active_preset.get_palette_or_neutral() if _lux.active_preset else null)
		_frame_building()


func _frame_building() -> void:
	# Fit the orbit to the building's actual bounds so we circle AROUND it
	# (establishing shot) instead of sweeping through the inside.
	var aabb: AABB = _node_aabb(_building)
	if aabb.size.length() < 0.01:
		return
	_center = aabb.get_center()
	var radius: float = aabb.size.length() * 0.5
	_dist = radius * 2.2           # pull back to fit the whole building
	_height = _center.y + radius * 0.7   # look slightly down on it


func _node_aabb(node: Node) -> AABB:
	# Union of every MeshInstance3D's world-space AABB under `node`.
	var out: AABB = AABB()
	var first := true
	for mi in _all_mesh_instances(node):
		var world: AABB = mi.global_transform * mi.get_aabb()
		if first:
			out = world; first = false
		else:
			out = out.merge(world)
	return out


func _all_mesh_instances(node: Node) -> Array:
	var result: Array = []
	if node is MeshInstance3D:
		result.append(node)
	for c in node.get_children():
		result.append_array(_all_mesh_instances(c))
	return result


func _setup_hud() -> void:
	var ui: CanvasLayer = CanvasLayer.new(); add_child(ui)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 4)
	ui.add_child(_hud)


func _process(delta: float) -> void:
	if _walking:
		_process_walk(delta)
	else:
		_orbit += delta * 0.15
		if _cam:
			_cam.position = _center + Vector3(
				sin(_orbit) * _dist, _height - _center.y, cos(_orbit) * _dist)
			_cam.look_at(_center, Vector3.UP)
	_refresh_hud()


func _process_walk(delta: float) -> void:
	if _cam == null:
		return
	# WASD relative to facing; Shift = sprint, Space/Ctrl = up/down (noclip fly,
	# so you can rise to see rooflines or drop to floor level).
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input.z -= 1.0
	if Input.is_key_pressed(KEY_S): input.z += 1.0
	if Input.is_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_key_pressed(KEY_D): input.x += 1.0
	if Input.is_key_pressed(KEY_E): input.y += 1.0
	if Input.is_key_pressed(KEY_Q): input.y -= 1.0
	var speed: float = _walk_speed * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	# rotate horizontal input by yaw
	var fwd := Vector3(sin(_walk_yaw), 0, cos(_walk_yaw))
	var right := Vector3(cos(_walk_yaw), 0, -sin(_walk_yaw))
	_walk_pos += (right * input.x + fwd * input.z + Vector3.UP * input.y) \
		* speed * delta
	_cam.position = _walk_pos
	var basis: Basis = Basis.from_euler(Vector3(_walk_pitch, _walk_yaw, 0))
	_cam.transform.basis = basis


func _push() -> void:
	# Re-apply the edited preset instantly (blend_time 0) so edits show live.
	if _lux and _lux_on:
		_lux.apply_preset(_live, 0.0)


func _bump(field: String, dir: int) -> void:
	var rng: Array = KNOBS[field]
	var cur: float = _live.get(field)
	var nv: float = clampf(cur + dir * float(rng[2]), float(rng[0]), float(rng[1]))
	_live.set(field, nv)
	_push()


func _unhandled_input(e: InputEvent) -> void:
	# mouse look while walking
	if _walking and e is InputEventMouseMotion:
		_walk_yaw -= e.relative.x * _MOUSE_SENS
		_walk_pitch = clampf(_walk_pitch - e.relative.y * _MOUSE_SENS,
			-1.4, 1.4)
		return
	# mouse wheel = zoom the orbit in/out (orbit mode only)
	if not _walking and e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(2.0, _dist * 0.9)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = _dist * 1.1
	if not (e is InputEventKey and e.pressed and not e.echo):
		return

	# Tab always toggles walk/orbit.
	if e.keycode == KEY_TAB:
		_toggle_walk()
		return
	# Escape drops mouse capture (so you can click out) but stays in walk mode.
	if e.keycode == KEY_ESCAPE and _walking:
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)
		return

	# While walking, WASD/QE/Shift drive movement (handled in _process), so we
	# only listen for the non-conflicting review keys here. The grade-tuning
	# hotkeys (which reuse Q/W/E/A/S/D) are ORBIT-ONLY to avoid clashing.
	if _walking:
		match e.keycode:
			KEY_SPACE: _toggle_lux()
			KEY_BRACKETLEFT: _shot("before")
			KEY_BRACKETRIGHT: _shot("after")
			KEY_F5: _dump()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				_jump_preset(e.keycode - KEY_1)
		return

	match e.keycode:
		KEY_Q: _bump("saturation", 1)
		KEY_A: _bump("saturation", -1)
		KEY_W: _bump("glow_intensity", 1)
		KEY_S: _bump("glow_intensity", -1)
		KEY_E: _bump("contrast", 1)
		KEY_D: _bump("contrast", -1)
		KEY_R: _bump("warmth", 1)
		KEY_F: _bump("warmth", -1)
		KEY_T: _bump("palette_influence", 1)
		KEY_G: _bump("palette_influence", -1)
		KEY_U: _bump("dither_strength", 1)
		KEY_J: _bump("dither_strength", -1)
		KEY_I: _bump("vignette_strength", 1)
		KEY_K: _bump("vignette_strength", -1)
		KEY_O: _bump("fog_density", 1)
		KEY_L: _bump("fog_density", -1)
		KEY_Z: _bump("exposure", 1)
		KEY_X: _bump("exposure", -1)
		KEY_C: _bump("glow_hdr_threshold", 1)
		KEY_V: _bump("glow_hdr_threshold", -1)
		KEY_SPACE: _toggle_lux()
		KEY_UP: _height += 1.5
		KEY_DOWN: _height -= 1.5
		KEY_HOME: _frame_building()
		KEY_BACKSLASH: _reset()
		KEY_F5: _dump()
		KEY_BRACKETLEFT: _shot("before")
		KEY_BRACKETRIGHT: _shot("after")
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			_jump_preset(e.keycode - KEY_1)


func _jump_preset(idx: int) -> void:
	if idx < 0 or idx >= PRESETS.size():
		return
	_lux.blend_to_preset(PRESETS[idx], 0.4)
	await get_tree().create_timer(0.45).timeout
	_base = _lux.active_preset.duplicate(true)
	_live = _base.duplicate(true)
	_lux.local_override = _live


func _toggle_walk() -> void:
	_walking = not _walking
	if _walking:
		# start at the building's near edge, at eye height, facing the centre.
		_walk_pos = _center + Vector3(0, _EYE_HEIGHT - _center.y + 0.5, _dist * 0.5)
		_walk_yaw = PI                    # face -Z toward centre
		_walk_pitch = 0.0
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _toggle_lux() -> void:
	_lux_on = not _lux_on
	if _lux_on:
		_push()
	else:
		# crude "off": neutral preset so you see the raw baked albedo x flat light
		var neutral: LuxPreset = LuxPreset.new()
		neutral.preset_name = &"(Lux off — raw bake)"
		neutral.saturation = 1.0; neutral.contrast = 1.0
		neutral.glow_enabled = false; neutral.dither_enabled = false
		neutral.palette_influence = 0.0; neutral.vignette_strength = 0.0
		_lux.apply_preset(neutral, 0.0)


func _reset() -> void:
	_live = _base.duplicate(true)
	_lux.local_override = _live
	_push()


func _dump() -> void:
	print("── look-dev pop values (paste into your preset .tres) ──")
	for f in KNOBS:
		print("  %s = %s" % [f, _live.get(f)])
	print("───────────────────────────────────────────────────────")


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/lookdev_%s.png" % [screenshot_dir, label]
	img.save_png(path)
	print("look-dev: saved %s -> %s" % [label, ProjectSettings.globalize_path(path)])


func _refresh_hud() -> void:
	if _hud == null:
		return
	if _walking:
		_hud.text = "WALK — WASD move, mouse look, Shift sprint, Q/E down/up\n"
		_hud.text += "Tab → back to orbit   Esc → free mouse   [Space] Lux on/off\n"
		_hud.text += "[1-6] preset   '[' before   ']' after   F5 dump\n"
		_hud.text += "preset: %s" % (String(_base.preset_name) if _base else "?")
		return
	var p: LuxPreset = _live
	_hud.text = "LOOK-DEV — Lux: %s   preset: %s\n" % [
		"ON" if _lux_on else "OFF (raw bake)",
		String(_base.preset_name) if _base else "?"]
	_hud.text += "sat %.2f [Q/A]   glow %.2f [W/S]   contrast %.2f [E/D]\n" % [
		p.saturation, p.glow_intensity, p.contrast]
	_hud.text += "warmth %.2f [R/F]   palette %.2f [T/G]   dither %.2f [U/J]\n" % [
		p.warmth, p.palette_influence, p.dither_strength]
	_hud.text += "vignette %.2f [I/K]   fog %.4f [O/L]\n" % [
		p.vignette_strength, p.fog_density]
	_hud.text += "exposure %.2f [Z/X]   glow-threshold %.2f [C/V]   <- the HDR pop\n" % [
		p.exposure, p.glow_hdr_threshold]
	_hud.text += "[1-6] preset   [Space] Lux on/off   '[' before   ']' after   F5 dump   \\ reset\n"
	_hud.text += "wheel zoom   up/down height   Home reframe   TAB to walk"
