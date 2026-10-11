extends SceneTree
## A home's dome lights its room from under its bowl (0.75.0).
##
##     godot --headless --path lux -s res://tools/dome_lamp_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: a `dome` anchor (Deli Counter 0.208.0, a home's room) builds
## a rig, warm like the pendant, whose lamp hangs below the deepest bowl Zoo's
## `dome_fixture` builds -- its genome's 0.16 m height under the anchor -- on the
## manifest path and on the marker path, which is how lights ship; its range
## reaches its bay's corner. Controls: a pendant still hangs BULB_LAMP_DROP_M and
## a fluorescent row at FLUORESCENT_MOUNT. What the bake makes of it is measured
## on a level, not here.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
## Zoo's `dome_fixture`: the deepest dome (genome height max 0.16 m) hangs its
## whole height below the anchor. Zoo's number, written down here.
const ZOO_DOME_DEPTH_M := 0.16

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
		push_error("[dome_lamp_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("dome lamp selftest")
	var consts: Dictionary = loader.get_script_constant_map()
	var drop: Variant = consts.get("DOME_LAMP_DROP_M", null)
	var bay: Variant = consts.get("HOME_BAY_M", null)
	_check("the loader names the dome's clearance", drop != null, true)
	_check("the loader names a home's bay", bay != null, true)
	var room_drop: float = 2.9
	var dome: Node = loader.rig_for_anchor({"id": "bedroom_ceiling", "type": "dome",
		"pos": [0.0, 0.0, 2.9], "rot_y": 0.0, "drop": room_drop,
		"row": {"count": 2, "spacing": 7.0}})
	var bulb: Node = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, 0.0, 2.6], "rot_y": 0.0, "drop": 2.6, "row": {"count": 1, "spacing": 0.0}})
	var row: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	if dome == null or bulb == null or row == null:
		print("dome lamp selftest: a rig was not built -- cannot measure")
		quit(2)
		return
	for r in [dome, bulb, row]:
		get_root().add_child(r)
	await process_frame
	var ld := _lamp(dome)
	var lb := _lamp(bulb)
	var lr := _lamp(row)
	if ld == null or lb == null or lr == null:
		print("dome lamp selftest: a rig built no lamp -- cannot measure")
		quit(2)
		return
	_below("a dome's lamp is under its bowl", ld.position.y, -ZOO_DOME_DEPTH_M)
	if drop != null:
		_near("the dome hangs DOME_LAMP_DROP_M down", ld.position.y, -float(drop), 1e-6)
	_check("a dome's light is warm (the pendant's colour)", ld.light_color, lb.light_color)
	if bay != null:
		var half_diag: float = float(bay) / sqrt(2.0)
		var want_range: float = sqrt(room_drop * room_drop + half_diag * half_diag)
		var got_range: float = float(ld.get("omni_range")) if ld is OmniLight3D \
				else float(ld.get("spot_range"))
		_near("the pool reaches the bay's corner", got_range, want_range, 1e-3)
	_near("control: a pendant at BULB_LAMP_DROP_M", lb.position.y,
		-float(loader.BULB_LAMP_DROP_M), 1e-6)
	_near("control: a fluorescent row at FLUORESCENT_MOUNT", lr.position.y,
		float(loader.FLUORESCENT_MOUNT), 1e-6)
	# the marker path, which is how lights ship
	var level := Node3D.new()
	get_root().add_child(level)
	var mk := Node3D.new()
	mk.name = "LuxEmit_dome"
	mk.position = Vector3(0.0, 2.9, 0.0)
	mk.set_meta(&"extras", {"lux_type": "dome", "lux_anchor_id": "bedroom_ceiling",
		"lux_slot": 0, "lux_drop": 2.9})
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
		_below("from a marker, the lamp is under the bowl",
			spawned.global_position.y - mk.global_position.y, -ZOO_DOME_DEPTH_M)
	print("dome lamp selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
