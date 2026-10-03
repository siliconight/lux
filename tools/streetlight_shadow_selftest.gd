extends SceneTree
## The streetlight's lamp sits beside its pole, under the lens (0.65.0).
##
##     godot --rendering-method gl_compatibility --path lux -s res://tools/streetlight_shadow_selftest.gd
##
## Opens a window (it reads frames; headless draws nothing), measures, and
## quits itself. Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2
## = could not run.
##
## What this holds, on the pole the loader's own `streetlight` branch
## builds over Zoo's streetlight at a slot (a 0.06 m shaft whose cap is 5 mm
## under the mount, the lens on the mount, the shoebox head above):
##
##   * the lamp sits `POLE_LAMP_ALONG_M` along the head from the pole's axis
##     and `POLE_LAMP_DROP_M` under the lens: outside the steel, under the
##     lens at the genome's narrowest head;
##   * placed so and shadowed, the pool keeps at least 0.8 of its
##     unshadowed self in real time;
##   * two controls prove the instrument sees a shadow: a slab under the
##     lamp blacks the pool, and the lamp on the axis at the lens point --
##     the placement before 0.64.0 -- blacks it too;
##   * a wall pack (the same rig, its own geometry) keeps 0.64.0's
##     placement, 0.10 m under its mount on the axis.
##
## What it cannot hold, and `docs/findings/light_bake/NOTES.md` does: the
## light BAKE sees the lamp inside the shaft (0.64.0's hang) as sealed in --
## 0 lit texels -- where a shadow map, culling the shaft's inside faces,
## drew the pool. A bake needs the editor and cannot run here.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"

var _fails: int = 0


func _initialize() -> void:
	_main.call_deferred()


func _exit(code: int) -> void:
	quit(code)
	await process_frame
	await process_frame
	OS.kill(OS.get_process_id())


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


func _lamp(rig: Node) -> SpotLight3D:
	for c in rig.get_children():
		if c is SpotLight3D:
			return c
	return null


func _band(img: Image) -> float:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var s: float = 0.0
	var n: int = 0
	for y in range(int(h * 0.50), int(h * 0.70), 2):
		for x in range(int(w * 0.3), int(w * 0.7), 2):
			s += img.get_pixel(x, y).get_luminance()
			n += 1
	return s / float(n)


func _read() -> float:
	for _i in range(8):
		await process_frame
	return _band(root.get_viewport().get_texture().get_image())


