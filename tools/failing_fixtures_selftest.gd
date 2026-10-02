extends SceneTree
## Failing fixtures (0.62.0): one bad tube a room, every third streetlight
## cycling, everything else steady.
##
##     godot --headless --path lux -s res://tools/failing_fixtures_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: the model is steady almost always and drops when it
## drops (a stutter sits at 1.0 for 95 % of ten minutes and never below its
## floor; a cycling lamp reaches dark and comes all the way back; a waver
## stays within 5 %); the same seed gives the same answer twice and two seeds
## differ; the loader leaves the old hum at 0 and makes every third pole
## cycle; the spawner picks exactly one lamp an anchor; and a stuttering rig
## in a tree moves its lamp AND the lens nearest it, on an override of its
## own, while a steady rig moves neither. Fails on 0.61.0, which has no
## `LuxFailing` to load.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const SPAWNER := "res://addons/lux/runtime/lux_fixture_spawner.gd"
const FAILING := "res://addons/lux/runtime/lux_failing.gd"

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


func _lamp(rig: Node) -> Light3D:
	for c in rig.get_children():
		if c is Light3D:
			return c
	return null


## Sample a kind at `hz` over `span` seconds: ``{min, max, at_one, drops}``
## where `drops` counts falling edges below 0.9.
func _sample(F: Script, kind: int, seed: int, span: float, hz: float) -> Dictionary:
	var n: int = int(span * hz)
	var lo: float = 1e9
	var hi: float = -1e9
	var ones: int = 0
	var drops: int = 0
	var was_low: bool = false
	for i in n:
		var v: float = F.level(kind, seed, float(i) / hz)
		lo = minf(lo, v)
		hi = maxf(hi, v)
		if v >= 0.999:
			ones += 1
		var low: bool = v < 0.9
		if low and not was_low:
			drops += 1
		was_low = low
	return {"min": lo, "max": hi, "at_one": float(ones) / float(n), "drops": drops}


func _marker(name: String, anchor: String) -> Node3D:
	var m := Node3D.new()
	m.name = name
	m.set_meta("lux_anchor_id", anchor)
	return m


