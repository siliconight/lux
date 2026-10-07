extends SceneTree
## A bare bulb's lamp hangs under its glass, not inside it (0.67.0).
##
##     godot --headless --path lux -s res://tools/bulb_lamp_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: a pendant's lamp and a counter accent's (the same
## hardware) hang below the lowest point of Zoo's widest bulb -- 0.15 of its
## 0.08 m radius under the anchor -- on the manifest path and on the marker
## path, which is how lights ship. Controls: a fluorescent row still hangs at
## FLUORESCENT_MOUNT and a wall pack at its rig's LAMP_HANG_M, both already
## clear of their hardware. What the bake makes of it is measured on a level,
## not here (`docs/findings/night_interiors/`).

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
## Zoo's `pendant_fixture`: the widest bulb (genome width max 0.16 m) reaches
## 0.15 of its radius below the anchor. Zoo's number, written down here.
const ZOO_BULB_REACH_M := 0.15 * 0.08

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _below(label: String, got: float, limit: float) -> void:
	var ok := got < limit
	if not ok:
		_fails += 1
	print("  %s %s: %.4f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted below %.4f)" % limit])


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
		push_error("[bulb_lamp_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("bulb lamp selftest")
	# read through the constant map, so a loader without the constant FAILS
	# here rather than stopping the script on an invalid index
	var drop: Variant = loader.get_script_constant_map().get("BULB_LAMP_DROP_M", null)
	_check("the loader names the bulb's clearance", drop != null, true)
	var bulb: Node = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, 0.0, 2.6], "rot_y": 0.0, "drop": 2.6, "row": {"count": 1, "spacing": 0.0}})
	var acc: Node = loader.rig_for_anchor({"id": "sales_floor_counter_accent", "type": "counter_accent",
		"pos": [0.0, -8.5, 2.6], "rot_y": 0.0, "drop": 2.6})
	var row: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	var pack: Node = loader.rig_for_anchor({"id": "ext_wall_pack", "type": "wall_pack",
		"pos": [0.0, 0.0, 3.0], "rot_y": 0.0, "drop": 3.0})
	for r in [bulb, acc, row, pack]:
		get_root().add_child(r)
	await process_frame
	var lb := _lamp(bulb)
	var la := _lamp(acc)
	var lr := _lamp(row)
	var lp := _lamp(pack)
	if lb == null or la == null or lr == null or lp == null:
		print("bulb lamp selftest: a rig built no lamp -- cannot measure")
		quit(2)
		return
	_below("a pendant's lamp is under its glass", lb.position.y, -ZOO_BULB_REACH_M)
	_below("a counter accent's lamp is under its glass", la.position.y, -ZOO_BULB_REACH_M)
	if drop != null:
		_near("the pendant hangs BULB_LAMP_DROP_M down", lb.position.y, -float(drop), 1e-6)
		_near("the accent hangs BULB_LAMP_DROP_M down", la.position.y, -float(drop), 1e-6)
	_near("control: a fluorescent row at FLUORESCENT_MOUNT", lr.position.y,
		float(loader.FLUORESCENT_MOUNT), 1e-6)
	_near("control: a wall pack at its rig's hang", lp.position.y,
		-LuxStreetlightRig.LAMP_HANG_M, 1e-6)
	# the marker path, which is how lights ship
	var level := Node3D.new()
	get_root().add_child(level)
	var mk := Node3D.new()
	mk.name = "LuxEmit_pendant"
	mk.position = Vector3(0.0, 2.6, 0.0)
	mk.set_meta(&"extras", {"lux_type": "pendant", "lux_anchor_id": "vault_bulbs",
		"lux_slot": 0, "lux_drop": 2.6})
	level.add_child(mk)
	var res: Dictionary = LuxFixtureSpawner.spawn(level)
	_check("the spawner makes it from a marker", int(res.get("count", 0)), 1)
	await process_frame
	var spawned: Light3D = null
	for n in level.find_children("*", "Light3D", true, false):
		spawned = n as Light3D
	if spawned == null:
		_fails += 1
		print("  FAIL the marker's rig built no lamp")
	else:
		_below("from a marker, the lamp is under the bulb point",
			spawned.global_position.y - mk.global_position.y, -ZOO_BULB_REACH_M)
	print("bulb lamp selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
