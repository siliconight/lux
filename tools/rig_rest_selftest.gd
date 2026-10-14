extends SceneTree
## A rig at rest before its scene is packed (0.77.0, the factory's roadmap 247).
##
##     godot --headless --path lux -s res://tools/rig_rest_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## A failing or flickering fixture, a failing streetlight and a cycling stage
## light animate from their own clocks whenever they process, and a scene
## packed after some frames of that keeps whatever the clocks had reached: the
## factory's Lux apply awaits seven frames before it packs, and across its cold
## runs 9295 to 9300 eleven lights' `light_energy` differed in every pair. What
## this holds: each rig, driven to a dimmed lamp or a turned colour, answers
## `rest()` with every lamp at what its rebuild gave it, a failing tube's lens
## at its own glow, and its clock at zero. Fails on 0.76.1, which has no
## `rest()`.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const FAILING := "res://addons/lux/runtime/lux_failing.gd"
const STREET := "res://addons/lux/runtime/rigs/lux_streetlight_rig.gd"
const STAGE := "res://addons/lux/runtime/rigs/lux_stage_light_rig.gd"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _within(label: String, got: float, lo: float, hi: float) -> void:
	var ok: bool = got >= lo and got <= hi
	if not ok:
		_fails += 1
	print("  %s %s: %.4f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.4f .. %.4f)" % [lo, hi]])


func _lamps(rig: Node) -> Array[Light3D]:
	var out: Array[Light3D] = []
	for c in rig.get_children():
		if c is Light3D:
			out.append(c)
	return out


## Call `rest()` where the rig has one; say so either way.
func _rest(label: String, rig: Node) -> bool:
	var has: bool = rig.has_method("rest")
	_check(label + " answers rest()", has, true)
	if has:
		rig.call("rest")
	return has


