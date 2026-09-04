extends SceneTree
## The walk: film emulsion on REAL pipeline geometry, not a blockout.
##
## Driven by tools/film_walk_probe.py. Assembles a staged Zoo/Patina level the
## way walk/headless/walk_night_strip.gd does -- fixtures GLB into a stage,
## LuxRoot, site lights baked through LuxLightLoader, a night preset -- then
## shoots it from cameras DERIVED FROM THE SCENE'S OWN BOUNDS, three times:
## film off, film on with per-channel quantization, film on with the shared
## decision.
##
## WHY THE SAMPLE SCENE IS NOT ENOUGH, AND WHY THIS EXISTS. Roadmap item 61
## names "the walk as the final judge". Everything measured before this ran on
## a blockout of untextured boxes: no Patina vertex bake, no tiled trim, no
## modular repetition, no signage, no real fixture hardware. Film response is a
## treatment of what the lighting DOES, so a scene with nothing in it can only
## show that the arithmetic is right -- which was already known.
##
## WHY THE CAMERAS COME FROM THE AABB. A hand-placed camera is a camera for one
## GLB. Framing the merged bounds means this runs on any staged level the
## pipeline produces, which is what makes it a walk instrument rather than a
## screenshot of one night strip.
##
## NOT --headless: rendering is the point.

const BEGIN := "<<<FILM_WALK_JSON"
const END := "FILM_WALK_JSON>>>"

var _lux: LuxRoot
var _stage: Node3D
var _cam: Camera3D
var _preset: LuxPreset
var _out: Dictionary = {}


func _initialize() -> void:
	_main()


func _log(s: String) -> void:
	print("[film_walk] " + s)


func _fail(why: String) -> void:
	push_error("[film_walk] " + why)
	print("[film_walk] FAILED: " + why)
	quit(2)


## Union of every VisualInstance3D AABB in world space. The staged level bakes
## its world transforms into the GLB, so this is the site's real extent.
func _world_bounds(n: Node, acc: AABB, seen: bool) -> Array:
	if n is VisualInstance3D:
		var vi := n as VisualInstance3D
		var box: AABB = vi.global_transform * vi.get_aabb()
		acc = box if not seen else acc.merge(box)
		seen = true
	for c in n.get_children():
		var r := _world_bounds(c, acc, seen)
		acc = r[0]
		seen = bool(r[1])
	return [acc, seen]


