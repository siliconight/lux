extends SceneTree
## Falsification test for the fixture co-location gate (roadmap item 71).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/colocation_selftest.gd
##
## THE IMPORT PASS IS NOT OPTIONAL and is why the first attempt at this file
## failed. Lux's runtime scripts carry `class_name` annotations and refer to
## each other by those names. A `-s` script in a project that has never been
## imported has no `.godot/global_script_class_cache.cfg`, so every one of
## those names fails to resolve and `lux_validator.gd` will not compile --
## a wall of "Could not find type LuxRoot / LuxPreset / LuxFixtureSpawner"
## that says nothing about the code under test. `run_fixture_gate.gd` avoids
## this by running against a project Level Factory has already imported.
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## WHY THIS EXISTS. `check_fixture_colocation` used to measure from each marker
## to the nearest Light3D. A spawned fluorescent hangs its bulb 0.25 m below
## its rig root on purpose -- `lux_light_loader` sets `mount_height = -0.25`
## under a comment about tubes grazing the ceiling -- so the check reported
## every fluorescent in the factory as "floating light" and blocked two cold
## runs. It now measures to the RIG ROOT.
##
## The hard part of testing that is not case A. It is case B: a fix that makes
## the check stop complaining is indistinguishable from a fix that makes the
## check stop working, and only a deliberate failure tells them apart.
##
## Case 0 proves the drop is REAL before anything else runs. Without it, a
## future change that quietly zeroed `mount_height` would make case A pass for
## entirely the wrong reason and this file would be a rubber stamp.

const SPAWNER := "res://addons/lux/runtime/lux_fixture_spawner.gd"
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


func _errors(Validator: GDScript, stage: Node, tol: float) -> Array:
	var out: Array = []
	for f in Validator.check_fixture_colocation(stage, tol):
		if f.severity == Validator.Severity.ERROR:
			out.append(String(f.message))
	return out


## Three markers in a row, named so `marker_type` reads "fluorescent".
func _markers(stage: Node3D) -> Array:
	var made: Array = []
	for i in 3:
		var m := Node3D.new()
		m.name = "LuxEmit_fluorescent_%d" % i
		stage.add_child(m)
		m.global_position = Vector3(float(i) * 4.0, 3.0, 0.0)
		made.append(m)
	return made


func _lowest_light(n: Node) -> Node3D:
	if n is Light3D and not n is DirectionalLight3D:
		return n as Node3D
	for c in n.get_children():
		var f: Node3D = _lowest_light(c)
		if f != null:
			return f
	return null


func _main() -> void:
	await process_frame

	var Spawner: GDScript = load(SPAWNER) as GDScript
	var Validator: GDScript = load(VALIDATOR) as GDScript
	if Spawner == null or Validator == null:
		push_error("colocation_selftest: lux runtime scripts not found")
		quit(2)
		return
	# A script that FAILED TO COMPILE still comes back from load() as a
	# non-null GDScript, so the null check above proves nothing. The first
	# run of this file sailed past it and died 12 lines later on
	# "Nonexistent function 'spawn'", which reads like a missing method and
	# is really a missing class cache. Ask whether it compiled.
	if not Spawner.can_instantiate() or not Validator.can_instantiate():
		push_error("colocation_selftest: a lux runtime script did not COMPILE. "
			+ "Almost always the global script class cache: run "
			+ "`godot --headless --path lux --import` once, then re-run this.")
		quit(2)
		return

	var stage := Node3D.new()
	stage.name = "ColocationStage"
	root.add_child(stage)
	var markers: Array = _markers(stage)
	await process_frame

	var spawn: Dictionary = Spawner.spawn(stage)
	await process_frame
	if int(spawn.get("count", 0)) != 3:
		push_error("colocation_selftest: spawned %d rig(s), expected 3 -- %s"
			% [int(spawn.get("count", 0)), String(spawn.get("msg", ""))])
		quit(2)
		return

	var container: Node = stage.get_node_or_null(NodePath("LuxFixtureLights"))
	if container == null or container.get_child_count() != 3:
		push_error("colocation_selftest: no LuxFixtureLights with 3 rigs")
		quit(2)
		return
	var rig0: Node3D = container.get_child(0) as Node3D

	print("case 0 -- the drop this whole item is about is REAL")
	var bulb: Node3D = _lowest_light(rig0)
	if bulb == null:
		push_error("colocation_selftest: rig 0 has no positional light")
		quit(2)
		return
	var drop: float = (rig0.global_position - bulb.global_position).length()
	_check("rig root sits ON its marker",
		snappedf((rig0.global_position - (markers[0] as Node3D).global_position)
			.length(), 0.001), 0.0)
	_check("bulb hangs BELOW the rig root", snappedf(drop, 0.001), 0.25)
	if drop <= 0.1:
		print("  the fluorescent drop is gone -- case A below would pass for the")
		print("  wrong reason. Fix the drop or retire this file; do not trust it.")

	print("case A -- a correctly hung fixture is NOT a finding (roadmap 71)")
	_check("errors", _errors(Validator, stage, 0.1).size(), 0)

	print("case B -- a rig adrift is still caught (the check can still fail)")
	rig0.global_position += Vector3(5.0, 0.0, 0.0)
	await process_frame
	var adrift: Array = _errors(Validator, stage, 0.1)
	_check("error count", adrift.size(), 2)
	var joined := " | ".join(adrift)
	_check("names the dark marker", joined.contains("dark hardware"), true)
	_check("names the floating rig", joined.contains("floating light"), true)
	rig0.global_position -= Vector3(5.0, 0.0, 0.0)
	await process_frame
	_check("and it recovers when the rig goes back", _errors(Validator, stage, 0.1).size(), 0)

	print("case C -- no spawn at all is dark hardware, not silence")
	Spawner.clear(stage)
	await process_frame
	var unlit: Array = _errors(Validator, stage, 0.1)
	_check("error count", unlit.size(), 1)
	_check("is the dark-hardware finding",
		(" | ".join(unlit)).contains("dark hardware"), true)

	print("case D -- a manifest-baked lamp still satisfies a marker")
	var baked := OmniLight3D.new()
	baked.name = "BakedOnMarker"
	stage.add_child(baked)
	baked.global_position = (markers[0] as Node3D).global_position
	await process_frame
	var mixed: Array = _errors(Validator, stage, 0.1)
	_check("only the two markers with nothing on them are dark",
		(" | ".join(mixed)).contains("2 fixture marker"), true)

	print("")
	if _fails == 0:
		print("  colocation selftest ok: the drop is real, a hung fixture passes,")
		print("  an adrift rig fails, an empty scene fails, a bake counts.")
	else:
		print("  colocation selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
