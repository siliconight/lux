extends SceneTree
## The roller grill's heat lamp (0.63.0).
##
##     godot --headless --path lux -s res://tools/heat_lamp_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: a `heat_lamp` anchor builds ONE warm downlight at a
## fraction of a fluorescent's energy in the hood's reach, redder than a
## bulb, not scaled by the preset; it arrives on the marker path (how a
## grill's lamp ships: `LuxEmit_heat_lamp`, no drop, no row); a power cut
## kills it; and the controls -- the counter accent still scales, a
## fluorescent still takes its drop range -- are untouched.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const SPAWNER := "res://addons/lux/runtime/lux_fixture_spawner.gd"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _near(label: String, got: float, want: float, tol: float) -> void:
	var ok := absf(got - want) <= tol
	if not ok:
		_fails += 1
	print("  %s %s: %.4f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.4f +/- %.4f)" % [want, tol]])


func _lamp(rig: Node) -> Light3D:
	for c in rig.get_children():
		if c is Light3D:
			return c
	return null


func _main() -> void:
	var loader: Script = load(LOADER)
	var spawner: Script = load(SPAWNER)
	if loader == null or spawner == null:
		push_error("[heat_lamp_selftest] could not load the loader or the spawner")
		quit(2)
		return
	print("heat lamp selftest")
	var hl: Node = loader.rig_for_anchor({"id": "Spawned_heat_lamp", "type": "heat_lamp",
		"drop": 0.0, "reach": 0.0})
	var acc: Node = loader.rig_for_anchor({"id": "sales_floor_counter_accent", "type": "counter_accent",
		"pos": [0.0, -8.5, 3.2], "rot_y": 0.0, "drop": 3.2})
	var row: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	_check("a heat lamp is a fluorescent-class rig (one downlight)", hl is LuxFluorescentRig, true)
	var r: LuxLightRig = hl.get("rig")
	_near("its energy is HEAT_LAMP_LEVEL of a fluorescent", r.energy,
		loader.FLUORESCENT_ENERGY * loader.HEAT_LAMP_LEVEL, 1e-6)
	_near("its range is the hood, not a drop", r.light_range, loader.HEAT_LAMP_RANGE_M, 1e-6)
	_near("its falloff is the measured one, flatter than the inverse square", r.attenuation, loader.HEAT_LAMP_ATTENUATION, 1e-6)
	_check("and it is a glow, under a fifth of a troffer", r.energy < loader.FLUORESCENT_ENERGY * 0.2, true)
	_check("one lamp, no row", [r.count, r.spacing], [1, 0.0])
	_check("not scaled by the preset", r.preset_scaled, false)
	_check("steady", [r.flicker_amount, r.failing_kind], [0.0, 0])
	var c: Color = r.light_color
	_check("redder than a bulb: r > g > b", c.r > c.g and c.g > c.b, true)
	var bulb: Color = LuxColorTemp.kelvin(LuxColorTemp.INCANDESCENT)
	_check("and redder than the incandescent (less blue per red)", c.b / c.r < bulb.b / bulb.r, true)
	# a LuxRoot FIRST, so the rigs register their lamps with it at ready and
	# a power cut can reach them (the counter accent selftest's order)
	var root := LuxRoot.new()
	get_root().add_child(root)
	await process_frame
	get_root().add_child(hl)
	get_root().add_child(acc)
	get_root().add_child(row)
	await process_frame
	var lamp: Light3D = _lamp(hl)
	_check("the rig spawned its lamp", lamp != null, true)
	if lamp != null:
		_near("the lamp carries the energy", lamp.light_energy, r.energy, 1e-6)
		_check("the lamp is an omni: the buns above the shelf and the dogs below both see it", lamp is OmniLight3D, true)
	# the controls
	_check("the counter accent still scales with the preset", (acc.get("rig") as LuxLightRig).preset_scaled, true)
	_check("a fluorescent still takes its drop range",
		(row.get("rig") as LuxLightRig).light_range > loader.HEAT_LAMP_RANGE_M, true)
	# the marker path: a LuxEmit_heat_lamp empty with no payload
	var scene := Node3D.new()
	var mk := Node3D.new()
	mk.name = "LuxEmit_heat_lamp"
	scene.add_child(mk)
	get_root().add_child(scene)
	mk.global_position = Vector3(1.0, 1.2, -2.0)
	var res: Dictionary = spawner.spawn(scene)
	_check("the spawner makes one lamp of the marker", int(res.get("count", 0)), 1)
	_check("nothing skipped", (res.get("skipped", []) as Array).size(), 0)
	var spawned: Array = []
	for n in scene.get_node("LuxFixtureLights").get_children():
		spawned.append(n)
	_check("one rig under the container", spawned.size(), 1)
	if spawned.size() == 1:
		_check("named for the marker", String(spawned[0].name), "Spawned_heat_lamp")
		_near("standing on the marker", (spawned[0] as Node3D).global_position.distance_to(mk.global_position), 0.0, 1e-4)
	# the power cut
	root.set_fixtures_powered(false)
	await process_frame
	if lamp != null:
		_check("a power cut kills it", lamp.visible, false)
	root.set_fixtures_powered(true)
	await process_frame
	if lamp != null:
		_check("and restores it", lamp.visible, true)
	print("heat lamp selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
