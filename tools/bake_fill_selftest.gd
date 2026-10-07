extends SceneTree
## The rooms' floor, in the bake (0.68.0).
##
##     godot --headless --path lux -s res://tools/bake_fill_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds: `LuxLightLoader.add_bake_fills` lays one static omni a
## BAKE_FILL_CELL_M cell over every UNTINTED room probe, BAKE_FILL_HEIGHT_M
## over the room's floor and inside the room even when the probe is turned;
## a tinted probe (a club room) gets none; a room a Bare Bulb rig hangs in
## gets BAKE_FILL_BULB_SHARE of the energy; every fill reaches
## BAKE_FILL_REACH_CELLS cells, flat; the container has no owner, so a save
## cannot keep it; a second call replaces it; and with no energy given it
## reads the scene's LuxRoot preset, `bake_room_fill`. What the bake makes of
## it is measured on a level (`docs/findings/night_interiors/`).

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
## Lux's ROOM_AMBIENT_MARGIN: a probe is its room plus this a side
const MARGIN := 0.1

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


func _probe(pname: String, centre: Vector3, room: Vector3, yaw_deg: float, col: Color) -> ReflectionProbe:
	var p := ReflectionProbe.new()
	p.name = pname
	p.size = room + Vector3.ONE * 2.0 * MARGIN
	p.interior = true
	p.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	p.ambient_color = col
	p.position = centre
	p.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	return p


func _fills_of(container: Node, pname: String) -> Array:
	var out: Array = []
	if container == null:
		return out
	for c in container.get_children():
		if String(c.name).begins_with(pname + "_"):
			out.append(c)
	return out


func _inside(p: ReflectionProbe, at: Vector3) -> bool:
	var l: Vector3 = p.global_transform.affine_inverse() * at
	return absf(l.x) <= p.size.x * 0.5 and absf(l.y) <= p.size.y * 0.5 and absf(l.z) <= p.size.z * 0.5


