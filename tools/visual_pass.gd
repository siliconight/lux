extends SceneTree
# [VP] visual pass — rebuilds the SAME stage the headless harness verified
# (fresh bake; does NOT load headless_walk.tscn — re-instancing that scene
# would duplicate rig lamps since rigs _rebuild in _ready), applies presets,
# and saves 1080p screenshots to res://walk/headless/shots/.
# Runs WINDOWED (rendering required): a Godot window will flash for ~15s.
#
# Edit SHOT_LIST to reframe — pos/look are world coords. Known geometry:
# lobby fluoro row y=3.5 z=4.5 (x -12..12), offices y=3.5 z=-6.5,
# vault row y=-0.1 (basement), building roughly 30x22m around origin.

const DIRP: String = "res://walk/headless"
const SHOTS: String = DIRP + "/shots"
const SETTLE_FRAMES: int = 10

const SHOT_LIST: Array = [
	{"name": "01_exterior_wide",    "pos": Vector3(28, 10, 24),     "look": Vector3(0, 2, 0),      "preset": &"Gas Station Fluorescent", "powered": true},
	{"name": "02_lobby_row",        "pos": Vector3(0, 2.2, -3.5),   "look": Vector3(0, 3.2, 4.5),  "preset": &"Gas Station Fluorescent", "powered": true},
	{"name": "03_fixture_closeup",  "pos": Vector3(-9.8, 2.9, 2.8), "look": Vector3(-12, 3.5, 4.5),"preset": &"Gas Station Fluorescent", "powered": true},
	{"name": "04_office_rows",      "pos": Vector3(0, 2.2, 1.0),    "look": Vector3(0, 3.2, -6.5), "preset": &"Gas Station Fluorescent", "powered": true},
	{"name": "05_vault_row",        "pos": Vector3(0, -2.4, -7.0),  "look": Vector3(0, -1.0, 0),   "preset": &"Gas Station Fluorescent", "powered": true},
	{"name": "06_power_cut_lobby",  "pos": Vector3(0, 2.2, -3.5),   "look": Vector3(0, 3.2, 4.5),  "preset": &"Gas Station Fluorescent", "powered": false},
	{"name": "07_power_cut_closeup","pos": Vector3(-9.8, 2.9, 2.8), "look": Vector3(-12, 3.5, 4.5),"preset": &"Gas Station Fluorescent", "powered": false},
	{"name": "08_blue_hour_exterior","pos": Vector3(28, 10, 24),    "look": Vector3(0, 2, 0),      "preset": &"Blue Hour",               "powered": true},
]

func _initialize() -> void:
	_main()

func _log(s: String) -> void:
	print("[VP] " + s)

func _main() -> void:
	await process_frame
	root.size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))

	# ---- locate staged inputs (same rule as the harness) ----------
	var d: DirAccess = DirAccess.open(DIRP)
	if d == null:
		_log("FAIL: cannot open " + DIRP)
		quit(1)
		return
	var shell_path: String = ""
	var fix_path: String = ""
	var lights_path: String = ""
	for f in d.get_files():
		var fl: String = String(f)
		if fl.ends_with(".import"):
			continue
		if fl.ends_with("_fixtures.glb"):
			fix_path = DIRP + "/" + fl
		elif fl.ends_with(".glb"):
			shell_path = DIRP + "/" + fl
		elif fl.ends_with(".lights.json"):
			lights_path = DIRP + "/" + fl
	if fix_path == "" or lights_path == "":
		_log("FAIL: need *_fixtures.glb and *.lights.json in " + DIRP)
		quit(1)
		return

	# ---- rebuild the verified stage --------------------------------
	var stage: Node3D = Node3D.new()
	stage.name = "VisualPass"
	root.add_child(stage)
	if shell_path != "":
		var sps: PackedScene = load(shell_path) as PackedScene
		if sps != null:
			stage.add_child(sps.instantiate())
	var fps_: PackedScene = load(fix_path) as PackedScene
	stage.add_child(fps_.instantiate())

	var lux_root: LuxRoot = LuxRoot.new()
	stage.add_child(lux_root)
	await process_frame

	var bake: Dictionary = LuxLightLoader.bake(lights_path, stage)
	_log("bake: " + str(bake))
	await process_frame
	var bind: Dictionary = lux_root.bind_fixture_emissives(stage)
	_log("bind: " + str(bind))

	var lib: Variant = lux_root.get("_preset_library")
	if typeof(lib) == TYPE_DICTIONARY:
		_log("presets available: " + str((lib as Dictionary).keys()))

	var cam: Camera3D = Camera3D.new()
	cam.fov = 70.0
	stage.add_child(cam)
	cam.current = true

	# ---- shoot ------------------------------------------------------
	var last_preset: StringName = &""
	for s in SHOT_LIST:
		var shot: Dictionary = s
		var preset: StringName = shot["preset"]
		if preset != last_preset:
			lux_root.blend_to_preset(preset, 0.0)
			last_preset = preset
		lux_root.set_fixtures_powered(bool(shot["powered"]))
		cam.look_at_from_position(shot["pos"], shot["look"], Vector3.UP)
		for i in SETTLE_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		var out: String = ProjectSettings.globalize_path(SHOTS + "/" + String(shot["name"]) + ".png")
		var err: int = img.save_png(out)
		_log("shot " + String(shot["name"]) + " -> err=" + str(err))
		lux_root.set_fixtures_powered(true)

	_log("visual pass complete — " + str(SHOT_LIST.size()) + " shots in " + SHOTS)
	quit(0)
