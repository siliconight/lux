extends SceneTree
## Falsification test for the ceiling downlight and the light-leak meter
## (Lux 0.34.0).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/light_leak_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
## The import pass is not optional, for the reason colocation_selftest.gd
## gives.
##
## THE STAGE is two storeys in boxes: a floor whose top is y = 0, a 0.30 m
## slab from y = 3.0 to 3.3, and a fluorescent marker on the slab's underside
## (drop 3.0), so the lamp hangs at 2.75. Above the slab, a wall face 1.85 m
## to the side and a box resting FLUSH on the slab's top.
##
## Each claim is tested from both sides: the omni the downlight replaced must
## register the leak (or case B passes for the wrong reason); the flush box's
## underside must not count, but the same box lifted 10 cm must (or the
## exposure rule is a blanket refusal); a shadowed light is counted apart.

const SPAWNER := "res://addons/lux/runtime/lux_fixture_spawner.gd"
const METER := "res://addons/lux/runtime/lux_leak_meter.gd"
const LIGHTING := "res://addons/lux/runtime/lux_lighting.gd"
const VALIDATOR := "res://addons/lux/runtime/lux_validator.gd"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _box(parent: Node3D, label: String, size: Vector3, centre: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)
	body.global_position = centre
	return body


func _settle() -> void:
	for i in 3:
		await process_frame
		await physics_frame


func _lamp(n: Node) -> Light3D:
	if n is Light3D:
		return n as Light3D
	for c in n.get_children():
		var f: Light3D = _lamp(c)
		if f != null:
			return f
	return null


func _summary(meter: GDScript, stage: Node) -> Dictionary:
	var m: Dictionary = meter.measure(stage, root.world_3d.direct_space_state, 256, -1)
	return m.summary


