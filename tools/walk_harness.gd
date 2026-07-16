extends SceneTree
# [HW] Lux walkabout harness (v0.15) — machine gates for the fixture pass.
# Home: lux/tools/walk_harness.gd. Stage inputs into res://walk/headless/
# (<shell>.glb optional, <scope>_fixtures.glb, <scope>.lights.json), run an
# --import pass, then:
#   godot --headless --path <lux project> --script res://tools/walk_harness.gd
#
# PHASE A — manifest bake path (LuxLightLoader.bake): rig/lamp counts,
#   lamp<->diffuser co-location, Bind Emissives census, fixtures_powered
#   kill/restore (LuxSun excluded — preset-owned, survives by design).
# PHASE B — emitter-marker path (LuxFixtureSpawner, Zoo v0.30+ GLBs):
#   spawn count == marker count, validator co-location gate, powered kill
#   on spawned lamps. SKIPS (passes) when the GLB predates markers.
#
# Emits [HW] lines + headless_report.json + headless_walk.tscn beside the
# staged inputs. Proven-on-hardware gotchas encoded here: everything waits
# for the first process frame (nodes added in _initialize are not in-tree
# and _ready hasn't fired), and settle frames follow every bake/spawn/bind.

const DIRP: String = "res://walk/headless"

var rep: Dictionary = {}

func _initialize() -> void:
	_main()

func _main() -> void:
	await process_frame
	var code: int = await _run()
	_save_report()
	print("[HW] exit code ", code)
	quit(code)

func _log(s: String) -> void:
	print("[HW] " + s)

