extends SceneTree
## The payphone's hood lamp (0.70.0, roadmap 210).
##
##     godot --headless --path lux -s res://tools/payphone_hood_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: a `payphone_hood` anchor builds ONE downlight, cool
## fluorescent, whose range is a ceiling lamp's for the marker's drop and whose
## energy puts PAYPHONE_HOOD_LEVEL on the ground under it at any drop; a marker
## that carries no drop hangs at the default booth's; the preset does not scale
## it; it arrives on the marker path with its payload in the node's `extras`
## (how Zoo 1.89.0 ships it) and by its name alone; a power cut kills it; and
## the control -- the heat lamp -- is untouched. On 0.69.0 the loader has no
## `payphone_hood` row and the first case fails.

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


## What the lamp puts on a floor straight below it at `d`, in the loader's
## own terms: energy times the range window over d squared.
func _floor_value(loader: Script, r: LuxLightRig, d: float) -> float:
	return r.energy * float(loader.range_window(d, r.light_range)) / (d * d)


func _spawned(scene: Node) -> Array:
	var out: Array = []
	var box: Node = scene.get_node_or_null("LuxFixtureLights")
	if box != null:
		for n in box.get_children():
			out.append(n)
	return out


func _main() -> void:
	var loader: Script = load(LOADER)
	var spawner: Script = load(SPAWNER)
	if loader == null or spawner == null:
		push_error("[payphone_hood_selftest] could not load the loader or the spawner")
		quit(2)
		return
	print("payphone hood selftest")
	var drop: float = 2.211
	var ph: Node = loader.rig_for_anchor({"id": "Spawned_payphone_hood", "type": "payphone_hood",
		"drop": drop, "reach": 0.0})
	_check("a payphone_hood anchor builds a rig", ph != null, true)
	if ph == null:
		print("payphone hood selftest: 1 FAIL (no rig, so nothing else can be asked)")
		quit(1)
		return
	_check("a fluorescent-class rig", ph is LuxFluorescentRig, true)
	var r: LuxLightRig = ph.get("rig")
	_near("its range is a ceiling lamp's for its drop", r.light_range,
		float(loader.fluorescent_range(drop)), 1e-6)
	_near("it puts PAYPHONE_HOOD_LEVEL on the ground under it", _floor_value(loader, r, drop),
		float(loader.PAYPHONE_HOOD_LEVEL), 1e-4)
	_near("which is the energy the probe stood (3.0508)", r.energy, 3.0508, 1e-3)
	_check("a downlight: nothing above the lamp's plane", r.downlight_angle_deg > 0.0, true)
	_check("one lamp, no row", [r.count, r.spacing], [1, 0.0])
	_check("not scaled by the preset", r.preset_scaled, false)
	_check("and not named fluorescent, which would scale it anyway",
		String(r.rig_name).to_lower().contains("fluorescent"), false)
	_check("steady", [r.flicker_amount, r.failing_kind], [0.0, 0])
	_check("cool fluorescent", r.light_color, LuxColorTemp.cool_fluorescent())
	# a taller booth's lamp hangs higher and is solved for the same ground
	var tall: Node = loader.rig_for_anchor({"id": "tall", "type": "payphone_hood", "drop": 3.131})
	var rt: LuxLightRig = tall.get("rig")
	_near("a taller booth: the same ground value", _floor_value(loader, rt, 3.131),
		float(loader.PAYPHONE_HOOD_LEVEL), 1e-4)
	_check("from more energy", rt.energy > r.energy, true)
	# no drop on the marker: the default booth's
	var bare: Node = loader.rig_for_anchor({"id": "bare", "type": "payphone_hood", "drop": 0.0})
	_near("the default booth's drop is Zoo 1.89.0's", float(loader.PAYPHONE_DEFAULT_DROP), drop, 1e-9)
	_near("a marker with no drop hangs there", (bare.get("rig") as LuxLightRig).energy, r.energy, 1e-6)
	# the control
	var hl: Node = loader.rig_for_anchor({"id": "Spawned_heat_lamp", "type": "heat_lamp", "drop": 0.0})
	_near("the heat lamp is untouched", (hl.get("rig") as LuxLightRig).energy,
		float(loader.FLUORESCENT_ENERGY) * float(loader.HEAT_LAMP_LEVEL), 1e-6)
	# a LuxRoot FIRST, so the rigs register their lamps with it at ready and a
	# power cut can reach them (the heat lamp selftest's order)
	var root := LuxRoot.new()
	get_root().add_child(root)
	await process_frame
	get_root().add_child(ph)
	await process_frame
	var lamp: Light3D = _lamp(ph)
	_check("the rig spawned its lamp", lamp != null, true)
	if lamp != null:
		_check("a spot", lamp is SpotLight3D, true)
		_near("carrying the energy", lamp.light_energy, r.energy, 1e-6)
		_near("pointing straight down", (-lamp.global_transform.basis.z).dot(Vector3.DOWN), 1.0, 1e-4)
		(ph as LuxFluorescentRig).set_energy_scale(6.0)
		_near("a night preset's fluorescent scale leaves it alone", lamp.light_energy, r.energy, 1e-6)
	# the marker path, as Zoo 1.89.0 ships it: the payload in `extras`
	var scene := Node3D.new()
	var mk := Node3D.new()
	mk.name = "LuxEmit_payphone_hood"
	mk.set_meta(&"extras", {"lux_type": "payphone_hood", "lux_drop": 3.131})
	scene.add_child(mk)
	get_root().add_child(scene)
	mk.global_position = Vector3(34.273, 2.3084, -2.075)
	var res: Dictionary = spawner.spawn(scene)
	_check("the spawner makes one lamp of the marker", int(res.get("count", 0)), 1)
	_check("nothing skipped", (res.get("skipped", []) as Array).size(), 0)
	var spawned: Array = _spawned(scene)
	_check("one rig under the container", spawned.size(), 1)
	if spawned.size() == 1:
		var sr: LuxLightRig = (spawned[0] as Node).get("rig")
		_near("solved from the marker's drop", sr.energy, rt.energy, 1e-6)
		_near("standing on the marker", (spawned[0] as Node3D).global_position.distance_to(mk.global_position),
			0.0, 1e-4)
	# and by its name alone, as Blender may dedupe it (`.001` -> `_001`)
	var scene2 := Node3D.new()
	var mk2 := Node3D.new()
	mk2.name = "LuxEmit_payphone_hood_001"
	scene2.add_child(mk2)
	get_root().add_child(scene2)
	var res2: Dictionary = spawner.spawn(scene2)
	_check("a deduped name with no payload still spawns", int(res2.get("count", 0)), 1)
	var spawned2: Array = _spawned(scene2)
	if spawned2.size() == 1:
		_near("at the default booth's drop", ((spawned2[0] as Node).get("rig") as LuxLightRig).energy,
			(bare.get("rig") as LuxLightRig).energy, 1e-6)
	# the power cut
	root.set_fixtures_powered(false)
	await process_frame
	if lamp != null:
		_check("a power cut kills it", lamp.visible, false)
	root.set_fixtures_powered(true)
	await process_frame
	if lamp != null:
		_check("and restores it", lamp.visible, true)
	print("payphone hood selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
