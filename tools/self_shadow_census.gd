extends SceneTree
## Self-shadow census: which rig lights go dark when they are given a shadow
## map? Run on a walk copy of an export, with a window (it reads frames):
##
##     copy this file beside the walk's project.godot, then
##     godot --path <walk copy> --script self_shadow_census.gd
##
## For every Light3D under a node carrying a `rig` (a Lux rig), with every
## other light off: the light's target is the first collider its axis hits
## (its range * 0.6 along the axis when nothing is hit), a camera 6 m to the
## side of the target and 1.2 m above it looks at it, and the frame's centre
## band is read with the light's shadow OFF and then ON. A light whose own
## hardware sits inside its shadow frustum reads near 0: the fixture shadows
## its own pool. The summary lists those under SELF_SHADOW_RATIO. A row
## whose unshadowed read is under 0.01 is `unreadable` from that camera, not
## a verdict. Prints what it measured and nothing else; the cause belongs
## with whoever reads it.

const SELF_SHADOW_RATIO := 0.5
const SCENE := "res://_walk.tscn"


func _initialize() -> void:
	_run.call_deferred()


func _exit(code: int) -> void:
	quit(code)
	await process_frame
	await process_frame
	OS.kill(OS.get_process_id())


func _all_lights(n: Node, out: Array) -> void:
	if n is Light3D and not (n is DirectionalLight3D):
		out.append(n)
	for c in n.get_children():
		_all_lights(c, out)


func _hide_canvas(n: Node) -> void:
	if n is CanvasLayer and not String(n.name).contains("Lux"):
		(n as CanvasLayer).visible = false
	for c: Node in n.get_children():
		_hide_canvas(c)


func _band(img: Image) -> float:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var s: float = 0.0
	var n: int = 0
	for y in range(int(h * 0.35), int(h * 0.75), 2):
		for x in range(int(w * 0.25), int(w * 0.75), 2):
			s += img.get_pixel(x, y).get_luminance()
			n += 1
	return s / float(n)


func _read() -> float:
	for _i in range(6):
		await process_frame
	return _band(root.get_viewport().get_texture().get_image())


func _rig_name(l: Light3D) -> String:
	var p: Node = l.get_parent()
	while p != null:
		if p.get(&"rig") != null:
			return String(p.name)
		p = p.get_parent()
	return ""


## The surface the light's axis reaches: the first collider hit, else
## `range * 0.6` along the axis. An omni's axis is straight down.
func _target(lt: Light3D, rng: float) -> Vector3:
	var fwd: Vector3 = -lt.global_transform.basis.z if lt is SpotLight3D else Vector3.DOWN
	var from: Vector3 = lt.global_position + fwd * 0.3
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * rng)
	var hit: Dictionary = lt.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return lt.global_position + fwd * rng * 0.6
	return hit["position"]


func _run() -> void:
	change_scene_to_file(SCENE)
	for _i in range(30):
		await process_frame
	var steady: int = 0
	var waited: int = 0
	while steady < 30 and waited < 6000:
		await process_frame
		waited += 1
		steady = steady + 1 if is_equal_approx(root.get_viewport().scaling_3d_scale, 1.0) else 0
	if steady < 30:
		print("CENSUS CANNOT SHOOT")
		_exit(2)
		return
	_hide_canvas(root)
	var all: Array = []
	_all_lights(root, all)
	var rigged: Array = []
	var was: Dictionary = {}
	for l in all:
		was[l] = [l.visible, l.shadow_enabled]
		l.visible = false
		if _rig_name(l) != "":
			rigged.append(l)
	print("CENSUS %d positional lights, %d on rigs" % [all.size(), rigged.size()])
	var cam := Camera3D.new()
	cam.fov = 60.0
	root.add_child(cam)
	cam.make_current()
	var flagged: Array = []
	var unreadable: int = 0
	for l in rigged:
		var lt: Light3D = l
		var rng: float = (lt as SpotLight3D).spot_range if lt is SpotLight3D else (lt as OmniLight3D).omni_range
		var target: Vector3 = _target(lt, rng)
		var fwd: Vector3 = -lt.global_transform.basis.z
		var side: Vector3 = Vector3(fwd.z, 0.0, -fwd.x)
		if side.length() < 0.1:
			side = Vector3(1.0, 0.0, 0.0)
		var eye: Vector3 = target + side.normalized() * 6.0 + Vector3(0.0, 1.2, 0.0)
		cam.look_at_from_position(eye, target, Vector3.UP)
		lt.visible = true
		lt.shadow_enabled = false
		var off: float = await _read()
		lt.shadow_enabled = true
		var on: float = await _read()
		lt.shadow_enabled = was[l][1]
		lt.visible = false
		var ratio: float = on / off if off > 1e-4 else -1.0
		var tag: String = "ok"
		if off <= 0.01:
			tag = "unreadable"
			unreadable += 1
		elif ratio >= 0.0 and ratio < SELF_SHADOW_RATIO:
			tag = "SELF-SHADOWED"
			flagged.append(_rig_name(lt))
		print("CENSUS %-28s %-14s %-4s at (%6.1f %5.1f %6.1f) target y %5.2f off=%.3f on=%.3f ratio=%s %s" % [
			_rig_name(lt), String(lt.name), "spot" if lt is SpotLight3D else "omni",
			lt.global_position.x, lt.global_position.y, lt.global_position.z, target.y, off, on,
			("%.2f" % ratio) if ratio >= 0.0 else "-", tag])
	for l in all:
		l.visible = was[l][0]
	print("CENSUS self-shadowed: %d of %d rig lights (%d unreadable): %s" % [flagged.size(), rigged.size(), unreadable, str(flagged)])
	print("CENSUS done")
	_exit(0)