# ------------------------------------------------------------------
func _run() -> int:
	_log("=== lux walkabout harness (v0.15) ===")
	var d: DirAccess = DirAccess.open(DIRP)
	if d == null:
		_log("FAIL: cannot open " + DIRP + " — stage inputs first")
		return 1
	var shell_path: String = ""
	var fix_path: String = ""
	var lights_path: String = ""
	for f in d.get_files():
		var fl: String = String(f)
		if fl.ends_with(".import"):
			continue
		if fl.ends_with("_fixtures.glb"):
			fix_path = DIRP + "/" + fl
		elif fl.ends_with(".glb"):
			shell_path = DIRP + "/" + fl
		elif fl.ends_with(".lights.json"):
			lights_path = DIRP + "/" + fl
	rep["inputs"] = {"shell": shell_path, "fixtures": fix_path, "lights": lights_path}
	_log("shell=" + shell_path + " fixtures=" + fix_path + " lights=" + lights_path)
	if fix_path == "" or lights_path == "":
		_log("FAIL: need a *_fixtures.glb and a *.lights.json in " + DIRP)
		return 1

	var stage: Node3D = Node3D.new()
	stage.name = "HeadlessWalk"
	root.add_child(stage)

	if shell_path != "":
		var shell_scene: PackedScene = load(shell_path) as PackedScene
		if shell_scene != null:
			var shell: Node = shell_scene.instantiate()
			shell.name = "Shell"
			stage.add_child(shell)
		else:
			_log("WARN: shell glb failed to load (missing --import pass?)")

	var fix_scene: PackedScene = load(fix_path) as PackedScene
	if fix_scene == null:
		_log("FAIL: fixtures glb failed to load as PackedScene — was --import run?")
		return 1
	var fixtures: Node = fix_scene.instantiate()
	fixtures.name = "Fixtures"
	stage.add_child(fixtures)

	var lux_root: LuxRoot = LuxRoot.new()
	lux_root.name = "LuxRoot"
	stage.add_child(lux_root)
	await process_frame

	# ============================================================
	# PHASE A — manifest bake path
	# ============================================================
	_log("--- PHASE A: manifest bake (LuxLightLoader) ---")
	var bake: Dictionary = LuxLightLoader.bake(lights_path, stage)
	rep["bake"] = bake
	_log("bake: " + str(bake))
	if not bool(bake.get("ok", false)):
		_log("FAIL: bake refused")
		return 1
	await process_frame

	var lights: Array = _fixture_lights(stage)
	rep["a_lights"] = lights.size()
	rep["a_directional_excluded"] = _directional_count(stage)
	_log("fixture lights: " + str(lights.size()) + " (directional excluded: "
		+ str(rep["a_directional_excluded"]) + ")")
	if lights.is_empty():
		_log("FAIL: bake produced zero fixture lights")
		return 1

	var diffusers: Array = []
	_collect_name(fixtures, "Diffuser", diffusers)
	if diffusers.size() > 0:
		var co: Dictionary = _nearest_stats(lights, diffusers)
		rep["a_colocation_fluoro_note"] = "min over ALL lamps incl. window/area (no hardware by design)"
		rep["a_colocation"] = co
		_log("lamp->nearest diffuser (m): min %.3f avg %.3f max %.3f (window/area lamps have no hardware — max is theirs)"
			% [co["min"], co["avg"], co["max"]])

	var bind: Dictionary = lux_root.bind_fixture_emissives(stage)
	rep["bind"] = bind
	_log("bind: " + str(bind))
	if not bool(bind.get("ok", false)):
		_log("FAIL: bind refused")
		return 1
	await process_frame

	var mats: Dictionary = {}
	_lens_materials(fixtures, mats)
	var a_gate: Dictionary = _powered_gate(lux_root, lights, mats)
	rep["a_powered_gate"] = a_gate
	_log("PHASE A powered gate: kill=" + str(a_gate["kill"]) + " restore=" + str(a_gate["restore"]))
	if not (bool(a_gate["kill"]) and bool(a_gate["restore"])):
		return 1

	# ============================================================
	# PHASE B — emitter-marker path (Zoo v0.30+)
	# ============================================================
	_log("--- PHASE B: emitter markers (LuxFixtureSpawner) ---")
	LuxLightLoader.clear(stage)
	await process_frame

	var markers: Array = []
	LuxFixtureSpawner.collect_markers(stage, markers)
	rep["b_markers"] = markers.size()
	if markers.is_empty():
		_log("SKIP: no LuxEmit_* markers — fixtures GLB predates Zoo v0.30. Rebuild fixtures to exercise the marker path.")
		rep["b_status"] = "skipped_no_markers"
		_save_scene(stage)
		_log("=== harness complete (Phase A only) ===")
		return 0

	var spawn: Dictionary = LuxFixtureSpawner.spawn(stage)
	rep["spawn"] = spawn
	_log("spawn: " + str(spawn))
	await process_frame

	if int(spawn.get("count", 0)) != markers.size() - _unspawnable(markers):
		_log("FAIL: spawn count " + str(spawn.get("count")) + " != spawnable marker count")
		return 1

	var findings: Array = LuxValidator.check_fixture_colocation(stage)
	var errs: int = 0
	for f in findings:
		var sev: int = f.severity
		_log("validator: [" + str(sev) + "] " + String(f.message))
		if sev == LuxValidator.Severity.ERROR:
			errs += 1
	rep["b_validator_errors"] = errs
	if errs > 0:
		_log("FAIL: co-location validator reported errors")
		return 1

	var spawned: Array = _fixture_lights(stage)
	rep["b_lights"] = spawned.size()
	var b_gate: Dictionary = _powered_gate(lux_root, spawned, mats)
	rep["b_powered_gate"] = b_gate
	_log("PHASE B powered gate: kill=" + str(b_gate["kill"]) + " restore=" + str(b_gate["restore"]))
	if not (bool(b_gate["kill"]) and bool(b_gate["restore"])):
		return 1

	_save_scene(stage)
	_log("=== harness complete (Phases A + B) ===")
	return 0

# ------------------------------------------------------------------
func _fixture_lights(node: Node) -> Array:
	var all_l: Array = []
	_collect_class(node, "Light3D", all_l)
	var out: Array = []
	for l in all_l:
		if not (l as Node).is_class("DirectionalLight3D"):
			out.append(l)
	return out

func _directional_count(node: Node) -> int:
	var all_l: Array = []
	_collect_class(node, "Light3D", all_l)
	var n: int = 0
	for l in all_l:
		if (l as Node).is_class("DirectionalLight3D"):
			n += 1
	return n

