extends SceneTree
## Light-leak probe: runs LuxLeakMeter over a scene's RUNNING tree and writes
## the numbers. Prints what it measured and stops; the cause belongs in
## whoever reads it.
##
##     godot --headless --path <project> -s res://tools/light_leak_probe.gd -- \
##         --scene res://presentation/lux.applied.tscn [--out <abs.json>] \
##         [--samples 128] [--settle 6] \
##         [--meter res://addons/lux/runtime/lux_leak_meter.gd]
##
## The running tree, not the file: every Lux rig rebuilds its lights in
## `_ready` from its rig resource, and LuxRoot's shadow policy re-decides
## `shadow_enabled` a frame after the rigs register, so the saved scene's own
## light nodes and shadow flags are not what renders. `--settle` frames pass
## before measuring, physics frames included, so colliders are in the space.
##
## `--meter` exists because a shipped package vendors Lux under another path
## (Level Factory copies it to res://runtime/lux); the meter has no class
## dependencies and loads from anywhere it is copied.
##
## Exit 0 = measured and written. Exit 2 = could not measure, never a pass.

const DEFAULT_METER := "res://addons/lux/runtime/lux_leak_meter.gd"


func _initialize() -> void:
	_main()


func _args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a: String = argv[i]
		if a.begins_with("--"):
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[a.substr(2)] = argv[i + 1]
				i += 1
			else:
				out[a.substr(2)] = true
		i += 1
	return out


func _main() -> void:
	var args := _args()
	var scene_path: String = String(args.get("scene", ""))
	var meter_path: String = String(args.get("meter", DEFAULT_METER))
	var samples: int = int(args.get("samples", "128"))
	var settle: int = int(args.get("settle", "6"))
	var out_path: String = String(args.get("out", ""))
	if scene_path.is_empty():
		push_error("light_leak_probe: --scene res://... is required")
		quit(2)
		return
	var meter: GDScript = load(meter_path) as GDScript
	if meter == null or not meter.can_instantiate():
		push_error("light_leak_probe: meter did not load or compile: %s" % meter_path)
		quit(2)
		return
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		push_error("light_leak_probe: could not load %s" % scene_path)
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	for i in maxi(settle, 2):
		await process_frame
		await physics_frame

	var budget := -1
	var tier := -1
	for lr in get_nodes_in_group(&"lux_root"):
		if lr.has_method("get_quality_profile"):
			var q: Object = lr.get_quality_profile()
			if q != null:
				budget = int(q.get("max_shadow_casters"))
				tier = int(q.get("tier"))
			break
	var space: PhysicsDirectSpaceState3D = root.world_3d.direct_space_state
	var result: Dictionary = meter.measure(scene, space, samples, budget)
	result["scene"] = scene_path
	result["tier"] = tier
	result["engine"] = Engine.get_version_info().get("string", "")

	var s: Dictionary = result.summary
	print("LUX_LEAK lights=%d omni=%d spot=%d shadowed=%d budget=%d unshadowed=%d"
		% [s.lights, s.omni, s.spot, s.shadowed, s.shadow_budget, s.unshadowed])
	print("LUX_LEAK unshadowed_leaking=%d slab=%d wall=%d shadowed_leaking=%d"
		% [s.unshadowed_leaking, s.unshadowed_leaking_slab,
			s.unshadowed_leaking_wall, s.shadowed_leaking])
	print("LUX_LEAK e_seen=%.4f e_leak_slab=%.4f e_leak_wall=%.4f leak_share=%.4f"
		% [s.unshadowed_e_seen, s.unshadowed_e_leak_slab,
			s.unshadowed_e_leak_wall, s.unshadowed_leak_share])
	var classes: Array = (s.by_class as Dictionary).keys()
	classes.sort()
	for c in classes:
		var cd: Dictionary = s.by_class[c]
		print("LUX_LEAK class=%s unshadowed=%d leaking=%d e_seen=%.4f e_leak=%.4f"
			% [c, cd.unshadowed, cd.leaking, cd.e_seen, cd.e_leak])
	if not out_path.is_empty():
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			push_error("light_leak_probe: cannot write %s" % out_path)
			quit(2)
			return
		f.store_string(JSON.stringify(result, "  "))
		f.close()
		print("LUX_LEAK wrote %s" % out_path)
	quit(0)
