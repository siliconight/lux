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
var _dist := 14.0
var _height := 6.0

const PRESETS := [
	&"Delco Summer Afternoon", &"Blue Hour", &"Gas Station Fluorescent",
	&"Heavy Rain", &"Mission Goes Hot",
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
	var packed := load(building_path)
	_building = packed.instantiate() if packed is PackedScene else null
	if _building == null and packed is Mesh:
		var mi := MeshInstance3D.new(); mi.mesh = packed; _building = mi
	if _building:
		add_child(_building)
		# apply the Lux LEVEL role so the stylized material + vertex colour show.
		if ClassDB.class_exists("LuxMaterialApplier") or true:
			LuxMaterialApplier.apply_role(_building, LuxRole.Role.LEVEL,
				_lux.active_preset.get_palette_or_neutral() if _lux.active_preset else null)


func _setup_hud() -> void:
	var ui := CanvasLayer.new(); add_child(ui)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 4)
	ui.add_child(_hud)


func _process(delta: float) -> void:
	_orbit += delta * 0.15
	if _cam:
		_cam.position = Vector3(sin(_orbit) * _dist, _height, cos(_orbit) * _dist)
		_cam.look_at(Vector3.ZERO, Vector3.UP)
	_refresh_hud()


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
	if not (e is InputEventKey and e.pressed and not e.echo):
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
		KEY_SPACE: _toggle_lux()
		KEY_Z: _reset()
		KEY_F5: _dump()
		KEY_BRACKETLEFT: _shot("before")
		KEY_BRACKETRIGHT: _shot("after")
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var idx := e.keycode - KEY_1
			if idx < PRESETS.size():
				_lux.blend_to_preset(PRESETS[idx], 0.4)
				await get_tree().create_timer(0.45).timeout
				_base = _lux.active_preset.duplicate(true)
				_live = _base.duplicate(true)
				_lux.local_override = _live


func _toggle_lux() -> void:
	_lux_on = not _lux_on
	if _lux_on:
		_push()
	else:
		# crude "off": neutral preset so you see the raw baked albedo x flat light
		var neutral := LuxPreset.new()
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
	var img := get_viewport().get_texture().get_image()
	var path := "%s/lookdev_%s.png" % [screenshot_dir, label]
	img.save_png(path)
	print("look-dev: saved %s -> %s" % [label, ProjectSettings.globalize_path(path)])


func _refresh_hud() -> void:
	if _hud == null:
		return
	var p := _live
	_hud.text = "LOOK-DEV — Lux: %s   preset: %s\n" % [
		"ON" if _lux_on else "OFF (raw bake)",
		String(_base.preset_name) if _base else "?"]
	_hud.text += "sat %.2f [Q/A]   glow %.2f [W/S]   contrast %.2f [E/D]\n" % [
		p.saturation, p.glow_intensity, p.contrast]
	_hud.text += "warmth %.2f [R/F]   palette %.2f [T/G]   dither %.2f [U/J]\n" % [
		p.warmth, p.palette_influence, p.dither_strength]
	_hud.text += "vignette %.2f [I/K]   fog %.4f [O/L]\n" % [
		p.vignette_strength, p.fog_density]
	_hud.text += "[1-5] preset   [Space] Lux on/off   '[' before-shot   ']' after-shot   F5 dump   Z reset"