func _box(parent: Node, size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	parent.add_child(mi)
	mi.position = at


func _main() -> void:
	print("streetlight shadow selftest")
	var loader: Script = load(LOADER)
	if loader == null:
		print("  FAIL could not load the loader")
		_exit(2)
		return
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.BLACK
	e.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.environment = e
	world.add_child(env)
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.6, 0.6, 0.6)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40.0, 40.0)
	ground.mesh = pm
	ground.material_override = grey
	world.add_child(ground)
	# Zoo's streetlight at a slot: the mount is the lens point Lot writes;
	# the shaft's cap is 5 mm under it, the lens sits on it, the head over it.
	var mount: float = 6.0
	var cap: float = mount - 0.005
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.06
	cm.bottom_radius = 0.06
	cm.height = cap
	shaft.mesh = cm
	shaft.material_override = grey
	world.add_child(shaft)
	shaft.position = Vector3(0.0, cap * 0.5, 0.0)
	_box(world, Vector3(0.7, 0.16, 0.3), Vector3(0.0, cap + 0.02 + 0.08, 0.0), grey)
	_box(world, Vector3(0.56, 0.02, 0.225), Vector3(0.0, cap + 0.015, 0.0), grey)
	var cam := Camera3D.new()
	cam.fov = 60.0
	world.add_child(cam)
	cam.make_current()
	cam.look_at_from_position(Vector3(9.0, 1.6, 0.0), Vector3(0.0, 0.3, 0.0), Vector3.UP)
	# the pole, built by the loader's own streetlight branch
	var rig: Node3D = loader.rig_for_anchor({"id": "site_lamp_t", "type": "streetlight",
		"pos": [0.0, 0.0, mount], "rot_y": 0.0})
	var rr: LuxLightRig = rig.get("rig")
	rr.shadows_enabled = true                  # what the shadow budget gives the first poles
	world.add_child(rig)
	rig.position = Vector3(0.0, mount, 0.0)
	for _i in range(20):
		await process_frame
	var lamp: SpotLight3D = _lamp(rig)
	if lamp == null:
		print("  FAIL the rig built no lamp")
		_exit(2)
		return
	_near("the lamp sits POLE_LAMP_ALONG_M along the head", lamp.position.x,
		LuxStreetlightRig.POLE_LAMP_ALONG_M, 1e-6)
	_near("...and POLE_LAMP_DROP_M under the lens", lamp.position.y,
		rr.mount_height - LuxStreetlightRig.POLE_LAMP_DROP_M, 1e-6)
	_check("outside the steel: 0.1 m or more clear of the shaft's 0.06 m radius",
		absf(lamp.position.x) - 0.06 >= 0.1, true)
	_check("under the lens at the genome's narrowest head (lens half-length 0.2 m)",
		absf(lamp.position.x) <= 0.2 + 1e-6, true)
	_check("the lamp carries the shadow the budget gave it", lamp.shadow_enabled, true)
	_near("...at the pole's shadow bias, 0.1 (acne at the default in a 16-bit atlas)", lamp.shadow_bias, 0.1, 1e-6)
	# the instrument's own control: a slab a metre under the lamp
	var slab := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(3.0, 0.05, 3.0)
	slab.mesh = sm
	slab.material_override = grey
	world.add_child(slab)
	slab.position = Vector3(0.0, mount - 1.0, 0.0)
	var slabbed: float = await _read()
	slab.visible = false
	var placed: float = await _read()
	lamp.shadow_enabled = false
	var unshadowed: float = await _read()
	lamp.shadow_enabled = true
	# The cap control runs at the ENGINE's bias: at the pole's 0.1 the cap
	# 5 mm under an on-axis lamp is swallowed by the bias and the pool stays
	# lit, which is a fact about the bias and not the instrument. (A ray-traced
	# bake has no bias, and baked that lamp to nothing; hence the offset.)
	var keep: Vector3 = lamp.position
	var keep_bias: float = lamp.shadow_bias
	lamp.position = Vector3(0.0, rr.mount_height, 0.0)
	lamp.shadow_bias = 0.03
	var on_axis: float = await _read()
	lamp.position = keep
	lamp.shadow_bias = keep_bias
	print("  ground under the pole, 9 m off:  placed %.3f   unshadowed %.3f   on the axis at the lens %.3f   under a slab %.3f" % [
		placed, unshadowed, on_axis, slabbed])
	_check("the unshadowed pool is lit at all", unshadowed > 0.05, true)
	_check("control: a slab under the lamp blacks the pool (shadows draw here)", slabbed < unshadowed * 0.1, true)
	_check("control: on the axis at the lens point, the cap blacks the pool", on_axis < unshadowed * 0.1, true)
	_check("placed, the pool keeps at least 0.8 of the unshadowed pool", placed >= unshadowed * 0.8, true)
	# a wall pack keeps its own placement
	var wp: Node3D = loader.rig_for_anchor({"id": "Spawned_wall_pack_t", "type": "wall_pack",
		"pos": [0.0, 0.0, 2.5], "rot_y": 0.0})
	world.add_child(wp)
	await process_frame
	var wl: SpotLight3D = _lamp(wp)
	_check("a wall pack keeps 0.64.0's placement", [snappedf(wl.position.x, 1e-6), snappedf(wl.position.y, 1e-6)],
		[0.0, snappedf((wp.get("rig") as LuxLightRig).mount_height - LuxStreetlightRig.LAMP_HANG_M, 1e-6)])
	print("streetlight shadow selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	_exit(1 if _fails > 0 else 0)
