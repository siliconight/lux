extends SceneTree
## What the renderer actually does with the rain technique, measured in pixels.
##
##     godot --path lux --rendering-method gl_compatibility -s res://tools/rain_renderer_probe.gd
##     godot --path lux --rendering-method forward_plus     -s res://tools/rain_renderer_probe.gd
##
## NEEDS A WINDOW: `--headless` has no rendering, so there is nothing to count.
##
## Every case is the same stage: a black void, one camera 20 m back looking at
## the origin, an emitter 10 m up dropping white unshaded particles straight
## down for 20 m, and (where the case has one) a collider whose top is y = 0.
## Particles are counted as bright pixels in two screen bands projected from
## world space: ABOVE (y 2..8) and BELOW (y -8..-2). A collider that works
## leaves BELOW near zero while ABOVE stays lit; the no-collider baseline is
## what proves BELOW can be lit at all, so a zero there is not a blank frame.
##
## Prints one `RAIN_PROBE` line per case and a JSON block. Numbers only: what
## a count means is argued in the changelog, not here.

const W := 800
const H := 600
const SETTLE_S := 2.5

var _cam: Camera3D
var _stage: Node3D
var _results: Array = []


func _initialize() -> void:
	_main()


func _main() -> void:
	root.size = Vector2i(W, H)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.BLACK
	e.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	root.add_child(env)

	_cam = Camera3D.new()
	_cam.fov = 75.0
	_cam.far = 200.0
	root.add_child(_cam)
	await process_frame
	_cam.global_position = Vector3(0.0, 0.0, 20.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	_cam.make_current()

	var vp_rid: RID = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	for _i in 5:
		await process_frame

	await _case("baseline_no_collider", {})
	await _case("box_hide_on_contact", {"collider": "box", "thickness": 0.5})
	await _case("heightfield_hide_on_contact", {"collider": "heightfield"})
	# The control for the case above: the same heightfield with no geometry
	# under it. If this hides BELOW too, the heightfield case measured a box.
	await _case("heightfield_no_mesh", {"collider": "heightfield", "no_mesh": true})
	await _case("sphere_hide_on_contact", {"collider": "sphere"})
	# Preprocess: the volume should be full on the first drawn frame, which is
	# what a camera that teleports needs. Settled for 0.1 s, not 2.5.
	await _case("no_preprocess_short", {"settle_s": 0.1})
	await _case("preprocess_short", {"settle_s": 0.1, "preprocess": 2.0})
	# Does PREPROCESS honour colliders? The same box as box_hide_on_contact,
	# read 0.1 s after start with and without a 2 s preprocess, and again
	# 3 s after start, by which time every preprocessed drop has expired.
	await _case("box_preprocess_short", {"collider": "box", "thickness": 0.5, "settle_s": 0.1, "preprocess": 2.0})
	await _case("box_preprocess_3s", {"collider": "box", "thickness": 0.5, "settle_s": 3.0, "preprocess": 2.0})
	await _case("trails_no_collider", {"trails": true})
	await _case("trails_box", {"trails": true, "collider": "box", "thickness": 0.5})
	await _case("subemitter_box", {"collider": "box", "thickness": 0.5, "sub": true})
	# Tunnelling: a 5 cm box, 10 m/s fall. At fixed_fps 10 a particle moves
	# 1.0 m per step; at 60 it moves 0.167 m. Both exceed 0.05, so both are
	# expected to leak; the 1.0 m box case below is the control.
	# A particle BORN inside a collider: the emitter (y = 10) sits inside a box
	# spanning y -1..12. Hidden at once means a full-height building box keeps
	# the interior dry wherever the emitter plane lands.
	await _case("emit_inside_box", {"collider": "tall_box"})
	# How many colliders one system honours. Decoy boxes that touch no
	# particle are added FIRST, inside the visibility AABB; the slab last.
	await _case("decoys_30_then_slab", {"collider": "box", "thickness": 0.5, "decoys": 30})
	await _case("decoys_31_then_slab", {"collider": "box", "thickness": 0.5, "decoys": 31})
	await _case("decoys_32_then_slab", {"collider": "box", "thickness": 0.5, "decoys": 32})
	await _case("decoys_40_then_slab", {"collider": "box", "thickness": 0.5, "decoys": 40})
	await _case("slab_then_decoys_64", {"collider": "box", "thickness": 0.5, "decoys_after": 64})
	await _case("thin_box_fps10", {"collider": "box", "thickness": 0.05, "fixed_fps": 10})
	await _case("thin_box_fps60", {"collider": "box", "thickness": 0.05, "fixed_fps": 60})
	await _case("thick_box_fps10", {"collider": "box", "thickness": 1.2, "fixed_fps": 10})
	await _case("volumetric_fog_off", {"fog_test": false, "no_particles": true})
	await _case("volumetric_fog_on", {"fog_test": true, "no_particles": true})

	print("<<<RAIN_PROBE_JSON")
	print(JSON.stringify({
		"engine": String(Engine.get_version_info().get("string", "")),
		"rendering_method": String(RenderingServer.get_current_rendering_method()),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"cases": _results,
	}, " "))
	print("RAIN_PROBE_JSON>>>")
	quit(0)


func _case(case_name: String, opt: Dictionary) -> void:
	if _stage != null:
		_stage.queue_free()
		await process_frame
	_stage = Node3D.new()
	_stage.name = "Stage"
	root.add_child(_stage)
	var env: Environment = (root.get_child(0) as WorldEnvironment).environment
	env.volumetric_fog_enabled = false

	var fixed_fps: int = int(opt.get("fixed_fps", 60))
	var parts: GPUParticles3D = null
	if not bool(opt.get("no_particles", false)):
		parts = _emitter(fixed_fps, bool(opt.get("trails", false)))
		parts.preprocess = float(opt.get("preprocess", 0.0))
		_stage.add_child(parts)
		parts.global_position = Vector3(0.0, 10.0, 0.0)

	for i in int(opt.get("decoys", 0)):
		var d := GPUParticlesCollisionBox3D.new()
		d.size = Vector3(0.2, 0.2, 0.2)
		_stage.add_child(d)
		d.global_position = Vector3(13.0, -20.0 + float(i) * 0.5, -9.0)
	var collider: String = String(opt.get("collider", ""))
	var thickness: float = float(opt.get("thickness", 0.5))
	match collider:
		"box":
			var b := GPUParticlesCollisionBox3D.new()
			b.size = Vector3(24.0, thickness, 10.0)
			_stage.add_child(b)
			b.global_position = Vector3(0.0, -thickness * 0.5, 0.0)
		"tall_box":
			var tb := GPUParticlesCollisionBox3D.new()
			tb.size = Vector3(24.0, 13.0, 10.0)
			_stage.add_child(tb)
			tb.global_position = Vector3(0.0, 5.5, 0.0)
		"sphere":
			var s := GPUParticlesCollisionSphere3D.new()
			s.radius = 30.0
			_stage.add_child(s)
			s.global_position = Vector3(0.0, -30.0, 0.0)
		"heightfield":
			# A heightfield captures GEOMETRY from above, so it needs a mesh
			# to see. The slab is dark so it adds no bright pixels itself.
			var slab := MeshInstance3D.new()
			slab.visible = not bool(opt.get("no_mesh", false))
			var bm := BoxMesh.new()
			bm.size = Vector3(24.0, 0.5, 10.0)
			var dark := StandardMaterial3D.new()
			dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			dark.albedo_color = Color(0.02, 0.02, 0.02)
			bm.material = dark
			slab.mesh = bm
			_stage.add_child(slab)
			slab.global_position = Vector3(0.0, -0.25, 0.0)
			var hf := GPUParticlesCollisionHeightField3D.new()
			hf.size = Vector3(30.0, 30.0, 30.0)
			hf.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
			hf.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_ALWAYS
			_stage.add_child(hf)
			hf.global_position = Vector3.ZERO

	for i in int(opt.get("decoys_after", 0)):
		var d2 := GPUParticlesCollisionBox3D.new()
		d2.size = Vector3(0.2, 0.2, 0.2)
		_stage.add_child(d2)
		d2.global_position = Vector3(13.0, -20.0 + float(i) * 0.4, -9.0)

	var sub_parts: GPUParticles3D = null
	if bool(opt.get("sub", false)) and parts != null:
		sub_parts = _ring_emitter()
		_stage.add_child(sub_parts)
		parts.sub_emitter = parts.get_path_to(sub_parts)
		var pm: ParticleProcessMaterial = parts.process_material
		pm.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_COLLISION
		pm.sub_emitter_amount_at_collision = 1

	if bool(opt.get("fog_test", false)):
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.2
		env.volumetric_fog_albedo = Color.WHITE
		env.volumetric_fog_emission = Color.WHITE
		env.volumetric_fog_emission_energy = 1.0

	var gpu: Array[float] = []
	var t0: int = Time.get_ticks_msec()
	var vp_rid: RID = root.get_viewport_rid()
	var settle_s: float = float(opt.get("settle_s", SETTLE_S))
	while float(Time.get_ticks_msec() - t0) / 1000.0 < settle_s:
		await RenderingServer.frame_post_draw
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))

	var img: Image = root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	var shot_dir: String = OS.get_environment("RAIN_PROBE_SHOTS")
	if shot_dir != "":
		img.save_png(shot_dir.path_join("%s_%s.png" % [
			String(RenderingServer.get_current_rendering_method()), case_name]))
	var above: Dictionary = _band(img, 2.0, 8.0)
	var below: Dictionary = _band(img, -8.0, -2.0)
	gpu.sort()
	var rec := {
		"case": case_name, "options": opt,
		"above_white": above.white, "above_red": above.red,
		"below_white": below.white, "below_red": below.red,
		"band_pixels": above.total,
		"frame_mean_luma": _mean_luma(img),
		"gpu_ms_median": gpu[gpu.size() / 2] if not gpu.is_empty() else -1.0,
		"frames": gpu.size(),
	}
	_results.append(rec)
	print("RAIN_PROBE %-28s above_white %6d below_white %6d above_red %5d below_red %5d mean %.4f gpu %.3f" % [
		case_name, above.white, below.white, above.red, below.red,
		rec.frame_mean_luma, rec.gpu_ms_median])


