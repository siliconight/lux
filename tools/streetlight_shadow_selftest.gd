extends SceneTree
## The streetlight's lamp hangs below its mount (0.64.0).
##
##     godot --rendering-method gl_compatibility --path lux -s res://tools/streetlight_shadow_selftest.gd
##
## Opens a window (it reads frames; headless draws nothing), measures, and
## quits itself. Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2
## = could not run.
##
## What this holds: a shadowed spot at the lens point, 5 mm over the
## shaft's top cap, blacks its whole pool (the control, which proves the
## instrument sees what the walk showed); the rig hangs its lamp
## `LAMP_HANG_M` below the mount, and hung there the pool is what it is with
## no shadow at all. The geometry is Zoo's streetlight recipe at a slot: a
## 0.06 m shaft whose cap is 5 mm under the mount, the lens on the mount,
## the shoebox head above.

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
	# Zoo's streetlight at a slot: the mount is the lens point Lot writes
	# (the module's top less 0.175); the shaft's top cap is 5 mm under it,
	# the lens 0.02 thick sits on it, the head 0.015 over it.
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
	var rr := LuxLightRig.new()
	rr.rig_name = &"Streetlight (baked)"
	rr.light_color = Color(1.0, 0.54, 0.05)
	rr.energy = 19.2
	rr.light_range = 14.0
	rr.count = 1
	rr.spacing = 0.0
	rr.mount_height = 0.0
	rr.shadows_enabled = true
	var rig := LuxStreetlightRig.new()
	rig.rig = rr
	world.add_child(rig)
	rig.position = Vector3(0.0, mount, 0.0)
	for _i in range(20):
		await process_frame
	var lamp: SpotLight3D = _lamp(rig)
	if lamp == null:
		print("  FAIL the rig built no lamp")
		_exit(2)
		return
	var vp: Viewport = root.get_viewport()
	print("  renderer %s, positional shadow atlas %d (%s), lamp shadow bias %.3f normal %.2f" % [
		RenderingServer.get_current_rendering_method(), vp.positional_shadow_atlas_size,
		str(ProjectSettings.get_setting("rendering/lights_and_shadows/positional_shadow/atlas_size", "default")),
		lamp.shadow_bias, lamp.shadow_normal_bias])
	# The instrument's own control: a slab a metre under the lamp, inside the
	# cone, must black the pool, or shadows are not drawing here at all.
	var slab := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(3.0, 0.05, 3.0)
	slab.mesh = sm
	slab.material_override = grey
	world.add_child(slab)
	slab.position = Vector3(0.0, mount - 1.0, 0.0)
	var slabbed: float = await _read()
	slab.visible = false
	_near("the lamp hangs LAMP_HANG_M below the mount", lamp.position.y,
		rr.mount_height - LuxStreetlightRig.LAMP_HANG_M, 1e-6)
	_check("the lamp carries the shadow the budget gave it", lamp.shadow_enabled, true)
	var hung: float = await _read()
	lamp.shadow_enabled = false
	var unshadowed: float = await _read()
	lamp.shadow_enabled = true
	lamp.position.y = rr.mount_height
	var at_lens: float = await _read()
	print("  ground under the pole, 9 m off:  hung %.3f   unshadowed %.3f   at the lens point %.3f   under a slab %.3f" % [hung, unshadowed, at_lens, slabbed])
	_check("the unshadowed pool is lit at all", unshadowed > 0.05, true)
	_check("control: a slab under the lamp blacks the pool (shadows draw here)", slabbed < unshadowed * 0.1, true)
	_check("control: at the lens point, the cap 5 mm under it blacks the pool (under a tenth)", at_lens < unshadowed * 0.1, true)
	_check("hung, the pool keeps at least 0.8 of the unshadowed pool", hung >= unshadowed * 0.8, true)
	print("streetlight shadow selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	_exit(1 if _fails > 0 else 0)
