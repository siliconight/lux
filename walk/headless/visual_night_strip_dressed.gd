extends SceneTree
# [VP] night_strip DRESSED visual pass (lot v0.18.2). Staged by
# tools/night_strip_dress.ps1. Same seven framings as the graybox pass for a
# pure A/B — but each store instances its full art stack: the Patina
# procedural shell + Zoo kit modules + Zoo dressing, all at the site
# transforms (sync with specs/night_strip.site.json). Fixtures GLB and the
# merged manifest bake are identical to the graybox run.

const DIRP: String = "res://walk/headless"
const SHOTS: String = DIRP + "/shots"
const SETTLE: int = 10

# Blender (x, y) at -> Godot (x, 0, -y). Sync with night_strip.site.json.
const STORES: Array = [
	{"glbs": ["night_deli.patina.glb", "night_deli_kit.glb", "night_deli_dressing.glb"], "pos": Vector3(-24, 0, -9)},
	{"glbs": ["night_pawn.patina.glb", "night_pawn_kit.glb", "night_pawn_dressing.glb"], "pos": Vector3(0, 0, -9)},
	{"glbs": ["night_auto.patina.glb", "night_auto_kit.glb", "night_auto_dressing.glb"], "pos": Vector3(24, 0, -9)},
]

const SHOT_LIST: Array = [
	{"name": "01_down_street",     "pos": Vector3(-34, 2.2, 0),  "look": Vector3(30, 4, -2),   "preset": &"Blue Hour",                "powered": true},
	{"name": "02_storefront_pawn", "pos": Vector3(0, 1.8, 4.5),  "look": Vector3(0, 2.8, -7),  "preset": &"Blue Hour",                "powered": true},
	{"name": "03_streetlight_row", "pos": Vector3(10, 1.8, 2.0), "look": Vector3(-16, 5.5, 0), "preset": &"Blue Hour",                "powered": true},
	{"name": "04_strip_wide",      "pos": Vector3(0, 12, 26),    "look": Vector3(0, 2, -8),    "preset": &"Blue Hour",                "powered": true},
	{"name": "05_deli_corner",     "pos": Vector3(-30, 1.9, 3),  "look": Vector3(-22, 2.8, -8),"preset": &"Blue Hour",                "powered": true},
	{"name": "06_power_cut",       "pos": Vector3(-34, 2.2, 0),  "look": Vector3(30, 4, -2),   "preset": &"Blue Hour",                "powered": false},
	{"name": "07_fluoro_contrast", "pos": Vector3(0, 1.8, 4.5),  "look": Vector3(0, 2.8, -7),  "preset": &"Gas Station Fluorescent",  "powered": true},
]

func _initialize() -> void:
	_main()

func _log(s: String) -> void:
	print("[VP] " + s)

func _main() -> void:
	await process_frame
	root.size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))

	var d: DirAccess = DirAccess.open(DIRP)
	if d == null:
		_log("FAIL: cannot open " + DIRP)
		quit(1)
		return
	var fix_path: String = ""
	var lights_path: String = ""
	for f in d.get_files():
		var fl: String = String(f)
		if fl.ends_with("_fixtures.glb"):
			fix_path = DIRP + "/" + fl
		elif fl.ends_with(".lights.json"):
			lights_path = DIRP + "/" + fl
	if fix_path == "" or lights_path == "":
		_log("FAIL: need the fixtures glb and the site lights manifest staged")
		quit(1)
		return

	var stage: Node3D = Node3D.new()
	stage.name = "NightStripDressed"
	root.add_child(stage)

	for s in STORES:
		var entry: Dictionary = s
		for g in entry["glbs"]:
			var ps: PackedScene = load(DIRP + "/" + String(g)) as PackedScene
			if ps == null:
				_log("WARN: missing " + String(g))
				continue
			var inst: Node3D = ps.instantiate() as Node3D
			stage.add_child(inst)
			inst.global_position = entry["pos"]

	var fixtures: Node = (load(fix_path) as PackedScene).instantiate()
	fixtures.name = "Fixtures"
	stage.add_child(fixtures)  # site-space build: transforms are world already

	var lux: LuxRoot = LuxRoot.new()
	stage.add_child(lux)
	await process_frame

	var bake: Dictionary = LuxLightLoader.bake(lights_path, stage)
	_log("bake: " + str(bake))
	await process_frame
	var bind: Dictionary = lux.bind_fixture_emissives(stage)
	_log("bind: " + str(bind))

	var cam: Camera3D = Camera3D.new()
	cam.fov = 70.0
	stage.add_child(cam)
	cam.current = true

	var last_preset: StringName = &""
	for s in SHOT_LIST:
		var shot: Dictionary = s
		var preset: StringName = shot["preset"]
		if preset != last_preset:
			lux.blend_to_preset(preset, 0.0)
			last_preset = preset
		lux.set_fixtures_powered(bool(shot["powered"]))
		cam.look_at_from_position(shot["pos"], shot["look"], Vector3.UP)
		for i in SETTLE:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		var err: int = img.save_png(ProjectSettings.globalize_path(SHOTS + "/" + String(shot["name"]) + ".png"))
		_log("shot " + String(shot["name"]) + " err=" + str(err))
		lux.set_fixtures_powered(true)

	_log("night strip DRESSED visual pass complete - " + str(SHOT_LIST.size()) + " shots")
	quit(0)