func _main() -> void:
	var loader: Script = load(LOADER)
	var spawner: Script = load(SPAWNER)
	var F: Script = load(FAILING)
	if loader == null or spawner == null or F == null:
		push_error("[failing_fixtures_selftest] could not load the loader, the spawner or lux_failing.gd")
		quit(2)
		return
	print("failing fixtures selftest")

	# --- the model ------------------------------------------------------------
	for seed in [7, 12345, 99991]:
		var st: Dictionary = _sample(F, F.STUTTER, seed, 600.0, 120.0)
		var period: float = F.stutter_period(seed)
		_within("stutter %d: period in 4..15 s" % seed, period, 4.0, 15.0)
		_within("stutter %d: fraction of ten minutes at full" % seed, float(st["at_one"]), 0.95, 1.0)
		_within("stutter %d: floor" % seed, float(st["min"]), 0.60, 0.75)
		# two to four drops a period, so at least twice the period count
		_within("stutter %d: drops in ten minutes" % seed, float(st["drops"]),
			2.0 * floor(600.0 / period), 4.0 * ceil(600.0 / period))
		var cy: Dictionary = _sample(F, F.CYCLING, seed, F.cycle_length(seed), 120.0)
		_within("cycling %d: length in 40..70 s" % seed, F.cycle_length(seed), 40.0, 70.0)
		_check("cycling %d: reaches dark" % seed, float(cy["min"]) <= 0.0, true)
		_check("cycling %d: comes all the way back" % seed, float(cy["max"]) >= 0.99, true)
		var wv: Dictionary = _sample(F, F.WAVER, seed, 60.0, 120.0)
		_within("waver %d: min" % seed, float(wv["min"]), 0.95, 1.0)
		_within("waver %d: max" % seed, float(wv["max"]), 0.95, 1.0)
	_check("the same seed answers the same twice",
		F.level(F.STUTTER, 7, 123.456) == F.level(F.STUTTER, 7, 123.456), true)
	_check("two seeds have their own periods", F.stutter_period(7) != F.stutter_period(12345), true)
	_check("steady is 1.0", F.level(F.NONE, 7, 5.0), 1.0)

	# --- the loader ------------------------------------------------------------
	var row: Node = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 2, "spacing": 1.2}})
	_check("a fluorescent row no longer hums", (row.get("rig") as LuxLightRig).flicker_amount, 0.0)
	_check("a fluorescent row is steady until the spawner chooses", (row.get("rig") as LuxLightRig).failing_kind, F.NONE)
	var bulbs: Node = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, 0.0, 3.2], "rot_y": 0.0, "drop": 3.2, "row": {"count": 1, "spacing": 0.0}})
	_check("a pendant no longer hums", (bulbs.get("rig") as LuxLightRig).flicker_amount, 0.0)
	var cyc_id: String = ""
	var steady_id: String = ""
	for i in range(1, 40):
		var id := "lot_pole_%d" % i
		if id.hash() % 3 == 0:
			if cyc_id == "":
				cyc_id = id
		elif steady_id == "":
			steady_id = id
	var pole_c: Node = loader.rig_for_anchor({"id": cyc_id, "type": "streetlight",
		"pos": [4.0, 4.0, 6.0], "rot_y": 0.0})
	var pole_s: Node = loader.rig_for_anchor({"id": steady_id, "type": "streetlight",
		"pos": [8.0, 4.0, 6.0], "rot_y": 0.0})
	_check("every third pole cycles (%s)" % cyc_id, (pole_c.get("rig") as LuxLightRig).failing_kind, F.CYCLING)
	_check("a cycling pole has its own seed", (pole_c.get("rig") as LuxLightRig).failing_seed != 0, true)
	_check("a cycling pole no longer buzzes", (pole_c.get("rig") as LuxLightRig).flicker_amount, 0.0)
	_check("the other poles are steady (%s)" % steady_id, (pole_s.get("rig") as LuxLightRig).failing_kind, F.NONE)

	# --- the spawner's choice ---------------------------------------------------
	var markers: Array = [
		_marker("LuxEmit_fluorescent", "room_a"), _marker("LuxEmit_fluorescent_2", "room_a"),
		_marker("LuxEmit_fluorescent_3", "room_a"),
		_marker("LuxEmit_fluorescent_4", "room_b"),
		_marker("LuxEmit_pendant", "vault"), _marker("LuxEmit_pendant_2", "vault"),
		_marker("LuxEmit_sign", "sign"),
	]
	var chosen: Dictionary = spawner.choose_failing(markers)
	_check("one failing lamp an anchor: three anchors, three lamps", chosen.size(), 3)
	var kinds: Dictionary = {}
	var anchors: Dictionary = {}
	for mk in chosen:
		kinds[int(chosen[mk][0])] = int(kinds.get(int(chosen[mk][0]), 0)) + 1
		anchors[String(mk.get_meta("lux_anchor_id"))] = true
	_check("two rooms stutter, the vault wavers", kinds, {F.STUTTER: 2, F.WAVER: 1})
	_check("each chosen lamp is in its own anchor", anchors.size(), 3)
	_check("the sign is never chosen", chosen.has(markers[6]), false)
	var again: Dictionary = spawner.choose_failing(markers)
	_check("the same anchors choose the same lamps", again.keys() == chosen.keys(), true)
	for mk in markers:
		mk.free()

	# --- a failing rig in a tree moves its lamp and its own lens ---------------
	var tube: Node = loader.rig_for_anchor({"id": "stockroom_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	var tube_rig: LuxLightRig = tube.get("rig")
	tube_rig.failing_kind = F.STUTTER
	tube_rig.failing_seed = 7
	var steady: Node = loader.rig_for_anchor({"id": "office_ceiling", "type": "fluorescent",
		"pos": [20.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	get_root().add_child(tube)
	get_root().add_child(steady)
	await process_frame
	var lamp: Light3D = _lamp(tube)
	var lamp_s: Light3D = _lamp(steady)
	_check("the tube has a lamp", lamp != null, true)
	if lamp == null:
		_finish()
		return
	# a diffuser 10 cm under the lamp, and the SAME material on a far one
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
	var far := MeshInstance3D.new()
	var far_mesh := BoxMesh.new()
	far_mesh.material = shared
	far.mesh = far_mesh
	get_root().add_child(far)
	far.global_position = lamp.global_position + Vector3(20.0, 0.0, 0.0)
	await process_frame
	tube.call("_bind_lenses")
	steady.call("_bind_lenses")
	var lenses: Array = tube.get("_lenses")
	_check("the tube bound one lens", lenses.size(), 1)
	_check("a steady rig binds none", (steady.get("_lenses") as Array).size(), 0)
	if lenses.size() != 1:
		_finish()
		return
	_check("the lens is the near one", lenses[0][0] == lens, true)
	_check("the lens got an override of its own", lens.get_surface_override_material(0) != shared, true)
	_check("the far face keeps the shared material", far.get_surface_override_material(0) == null, true)
	# find a second in this seed's first period where the model drops
	var drop_t: float = -1.0
	var i: int = 0
	while i < 12000 and drop_t < 0.0:
		if F.level(F.STUTTER, 7, float(i) / 200.0) < 0.9:
			drop_t = float(i) / 200.0
		i += 1
	_check("the seed has a drop in its first minute", drop_t >= 0.0, true)
	var base_e: float = lamp.light_energy
	var base_s: float = lamp_s.light_energy
	tube.set("_fail_t", drop_t)
	tube.call("_process", 0.0)
	steady.set("_fail_t", drop_t)
	steady.call("_process", 0.0)
	var lvl: float = F.level(F.STUTTER, 7, drop_t)
	_within("in a drop the lamp is at the model's level", lamp.light_energy / base_e, lvl - 0.001, lvl + 0.001)
	_within("and the lens follows it", (lenses[0][2] as BaseMaterial3D).emission_energy_multiplier / 1.86,
		lvl - 0.001, lvl + 0.001)
	_within("the shared material is untouched", shared.emission_energy_multiplier, 1.859, 1.861)
	_check("the steady rig's lamp did not move", lamp_s.light_energy, base_s)
	tube.set("_fail_t", drop_t + 2.0 * F.stutter_period(7) - 0.001)
	tube.call("_process", 0.0)
	# steady again between bursts: the model is at 1.0 for 95 % of the time,
	# so step back from the burst by half a period
	tube.set("_fail_t", drop_t + F.stutter_period(7) * 0.5)
	tube.call("_process", 0.0)
	if F.level(F.STUTTER, 7, drop_t + F.stutter_period(7) * 0.5) >= 0.999:
		_within("between bursts the lamp is back at full", lamp.light_energy, base_e - 0.001, base_e + 0.001)
		_within("and so is the lens", (lenses[0][2] as BaseMaterial3D).emission_energy_multiplier, 1.859, 1.861)
	_finish()


func _finish() -> void:
	print("failing fixtures selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