func _emitter(fixed_fps: int, trails: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 3000
	p.lifetime = 2.0
	p.fixed_fps = fixed_fps
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-15.0, -25.0, -10.0), Vector3(30.0, 30.0, 20.0))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(8.0, 0.1, 3.0)
	pm.direction = Vector3.DOWN
	pm.spread = 0.0
	pm.initial_velocity_min = 10.0
	pm.initial_velocity_max = 10.0
	pm.gravity = Vector3.ZERO
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	pm.collision_use_scale = false
	p.process_material = pm
	p.collision_base_size = 0.01

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	if trails:
		p.trail_enabled = true
		p.trail_lifetime = 0.05
		var rib := RibbonTrailMesh.new()
		rib.shape = RibbonTrailMesh.SHAPE_FLAT
		rib.size = 0.05
		rib.sections = 2
		rib.section_segments = 1
		mat.use_particle_trails = true
		rib.material = mat
		p.draw_pass_1 = rib
	else:
		var q := QuadMesh.new()
		q.size = Vector2(0.08, 0.5)
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		mat.billboard_keep_scale = true
		q.material = mat
		p.draw_pass_1 = q
	return p


func _ring_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 3000
	p.lifetime = 0.5
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-15.0, -25.0, -10.0), Vector3(30.0, 30.0, 20.0))
	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0.0, 4.0, 0.0)
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	p.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.RED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var q := QuadMesh.new()
	q.size = Vector2(0.4, 0.4)
	q.material = mat
	p.draw_pass_1 = q
	return p


