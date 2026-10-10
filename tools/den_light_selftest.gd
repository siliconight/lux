extends SceneTree
## A den is lit at its walls and in its own colour (0.72.0, roadmap 219 note 1).
##
##     godot --headless --path lux -s res://tools/den_light_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds, of `LuxLightLoader.add_bake_fills` on a den -- a building
## with a tinted room probe:
## - its tinted room is filled at DEN_FILL_SHARE in the probe's own colour,
##   and its untinted back room white at DEN_BACK_SHARE, the bulb rooms'
##   share (BAKE_FILL_BULB_SHARE);
## - the tinted room gets DEN_WASH_PREFIX washers along every wall, about
##   DEN_WASH_PITCH_M apart: inside the room, DEN_WASH_DROP_M under its
##   ceiling, static, owned, each aimed down at the wall it washes and in the
##   colour of the nearest club wash in the room;
## - each washer puts DEN_WASH_LEVEL x REFERENCE_POOL on the WALL at its aim
##   point, by the closed form the loader's energies are solved with,
##   cosine of incidence included;
## - the back room gets no washers, and an ordinary building beside the den
##   keeps its white fill at share 1 and gets none either.
## What the bake makes of it is measured on a level: the factory root's
## `docs/findings/club_light_trials/`.

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


func _probe(pname: String, centre: Vector3, room: Vector3, col: Color) -> ReflectionProbe:
	var p := ReflectionProbe.new()
	p.name = pname
	p.size = room + Vector3.ONE * 2.0 * MARGIN
	p.interior = true
	p.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	p.ambient_color = col
	p.position = centre
	return p