func _unspawnable(markers: Array) -> int:
	var n: int = 0
	for m in markers:
		var t: String = LuxFixtureSpawner.marker_type(m as Node)
		if t == "" or t == "window" or t == "sun":
			n += 1
	return n

func _nearest_stats(from_nodes: Array, to_nodes: Array) -> Dictionary:
	var best_min: float = 1e9
	var worst: float = 0.0
	var total: float = 0.0
	for a in from_nodes:
		var ap: Vector3 = (a as Node3D).global_position
		var nearest: float = 1e9
		for b in to_nodes:
			var dd: float = (ap - (b as Node3D).global_position).length()
			if dd < nearest:
				nearest = dd
		total += nearest
		worst = maxf(worst, nearest)
		best_min = minf(best_min, nearest)
	return {"min": best_min, "avg": total / maxf(1.0, float(from_nodes.size())), "max": worst}

func _powered_gate(lux_root: LuxRoot, lights: Array, mats: Dictionary) -> Dictionary:
	var pre_e: float = _energy_sum(lights, false)
	var pre_a: float = _energy_sum(lights, true)
	var pre_g: float = _emission_sum(mats)
	lux_root.set_fixtures_powered(false)
	var off_e: float = _energy_sum(lights, false)
	var off_a: float = _energy_sum(lights, true)
	var off_g: float = _emission_sum(mats)
	lux_root.set_fixtures_powered(true)
	var back_e: float = _energy_sum(lights, false)
	var back_g: float = _emission_sum(mats)
	return {"kill": off_e == 0.0 and off_g == 0.0 and off_a == pre_a,
		"restore": back_e == pre_e and back_g == pre_g,
		"non_alarm_before": pre_e, "non_alarm_off": off_e,
		"glow_before": pre_g, "glow_off": off_g}

func _collect_class(n: Node, klass: String, outp: Array) -> void:
	if n.is_class(klass):
		outp.append(n)
	for c in n.get_children():
		_collect_class(c, klass, outp)

func _collect_name(n: Node, needle: String, outp: Array) -> void:
	if String(n.name).findn(needle) != -1 and n is Node3D:
		outp.append(n)
	for c in n.get_children():
		_collect_name(c, needle, outp)

func _lens_materials(n: Node, acc: Dictionary) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n as MeshInstance3D
		if mi.mesh != null:
			for i in range(mi.mesh.get_surface_count()):
				var mat: Material = mi.get_active_material(i)
				if mat != null and LuxEmissiveBinder.matches(mat.resource_name):
					acc[mat] = true
	for c in n.get_children():
		_lens_materials(c, acc)

func _emission_sum(mats: Dictionary) -> float:
	var total: float = 0.0
	for m in mats.keys():
		var sm: StandardMaterial3D = m as StandardMaterial3D
		if sm != null and sm.emission_enabled:
			total += sm.emission_energy_multiplier
	return total

func _energy_sum(lights: Array, alarm_only: bool) -> float:
	var total: float = 0.0
	for lo in lights:
		var li: Light3D = lo as Light3D
		if not is_instance_valid(li):
			continue
		var in_alarm: bool = li.is_in_group(&"lux_alarm")
		if in_alarm == alarm_only:
			total += li.light_energy * (1.0 if li.visible else 0.0)
	return total

func _save_scene(stage: Node) -> void:
	_own_recursive(stage, stage)
	var packed: PackedScene = PackedScene.new()
	if packed.pack(stage) == OK:
		var err: int = ResourceSaver.save(packed, DIRP + "/headless_walk.tscn")
		_log("scene saved -> " + DIRP + "/headless_walk.tscn (err=" + str(err) + ")")

func _own_recursive(n: Node, o: Node) -> void:
	for c in n.get_children():
		c.owner = o
		_own_recursive(c, o)

func _save_report() -> void:
	var f: FileAccess = FileAccess.open(DIRP + "/headless_report.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rep, "  "))
		f.close()
	print("[HW-REPORT-BEGIN]")
	print(JSON.stringify(rep, "  "))
	print("[HW-REPORT-END]")
