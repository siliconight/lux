extends Node
## A lit room in a built level, measured in pixels and milliseconds (0.37.0).
##
## An AUTOLOAD, run through the factory's tools/godot_probe.py mirror by
## tools/club_walk_probe.py -- never registered in the project under test.
## Needs a window: rendering is the point.
##
## For each VARIANT (a set of edits to the running tree, undone afterwards)
## and each given STATION (eye, target; Godot metres, Y up) it saves the frame
## and reports, over the whole frame, 8-bit sRGB after tonemap and post:
##   luma_mean / p05 / p50 / p95   Rec.709 luma
##   rgb_mean                      mean R, G, B
##   chroma_mean                   mean of (max - min) channel per pixel
##   chroma40_pct                  % of pixels whose (max - min) >= 40 codes
## Non-Lux CanvasLayers (the walk harness HUD) are hidden first, as look_shots
## does, because its white text biases every statistic.
##
## Then the COST, per station: `rounds` x (every variant in turn), each a
## settle of 30 frames and a window of `cost_frames` frames, reporting mean
## wall-clock frame time (the driver turns vsync off) and the median viewport
## GPU time from the engine's timestamps. Variants are interleaved within a
## round so slow drift lands on all of them alike.
##
## Variant edits:
##   "hide": [suffix, ...]       Node3D made invisible (first node whose path
##                               ends with "/<suffix>")
##   "show": [suffix, ...]       made visible
##   "shadow": [suffix, ...]     every Light3D under the node gets shadows
##   "sun_shadow": true|false    LuxSun.shadow_enabled
##   "fog": true|false           the WorldEnvironment's fog_enabled
##   "energy_scale": {suffix: k} every Light3D under the node x k (a tuning
##                               question asked of the running level; flicker
##                               and the stage cycle never write energy)
##   "set": {suffix: {prop: v}}  set properties on a node; a 3-number array
##                               becomes a Vector3
##   "env": {prop: v}            set properties on the WorldEnvironment's
##                               Environment (e.g. "glow_enabled": false)
##   "post": false               hide the CanvasLayers under LuxRoot (post)
##
## Prints a fenced JSON block and quits. Numbers only.

const BEGIN := "<<<CLUB_WALK_JSON"
const END := "CLUB_WALK_JSON>>>"


func _ready() -> void:
	var out_dir := String(ProjectSettings.get_setting("club_walk/out_dir", ""))
	var stations: Array = JSON.parse_string(String(ProjectSettings.get_setting("club_walk/stations", "[]")))
	var variants: Array = JSON.parse_string(String(ProjectSettings.get_setting("club_walk/variants", "[{\"name\": \"as_built\"}]")))
	var cost_frames: int = int(ProjectSettings.get_setting("club_walk/cost_frames", 240))
	var rounds: int = int(ProjectSettings.get_setting("club_walk/rounds", 2))
	for _i in 30:
		await get_tree().process_frame
	var scene: Node = get_tree().current_scene
	var hidden_canvas: Array = []
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if not String(n.get_path()).contains("LuxRoot") and (n as CanvasLayer).visible:
			(n as CanvasLayer).visible = false
			hidden_canvas.append(String(n.get_path()))
	var cam := Camera3D.new()
	cam.far = 2000.0
	scene.add_child(cam)
	cam.make_current()
	var vp_rid: RID = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)

	var out_stations: Array = []
	for st in stations:
		var sd: Dictionary = st
		cam.global_position = Vector3(sd.eye[0], sd.eye[1], sd.eye[2])
		cam.look_at(Vector3(sd.target[0], sd.target[1], sd.target[2]), Vector3.UP)
		var rec := {"name": sd.name, "eye": sd.eye, "target": sd.target, "frames": [], "cost": []}
		for v in variants:
			var vd: Dictionary = v
			var undo: Array = _apply(scene, vd)
			for _i in 12:
				await RenderingServer.frame_post_draw
			var img: Image = get_viewport().get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			var stats: Dictionary = _stats(img)
			stats["variant"] = String(vd.get("name", "v"))
			stats["missing"] = undo.filter(func(u): return u[0] == null).map(func(u): return u[1])
			if out_dir != "":
				var png := out_dir.path_join("%s__%s.png" % [String(sd.name), String(vd.get("name", "v"))])
				img.save_png(png)
				stats["png"] = png
			rec.frames.append(stats)
			_undo(undo)
		for _r in rounds:
			for v in variants:
				var vd2: Dictionary = v
				var undo2: Array = _apply(scene, vd2)
				for _i in 30:
					await RenderingServer.frame_post_draw
				var gpu: Array[float] = []
				var u0: int = Time.get_ticks_usec()
				for _i in cost_frames:
					await RenderingServer.frame_post_draw
					gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
				var wall_ms: float = float(Time.get_ticks_usec() - u0) / 1000.0 / float(cost_frames)
				gpu.sort()
				rec.cost.append({"variant": String(vd2.get("name", "v")), "frame_ms_mean": wall_ms,
					"gpu_ms_median": gpu[gpu.size() / 2], "frames": cost_frames})
				_undo(undo2)
		out_stations.append(rec)

	print(BEGIN)
	print(JSON.stringify({
		"engine": String(Engine.get_version_info().get("string", "")),
		"rendering_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"viewport": [get_viewport().size.x, get_viewport().size.y],
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"max_renderable_lights": ProjectSettings.get_setting("rendering/limits/opengl/max_renderable_lights", -1),
		"max_lights_per_object": ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object", -1),
		"hidden_canvas_layers": hidden_canvas,
		"stations": out_stations,
	}))
	print(END)
	get_tree().quit(0)


