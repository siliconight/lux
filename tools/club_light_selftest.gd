extends SceneTree
## The club set (0.37.0): club_wash, stage_light, neon, room_ambient.
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/club_light_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## Headless has no renderer, so nothing here says a pool is VISIBLE or how
## bright it reads -- those are frames (see the 0.37.0 changelog). What this
## holds is the tuning table: each type builds the node it should, its range
## and energy follow the derivation (recomputed here from the closed form, not
## read back from the loader's helpers), two different drops give two
## different answers, a colour picked from an id is the same every time and
## is the one a Python djb2 predicts, an unknown colour name is REFUSED on
## every path, a stage spot points at its target after placement, the cycle
## is a pure function of time, and a stage rig survives being saved.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const LIGHTING := "res://addons/lux/runtime/lux_lighting.gd"
const STAGE := "res://addons/lux/runtime/rigs/lux_stage_light_rig.gd"

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
	print("  %s %s: %.5f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.5f +/- %.5f)" % [want, tol]])


## The closed form, written again here so a wrong helper cannot agree with
## itself: value(d) = energy * (1 - (d/R)^4)^2 / d^2.
func _value(energy: float, d: float, r: float) -> float:
	return energy * pow(maxf(1.0 - pow(d / r, 4.0), 0.0), 2.0) / (d * d)


## One office lamp's floor value at `drop`, from the fluorescent branch's
## documented rule (range clamp(drop + 0.75, 4, 7.5), hung 0.25 m, energy 1).
func _office(drop: float) -> float:
	return _value(1.0, drop - 0.25, clampf(drop + 0.75, 4.0, 7.5))


func _djb2(s: String) -> int:
	var h := 5381
	for b in s.to_utf8_buffer():
		h = (h * 33 + b) & 0xFFFFFFFF
	return h


