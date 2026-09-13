extends Node
## Rain in a built level, measured in pixels and milliseconds (Lux 0.35.0).
##
## An AUTOLOAD, run through the factory's tools/godot_probe.py mirror by
## tools/rain_walk_probe.py -- never registered in the project under test.
## Needs a window: rendering is the point.
##
## For each given station (eye, target; Godot metres, Y up) it stands a camera
## there and, for each variant, takes a BASELINE frame with the LuxRain node
## hidden, shows it, restarts it, and at each sample time counts pixels whose
## Rec.709 luma rose more than `threshold` codes over the baseline. A station
## inside a building should count ~0; a street station counts the rain. The
## threshold sits above the preset's animated grain, which differs frame to
## frame: the diff mask PNG beside each count is what to look at before
## believing a small number.
##
## Then the cost: per round, a window of `cost_frames` frames with the rain
## stopped and hidden, then one per drop count in `cost_amounts`, reporting
## mean wall-clock frame time (vsync is turned off by the driver so the frame
## is not pinned to the display) and the median viewport GPU time from the
## engine's timestamps.
##
## Prints a fenced JSON block and quits. Numbers only.

const BEGIN := "<<<RAIN_WALK_JSON"
const END := "RAIN_WALK_JSON>>>"

var _out_dir: String = ""
var _threshold: int = 30
## Leak pixels in the top, middle and bottom third of the last frame counted.
var _last_bands: Array[int] = [0, 0, 0]


func _ready() -> void:
	_out_dir = String(ProjectSettings.get_setting("rain_walk/out_dir", ""))
	_threshold = int(ProjectSettings.get_setting("rain_walk/threshold", 30))
	var stations: Array = JSON.parse_string(String(ProjectSettings.get_setting("rain_walk/stations", "[]")))
	var variants: Array = JSON.parse_string(String(ProjectSettings.get_setting("rain_walk/variants", "[{\"name\": \"as_built\"}]")))
	var times: Array = JSON.parse_string(String(ProjectSettings.get_setting("rain_walk/times", "[0.5, 3.0]")))
	var cost_frames: int = int(ProjectSettings.get_setting("rain_walk/cost_frames", 240))
	var cost_rounds: int = int(ProjectSettings.get_setting("rain_walk/cost_rounds", 2))
	# Drop counts timed against "off"; empty means the level's own count.
	var cost_amounts: Array = JSON.parse_string(String(ProjectSettings.get_setting("rain_walk/cost_amounts", "[]")))
	for _i in 20:
		await get_tree().process_frame

	var rain: GPUParticles3D = _find_rain(get_tree().root)
	if rain == null:
		_emit({"error": "no LuxRain (GPUParticles3D named LuxRain) in the running tree"})
		return
	var cam := Camera3D.new()
	cam.far = 2000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	var vp_rid: RID = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)

	var base_preprocess: float = rain.preprocess
	var base_fps: int = rain.fixed_fps
	var out_stations: Array = []
	for st in stations:
		var sd: Dictionary = st
		var eye := Vector3(sd.eye[0], sd.eye[1], sd.eye[2])
		var tgt := Vector3(sd.target[0], sd.target[1], sd.target[2])
		cam.global_position = eye
		cam.look_at(tgt, Vector3.UP)
		for _i in 5:
			await RenderingServer.frame_post_draw
		var rec := {"name": sd.name, "eye": sd.eye, "target": sd.target,
			"emitter": [], "variants": [], "cost": []}
		for v in variants:
			var vd: Dictionary = v
			rain.preprocess = float(vd.get("preprocess", base_preprocess))
			rain.fixed_fps = int(vd.get("fixed_fps", base_fps))
			var undo: Array = _apply_variant_nodes(vd)
			rain.visible = false
			for _i in 3:
				await RenderingServer.frame_post_draw
			var base_img: Image = _grab()
			rain.visible = true
			rain.restart()
			var t0: int = Time.get_ticks_msec()
			var samples: Array = []
			for t in times:
				while float(Time.get_ticks_msec() - t0) / 1000.0 < float(t):
					await RenderingServer.frame_post_draw
				var img: Image = _grab()
				var tag := "%s_%s_t%.1f" % [String(sd.name), String(vd.get("name", "v")), float(t)]
				var n: int = _count_and_mask(base_img, img, tag)
				samples.append({"t_s": float(t), "risen_px": n,
					"risen_px_by_band": _last_bands})
			rec.variants.append({"variant": vd, "samples": samples})
			_undo(undo)
			rec.emitter = [rain.global_position.x, rain.global_position.y, rain.global_position.z]
		rain.preprocess = base_preprocess
		rain.fixed_fps = base_fps
		rain.visible = true
		rain.emitting = true
		rain.restart()
		var base_amount: int = rain.amount
		if cost_amounts.is_empty():
			cost_amounts = [base_amount]
		for _r in cost_rounds:
			var states: Array = ["off"]
			for amt in cost_amounts:
				states.append(int(amt))
			for state in states:
				var on: bool = typeof(state) == TYPE_INT
				rain.emitting = on
				rain.visible = on
				if on:
					rain.amount = int(state)
					rain.restart()
				for _i in 30:
					await RenderingServer.frame_post_draw
				var gpu: Array[float] = []
				var u0: int = Time.get_ticks_usec()
				for _i in cost_frames:
					await RenderingServer.frame_post_draw
					gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
				var wall_ms: float = float(Time.get_ticks_usec() - u0) / 1000.0 / float(cost_frames)
				gpu.sort()
				rec.cost.append({"state": str(state), "frame_ms_mean": wall_ms,
					"gpu_ms_median": gpu[gpu.size() / 2], "frames": cost_frames})
		rain.amount = base_amount
		rain.emitting = true
		rain.visible = true
		out_stations.append(rec)

	_emit({
		"engine": String(Engine.get_version_info().get("string", "")),
		"rendering_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_api": RenderingServer.get_video_adapter_api_version(),
		"viewport": [get_viewport().size.x, get_viewport().size.y],
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"rain_amount": rain.amount, "rain_fixed_fps": base_fps,
		"threshold": _threshold,
		"stations": out_stations,
	})


