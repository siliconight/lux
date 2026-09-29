extends SceneTree
## A fluorescent row that faces a storefront reaches the glass (0.56.0).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/storefront_reach_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## Headless has no renderer, so nothing here says the store READS from the
## street -- that was measured in frames on cold run 9103's walk copy (see
## `LuxLightLoader.fluorescent_range`). What this holds:
##
##   * the rule is unchanged for every lamp without a `reach`: the clubs and
##     `office_floor_value` price against it;
##   * a `reach` measures the same rule to the floor at the glass, under the
##     same clamp;
##   * the SHIPPING path carries it: a marker's `lux_reach` extra reaches the
##     spawned lamp's range, and a marker without one is as before -- the
##     control that proves the check can tell the two apart;
##   * a bare bulb ignores it.

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


func _range(rig: Node) -> float:
	for c in rig.get_children():
		if c is SpotLight3D:
			return (c as SpotLight3D).spot_range
		if c is OmniLight3D:
			return (c as OmniLight3D).omni_range
	return -1.0


func _marker(parent: Node, nm: String, extras: Dictionary) -> void:
	var mk := Node3D.new()
	mk.name = nm
	mk.set_meta(&"extras", extras)
	parent.add_child(mk)


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[storefront_reach_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("storefront reach selftest")

	# ------------------------------------------------------------ the rule
	_near("no reach: drop + 0.75, as before", loader.fluorescent_range(3.8), 4.55, 1e-4)
	_near("reach 0 is the same rule", loader.fluorescent_range(3.8, 0.0), 4.55, 1e-4)
	_near("the clamp's floor, as before", loader.fluorescent_range(2.5), 4.0, 1e-4)
	_near("the sales floor, 6.0 m from its glass: the clamp", loader.fluorescent_range(3.8, 6.0), 7.5, 1e-4)
	_near("2.0 m from the glass: hypot + 0.75", loader.fluorescent_range(3.8, 2.0),
		sqrt(3.8 * 3.8 + 2.0 * 2.0) + 0.75, 1e-4)
	_near("no drop still falls back", loader.fluorescent_range(0.0, 6.0), 4.0, 1e-4)
	_near("the clubs' unit is unmoved (3.2 m)", loader.office_floor_value(3.2), 0.0570, 5e-4)

	# ---------------------------------------------------- the manifest path
	var fl: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "reach": 6.0,
		"row": {"count": 1, "spacing": 0.0}})
	var bulb: Node = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, 0.0, 3.2], "rot_y": 0.0, "drop": 3.2, "reach": 6.0,
		"row": {"count": 1, "spacing": 0.0}})
	get_root().add_child(fl)
	get_root().add_child(bulb)
	# a rig builds its lamps in _ready (fluorescent_scale_selftest measured it)
	await process_frame
	_near("an anchor's reach reaches its lamp", _range(fl), 7.5, 1e-4)
	_near("a bare bulb ignores it", _range(bulb), 4.2, 1e-4)

	# ------------------------------------------------- the shipping path
	var level := Node3D.new()
	get_root().add_child(level)
	_marker(level, "LuxEmit_fluorescent", {"lux_type": "fluorescent",
		"lux_anchor_id": "sales_floor_ceiling", "lux_slot": 0, "lux_drop": 3.8, "lux_reach": 6.0})
	_marker(level, "LuxEmit_fluorescent_001", {"lux_type": "fluorescent",
		"lux_anchor_id": "stockroom_ceiling", "lux_slot": 0, "lux_drop": 3.8})
	var res: Dictionary = LuxFixtureSpawner.spawn(level)
	_check("the spawner made both rigs", int(res.get("count", 0)), 2)
	await process_frame
	var box: Node = level.get_node_or_null(NodePath(LuxFixtureSpawner.CONTAINER))
	var ranges: Array = []
	if box != null:
		for rig in box.get_children():
			ranges.append(snappedf(_range(rig), 0.0001))
	ranges.sort()
	_check("a marker's lux_reach reaches the spawned lamp; one without is as before",
		ranges, [4.55, 7.5])

	print("storefront reach selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
