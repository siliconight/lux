extends SceneTree
## The derived room probes and the interior-dark preset knobs (0.38.0).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/room_ambient_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all -- against the 0.37.0 loader, which
## has no `bake_room_ambient`, this is the exit, and it is never a pass.
##
## Headless has no renderer, so nothing here says how dark a room READS --
## those are frames (the 0.38.0 changelog). What this holds is the
## derivation: a `room_box_local` lands on the room it describes at rot_y 0,
## 90 and 180, off-centre included; one room is one probe however many runs
## its row was split into; a room with no box is counted and not guessed; a
## room with an explicit `room_ambient` anchor is left to the club bake; the
## bake replaces itself; the preset knob writes the contribution the probe
## needs, for both live ambient sources; the sun's shadow takes the preset's
## mode and reach; a blend carries all three fields; and the four presets
## Level Factory picks from ask for dark interiors.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const ENVIRONMENT := "res://addons/lux/runtime/lux_environment.gd"
const LIGHTING := "res://addons/lux/runtime/lux_lighting.gd"
const ROOT := "res://addons/lux/runtime/lux_root.gd"
const PRESET := "res://addons/lux/resources/lux_preset.gd"
const QUALITY := "res://addons/lux/resources/lux_quality_profile.gd"
const MANIFEST := "user://room_ambient_selftest.lights.json"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _near_v(label: String, got: Vector3, want: Vector3, tol: float) -> void:
	var ok := (got - want).length() <= tol
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s +/- %.3f)" % [str(want), tol]])


func _anchor(id: String, room: String, pos: Array, rot: float, box: Variant) -> Dictionary:
	var a := {"id": id, "type": "fluorescent", "source": "derived", "pos": pos,
		"rot_y": rot, "room": room, "row": {"count": 1, "spacing": 0.0}, "drop": 3.8}
	if box != null:
		a["room_box_local"] = box
	return a


