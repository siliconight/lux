extends SceneTree
## The lit store spills out through its storefront onto the pavement (0.57.0).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/storefront_spill_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## Headless has no renderer, so nothing here says the pavement READS lit --
## that was matched in frames on cold run 9104's walk copy (see
## `LuxLightLoader.SPILL_FRAME_MATCH`). What this holds:
##
##   * the level is the room's lit floor, less the glass, at the frame match;
##   * the lamp throws OUT and DOWN: 45 degrees below the rig's local +X,
##     and after `_place` below the anchor's facing in the world -- a spill
##     facing Deli Counter's +X lands on Godot +X, one facing +Y on Godot -Z;
##   * it is a fluorescent to the preset (it scales) and a registered light
##     to the power cut;
##   * the control: a ceiling row's lamp still points straight down, and the
##     type is on the manifest bake, which has the whole anchor.

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


func _vnear(label: String, got: Vector3, want: Vector3, tol: float) -> void:
	var ok := got.distance_to(want) <= tol
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _lamp(rig: Node) -> Light3D:
	for c in rig.get_children():
		if c is Light3D:
			return c
	return null


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[storefront_spill_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("storefront spill selftest")

	# ------------------------------------------------------------ the level
	var floor_v: float = loader.office_floor_value(3.8, 6.0)
	_near("the sales floor's lit floor (drop 3.8, reach 6.0)", floor_v, 0.0716, 5e-4)
	_near("office_floor_value without reach is the old rule", loader.office_floor_value(3.2), 0.0570, 5e-4)
	_near("the spill level: floor x glass x frame match", loader.storefront_spill_level(3.8, 6.0),
		floor_v * 0.88 * 8.4, 1e-5)

	# ------------------------------------------------ the rig, from an anchor
	var a := {"id": "sales_floor_spill_S_0", "type": "storefront_spill",
		"pos": [0.0, 0.0, 3.0], "rot_y": 0.0, "head": 3.0, "drop": 3.8, "reach": 6.0}
	var sp: Node3D = loader.rig_for_anchor(a)
	_check("a spill is a fluorescent rig", sp is LuxFluorescentRig, true)
	get_root().add_child(sp)
	await process_frame
	var lamp := _lamp(sp)
	_check("one spot lamp", lamp is SpotLight3D, true)
	var spot := lamp as SpotLight3D
	_near("its cone is the window's", spot.spot_angle, 45.0, 1e-4)
	_near("its range reaches the ground twice the head out", spot.spot_range, 3.0 * sqrt(5.0), 1e-4)
	var want_e: float = loader.energy_for(loader.storefront_spill_level(3.8, 6.0), 3.0 * sqrt(2.0),
		3.0 * sqrt(5.0))
	_near("its energy puts the level where the axis lands", spot.light_energy, want_e, 1e-3)
	_vnear("it throws out along +X and down, in the rig", -spot.basis.z,
		Vector3(sqrt(0.5), -sqrt(0.5), 0.0), 1e-4)
	_check("the preset scales it", (sp as LuxFluorescentRig).scales_with_preset(), true)
	(sp as LuxFluorescentRig).set_energy_scale(6.0)
	_near("at Delco Night's 6.0", spot.light_energy, want_e * 6.0, 1e-3)

	# ------------------------------------------- the manifest bake's placement
	var world: Array = []
	for rot in [0.0, 90.0]:
		var b := a.duplicate()
		b["rot_y"] = rot
		var n: Node3D = loader.rig_for_anchor(b)
		get_root().add_child(n)
		loader._place(n, b)
		await process_frame
		world.append(-(_lamp(n) as Node3D).global_transform.basis.z.normalized())
	_vnear("facing DC +X throws toward Godot +X and down", world[0],
		Vector3(sqrt(0.5), -sqrt(0.5), 0.0), 1e-4)
	_vnear("facing DC +Y throws toward Godot -Z and down", world[1],
		Vector3(0.0, -sqrt(0.5), -sqrt(0.5)), 1e-4)
	_check("the manifest bake owns the type", loader.MANIFEST_BAKE_TYPES.has("storefront_spill"), true)

	# ------------------------------------------------------ the power cut
	var lighting := LuxLighting.new()
	get_root().add_child(lighting)
	await process_frame
	lighting.register_light(lamp)
	lighting.set_fixtures_powered(false)
	_check("a power cut kills it", lamp.visible, false)
	lighting.set_fixtures_powered(true)
	_check("and power brings it back", lamp.visible, true)

	# ----------------------------------------------------------- the control
	var row: Node3D = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	get_root().add_child(row)
	await process_frame
	_vnear("a ceiling row's lamp still points straight down", -(_lamp(row) as Node3D).basis.z,
		Vector3(0.0, -1.0, 0.0), 1e-4)
	_check("and keeps the rotation it always had", (_lamp(row) as Node3D).rotation_degrees,
		Vector3(-90.0, 0.0, 0.0))

	print("storefront spill selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