## Variant edits to the running tree, each undone after its samples:
##   "hide": ["b1/ceiling_master_suite", ...]  node paths under current_scene
##           (the first match by path suffix), made invisible
##   "box_top": {"Rain_b1": 60.0}              raise a collider's top to y
##   "box_away": ["Rain_b1"]                   move a collider 500 m down
func _apply_variant_nodes(vd: Dictionary) -> Array:
	var undo: Array = []
	var scene: Node = get_tree().current_scene
	for path in vd.get("hide", []):
		var n: Node = _find_suffix(scene, String(path))
		if n is Node3D:
			undo.append([n, "visible", (n as Node3D).visible])
			(n as Node3D).visible = false
	var tops: Dictionary = vd.get("box_top", {})
	for nm in tops:
		var b: Node = _find_suffix(scene, String(nm))
		if b is GPUParticlesCollisionBox3D:
			var box := b as GPUParticlesCollisionBox3D
			undo.append([box, "size", box.size])
			undo.append([box, "global_position", box.global_position])
			var bottom: float = box.global_position.y - box.size.y * 0.5
			var top: float = float(tops[nm])
			box.size = Vector3(box.size.x, top - bottom, box.size.z)
			box.global_position = Vector3(box.global_position.x, (top + bottom) * 0.5, box.global_position.z)
	for nm in vd.get("box_away", []):
		var b2: Node = _find_suffix(scene, String(nm))
		if b2 is Node3D:
			undo.append([b2, "global_position", (b2 as Node3D).global_position])
			(b2 as Node3D).global_position += Vector3(0.0, -500.0, 0.0)
	return undo


func _undo(undo: Array) -> void:
	for i in range(undo.size() - 1, -1, -1):
		var u: Array = undo[i]
		(u[0] as Object).set(String(u[1]), u[2])


func _find_suffix(n: Node, suffix: String) -> Node:
	var p: String = String(n.get_path())
	if p.ends_with("/" + suffix):
		return n
	for c in n.get_children():
		var r: Node = _find_suffix(c, suffix)
		if r != null:
			return r
	return null


func _find_rain(n: Node) -> GPUParticles3D:
	if n is GPUParticles3D and String(n.name) == "LuxRain":
		return n as GPUParticles3D
	for c in n.get_children():
		var r: GPUParticles3D = _find_rain(c)
		if r != null:
			return r
	return null


func _grab() -> Image:
	var img: Image = get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _count_and_mask(base_img: Image, img: Image, tag: String) -> int:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var a: PackedByteArray = img.get_data()
	var b: PackedByteArray = base_img.get_data()
	var m := PackedByteArray()
	m.resize(a.size())
	var n: int = 0
	var limit: float = float(_threshold)
	var i: int = 0
	var bands: Array[int] = [0, 0, 0]
	while i < a.size():
		var la: float = 0.2126 * a[i] + 0.7152 * a[i + 1] + 0.0722 * a[i + 2]
		var lb: float = 0.2126 * b[i] + 0.7152 * b[i + 1] + 0.0722 * b[i + 2]
		if la - lb > limit:
			n += 1
			m[i] = 255
			bands[mini(int((i / 3) / w) * 3 / h, 2)] += 1
		i += 3
	_last_bands = bands
	if _out_dir != "":
		img.save_png(_out_dir.path_join(tag + ".png"))
		Image.create_from_data(w, h, false, Image.FORMAT_RGB8, m).save_png(
			_out_dir.path_join(tag + "_mask.png"))
	return n


func _emit(report: Dictionary) -> void:
	print(BEGIN)
	print(JSON.stringify(report))
	print(END)
	get_tree().quit(0)
