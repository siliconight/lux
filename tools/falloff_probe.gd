extends SceneTree
## Omni / spot falloff on a floor, GL Compatibility, against the closed form
## the Lux club rigs derive energy from:
##
##     E_floor(d) = energy * (1 - (d / R)^4)^2 / d^attenuation * cos(incidence)
##
## One light at height h over a large matte plane, orthographic top-down, no
## ambient, linear tonemap. Samples the frame along a radius, converts the
## 8-bit sRGB red channel back to linear, divides by albedo, and prints the
## measured value beside the formula. Numbers only.
##
##   godot --path lux --rendering-method gl_compatibility -s res://tools/falloff_probe.gd -- kind=omni h=2.95 R=5.0 e=0.5

const OUT_BEGIN := "<<<FALLOFF_JSON"
const OUT_END := "FALLOFF_JSON>>>"

var args := {"kind": "omni", "h": "2.95", "R": "5.0", "e": "1.0", "att": "2.0"}


func _initialize() -> void:
	_main()


func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


func _main() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var h := float(args["h"])
	var R := float(args["R"])
	var e := float(args["e"])
	var att := float(args["att"])
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	root.add_child(we)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(24, 24)
	pm.subdivide_width = 32
	pm.subdivide_depth = 32
	mi.mesh = pm
	mi.material_override = mat
	root.add_child(mi)
	var l: Light3D
	if args["kind"] == "spot":
		var s := SpotLight3D.new()
		s.spot_range = R
		s.spot_attenuation = att
		s.spot_angle = 89.0
		s.spot_angle_attenuation = 0.125
		s.rotation_degrees = Vector3(-90, 0, 0)
		l = s
	else:
		var o := OmniLight3D.new()
		o.omni_range = R
		o.omni_attenuation = att
		l = o
	l.light_color = Color(1, 1, 1)
	l.light_energy = e
	l.position = Vector3(0, h, 0)
	root.add_child(l)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	await process_frame
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 12.0          # vertical extent, metres
	cam.look_at_from_position(Vector3(0, 20, 0), Vector3.ZERO, Vector3.FORWARD)
	for i in 6:
		await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var w := img.get_width()
	var hh := img.get_height()
	var m_per_px := 12.0 / float(hh)
	var rows: Array = []
	for rho_i in range(0, 13):
		var rho := float(rho_i) * 0.5
		var px := int(float(w) * 0.5 + rho / m_per_px)
		if px >= w:
			break
		var c := img.get_pixel(px, hh / 2)
		var meas := _lin(c.r)
		var d := sqrt(h * h + rho * rho)
		var win := pow(maxf(1.0 - pow(d / R, 4.0), 0.0), 2.0)
		var pred := e * win / pow(d, att) * (h / d)
		rows.append({"rho_m": rho, "d_m": snappedf(d, 0.001), "measured_lin": snappedf(meas, 0.0001),
			"formula": snappedf(pred, 0.0001), "srgb8": int(round(c.r * 255.0))})
	print(OUT_BEGIN)
	print(JSON.stringify({"engine": Engine.get_version_info().string,
		"method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"kind": args["kind"], "h": h, "R": R, "energy": e, "attenuation": att,
		"rows": rows}))
	print(OUT_END)
	quit(0)