func _named(container: Node, prefix: String) -> Array:
	var out: Array = []
	if container == null:
		return out
	for c in container.get_children():
		if String(c.name).begins_with(prefix):
			out.append(c)
	return out


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[den_light_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("den light selftest")
	var k: Dictionary = loader.get_script_constant_map()
	for cname in ["DEN_WASH_LEVEL", "DEN_WASH_PITCH_M", "DEN_WASH_INSET_M", "DEN_WASH_DROP_M",
			"DEN_WASH_AIM_M", "DEN_WASH_ANGLE_DEG", "DEN_WASH_RANGE_M", "DEN_WASH_PREFIX",
			"DEN_FILL_SHARE", "DEN_BACK_SHARE", "REFERENCE_POOL"]:
		_check("the loader names %s" % cname, k.has(cname), true)
	if not k.has("DEN_WASH_LEVEL") or not k.has("DEN_FILL_SHARE"):
		print("den light selftest: %d FAILED" % (_fails + 1))
		quit(1)
		return
	var level_v: float = k["DEN_WASH_LEVEL"]
	var pool: float = k["REFERENCE_POOL"]
	var fill_share: float = k["DEN_FILL_SHARE"]
	var back_share: float = k["DEN_BACK_SHARE"]
	var drop: float = k["DEN_WASH_DROP_M"]
	var inset: float = k["DEN_WASH_INSET_M"]
	var aim_h: float = k["DEN_WASH_AIM_M"]
	var wash_range: float = k["DEN_WASH_RANGE_M"]
	var prefix: String = k["DEN_WASH_PREFIX"]
	_near("a back room keeps the bulb rooms' moody share", back_share,
		float(k["BAKE_FILL_BULB_SHARE"]), 1e-6)

	var level := Node3D.new()
	level.name = "Level"
	get_root().add_child(level)
	var white := Color(1.0, 1.0, 1.0)
	var amber := Color(1.0, 0.55, 0.08)
	# a den, building b7: a 12 x 3.3 x 9 m club floor tinted amber, its floor
	# at y 0, and a 6 x 3.3 x 6 m back room, untinted; an ordinary office, b8
	var floor_p := _probe("b7_main_floor_ambient", Vector3(0.0, 1.65, 0.0), Vector3(12.0, 3.3, 9.0), amber)
	var back_p := _probe("b7_back_ambient", Vector3(0.0, 1.65, 10.0), Vector3(6.0, 3.3, 6.0), white)
	var office := _probe("b8_office_ambient", Vector3(40.0, 1.65, 0.0), Vector3(6.0, 3.3, 6.0), white)
	for p in [floor_p, back_p, office]:
		level.add_child(p)
	# two club washes in the club floor: red at its -x end, cyan at its +x end
	var red: Node3D = loader.rig_for_anchor({"type": "club_wash", "id": "b7/wash_red",
		"color": "red", "drop": 3.1})
	var cyan: Node3D = loader.rig_for_anchor({"type": "club_wash", "id": "b7/wash_cyan",
		"color": "cyan", "drop": 3.1})
	level.add_child(red)
	level.add_child(cyan)
	red.position = Vector3(-4.5, 3.3, 0.0)
	cyan.position = Vector3(4.5, 3.3, 0.0)
	await process_frame

	var got: Node3D = loader.add_bake_fills(level, 0.025)
	if got == null:
		print("  FAIL add_bake_fills laid nothing over three probes")
		print("den light selftest: %d FAILED" % (_fails + 1))
		quit(1)
		return

	# THE FILLS
	var ff := _named(got, "b7_main_floor_ambient_")
	_check("the club floor is filled, 2 x 2", ff.size(), 4)
	var ff_ok := true
	for f in ff:
		var o := f as OmniLight3D
		ff_ok = ff_ok and o.light_color.is_equal_approx(amber) \
			and absf(o.light_energy - 0.025 * fill_share) < 1e-6
	_check("...in its own colour, at DEN_FILL_SHARE", ff_ok, true)
	var bf := _named(got, "b7_back_ambient_")
	_check("the den's back room is filled once", bf.size(), 1)
	if bf.size() == 1:
		_check("...white", (bf[0] as OmniLight3D).light_color.is_equal_approx(white), true)
		_near("...at DEN_BACK_SHARE", (bf[0] as OmniLight3D).light_energy, 0.025 * back_share, 1e-6)
	var of := _named(got, "b8_office_ambient_")
	_check("an ordinary building beside it keeps its fill", of.size(), 1)
	if of.size() == 1:
		_near("...at share 1", (of[0] as OmniLight3D).light_energy, 0.025, 1e-6)
		_check("...white", (of[0] as OmniLight3D).light_color.is_equal_approx(white), true)

	# THE WASHERS: walls of 9 m (at +-x) take 3, walls of 12 m (at +-z) take 4
	var ws := _named(got, prefix + "_b7_main_floor_ambient_")
	_check("the club floor's washers, 3 + 3 + 4 + 4", ws.size(), 14)
	_check("the back room has none", _named(got, prefix + "_b7_back_ambient_").size(), 0)
	_check("the office has none", _named(got, prefix + "_b8_office_ambient_").size(), 0)
	var head := 3.3 - drop
	var placed := true
	var aimed := true
	var owned := true
	var on_wall := 0.0
	var red_ok := true
	var cyan_ok := true
	for s in ws:
		var sp := s as SpotLight3D
		var at := sp.global_position
		var l: Vector3 = floor_p.global_transform.affine_inverse() * at
		placed = placed and absf(l.x) <= 6.0 and absf(l.z) <= 4.5 and absf(at.y - head) < 1e-4 \
			and sp.light_bake_mode == Light3D.BAKE_STATIC
		owned = owned and sp.owner == level
		# the wall it washes is the one it stands `inset` from
		var normal := Vector3.ZERO
		if absf(absf(l.x) - (6.0 - inset)) < 1e-3:
			normal = Vector3(signf(l.x), 0.0, 0.0)
		elif absf(absf(l.z) - (4.5 - inset)) < 1e-3:
			normal = Vector3(0.0, 0.0, signf(l.z))
		var fwd := -sp.global_transform.basis.z
		aimed = aimed and normal != Vector3.ZERO and fwd.dot(normal) > 0.0 and fwd.y < 0.0
		# the value at its aim point, on the wall: the closed form, cosine included
		var d := sqrt(inset * inset + (head - aim_h) * (head - aim_h))
		var win := pow(maxf(1.0 - pow(d / wash_range, 4.0), 0.0), 2.0)
		on_wall = sp.light_energy * win * (inset / d) / (d * d)
		if normal == Vector3(-1.0, 0.0, 0.0):
			red_ok = red_ok and sp.light_color.is_equal_approx(Color(1.0, 0.04, 0.06))
		if normal == Vector3(1.0, 0.0, 0.0):
			cyan_ok = cyan_ok and sp.light_color.is_equal_approx(Color(0.0, 0.8, 1.0))
	_check("every washer hangs inside the room, under its ceiling, static", placed, true)
	_check("...owned by the scene, so the lightmapper takes it", owned, true)
	_check("...aimed down at the wall it stands in from", aimed, true)
	_check("the -x wall's washers take the red wash's colour", red_ok, true)
	_check("the +x wall's washers take the cyan wash's colour", cyan_ok, true)
	_near("a washer puts DEN_WASH_LEVEL x REFERENCE_POOL on the wall", on_wall, level_v * pool, 1e-3)

	# 4 + 1 + 1 fills and 14 washers; the second call frees the first container
	var first := got.get_child_count()
	_check("twenty in all", first, 20)
	var again: Node3D = loader.add_bake_fills(level, 0.025)
	var containers := 0
	for c in level.get_children():
		if String(c.name).begins_with(String(k["BAKE_FILL_CONTAINER"])):
			containers += 1
	_check("a second call replaces them, not adds to them", containers, 1)
	_check("...and lays the same twenty", again.get_child_count() if again != null else -1, first)

	if _fails == 0:
		print("den light selftest: all ok")
		quit(0)
	else:
		print("den light selftest: %d FAILED" % _fails)
		quit(1)
