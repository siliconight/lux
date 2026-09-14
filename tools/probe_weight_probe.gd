extends SceneTree
## How much of the environment's ambient an interior ReflectionProbe replaces,
## POINT BY POINT, GL Compatibility. A room of six planes W x H x D, flat grey
## COLOR ambient at energy 1, no lights, a probe of the room's size plus 0.1 m
## a side with ambient COLOR black at 0. The camera stands at the room centre
## (eye height 1.6) and looks straight at each sample point; the 5 x 5 pixels
## at screen centre are averaged. For each point: RGB sum without the probe,
## with it, and the fraction removed. Numbers only.
##
##   godot --path lux --rendering-method gl_compatibility -s res://tools/probe_weight_probe.gd -- w=17 h=3.48 d=40
##   options: margin=<m> blend=<m> start=sky_stay|sky|sky_recapture|bgsky_color|skyres_bgcolor
##   ("sky*" cases set ambient_light_sky_contribution 0.5, which is the variable
##   that decides the share replaced -- see LuxLightLoader room_ambient)

const OUT_BEGIN := "<<<PROBE_WEIGHT_JSON"
const OUT_END := "PROBE_WEIGHT_JSON>>>"


func _initialize() -> void:
	_main()


func _plane(size: Vector2, pos: Vector3, rot_deg: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	root.add_child(mi)


func _main() -> void:
	var a := {"w": "10", "h": "3", "d": "10", "blend": "1.0", "margin": "0.1"}
	for ua in OS.get_cmdline_user_args():
		var kv := String(ua).split("=", true, 1)
		if kv.size() == 2:
			a[kv[0]] = kv[1]
	var W := float(a["w"])
	var H := float(a["h"])
	var D := float(a["d"])
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.1, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.55)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	root.add_child(we)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.8, 0.8)
	mat.roughness = 1.0
	_plane(Vector2(W, D), Vector3(0, 0, 0), Vector3(0, 0, 0), mat)
	_plane(Vector2(W, D), Vector3(0, H, 0), Vector3(180, 0, 0), mat)
	_plane(Vector2(W, H), Vector3(0, H * 0.5, -D * 0.5), Vector3(90, 0, 0), mat)
	_plane(Vector2(W, H), Vector3(0, H * 0.5, D * 0.5), Vector3(-90, 0, 0), mat)
	_plane(Vector2(H, D), Vector3(-W * 0.5, H * 0.5, 0), Vector3(0, 0, -90), mat)
	_plane(Vector2(H, D), Vector3(W * 0.5, H * 0.5, 0), Vector3(0, 0, 90), mat)
	var m := float(a["margin"])
	var probe := ReflectionProbe.new()
	probe.position = Vector3(0, H * 0.5, 0)
	probe.size = Vector3(W, H, D) + Vector3.ONE * 2.0 * m
	probe.blend_distance = float(a["blend"])
	probe.interior = true
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = Color(0, 0, 0)
	probe.ambient_color_energy = 0.0
	root.add_child(probe)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	await process_frame
	# "start=sky": the environment begins Sky-sourced (Heavy Rain's shape) and
	# is switched to COLOR only after the probe has been on screen for frames,
	# the order the walk measurement used.
	if a.get("start", "") == "sky":
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.5
		cam.look_at_from_position(Vector3(0, 1.6, 0), Vector3(0.01, 0, -0.5), Vector3.FORWARD)
		for i in 20:
			await RenderingServer.frame_post_draw
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	if a.get("start", "") == "sky_stay":
		var sky2 := Sky.new()
		sky2.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky2
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.5
	if a.get("start", "") == "sky_recapture":
		var sky5 := Sky.new()
		sky5.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky5
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.5
		cam.look_at_from_position(Vector3(0, 1.6, 0), Vector3(0.01, 0, -0.5), Vector3.FORWARD)
		for i in 20:
			await RenderingServer.frame_post_draw
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		for i in 5:
			await RenderingServer.frame_post_draw
		root.remove_child(probe)
		root.add_child(probe)
	if a.get("start", "") == "skyres_bgcolor":
		# a Sky resource on the environment, background still COLOR, ambient COLOR
		var sky3 := Sky.new()
		sky3.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky3
	if a.get("start", "") == "bgsky_color":
		# background SKY, ambient COLOR from the start
		var sky4 := Sky.new()
		sky4.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky4
		env.background_mode = Environment.BG_SKY
	var eye := Vector3(0, 1.6, 0)
	var pts := {
		"floor_centre": Vector3(0.01, 0, -0.5),
		"floor_q_long": Vector3(0.01, 0, -D * 0.25),
		"floor_45_long": Vector3(0.01, 0, -D * 0.45),
		"floor_q_short": Vector3(W * 0.25, 0, -0.5),
		"ceiling_centre": Vector3(0.01, H, -0.5),
		"ceiling_q_long": Vector3(0.01, H, -D * 0.25),
		"wall_short_side": Vector3(W * 0.5, 1.6, -0.5),
		"wall_long_end": Vector3(0.0, 1.6, -D * 0.5),
	}
	var out := {"engine": Engine.get_version_info().string,
		"method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"room": [W, H, D], "probe_size": [probe.size.x, probe.size.y, probe.size.z],
		"blend_distance": probe.blend_distance, "start": a.get("start", "color"), "points": []}
	for name in pts:
		var p: Vector3 = pts[name]
		var up := Vector3.UP
		if absf((p - eye).normalized().dot(Vector3.UP)) > 0.95:
			up = Vector3.FORWARD
		cam.look_at_from_position(eye, p, up)
		var vals := []
		for on in [false, true]:
			probe.visible = on
			for i in 8:
				await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			var cx := img.get_width() / 2
			var cy := img.get_height() / 2
			var s := 0.0
			for y in range(cy - 2, cy + 3):
				for x in range(cx - 2, cx + 3):
					var px := img.get_pixel(x, y)
					s += (px.r + px.g + px.b) * 255.0
			vals.append(s / 25.0)
		out["points"].append({"point": name, "at": [p.x, p.y, p.z], "no_probe": snappedf(vals[0], 0.1),
			"probe": snappedf(vals[1], 0.1),
			"removed": snappedf(1.0 - vals[1] / maxf(vals[0], 0.001), 0.001)})
	print(OUT_BEGIN)
	print(JSON.stringify(out))
	print(OUT_END)
	quit(0)