func _lights_of(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Light3D:
			out.append(c)
	return out


func _main() -> void:
	await process_frame
	var Loader: GDScript = load(LOADER) as GDScript
	var Lighting: GDScript = load(LIGHTING) as GDScript
	var Stage: GDScript = load(STAGE) as GDScript
	if Loader == null or Lighting == null or Stage == null:
		print("  club light selftest could not load its scripts")
		quit(2)
		return
	# Read every contract constant as a Variant and check its TYPE before
	# typing it: against a loader without the club set, a typed assignment
	# from a missing constant is a script error that stops this function
	# before it can quit, and the run hangs instead of saying it could not run
	# (first found running this test against 0.36.0).
	var need := {"CLUB_PALETTE": TYPE_DICTIONARY, "CLUB_COLOR_ORDER": TYPE_ARRAY,
		"CLUB_WASH_LEVEL": TYPE_FLOAT, "CLUB_STAGE_LEVEL": TYPE_FLOAT,
		"CLUB_NEON_LEVEL": TYPE_FLOAT, "ROOM_AMBIENT_MARGIN": TYPE_FLOAT}
	for k in need:
		var v: Variant = Loader.get(k)
		if typeof(v) != need[k]:
			print("  club light selftest: loader has no %s of the expected type (got %s)" % [k, type_string(typeof(v))])
			quit(2)
			return
	var palette: Dictionary = Loader.get("CLUB_PALETTE")
	var order: Array = Loader.get("CLUB_COLOR_ORDER")
	var wash_level: float = Loader.get("CLUB_WASH_LEVEL")
	var stage_level: float = Loader.get("CLUB_STAGE_LEVEL")
	var neon_level: float = Loader.get("CLUB_NEON_LEVEL")
	if order.size() != 7:
		print("  club light selftest: CLUB_COLOR_ORDER has %d colours, not 7" % order.size())
		quit(2)
		return

	print("case A -- the office the club replaces is unchanged by the refactor")
	var fl: Node3D = Loader.rig_for_anchor({"type": "fluorescent", "id": "f", "drop": 3.2})
	_near("fluorescent range at drop 3.2", fl.get("rig").light_range, 4.0, 1e-6)
	_near("fluorescent energy", fl.get("rig").energy, 1.0, 1e-6)
	_near("office floor value at drop 3.2 (0.0570)", _office(3.2), 0.05698, 5e-5)

	print("case B -- club_wash builds a downlight with derived range and energy")
	var w: Node3D = Loader.rig_for_anchor({"type": "club_wash", "id": "main_wash_0",
		"color": "magenta", "drop": 3.2, "radius": 4.0, "pos": [0, 0, 3.2]})
	_check("club_wash is a LuxFluorescentRig", w is LuxFluorescentRig, true)
	var wr: LuxLightRig = w.get("rig")
	_check("colour magenta", wr.light_color, palette["magenta"])
	_near("range = sqrt(2.95^2 + 4^2)", wr.light_range, sqrt(2.95 * 2.95 + 16.0), 1e-4)
	_near("floor value below = level x office",
		_value(wr.energy, 2.95, wr.light_range), wash_level * _office(3.2), 1e-5)
	_check("downlight", wr.downlight_angle_deg > 0.0, true)
	root.add_child(w)
	await process_frame
	var wl := _lights_of(w)
	_check("one SpotLight3D", wl.size() == 1 and wl[0] is SpotLight3D, true)
	_near("built lamp energy", wl[0].light_energy, wr.energy, 1e-6)
	w.queue_free()
	var w2: Node3D = Loader.rig_for_anchor({"type": "club_wash", "id": "main_wash_0",
		"color": "magenta", "drop": 4.5, "radius": 4.0})
	var w2r: LuxLightRig = w2.get("rig")
	_check("a taller room derives a longer range", w2r.light_range > wr.light_range, true)
	_check("and a different energy", absf(w2r.energy - wr.energy) > 1e-3, true)
	_near("which still meets its own office value",
		_value(w2r.energy, 4.25, w2r.light_range), wash_level * _office(4.5), 1e-5)
	var w3: Node3D = Loader.rig_for_anchor({"type": "club_wash", "id": "x", "color": "red",
		"drop": 3.2})
	_near("no radius -> 1.25 x drop", w3.get("rig").light_range,
		sqrt(2.95 * 2.95 + 4.0 * 4.0), 1e-4)

	print("case C -- an absent colour is picked from the id, the same way every time")
	var seen := {}
	for id in ["zone_a", "zone_b", "booth_row", "bar_back", "vip", "stage_left", "entry"]:
		var c1: Node3D = Loader.rig_for_anchor({"type": "club_wash", "id": id, "drop": 3.2})
		var c2: Node3D = Loader.rig_for_anchor({"type": "club_wash", "id": id, "drop": 3.2})
		var want: Color = palette[order[_djb2(id) % 7]]
		_check("%s twice agrees" % id, c1.get("rig").light_color == c2.get("rig").light_color, true)
		_check("%s is djb2 %% 7 (%s)" % [id, order[_djb2(id) % 7]], c1.get("rig").light_color, want)
		seen[str(want)] = true
	_check("seven ids do not all land on one colour", seen.size() > 1, true)
	_check("djb2('zone_a') matches the Python spelling", _djb2("zone_a"), 747310433)

	print("case D -- an unknown colour name is refused on every type")
	for t in ["club_wash", "neon", "stage_light", "room_ambient"]:
		var bad: Variant = Loader.rig_for_anchor({"type": t, "id": "bad", "color": "chartreuse",
			"pos": [0, 0, 3], "target": [0, 0, 0], "size": [4, 4, 3]})
		_check("%s color=chartreuse -> null" % t, bad == null, true)
	var ok_all: Variant = Loader.rig_for_anchor({"type": "neon", "id": "n", "color": "cyan"})
	_check("a known name still builds", ok_all != null, true)

	print("case E -- stage_light aims at its target, cone and energy derived")
	var host := Node3D.new()
	root.add_child(host)
	var man := {"anchors": [
		{"id": "stage_spot", "type": "stage_light", "color": "violet", "pos": [2.0, -1.0, 3.3],
			"target": [5.0, 3.0, 0.9], "radius": 1.8, "rot_y": 90.0, "drop": 3.3},
		{"id": "stage_no_target", "type": "stage_light", "pos": [0, 0, 3]},
		{"id": "wash_typo", "type": "club_wash", "color": "pnik", "pos": [0, 0, 3]},
		{"id": "ok_wash", "type": "club_wash", "color": "blue", "pos": [0, 0, 3], "drop": 3.2},
		{"id": "ambient", "type": "room_ambient", "pos": [0, 0, 1.6], "size": [12.0, 6.0, 3.2]},
		{"id": "sign_neon", "type": "neon", "color": "hot_pink", "pos": [0, 5, 2.5],
			"size": [2.4, 0.6], "rot_y": 0.0, "row": {"count": 3, "spacing": 1.0}},
		{"id": "f_ignored", "type": "fluorescent", "pos": [0, 0, 3], "drop": 3.2},
	]}
	var path := OS.get_user_data_dir().path_join("club_selftest.lights.json")
	var fh := FileAccess.open(path, FileAccess.WRITE)
	fh.store_string(JSON.stringify(man))
	fh.close()
	var res: Dictionary = Loader.bake_club(path, host)
	_check("in_manifest counts the 6 club anchors", res.get("in_manifest"), 6)
	_check("count built", res.get("count"), 4)
	_check("refused names the two", res.get("refused"), ["stage_no_target", "wash_typo"])
	_check("ok is false while something was refused", res.get("ok"), false)
	await process_frame
	var box := host.get_node_or_null(NodePath("LuxClub"))
	_check("LuxClub container", box != null, true)
	var st: Node3D = box.get_node_or_null(NodePath("stage_spot"))
	_check("stage rig built", st is LuxStageLightRig, true)
	var spots := _lights_of(st)
	_check("one spot", spots.size(), 1)
	var sp: SpotLight3D = spots[0]
	var tgt := Vector3(5.0, 0.9, -3.0)
	var fwd := -sp.global_transform.basis.z.normalized()
	var to_t := (tgt - sp.global_position).normalized()
	_near("spot axis . direction to target (rot_y 90)", fwd.dot(to_t), 1.0, 1e-4)
	var throw := Vector3(3.0, -2.4, -4.0).length()
	_near("cone = atan(radius / throw)", sp.spot_angle, rad_to_deg(atan(1.8 / throw)), 1e-3)
	_near("range = 1.25 x throw", sp.spot_range, 1.25 * throw, 1e-4)
	_near("value on target = level x office", _value(sp.light_energy, throw, sp.spot_range),
		stage_level * _office(3.3), 1e-5)
	_check("static colour = the anchor's", sp.light_color, palette["violet"])

	print("case F -- neon: a small omni, row along the wall, derived reach")
	var ne: Node3D = box.get_node_or_null(NodePath("sign_neon"))
	var nl := _lights_of(ne)
	_check("three omnis", nl.size() == 3 and nl[0] is OmniLight3D, true)
	_near("range = 0.5 x 2.4 + 1.0", nl[0].omni_range, 2.2, 1e-5)
	_near("value at half range = level x office(default drop)",
		_value(nl[0].light_energy, 1.1, 2.2), neon_level * _office(3.0), 1e-5)
	# rot_y 0 faces DC +X; the row must run along DC Y, which is Godot -Z.
	_near("row lamps share Godot x", absf(nl[0].global_position.x - nl[2].global_position.x), 0.0, 1e-4)
	_near("row spans Godot z by 2 m", absf(nl[0].global_position.z - nl[2].global_position.z), 2.0, 1e-4)

	print("case G -- room_ambient is a probe the size of the room")
	var amb: Node = box.get_node_or_null(NodePath("ambient"))
	_check("ReflectionProbe", amb is ReflectionProbe, true)
	var margin: float = Loader.get("ROOM_AMBIENT_MARGIN")
	_check("margin is positive (a box AT the faces leaves them lit)", margin > 0.0, true)
	_check("size DC [12, 6, 3.2] -> Godot (12, 3.2, 6) + 2 x margin", (amb as ReflectionProbe).size,
		Vector3(12.0, 3.2, 6.0) + Vector3.ONE * 2.0 * margin)
	_check("ambient mode colour", (amb as ReflectionProbe).ambient_mode, ReflectionProbe.AMBIENT_COLOR)
	_check("interior", (amb as ReflectionProbe).interior, true)
	_check("default colour violet", (amb as ReflectionProbe).ambient_color, palette["violet"])
	_check("no size -> refused", Loader.rig_for_anchor({"type": "room_ambient", "id": "a"}) == null, true)

	print("case H -- the cycle is a pure function of time")
	var cols := PackedColorArray([Color.RED, Color.GREEN, Color.BLUE])
	_check("static lamp 1", Stage.colour_at(cols, 1, 99.0, 0.0), Color.GREEN)
	_check("t 0", Stage.colour_at(cols, 0, 0.0, 4.0), Color.RED)
	_check("t 2.9 still holding", Stage.colour_at(cols, 0, 2.9, 4.0), Color.RED)
	_check("t 3.5 half way", Stage.colour_at(cols, 0, 3.5, 4.0), Color.RED.lerp(Color.GREEN, 0.5))
	_check("t 4 next", Stage.colour_at(cols, 0, 4.0, 4.0), Color.GREEN)
	_check("lamp 2 at t 4 runs two ahead", Stage.colour_at(cols, 2, 4.0, 4.0), Color.RED)
	_check("same instant, same colour", Stage.colour_at(cols, 0, 13.37, 4.0),
		Stage.colour_at(cols, 0, 13.37, 4.0))

	print("case I -- the club set is never handed a shadow map before a sign")
	_check("a neon called *_sign_neon ranks last",
		Lighting.shadow_rank_of_name("ext_0_s_sign_neon neon (baked)"), 4)
	_check("a sign still ranks first", Lighting.shadow_rank_of_name("ext_0_s_sign window (baked)"), 0)
	_check("stage light ranks last", Lighting.shadow_rank_of_name("stage_spot stage light (baked)"), 4)

	print("case J -- a stage rig survives a PackedScene round trip without doubling")
	var cyc: Node3D = Loader.rig_for_anchor({"type": "stage_light", "id": "cyc", "color": "red",
		"pos": [0, 0, 3.0], "target": [0, 0, 0.9], "cycle_s": 6.0, "row": {"count": 2, "spacing": 0.6}})
	root.add_child(cyc)
	await process_frame
	for c in cyc.get_children():
		c.owner = cyc
	var packed := PackedScene.new()
	_check("pack ok", packed.pack(cyc), OK)
	cyc.queue_free()
	await process_frame
	var again: Node3D = packed.instantiate() as Node3D
	root.add_child(again)
	await process_frame
	_check("two lamps after reload, not four", _lights_of(again).size(), 2)
	_check("cycle period kept", again.get("cycle_period_s"), 6.0)
	_check("colour list kept (7)", (again.get("colors") as PackedColorArray).size(), 7)
	_check("lamp 1 starts one colour further along the order",
		(_lights_of(again)[1] as Light3D).light_color, palette[order[(order.find("red") + 1) % 7]])
	again.queue_free()
	host.queue_free()
	await process_frame

	print("")
	if _fails == 0:
		print("  club light selftest ok: derived reach and energy, stable colours,")
		print("  unknown names refused, spots on target, the cycle is a function of time.")
	else:
		print("  club light selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