func _apply(scene: Node, vd: Dictionary) -> Array:
	var undo: Array = []
	for path in vd.get("hide", []):
		var n: Node = _find_suffix(scene, String(path))
		if n is Node3D:
			undo.append([n, "visible", (n as Node3D).visible])
			(n as Node3D).visible = false
		else:
			undo.append([null, String(path), null])
	for path in vd.get("show", []):
		var n2: Node = _find_suffix(scene, String(path))
		if n2 is Node3D:
			undo.append([n2, "visible", (n2 as Node3D).visible])
			(n2 as Node3D).visible = true
		else:
			undo.append([null, String(path), null])
	for path in vd.get("shadow", []):
		var n3: Node = _find_suffix(scene, String(path))
		if n3 == null:
			undo.append([null, String(path), null])
			continue
		for l in n3.find_children("*", "Light3D", true, false):
			undo.append([l, "shadow_enabled", (l as Light3D).shadow_enabled])
			(l as Light3D).shadow_enabled = true
	if vd.has("sun_shadow"):
		var sun: Node = _find_suffix(scene, "LuxRoot/LuxSun")
		if sun is DirectionalLight3D:
			undo.append([sun, "shadow_enabled", (sun as DirectionalLight3D).shadow_enabled])
			(sun as DirectionalLight3D).shadow_enabled = bool(vd["sun_shadow"])
		else:
			undo.append([null, "LuxRoot/LuxSun", null])
	if vd.has("fog"):
		var we: Array = scene.find_children("*", "WorldEnvironment", true, false)
		if we.is_empty() or (we[0] as WorldEnvironment).environment == null:
			undo.append([null, "WorldEnvironment", null])
		else:
			var env: Environment = (we[0] as WorldEnvironment).environment
			undo.append([env, "fog_enabled", env.fog_enabled])
			env.fog_enabled = bool(vd["fog"])
	var scales: Dictionary = vd.get("energy_scale", {})
	for path in scales:
		var n4: Node = _find_suffix(scene, String(path))
		if n4 == null:
			undo.append([null, String(path), null])
			continue
		for l in n4.find_children("*", "Light3D", true, false):
			undo.append([l, "light_energy", (l as Light3D).light_energy])
			(l as Light3D).light_energy *= float(scales[path])
	var envs: Dictionary = vd.get("env", {})
	if not envs.is_empty():
		var we2: Array = scene.find_children("*", "WorldEnvironment", true, false)
		if we2.is_empty() or (we2[0] as WorldEnvironment).environment == null:
			undo.append([null, "WorldEnvironment", null])
		else:
			var e2: Environment = (we2[0] as WorldEnvironment).environment
			for prop in envs:
				undo.append([e2, String(prop), e2.get(String(prop))])
				e2.set(String(prop), envs[prop])
	if vd.has("post") and not bool(vd["post"]):
		for cl in get_tree().root.find_children("*", "CanvasLayer", true, false):
			if String(cl.get_path()).contains("LuxRoot") and (cl as CanvasLayer).visible:
				undo.append([cl, "visible", true])
				(cl as CanvasLayer).visible = false
	var sets: Dictionary = vd.get("set", {})
	for path in sets:
		var n5: Node = _find_suffix(scene, String(path))
		if n5 == null:
			undo.append([null, String(path), null])
			continue
		var props: Dictionary = sets[path]
		for prop in props:
			var val: Variant = props[prop]
			if typeof(val) == TYPE_ARRAY and (val as Array).size() == 3:
				val = Vector3(float(val[0]), float(val[1]), float(val[2]))
			undo.append([n5, String(prop), n5.get(String(prop))])
			n5.set(String(prop), val)
	return undo


func _undo(undo: Array) -> void:
	for i in range(undo.size() - 1, -1, -1):
		var u: Array = undo[i]
		if u[0] != null:
			(u[0] as Object).set(String(u[1]), u[2])


func _find_suffix(n: Node, suffix: String) -> Node:
	if String(n.get_path()).ends_with("/" + suffix):
		return n
	for c in n.get_children():
		var r: Node = _find_suffix(c, suffix)
		if r != null:
			return r
	return null


func _stats(img: Image) -> Dictionary:
	var a: PackedByteArray = img.get_data()
	var hist := PackedInt32Array()
	hist.resize(256)
	var n: int = 0
	var sr: float = 0.0
	var sg: float = 0.0
	var sb: float = 0.0
	var sl: float = 0.0
	var sc: float = 0.0
	var c40: int = 0
	var i: int = 0
	while i < a.size():
		var r: int = a[i]
		var g: int = a[i + 1]
		var b: int = a[i + 2]
		var l: float = 0.2126 * r + 0.7152 * g + 0.0722 * b
		hist[clampi(int(l), 0, 255)] += 1
		sr += r
		sg += g
		sb += b
		sl += l
		var c: int = maxi(r, maxi(g, b)) - mini(r, mini(g, b))
		sc += c
		if c >= 40:
			c40 += 1
		n += 1
		i += 6        # every other pixel on each row
	return {"luma_mean": snappedf(sl / n, 0.01), "p05": _pct(hist, n, 0.05),
		"p50": _pct(hist, n, 0.5), "p95": _pct(hist, n, 0.95),
		"rgb_mean": [snappedf(sr / n, 0.1), snappedf(sg / n, 0.1), snappedf(sb / n, 0.1)],
		"chroma_mean": snappedf(sc / n, 0.01), "chroma40_pct": snappedf(100.0 * c40 / n, 0.01),
		"samples": n}


func _pct(hist: PackedInt32Array, n: int, q: float) -> int:
	var want: int = int(q * n)
	var acc: int = 0
	for k in 256:
		acc += hist[k]
		if acc >= want:
			return k
	return 255