func _main() -> void:
	await process_frame

	var glb: String = OS.get_environment("LUX_WALK_GLB")
	var lights: String = OS.get_environment("LUX_WALK_LIGHTS")
	var out_dir: String = OS.get_environment("LUX_WALK_OUT")
	var preset_name: String = OS.get_environment("LUX_WALK_PRESET")
	if preset_name == "":
		preset_name = "Gothic Street Night"
	var site_env: String = OS.get_environment("LUX_WALK_SITE")
	if out_dir == "":
		_fail("LUX_WALK_OUT must be set")
		return
	if site_env == "" and glb == "":
		_fail("one of LUX_WALK_SITE (a composition) or LUX_WALK_GLB (a single "
			+ "self-contained level) must be set")
		return
	if site_env == "" and not ResourceLoader.exists(glb):
		_fail("no such resource: " + glb + " (was the project imported?)")
		return

	_stage = Node3D.new()
	_stage.name = "FilmWalkStage"
	root.add_child(_stage)

	# A STAGED SITE IS A COMPOSITION, NOT A FILE, and assuming otherwise is how
	# the first run of this probe rendered a void. `night_strip_fixtures.glb`
	# holds only the fixture HARDWARE -- lamps, brackets, sign faces. The
	# buildings are separate GLBs the walk harness places at known transforms,
	# so loading the fixtures alone produces rows of lit lamp faces floating in
	# black with nothing for them to illuminate. Every statistic taken off that
	# frame was measuring near-black noise, and one of them said film DOUBLED
	# the module repetition.
	#
	# LUX_WALK_SITE is a JSON array of {glb, pos} entries, applied in order.
	# LUX_WALK_GLB stays supported for a single self-contained level.
	var placed: int = 0
	var site_json: String = site_env
	if site_json != "":
		var parsed: Variant = JSON.parse_string(site_json)
		if not (parsed is Array):
			_fail("LUX_WALK_SITE is not a JSON array")
			return
		for entry: Variant in parsed:
			var d: Dictionary = entry
			var path: String = String(d.get("glb", ""))
			if not ResourceLoader.exists(path):
				_log("WARN: skipping missing " + path)
				continue
			var ps: PackedScene = load(path) as PackedScene
			if ps == null:
				_log("WARN: not a PackedScene: " + path)
				continue
			var inst: Node3D = ps.instantiate()
			var pos: Array = d.get("pos", [0, 0, 0])
			inst.position = Vector3(float(pos[0]), float(pos[1]),
				float(pos[2]))
			_stage.add_child(inst)
			placed += 1
			_log("placed %s at %s" % [path.get_file(), inst.position])
	else:
		var packed: PackedScene = load(glb) as PackedScene
		if packed == null:
			_fail("not a PackedScene: " + glb)
			return
		# World transforms baked in, so it goes at the origin as-is.
		_stage.add_child(packed.instantiate())
		placed = 1
	if placed == 0:
		_fail("nothing was placed -- the site spec matched no resources")
		return

	_lux = LuxRoot.new()
	_lux.name = "LuxRoot"
	_stage.add_child(_lux)
	await process_frame

	if lights != "" and ResourceLoader.exists(lights):
		var bake: Dictionary = LuxLightLoader.bake(lights, _stage)
		_log("site lights: " + str(bake))
	else:
		_log("WARN: no site lights manifest -- the level will be lit by the "
			+ "preset alone, which is not what a night walk looks like")

	# Fixtures spawn from LuxEmit_* markers in the GLB. This is the hardware
	# the night strip is actually lit by; without it the walk is a preset test.
	var spawned: Dictionary = LuxFixtureSpawner.spawn(_stage)
	_log("fixtures: " + str(spawned))

	_lux.blend_to_preset(StringName(preset_name), 0.0)
	await process_frame
	_preset = _lux.get_current_preset()
	if _preset == null:
		_fail("preset %s did not resolve" % preset_name)
		return
	_log("preset: " + String(_preset.preset_name))

	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = 600.0
	_cam.fov = 62.0
	_stage.add_child(_cam)
	_cam.make_current()

	var res: Array = _world_bounds(_stage, AABB(), false)
	if not bool(res[1]):
		_fail("no VisualInstance3D in the staged level -- nothing to frame")
		return
	var bounds: AABB = res[0]
	_log("site bounds: pos %s size %s" % [bounds.position, bounds.size])
	_out["bounds"] = {"position": [bounds.position.x, bounds.position.y,
		bounds.position.z], "size": [bounds.size.x, bounds.size.y,
		bounds.size.z]}

	# REFUSE TO MEASURE A VOID. The first run of this probe produced frames
	# that were 99.9% black and reported hue counts and repetition peaks off
	# them as if they meant something. A lit night frame has SOME lit surface;
	# one that does not is a staging failure, not a dark look.
	# Cameras: explicit ones from the site spec if given, else derived. A
	# derived camera is a guess about where the ground is, and this site's AABB
	# reaches y = -8 because something hangs below the street, so "eye height
	# above the bounds floor" put the camera underground. A site that knows
	# where its sidewalk is should say so; the derived set is the fallback.
	var shots := _shot_list(bounds)
	var cam_env: String = OS.get_environment("LUX_WALK_CAMERAS")
	if cam_env != "":
		var parsed_cams: Variant = JSON.parse_string(cam_env)
		if parsed_cams is Array and (parsed_cams as Array).size() > 0:
			shots = []
			for entry: Variant in parsed_cams:
				var d: Dictionary = entry
				var e: Array = d.get("eye", [0, 2, 10])
				var t: Array = d.get("at", [0, 2, 0])
				shots.append({
					"name": String(d.get("name", "shot")),
					"eye": Vector3(float(e[0]), float(e[1]), float(e[2])),
					"at": Vector3(float(t[0]), float(t[1]), float(t[2])),
				})
			_log("using %d camera(s) from the site spec" % shots.size())
	var report: Dictionary = {}
	# hdr_only IS THE CONTROL, and it exists because the first version of this
	# walk had none. The film states raise use_hdr_2d, so EVERY difference
	# they showed was "film or the render target, one of the two" -- the same
	# shape of error the optionality probe made before it got a control.
	# hdr_only is film OFF at the film states' render target: film_off vs
	# hdr_only is the target alone, hdr_only vs film_shared is the film alone.
	for state: String in ["film_off", "hdr_only", "film_perchannel",
			"film_shared"]:
		_configure(state)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var per_shot: Dictionary = {}
		for shot: Dictionary in shots:
			_cam.global_transform = Transform3D(Basis(), shot["eye"])
			_cam.look_at(shot["at"], Vector3.UP)
			for i in range(6):
				await RenderingServer.frame_post_draw
			var img: Image = root.get_texture().get_image()
			var path: String = "%s/%s__%s.png" % [out_dir.rstrip("/"),
				String(shot["name"]), state]
			img.save_png(path)
			# PER SHOT, not once before any camera was placed. The first
			# version sampled the default view, reported "lit fraction 1.0",
			# and then measured four frames that were 99% black anyway.
			var lit: float = _lit_fraction(img)
			per_shot[String(shot["name"])] = {"path": path, "lit": lit}
			if state == "film_off" and lit < 0.05:
				_log(("WARN: %s is only %.1f%% lit -- statistics off it will "
					+ "describe empty sky, not the level")
					% [String(shot["name"]), lit * 100.0])
		report[state] = {
			"shots": per_shot,
			"film_active": _lux.is_film_emulsion_active(),
			"coherence": _preset.dither_chroma_coherence,
			"use_hdr_2d": bool(root.use_hdr_2d),
		}
		_log("%-16s film_active=%-5s coherence=%.2f hdr_2d=%s"
			% [state, _lux.is_film_emulsion_active(),
			   _preset.dither_chroma_coherence, root.use_hdr_2d])

	_out["states"] = report
	_out["preset"] = String(_preset.preset_name)
	_out["adapter"] = RenderingServer.get_video_adapter_name()
	print(BEGIN)
	print(JSON.stringify(_out, "  "))
	print(END)
	quit(0)