## Bright pixels in the screen rows between two world heights at x = 0,
## z = 0, over the collider's width (x -8..8).
func _band(img: Image, y_lo: float, y_hi: float) -> Dictionary:
	var top: Vector2 = _cam.unproject_position(Vector3(-8.0, y_hi, 0.0))
	var bot: Vector2 = _cam.unproject_position(Vector3(8.0, y_lo, 0.0))
	var x0: int = clampi(int(minf(top.x, bot.x)), 0, img.get_width() - 1)
	var x1: int = clampi(int(maxf(top.x, bot.x)), 0, img.get_width() - 1)
	var y0: int = clampi(int(minf(top.y, bot.y)), 0, img.get_height() - 1)
	var y1: int = clampi(int(maxf(top.y, bot.y)), 0, img.get_height() - 1)
	var white: int = 0
	var red: int = 0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c: Color = img.get_pixel(x, y)
			if c.r > 0.5 and c.g > 0.5 and c.b > 0.5:
				white += 1
			elif c.r > 0.5 and c.g < 0.3:
				red += 1
	return {"white": white, "red": red, "total": (x1 - x0 + 1) * (y1 - y0 + 1)}


func _mean_luma(img: Image) -> float:
	var s: float = 0.0
	var n: int = 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c: Color = img.get_pixel(x, y)
			s += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return s / float(maxi(n, 1))