func _main() -> void:
	var loader: Script = load(LOADER)
	var F: Script = load(FAILING)
	var street_script: GDScript = load(STREET)
	var stage_script: GDScript = load(STAGE)
	if loader == null or F == null or street_script == null or stage_script == null:
		push_error("[rig_rest_selftest] could not load the loader, lux_failing.gd or a rig")
		quit(2)
		return
	print("rig rest selftest")

	# --- a failing tube and its own lens -------------------------------------
	var tube: Node = loader.rig_for_anchor({"id": "stockroom_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	var tube_rig: LuxLightRig = tube.get("rig")
	tube_rig.failing_kind = F.STUTTER
	tube_rig.failing_seed = 7
	tube_rig.bake_mode = 0
	get_root().add_child(tube)
	await process_frame
	var tube_lamps: Array[Light3D] = _lamps(tube)
	_check("the tube has a lamp", tube_lamps.size(), 1)
	if tube_lamps.is_empty():
		_finish()
		return
	var lamp: Light3D = tube_lamps[0]
	# what the rebuild gave the lamp -- not what it reads now: a rig that
	# processed through the frame above has already moved off it
	var base_e: float = tube_rig.energy * float(tube.get("energy_scale"))
	var shared := StandardMaterial3D.new()
	shared.resource_name = "M_Troffer_Diffuser"
	shared.emission_enabled = true
	shared.emission_energy_multiplier = 1.86
	var lens := MeshInstance3D.new()
	var lens_mesh := BoxMesh.new()
	lens_mesh.size = Vector3(1.2, 0.02, 0.3)
	lens_mesh.material = shared
	lens.mesh = lens_mesh
	get_root().add_child(lens)
	lens.global_position = lamp.global_position - Vector3(0.0, 0.1, 0.0)
	await process_frame
	tube.call("_bind_lenses")
	var lenses: Array = tube.get("_lenses")
	_check("the tube bound its lens", lenses.size(), 1)
	var drop_t: float = -1.0
	var i: int = 0
	while i < 12000 and drop_t < 0.0:
		if F.level(F.STUTTER, 7, float(i) / 200.0) < 0.9:
			drop_t = float(i) / 200.0
		i += 1
	tube.set("_fail_t", drop_t)
	tube.call("_process", 0.0)
	_within("driven into a drop, the tube's lamp is dim", lamp.light_energy / base_e, 0.0, 0.9)
	if _rest("the tube", tube):
		_within("at rest the lamp is back at its own energy", lamp.light_energy, base_e - 0.0001, base_e + 0.0001)
		if lenses.size() == 1:
			_within("and its lens at its own glow", (lenses[0][2] as BaseMaterial3D).emission_energy_multiplier,
				1.8599, 1.8601)
		_check("and its clock at zero", tube.get("_fail_t"), 0.0)

	# --- a flickering row ------------------------------------------------------
	var row: Node = loader.rig_for_anchor({"id": "office_ceiling", "type": "fluorescent",
		"pos": [20.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 2, "spacing": 2.0}})
	var row_rig: LuxLightRig = row.get("rig")
	row_rig.failing_kind = F.NONE
	row_rig.flicker_amount = 0.4
	row_rig.bake_mode = 0
	get_root().add_child(row)
	await process_frame
	var row_lamps: Array[Light3D] = _lamps(row)
	_check("the row has two lamps", row_lamps.size(), 2)
	if row_lamps.size() == 2:
		var row_base: float = row_rig.energy * float(row.get("energy_scale"))
		# phase 1.0: sin(1) / 2 + sin(3.7) / 2 is 0.156, so the lamps dip 3 %
		row.set("_flicker_phase", 1.0)
		row.call("_process", 0.0)
		_within("mid-flicker the row is dimmed", row_lamps[0].light_energy / row_base, 0.9, 0.995)
		if _rest("the row", row):
			for lamp_r in row_lamps:
				_within("at rest each lamp is at its own energy", lamp_r.light_energy,
					row_base - 0.0001, row_base + 0.0001)
			_check("and the row's clock at zero", row.get("_flicker_phase"), 0.0)

	# --- a cycling streetlight -------------------------------------------------
	var street: Node3D = street_script.new()
	var street_rig := LuxLightRig.new()
	street_rig.energy = 30.0
	street_rig.count = 1
	street_rig.failing_kind = F.CYCLING
	street_rig.failing_seed = 3
	street_rig.bake_mode = 0
	street.set("rig", street_rig)
	get_root().add_child(street)
	await process_frame
	var street_lamps: Array[Light3D] = _lamps(street)
	_check("the pole has a lamp", street_lamps.size(), 1)
	if street_lamps.size() == 1:
		var dark_t: float = -1.0
		var j: int = 0
		while j < 14000 and dark_t < 0.0:
			if F.level(F.CYCLING, 3, float(j) / 200.0) < 0.5:
				dark_t = float(j) / 200.0
			j += 1
		street.set("_fail_t", dark_t)
		street.call("_process", 0.0)
		_within("driven into its cycle's dark, the pole is dim", street_lamps[0].light_energy, 0.0, 15.0)
		if _rest("the pole", street):
			_within("at rest the pole's lamp is at its own energy", street_lamps[0].light_energy, 29.9999, 30.0001)
			_check("and its clock at zero", street.get("_fail_t"), 0.0)

	# --- a cycling stage light -------------------------------------------------
	var stage: Node3D = stage_script.new()
	var stage_rig := LuxLightRig.new()
	stage_rig.count = 2
	stage_rig.energy = 5.0
	stage_rig.bake_mode = 0
	stage.set("rig", stage_rig)
	stage.set("colors", PackedColorArray([Color(1, 0, 0), Color(0, 0, 1)]))
	stage.set("cycle_period_s", 4.0)
	get_root().add_child(stage)
	await process_frame
	var stage_lamps: Array[Light3D] = _lamps(stage)
	_check("the stage rig has two lamps", stage_lamps.size(), 2)
	if stage_lamps.size() == 2:
		# 3.5 s into a 4 s step: half way through the crossfade to the next colour
		stage.set("_t", 3.5)
		stage.call("_process", 0.0)
		_check("mid-cycle the first lamp has turned", stage_lamps[0].light_color != Color(1, 0, 0), true)
		if _rest("the stage rig", stage):
			_check("at rest the first lamp is the first colour", stage_lamps[0].light_color, Color(1, 0, 0))
			_check("and the second the second", stage_lamps[1].light_color, Color(0, 0, 1))
			_check("and its clock at zero", stage.get("_t"), 0.0)
	_finish()


func _finish() -> void:
	print("rig rest selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