func _main() -> void:
	await process_frame
	var Loader: GDScript = load(LOADER) as GDScript
	var Env: GDScript = load(ENVIRONMENT) as GDScript
	var Lighting: GDScript = load(LIGHTING) as GDScript
	var Root: GDScript = load(ROOT) as GDScript
	var Preset: GDScript = load(PRESET) as GDScript
	var Quality: GDScript = load(QUALITY) as GDScript
	if Loader == null or Env == null or Lighting == null or Root == null \
			or Preset == null or Quality == null:
		print("  room ambient selftest could not load its scripts")
		quit(2)
		return
	# Against a loader without the room bake (0.37.0) this is the exit --
	# a method looked up by name, so the script itself still compiles.
	if not Loader.has_method("bake_room_ambient") or not Loader.has_method("room_probe_for") \
			or not Loader.has_method("room_probe_plan"):
		print("  room ambient selftest cannot run: the loader has no bake_room_ambient (Lux < 0.38.0)")
		quit(2)
		return
	var field: Variant = Loader.get("ROOM_BOX_FIELD")
	if typeof(field) != TYPE_STRING:
		print("  room ambient selftest cannot run: no ROOM_BOX_FIELD on the loader")
		quit(2)
		return
	var margin: float = float(Loader.get("ROOM_AMBIENT_MARGIN"))
	var host := Node3D.new()
	host.name = "Host"
	root.add_child(host)
	await process_frame

	print("case A -- the field is the one Deli Counter is asked to write")
	_check("ROOM_BOX_FIELD", field, "room_box_local")

	print("case B -- a box relative to its lamp lands on the room, rot_y 0")
	# Lamp 3.8 m over the floor, 0.1 m under the slab; the room 10 x 6 m
	# centred on it. DC (10, 20, 3.8) -> Godot (10, 3.8, -20); the box centre
	# is 1.85 m below the lamp.
	var box := [-5.0, -3.0, -3.8, 5.0, 3.0, 0.1]
	var p0: ReflectionProbe = Loader.room_probe_for(_anchor("r_ceiling", "b0/r", [10.0, 20.0, 3.8], 0.0, box))
	_check("a probe is built", p0 != null, true)
	if p0 != null:
		_near_v("position (x, z_up - 1.85, -y)", p0.position, Vector3(10.0, 1.95, -20.0), 1e-4)
		_near_v("size swaps axes and adds the margin", p0.size,
			Vector3(10.0 + 2.0 * margin, 3.9 + 2.0 * margin, 6.0 + 2.0 * margin), 1e-4)
		_check("interior", p0.interior, true)
		_check("update once", p0.update_mode, ReflectionProbe.UPDATE_ONCE)
		_check("ambient colour mode", p0.ambient_mode, ReflectionProbe.AMBIENT_COLOR)
		_check("named after the room, path-safe", String(p0.name), "b0_r")
		_check("rotation.y 0", is_zero_approx(p0.rotation.y), true)
		p0.free()

	print("case C -- rot_y 90: the box's x runs along the row, an off-centre box follows it")
	# Local x from 0 to 10: the box centre is 5 m along the row. At rot_y 90
	# the row runs along DC +Y, so the centre is at DC (10, 25, 1.95).
	var p90: ReflectionProbe = Loader.room_probe_for(_anchor("r_ceiling", "b0/r", [10.0, 20.0, 3.8], 90.0,
		[0.0, -3.0, -3.8, 10.0, 3.0, 0.1]))
	if p90 != null:
		_near_v("position", p90.position, Vector3(10.0, 1.95, -25.0), 1e-4)
		_near_v("local +X lies along the row (DC +Y is Godot -Z)", p90.transform.basis.x, Vector3(0.0, 0.0, -1.0), 1e-4)
		_near_v("size is still local (x along the row)", p90.size,
			Vector3(10.0 + 2.0 * margin, 3.9 + 2.0 * margin, 6.0 + 2.0 * margin), 1e-4)
		p90.free()
	else:
		_check("a probe is built at rot 90", false, true)

	print("case D -- rot_y 180: an off-centre box across the row lands on the far side")
	# Local y from 0 to 6: centre 3 m across. At rot_y 180 local +Y is DC
	# (-sin 180, cos 180) = (0, -1), so DC (10, 17, 1.95) -> Godot (10, 1.95, -17).
	var p180: ReflectionProbe = Loader.room_probe_for(_anchor("r_ceiling", "b0/r", [10.0, 20.0, 3.8], 180.0,
		[-5.0, 0.0, -3.8, 5.0, 6.0, 0.1]))
	if p180 != null:
		_near_v("position", p180.position, Vector3(10.0, 1.95, -17.0), 1e-4)
		p180.free()
	else:
		_check("a probe is built at rot 180", false, true)

	print("case E -- a bad box is no box")
	_check("five numbers", Loader.room_probe_for(_anchor("x", "r", [0, 0, 3], 0.0, [0, 0, 0, 1, 1])) == null, true)
	_check("inverted", Loader.room_probe_for(_anchor("x", "r", [0, 0, 3], 0.0, [1, 0, 0, 0, 1, 1])) == null, true)
	_check("a string", Loader.room_probe_for(_anchor("x", "r", [0, 0, 3], 0.0, "10x6")) == null, true)
	_check("absent", Loader.room_probe_for(_anchor("x", "r", [0, 0, 3], 0.0, null)) == null, true)

	print("case F -- the plan: one room one probe, unboxed counted, explicit left alone")
	var anchors: Array = [
		_anchor("b0/lobby_ceiling_1", "b0/lobby", [0, 0, 3.8], 0.0, [-3, -3, -3.8, 3, 3, 0.1]),
		_anchor("b0/lobby_ceiling_0", "b0/lobby", [8, 0, 3.8], 0.0, [-11, -3, -3.8, -5, 3, 0.1]),
		_anchor("b0/hall_ceiling", "b0/hall", [0, 20, 3.8], 90.0, null),
		_anchor("b0/club_ceiling", "b0/club", [30, 0, 3.8], 0.0, [-5, -5, -3.8, 5, 5, 0.1]),
		{"id": "b0/club_room", "type": "room_ambient", "room": "b0/club", "pos": [30, 0, 1.9],
			"size": [10, 10, 3.8], "color": "violet"},
		{"id": "b0/ext_0_N_window_1", "type": "window", "pos": [0, 10, 1.5], "rot_y": 270.0,
			"size": [1.6, 1.4]},
	]
	var plan: Dictionary = Loader.room_probe_plan(anchors)
	_check("rooms named", plan["rooms"], 3)
	_check("boxed rooms", (plan["boxed"] as Dictionary).keys(), ["b0/lobby"])
	_check("the first run BY ID supplies the box", String((plan["boxed"]["b0/lobby"] as Dictionary)["id"]), "b0/lobby_ceiling_0")
	_check("without a box", plan["without_box"], ["b0/hall"])
	_check("left to the club bake", plan["explicit"], ["b0/club"])

	print("case G -- bake_room_ambient replaces itself and reports the same plan")
	var f := FileAccess.open(MANIFEST, FileAccess.WRITE)
	f.store_string(JSON.stringify({"light_manifest_version": "1.1.0", "anchors": anchors}))
	f.close()
	var r1: Dictionary = Loader.bake_room_ambient(MANIFEST, host)
	_check("ok", r1["ok"], true)
	_check("count", r1["count"], 1)
	_check("rooms", r1["rooms"], 3)
	_check("without_box", r1["without_box"], ["b0/hall"])
	_check("explicit", r1["explicit"], ["b0/club"])
	_check("message names the field", String(r1["msg"]).contains("room_box_local"), true)
	var c1: Node = host.get_node_or_null("LuxRoomAmbient")
	_check("container", c1 != null, true)
	if c1 != null:
		_check("one child", c1.get_child_count(), 1)
		_check("owned by the root the caller passed", c1.get_child(0).owner == host, true)
		_check("child is the lobby probe", String(c1.get_child(0).name), "b0_lobby")
		_near_v("placed from the _0 run at DC (8, 0): centre 8 m further along -X",
			(c1.get_child(0) as Node3D).position, Vector3(0.0, 1.95, 0.0), 1e-4)
	var r2: Dictionary = Loader.bake_room_ambient(MANIFEST, host)
	_check("second bake, still one container", host.get_children().filter(
		func(n: Node) -> bool: return String(n.name) == "LuxRoomAmbient").size(), 1)
	_check("second bake, still one probe", r2["count"], 1)
	var r3: Dictionary = Loader.bake_room_ambient("user://does_not_exist.lights.json", host)
	_check("a missing file is not ok", r3["ok"], false)
	_check("clear takes the room container too", Loader.clear(host), 1)
	_check("gone", host.get_node_or_null("LuxRoomAmbient") == null, true)

	print("case H -- the preset knob writes the contribution the probe needs")
	var env_mod: Node = Env.new()
	host.add_child(env_mod)
	env_mod.ensure_world_environment(host)
	var q: Resource = Quality.make_tier(0)
	var pre: Resource = Preset.new()
	pre.ambient_mode = 0
	pre.ambient_sky_contribution = 0.5
	pre.room_probes_replace_ambient = false
	env_mod.apply(pre, q)
	var env: Environment = env_mod.get_environment()
	_check("off: the preset's 0.5", env.ambient_light_sky_contribution, 0.5)
	pre.room_probes_replace_ambient = true
	env_mod.apply(pre, q)
	_check("on: 1.0 under Sky", env.ambient_light_sky_contribution, 1.0)
	pre.ambient_mode = 1
	pre.room_probes_replace_ambient = false
	env_mod.apply(pre, q)
	_check("off under Flat Color: written, the preset's 0.5", env.ambient_light_sky_contribution, 0.5)
	pre.room_probes_replace_ambient = true
	env_mod.apply(pre, q)
	_check("on under Flat Color: 1.0", env.ambient_light_sky_contribution, 1.0)
	_check("the source stayed Color", env.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR)

	print("case I -- the sun's shadow is priced by the preset")
	var lt: Node = Lighting.new()
	host.add_child(lt)
	lt.ensure_sun(host)
	var sp: Resource = Preset.new()
	sp.sun_shadows = true
	sp.sun_shadow_mode = 0
	sp.sun_shadow_max_distance = 48.0
	lt.apply(sp, q)
	var sun: DirectionalLight3D = lt.sun
	_check("shadowed", sun.shadow_enabled, true)
	_check("orthogonal", sun.directional_shadow_mode, DirectionalLight3D.SHADOW_ORTHOGONAL)
	_check("reach 48", sun.directional_shadow_max_distance, 48.0)
	sp.sun_shadow_mode = 2
	sp.sun_shadow_max_distance = 0.0
	lt.apply(sp, q)
	_check("0 = the tier's reach", sun.directional_shadow_max_distance, q.shadow_max_distance)
	_check("4 splits", sun.directional_shadow_mode, DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
	sp.sun_shadow_mode = 1
	lt.apply(sp, q)
	_check("2 splits", sun.directional_shadow_mode, DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)

	print("case J -- a blend carries the three fields (the lerp is exhaustive by contract)")
	var lr: Node = Root.new()
	lr._blend_scratch = Preset.new()
	var pa: Resource = Preset.new()
	var pb: Resource = Preset.new()
	pb.room_probes_replace_ambient = true
	pb.sun_shadow_mode = 0
	pb.sun_shadow_max_distance = 40.0
	var mid: Resource = lr._lerp_preset(pa, pb, 1.0)
	_check("knob at k 1", mid.room_probes_replace_ambient, true)
	_check("mode at k 1", mid.sun_shadow_mode, 0)
	_check("distance at k 1", mid.sun_shadow_max_distance, 40.0)
	var early: Resource = lr._lerp_preset(pa, pb, 0.25)
	_check("knob snaps at the midpoint, so k 0.25 is a's", early.room_probes_replace_ambient, false)
	_check("distance interpolates: 0.25 of the way from 0 to 40", early.sun_shadow_max_distance, 10.0)
	lr.free()

	print("case K -- the presets Level Factory picks from ask for dark interiors, and price their sun")
	# sun_shadows is what each preset SHIPPED WITH (0.38.0 refused turning it
	# on: +1.9 to +9.0 GPU ms at every setting on the 9054 walk, over the ~2
	# ms budget); the pricing fields are set on all four so that flipping it
	# is one line with a measured cost.
	var shadows := {"heavy_rain": false, "blue_hour": true, "delco_summer_afternoon": true,
		"gas_station_fluorescent": false}
	for name in shadows:
		var res: Resource = load("res://addons/lux/presets/%s.tres" % name)
		if res == null:
			_check("%s loads" % name, false, true)
			continue
		_check("%s: room_probes_replace_ambient" % name, res.room_probes_replace_ambient, true)
		_check("%s: sun_shadows as shipped" % name, res.sun_shadows, shadows[name])
		_check("%s: orthogonal" % name, res.sun_shadow_mode, 0)
		_check("%s: a reach of its own (> 0)" % name, res.sun_shadow_max_distance > 0.0, true)

	host.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MANIFEST))

	print("")
	if _fails == 0:
		print("  room ambient selftest ok: boxes land on their rooms at every yaw, one probe")
		print("  per room, unboxed rooms counted, the knob and the sun pricing reach the engine.")
	else:
		print("  room ambient selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
