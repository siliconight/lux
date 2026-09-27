extends SceneTree
## IS A LIT POOL LIT, OR BLOWN? Frame mean cannot tell them apart.
##
##     godot --path <walk copy> --script res://pool_exposure.gd
##
## WHY THIS EXISTS. Lux 0.43.0 reported a canopy's washes moving a frame's mean
## luminance by +20.6% and called that the fix working. It was measuring an
## OVEREXPOSURE -- the level was in the wrong unit and delivered fifteen times
## a tuned pool, so the tarmac saturated. Mean luminance rises either way, and
## nothing in that measurement could tell the two apart. The walker could, in
## one frame: "so dark now", over blown sodium discs on black ground.
##
## So this reports the SHAPE of the exposure, not its average:
##
##   clipped    fraction of pixels at or above `CLIP` in any channel. A lit
##              road has almost none. A blown pool is mostly this.
##   black      fraction at or below `FLOOR`. A night frame has a lot; a frame
##              that is ONLY pools and black has far too much.
##   midtones   what is left -- the part of the image carrying any shape at
##              all, and the number that actually distinguishes a lit scene
##              from a high-contrast one.
##   p50 / p99  the distribution, so a long bright tail is visible rather than
##              averaged away.
##
## No verdict is printed. A tool with no taste reports the histogram and a
## person decides whether a Delco street should be 12% midtones or 30%.

const W := 1280
const H := 720
const CLIP := 0.96
const FLOOR := 0.02


func _initialize() -> void:
	_run()


func _settle(n: int) -> void:
	for i in range(n):
		await process_frame


## Wait for a real frame instead of guessing a frame count: the first
## `get_image()` of a run comes back black however long you have waited, and
## that black frame has twice nearly "proved" a false answer in this repo.
func _first_real_frame() -> bool:
	for tries in range(40):
		await _settle(20)
		var img: Image = root.get_texture().get_image()
		if img != null and _stats(img)["mean"] > 0.0001:
			return true
	return false


func _stats(img: Image) -> Dictionary:
	var vals: Array[float] = []
	var clipped: int = 0
	var black: int = 0
	var total: float = 0.0
	var step: int = maxi(1, img.get_width() / 200)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c: Color = img.get_pixel(x, y)
			if c.r >= CLIP or c.g >= CLIP or c.b >= CLIP:
				clipped += 1
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if l <= FLOOR:
				black += 1
			vals.append(l)
			total += l
	vals.sort()
	var n: int = vals.size()
	return {
		"mean": total / maxf(float(n), 1.0),
		"clipped": float(clipped) / maxf(float(n), 1.0),
		"black": float(black) / maxf(float(n), 1.0),
		"p50": vals[int(n * 0.50)] if n > 0 else 0.0,
		"p99": vals[int(n * 0.99)] if n > 0 else 0.0,
	}


func _run() -> void:
	await process_frame
	DisplayServer.window_set_size(Vector2i(W, H))
	root.content_scale_size = Vector2i(W, H)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var packed: PackedScene = load(String(ProjectSettings.get_setting(
		"application/run/main_scene", ""))) as PackedScene
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 400.0
	root.add_child(cam)
	cam.make_current()
	cam.global_position = Vector3(104.0, 3.0, 10.0)
	cam.look_at(Vector3(92.0, 0.0, 10.0), Vector3.UP)
	if not await _first_real_frame():
		print("[exposure] REFUSED: never got a non-black frame")
		quit(1)
		return

	# Stations chosen to look AT lit ground rather than along it -- the
	# mistake `pool_ab.gd` made, which reported a pool it could not see.
	var stations: Array = [
		{"n": "forecourt", "eye": Vector3(104.0, 3.0, 10.0),
			"look": Vector3(92.0, 0.0, 10.0)},
		{"n": "under_canopy", "eye": Vector3(92.0, 2.5, 4.0),
			"look": Vector3(92.0, 0.0, 14.0)},
		{"n": "street_pool", "eye": Vector3(32.5, 2.5, 2.0),
			"look": Vector3(32.5, 0.0, -10.0)},
	]
	print("  %-14s %8s %9s %8s %8s %8s"
		% ["station", "mean", "clipped", "black", "p50", "p99"])
	for s in stations:
		cam.global_position = s["eye"]
		cam.look_at(s["look"], Vector3.UP)
		await _settle(45)
		var a: Dictionary = _stats(root.get_texture().get_image())
		await _settle(20)
		var b: Dictionary = _stats(root.get_texture().get_image())
		if absf(float(a["mean"]) - float(b["mean"])) > 0.0005:
			print("  %-14s REFUSED: two reads differ by %.5f"
				% [String(s["n"]), absf(float(a["mean"]) - float(b["mean"]))])
			continue
		print("  %-14s %8.4f %8.1f%% %7.1f%% %8.4f %8.4f"
			% [String(s["n"]), a["mean"], 100.0 * float(a["clipped"]),
				100.0 * float(a["black"]), a["p50"], a["p99"]])
	quit(0)
