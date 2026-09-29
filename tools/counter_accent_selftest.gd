extends SceneTree
## A store counter's warm accent (0.59.0).
##
##     godot --headless --path lux -s res://tools/counter_accent_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: a `counter_accent` anchor builds one warm downlight at a
## fluorescent's energy and range for its drop; the preset scales it (it has
## to hold against the scaled wash) and a power cut kills it; the controls --
## a bare-bulb pendant still refuses the scale, a fluorescent row still takes
## it -- and it arrives on the marker path, which is how lights ship.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"

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
	if loader == null:
		push_error("[counter_accent_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("counter accent selftest")
	var acc: Node = loader.rig_for_anchor({"id": "sales_floor_counter_accent", "type": "counter_accent",
		"pos": [0.0, -8.5, 3.2], "rot_y": 0.0, "drop": 3.2})
	var bulb: Node = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, 0.0, 3.2], "rot_y": 0.0, "drop": 3.2, "row": {"count": 1, "spacing": 0.0}})
	var row: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	_check("a counter accent is a fluorescent-class rig", acc is LuxFluorescentRig, true)
	get_root().add_child(acc)
	get_root().add_child(bulb)
	get_root().add_child(row)
	await process_frame
	var lamp := _lamp(acc)
	_check("one spot lamp", lamp is SpotLight3D, true)
	if not (lamp is SpotLight3D):
		# nothing below can be measured without it; end rather than error on
		print("counter accent selftest: %d FAILED" % _fails)
		quit(1)
		return
	_near("at a fluorescent's energy", lamp.light_energy, loader.FLUORESCENT_ENERGY, 1e-4)
	_near("with a fluorescent's range for its drop", (lamp as SpotLight3D).spot_range,
		loader.fluorescent_range(3.2), 1e-4)
	_near("a 45-degree pool", (lamp as SpotLight3D).spot_angle, 45.0, 1e-4)
	_check("warm: more red than blue", lamp.light_color.r > lamp.light_color.b, true)
	_check("a steady bulb: no flicker", (acc as LuxFluorescentRig).rig.flicker_amount, 0.0)
	_check("no shadow", lamp.shadow_enabled, false)
	_check("no per-frame work", acc.is_processing(), false)
	_check("the preset scales it", (acc as LuxFluorescentRig).scales_with_preset(), true)
	_check("control: a bare bulb still refuses", (bulb as LuxFluorescentRig).scales_with_preset(), false)
	_check("control: a fluorescent row still takes it", (row as LuxFluorescentRig).scales_with_preset(), true)
	(acc as LuxFluorescentRig).set_energy_scale(6.0)
	_near("at Delco Night's 6.0", lamp.light_energy, loader.FLUORESCENT_ENERGY * 6.0, 1e-4)
	var lighting := LuxLighting.new()
	get_root().add_child(lighting)
	await process_frame
	lighting.register_light(lamp)
	lighting.set_fixtures_powered(false)
	_check("a power cut kills it", lamp.visible, false)
	lighting.set_fixtures_powered(true)
	# the marker path, which is how lights ship
	var level := Node3D.new()
	get_root().add_child(level)
	var mk := Node3D.new()
	mk.name = "LuxEmit_counter_accent"
	mk.set_meta(&"extras", {"lux_type": "counter_accent", "lux_anchor_id": "sales_floor_counter_accent",
		"lux_slot": 0, "lux_drop": 3.2})
	level.add_child(mk)
	var res: Dictionary = LuxFixtureSpawner.spawn(level)
	_check("the spawner makes it from a marker", int(res.get("count", 0)), 1)
	print("counter accent selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