func _main() -> void:
	await process_frame
	var Spawner: GDScript = load(SPAWNER) as GDScript
	var Meter: GDScript = load(METER) as GDScript
	var Lighting: GDScript = load(LIGHTING) as GDScript
	if Spawner == null or Meter == null or Lighting == null:
		push_error("light_leak_selftest: lux runtime scripts not found")
		quit(2)
		return
	if not Spawner.can_instantiate() or not Meter.can_instantiate() or not Lighting.can_instantiate():
		push_error("light_leak_selftest: a lux runtime script did not COMPILE. "
			+ "Run `godot --headless --path lux --import` once, then re-run this.")
		quit(2)
		return

	var stage := Node3D.new()
	stage.name = "LeakStage"
	root.add_child(stage)
	_box(stage, "Floor", Vector3(20.0, 0.3, 20.0), Vector3(0.0, -0.15, 0.0))
	_box(stage, "Slab", Vector3(20.0, 0.3, 20.0), Vector3(0.0, 3.15, 0.0))
	var marker := Node3D.new()
	marker.name = "LuxEmit_fluorescent"
	marker.set_meta(&"extras", {"lux_type": "fluorescent", "lux_drop": 3.0})
	stage.add_child(marker)
	marker.global_position = Vector3(0.0, 3.0, 0.0)
	await _settle()

	var spawn: Dictionary = Spawner.spawn(stage)
	await _settle()
	var container: Node = stage.get_node_or_null(NodePath("LuxFixtureLights"))
	if int(spawn.get("count", 0)) != 1 or container == null or container.get_child_count() != 1:
		push_error("light_leak_selftest: expected one spawned rig -- %s" % String(spawn.get("msg", "")))
		quit(2)
		return
	var rig: Node3D = container.get_child(0) as Node3D
	var lamp: Light3D = _lamp(rig)
	if lamp == null:
		push_error("light_leak_selftest: the spawned rig has no light")
		quit(2)
		return

	print("case A -- a ceiling fluorescent is a downward spot, built from the loader's table")
	_check("lamp is a SpotLight3D", lamp is SpotLight3D, true)
	if lamp is SpotLight3D:
		var sp := lamp as SpotLight3D
		_check("half-angle", snappedf(sp.spot_angle, 0.001), 89.0)
		_check("rim (spot_angle_attenuation)", snappedf(sp.spot_angle_attenuation, 0.001), 0.125)
		_check("points straight down (dot)",
			snappedf((-sp.global_transform.basis.z).dot(Vector3.DOWN), 0.001), 1.0)
		_check("culling box stops at the lamp plane (aabb top, local)",
			snappedf(sp.get_aabb().end.z, 0.001), 0.0)
	_check("lamp still hangs 0.25 m under its marker",
		snappedf(marker.global_position.y - lamp.global_position.y, 0.001), 0.25)

	print("case B -- the downlight reaches nothing above its slab")
	var wall := _box(stage, "UpperWall", Vector3(0.3, 3.0, 10.0), Vector3(2.0, 4.8, 0.0))
	await _settle()
	var s_down: Dictionary = _summary(Meter, stage)
	_check("unshadowed lights leaking through a slab", s_down.unshadowed_leaking_slab, 0)

	print("case C -- the omni it replaced DOES register the same wall (the meter can fail)")
	var omni_rig: Resource = (rig.get(&"rig") as Resource).duplicate()
	omni_rig.set(&"downlight_angle_deg", 0.0)
	rig.set(&"rig", omni_rig)
	await _settle()
	lamp = _lamp(rig)
	_check("lamp is now an OmniLight3D", lamp is OmniLight3D, true)
	_check("exactly one light after the rebuild", rig.find_children("*", "Light3D", true, false).size(), 1)
	var s_omni: Dictionary = _summary(Meter, stage)
	_check("unshadowed lights leaking through a slab", s_omni.unshadowed_leaking_slab, 1)

	print("case D -- a box resting flush on the slab is a contact, not a leak")
	# 9 m wide so its SIDES are beyond the 4 m range and only its underside
	# can be reached. The first draft used a 0.5 m box 1.2 m off axis and
	# failed here, correctly: its side faces are in range and really are lit
	# through the slab, so it tested the wrong face.
	wall.free()
	var chair := _box(stage, "FlushBox", Vector3(9.0, 0.5, 9.0), Vector3(0.0, 3.55, 0.0))
	await _settle()
	_check("slab leak with only the flush box above", _summary(Meter, stage).unshadowed_leaking_slab, 0)
	chair.global_position = Vector3(0.0, 3.65, 0.0)
	await _settle()
	_check("the same box lifted 10 cm IS reached", _summary(Meter, stage).unshadowed_leaking_slab, 1)

	print("case E -- the validator reports the meter's numbers, as INFO")
	var Validator: GDScript = load(VALIDATOR) as GDScript
	if Validator == null or not Validator.can_instantiate():
		_check("lux_validator.gd compiles", false, true)
	else:
		var found: Array = Validator.check_light_leak(stage, root.world_3d.direct_space_state, 12)
		_check("one finding", found.size(), 1)
		if found.size() == 1:
			_check("severity INFO", found[0].severity, Validator.Severity.INFO)
			_check("carries the slab count",
				String(found[0].message).contains("1 of 1 unshadowed light(s) reach a surface behind a collider -- 1 through a slab"), true)
		_check("no physics space, no finding", Validator.check_light_leak(stage, null, 12).size(), 0)

	print("case F -- a shadowed light is counted apart")
	lamp.shadow_enabled = true
	var s_sh: Dictionary = _summary(Meter, stage)
	_check("unshadowed leaking", s_sh.unshadowed_leaking, 0)
	_check("shadowed leaking", s_sh.shadowed_leaking, 1)

	print("case G -- two buildings' identically named markers keep their type word")
	var site := Node3D.new()
	site.name = "TwoSites"
	root.add_child(site)
	for i in 2:
		var bld := Node3D.new()
		bld.name = "Building_%d" % i
		site.add_child(bld)
		var sign := Node3D.new()
		sign.name = "LuxEmit_sign"
		bld.add_child(sign)
		sign.global_position = Vector3(float(i) * 30.0, 3.0, 0.0)
	await process_frame
	var spawn2: Dictionary = Spawner.spawn(site)
	await process_frame
	_check("two rigs spawned", int(spawn2.get("count", 0)), 2)
	var c2: Node = site.get_node_or_null(NodePath("LuxFixtureLights"))
	var names: Array = []
	if c2 != null:
		for c in c2.get_children():
			names.append(String(c.name))
	_check("names", names, ["Spawned_sign", "Spawned_sign_dup2"])
	for n in names:
		_check("'%s' ranks with the signs" % n, Lighting.shadow_rank_of_name(String(n).to_lower()), 0)

	print("")
	if _fails == 0:
		print("  light leak selftest ok: the downlight stops the slab leak the omni")
		print("  had, a flush contact is not a leak and a gap is, shadows count apart,")
		print("  duplicate markers keep their type.")
	else:
		print("  light leak selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