## Fraction of pixels above 0.05 luminance -- "is anything actually lit".
func _lit_fraction(img: Image) -> float:
	if img == null:
		return 0.0
	var w: int = img.get_width()
	var h: int = img.get_height()
	var lit: int = 0
	var n: int = 0
	# Every 4th pixel in both axes: this is a sanity gate, not a measurement.
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c: Color = img.get_pixel(x, y)
			n += 1
			if c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722 > 0.05:
				lit += 1
	return float(lit) / float(maxi(n, 1))


## Four viewpoints derived from the site's own bounds, so this frames any level.
func _shot_list(b: AABB) -> Array:
	var c: Vector3 = b.get_center()
	var span: float = maxf(b.size.x, b.size.z)
	var eye_y: float = b.position.y + maxf(b.size.y * 0.35, 1.7)
	return [
		# Wide: the whole strip, from outside the long axis.
		{"name": "01_wide", "eye": c + Vector3(0, span * 0.45, span * 0.85),
			"at": c},
		# Three-quarter, eye height: what a player standing on the sidewalk
		# sees, which is where a look is actually judged.
		{"name": "02_street", "eye": Vector3(c.x - span * 0.35, eye_y,
			c.z + span * 0.45), "at": Vector3(c.x, eye_y, c.z)},
		# Down the facade: the shallow angle where modular repetition reads
		# hardest (roadmap items 57 and 74).
		{"name": "03_facade", "eye": Vector3(b.position.x + span * 0.05,
			eye_y, c.z + span * 0.28),
			"at": Vector3(b.position.x + b.size.x, eye_y, c.z + span * 0.1)},
		# Close: a light pool at eye height, where the rainbow lives.
		{"name": "04_pool", "eye": Vector3(c.x, eye_y, c.z + span * 0.14),
			"at": Vector3(c.x, eye_y * 0.6, c.z - span * 0.1)},
	]


func _configure(state: String) -> void:
	var vp := _lux.get_viewport()
	if state == "film_off" or state == "hdr_only":
		_preset.film_emulsion_enabled = false
		_lux.set_film_emulsion_enabled(false)
		_lux.apply_preset(_preset, 0.0)
		# Safe to write directly: _sync_film_precision is edge-triggered on
		# its own _hdr_2d_raised flag, which is false while film is off, so
		# it will not fight this and will not later "restore" it.
		if vp != null and "use_hdr_2d" in vp:
			vp.use_hdr_2d = (state == "hdr_only")
		return
	# Leaving hdr_only's raised target set would be captured as the film
	# states' saved value and restored on the way out -- put it back first.
	# ONLY when film is currently off. _sync_film_precision is edge-triggered
	# on its own raised flag: with film already active that flag is set, so
	# clearing the viewport here is never re-raised and the next film state
	# silently renders at the WRONG target. It did, on the first run of this
	# control -- film_shared reported hdr_2d=false. The state line in the log
	# is what caught it, which is the argument for printing state.
	if vp != null and "use_hdr_2d" in vp and not _lux.is_film_emulsion_active():
		vp.use_hdr_2d = false
	_preset.film_emulsion_enabled = true
	_preset.grain_mode = 2
	_preset.dither_chroma_coherence = 0.0 if state == "film_perchannel" else 1.0
	_lux.set_film_emulsion_enabled(true)
	_lux.apply_preset(_preset, 0.0)