func _fail_out(why: String) -> void:
	_fails += 1
	print("  FAIL %s" % why)
	print("bake fill selftest: %d FAILED" % _fails)
	quit(1)


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[bake_fill_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("bake fill selftest")
	var k: Dictionary = loader.get_script_constant_map()
	for cname in ["BAKE_FILL_CONTAINER", "BAKE_FILL_HEIGHT_M", "BAKE_FILL_CELL_M",
			"BAKE_FILL_REACH_CELLS", "BAKE_FILL_BULB_SHARE"]:
		_check("the loader names %s" % cname, k.has(cname), true)
	if not loader.has_method("add_bake_fills") or not k.has("BAKE_FILL_CELL_M"):
		_fail_out("the loader cannot lay a room's fill")
		return
	var cell: float = k["BAKE_FILL_CELL_M"]
	var height: float = k["BAKE_FILL_HEIGHT_M"]
	var reach: float = k["BAKE_FILL_REACH_CELLS"] * cell
	var share: float = k["BAKE_FILL_BULB_SHARE"]
	_near("a cell is 6 m", cell, 6.0, 1e-6)
	_near("a fill hangs at 1.7 m, under every ceiling fixture", height, 1.7, 1e-6)

	var level := Node3D.new()
	level.name = "Level"
	get_root().add_child(level)
	var white := Color(1.0, 1.0, 1.0)
	# a 12 x 3.2 x 8 m shop floor, its floor at y 0; a turned 7 x 3 x 5 room;
	# a club room, tinted violet; a 6 x 3.2 x 6 basement with a bare bulb
	var shop := _probe("shop_floor", Vector3(0.0, 1.6, 0.0), Vector3(12.0, 3.2, 8.0), 0.0, white)
	var turned := _probe("turned_room", Vector3(30.0, 1.5, 0.0), Vector3(7.0, 3.0, 5.0), 90.0, white)
	var club := _probe("club_floor", Vector3(-30.0, 1.6, 0.0), Vector3(10.0, 3.2, 10.0), 0.0,
		Color(0.6, 0.2, 1.0))
	var vault := _probe("vault", Vector3(0.0, -1.6, 20.0), Vector3(6.0, 3.2, 6.0), 0.0, white)
	for p in [shop, turned, club, vault]:
		level.add_child(p)
	var bulb: Node3D = loader.rig_for_anchor({"id": "vault_bulbs", "type": "pendant",
		"pos": [0.0, -20.0, -0.6], "rot_y": 0.0, "drop": 2.6, "row": {"count": 1, "spacing": 0.0}})
	level.add_child(bulb)
	bulb.position = Vector3(0.0, -0.6, 20.0)
	await process_frame

	var fills: Node3D = loader.add_bake_fills(level, 0.025)
	if fills == null:
		_fail_out("add_bake_fills laid nothing over four probes")
		return
	_check("the container's name", String(fills.name), String(k["BAKE_FILL_CONTAINER"]))
	_check("the container has no owner, so a save cannot keep it", fills.owner == null, true)
	_check("a 12 x 8 room gets 2 x 2 fills", _fills_of(fills, "shop_floor").size(), 4)
	_check("a turned 7 x 5 room gets 2 x 1", _fills_of(fills, "turned_room").size(), 2)
	_check("a club room gets none", _fills_of(fills, "club_floor").size(), 0)
	_check("a 6 x 6 basement gets 1", _fills_of(fills, "vault").size(), 1)
	_check("seven in all", fills.get_child_count(), 7)
	var shop_ok := true
	for f in _fills_of(fills, "shop_floor"):
		var o := f as OmniLight3D
		shop_ok = shop_ok and _inside(shop, o.global_position) \
			and absf(o.global_position.y - height) < 1e-4 \
			and absf(o.light_energy - 0.025) < 1e-6 \
			and absf(o.omni_range - reach) < 1e-4 \
			and o.omni_attenuation == 0.0 \
			and o.light_bake_mode == Light3D.BAKE_STATIC
	_check("the shop's fills: in the room, 1.7 m up, 0.025, flat, static, reach 9 m", shop_ok, true)
	var turned_ok := true
	for f in _fills_of(fills, "turned_room"):
		turned_ok = turned_ok and _inside(turned, (f as Node3D).global_position)
	_check("the turned room's fills stand inside it", turned_ok, true)
	var vf := _fills_of(fills, "vault")
	if vf.size() == 1:
		_near("the bulb-lit basement keeps the bulb share", (vf[0] as OmniLight3D).light_energy,
			0.025 * share, 1e-6)
		_near("over the basement's own floor", (vf[0] as Node3D).global_position.y, -3.2 + height, 1e-4)

	var again: Node3D = loader.add_bake_fills(level, 0.025)
	var containers := 0
	for c in level.get_children():
		if String(c.name).begins_with(String(k["BAKE_FILL_CONTAINER"])):
			containers += 1
	_check("a second call replaces the fill, not adds to it", containers, 1)
	_check("...and lays the same seven", again.get_child_count() if again != null else -1, 7)
	again.free()

	# with no energy given: the scene's LuxRoot preset decides
	_check("no LuxRoot in the scene: no fill", loader.add_bake_fills(level) == null, true)
	var preset := LuxPreset.new()
	_check("a preset's default floor", str(preset.get("bake_room_fill")), "0.025")
	preset.set("bake_room_fill", 0.04)
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar active_preset: Resource\nvar local_override: Resource\n"
	gs.reload()
	var stand_in := Node.new()
	stand_in.set_script(gs)
	stand_in.set("active_preset", preset)
	level.add_child(stand_in)
	stand_in.add_to_group(&"lux_root")
	var from_preset: Node3D = loader.add_bake_fills(level)
	var pf := _fills_of(from_preset, "shop_floor")
	_check("the preset's fill is laid", pf.size(), 4)
	if pf.size() > 0:
		_near("at the preset's energy", (pf[0] as OmniLight3D).light_energy, 0.04, 1e-6)
	preset.set("bake_room_fill", 0.0)
	_check("a preset with no floor lays none", loader.add_bake_fills(level) == null, true)
	_check("...and clears the fill an earlier call laid",
		level.get_node_or_null(NodePath(String(k["BAKE_FILL_CONTAINER"]))) == null, true)

	print("bake fill selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
