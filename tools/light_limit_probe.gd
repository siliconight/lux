extends SceneTree
## Per-object light limit, GL Compatibility, measured in pixels.
##
##   godot --path lux --rendering-method gl_compatibility -s res://tools/light_limit_probe.gd -- n=12 tiles=1 kind=omni
##   (a window is required; the per-object cap is set with an override.cfg:
##    [rendering] limits/opengl/max_lights_per_object=16)
##
## A floor (one mesh, or tiles x tiles meshes over the same area) under n
## coloured lights in a grid. For every camera station the frame is rendered
## with ALL lights on, then once per light with only that light on. Light is
## additive (ambient off, black background, linear tonemap, no glow), so in a
## light's own footprint the all-on frame can never be darker than its single
## frame unless the engine dropped that light for that mesh. Per light and
## station it reports the footprint size and the fraction of the footprint
## where all-on is below half of single-on. Numbers only.

const OUT_BEGIN := "<<<LIGHT_LIMIT_JSON"
const OUT_END := "LIGHT_LIMIT_JSON>>>"

var args := {"n": "12", "tiles": "1", "kind": "omni", "side": "21.68",
	"h": "3.0", "energy": "1.0", "shots": ""}
var cam: Camera3D
var lights: Array[Light3D] = []


func _initialize() -> void:
	_main()


func _main() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var n := int(args["n"])
	var tiles := int(args["tiles"])
	var side := float(args["side"])
	var h := float(args["h"])

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	we.environment = env
	root.add_child(we)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.8, 0.8)
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	var ts := side / float(tiles)
	for i in tiles:
		for j in tiles:
			var mi := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(ts, ts)
			pm.subdivide_width = 8
			pm.subdivide_depth = 8
			mi.mesh = pm
			mi.material_override = mat
			mi.position = Vector3(-side * 0.5 + ts * (i + 0.5), 0.0, -side * 0.5 + ts * (j + 0.5))
			root.add_child(mi)

	# grid of n lights, as square as possible
	var cols := int(ceil(sqrt(float(n))))
	var rows := int(ceil(float(n) / float(cols)))
	var sx := side / float(cols)
	var sz := side / float(rows)
	var pool := minf(sx, sz) * 0.75
	var rng := sqrt(h * h + pool * pool)
	var palette := [Color(1, 0, 0.55), Color(1, 0.2, 0.6), Color(1, 0.05, 0.05),
		Color(0.55, 0.1, 1), Color(0.1, 0.2, 1), Color(0, 0.85, 1), Color(1, 0.55, 0.05)]
	for k in n:
		var cx := -side * 0.5 + sx * (float(k % cols) + 0.5)
		var cz := -side * 0.5 + sz * (float(k / cols) + 0.5)
		var l: Light3D
		if args["kind"] == "spot":
			var s := SpotLight3D.new()
			s.spot_range = rng
			s.spot_attenuation = 2.0
			s.spot_angle = 89.0
			s.spot_angle_attenuation = 0.125
			s.rotation_degrees = Vector3(-90, 0, 0)
			l = s
		else:
			var o := OmniLight3D.new()
			o.omni_range = rng
			o.omni_attenuation = 2.0
			l = o
		l.light_color = palette[k % palette.size()]
		l.light_energy = float(args["energy"]) * h * h
		l.position = Vector3(cx, h, cz)
		root.add_child(l)
		lights.append(l)

	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	await process_frame
	await process_frame

	var stations: Array = [
		{"name": "top_ortho", "ortho": side * 1.02, "eye": Vector3(0, 30, 0.001), "target": Vector3.ZERO},
		{"name": "corner_eye", "eye": Vector3(-side * 0.5 + 0.5, 1.6, -side * 0.5 + 0.5), "target": Vector3(0, 0, 0)},
		{"name": "centre_eye_n", "eye": Vector3(0, 1.6, 0), "target": Vector3(0, 0.2, -side * 0.5)},
		{"name": "centre_eye_s", "eye": Vector3(0, 1.6, 0), "target": Vector3(0, 0.2, side * 0.5)},
		{"name": "wall_eye", "eye": Vector3(side * 0.5 - 0.3, 1.6, 0), "target": Vector3(-side * 0.5, 0.0, 0)},
		{"name": "high_oblique", "eye": Vector3(-side * 0.6, 8.0, side * 0.6), "target": Vector3(0, 0, 0)},
	]

	var out := {"engine": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(),
		"method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"max_lights_per_object": ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object"),
		"max_renderable_lights": ProjectSettings.get_setting("rendering/limits/opengl/max_renderable_lights"),
		"n": n, "tiles": tiles, "tile_side_m": ts, "floor_m2": side * side,
		"kind": args["kind"], "light_h": h, "light_range": rng, "pool": pool,
		"stations": []}

	for st in stations:
		if st.has("ortho"):
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = st["ortho"]
		else:
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 75.0
		cam.position = st["eye"]
		cam.look_at(st["target"], Vector3.FORWARD if st.has("ortho") else Vector3.UP)
		for l in lights:
			l.visible = true
		var all_img := await _grab()
		var rec := {"name": st["name"], "lights": []}
		var total_missing := 0
		for k in lights.size():
			for m in lights.size():
				lights[m].visible = (m == k)
			var one := await _grab()
			var fp := 0
			var miss := 0
			var w := one.get_width()
			var hh := one.get_height()
			for y in range(0, hh, 2):
				for x in range(0, w, 2):
					var c1 := one.get_pixel(x, y)
					var s1 := c1.r + c1.g + c1.b
					if s1 < 0.06:
						continue
					fp += 1
					var ca := all_img.get_pixel(x, y)
					if ca.r + ca.g + ca.b < s1 * 0.5:
						miss += 1
			var frac := float(miss) / float(fp) if fp > 0 else 0.0
			if fp > 0 and frac > 0.05:
				total_missing += 1
			rec["lights"].append({"k": k, "footprint_px": fp, "missing_frac": snappedf(frac, 0.001)})
		rec["lights_missing_over_5pct"] = total_missing
		rec["lights_in_view"] = rec["lights"].filter(func(e): return e["footprint_px"] > 0).size()
		out["stations"].append(rec)
		if args["shots"] != "":
			all_img.save_png("%s/%s_n%d_t%d_%s.png" % [args["shots"], st["name"], n, tiles, args["kind"]])

	print(OUT_BEGIN)
	print(JSON.stringify(out))
	print(OUT_END)
	quit(0)


func _grab() -> Image:
	for i in 3:
		await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
