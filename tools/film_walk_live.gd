extends SceneTree
## THE WALK, walked. First person, on the real staged night strip, with the
## film treatment on a key.
##
## `film_walk_probe.gd` opens Godot, points four fixed cameras at the level,
## saves sixteen PNGs and quits. That is a screenshot run. It can tell you the
## treatment behaves the way the arithmetic says it should; it cannot tell you
## what the street feels like to move down, which is the only question roadmap
## item 61 names as its closing condition and the only one a still cannot
## answer -- grain is TEMPORAL and screen-space, so a frozen frame hides both
## the thing it does well (it moves, and the banding does not) and the thing it
## might do badly (it crawls).
##
##   WASD move   SHIFT sprint   SPACE jump   mouse look   ESC release   F8 quit
##   F  cycle film: off -> per-channel -> SHARED
##   V  toggle use_hdr_2d INDEPENDENTLY of film (this is the control)
##   N  toggle chroma coherence          [ ] grain strength
##   -  = exposure (the strip is dark)   G  cycle preset
##   P  screenshot, with calibration read
##
## THE GAMMA NULL TEST IN THE HUD IS NOT DECORATION. The walk's stills showed
## that with `use_hdr_2d` raised the saved frame is the LINEAR form of the
## unraised one (best-fit exponent 2.265 over 746k mid-tone pixels, residual
## 0.239 -> 0.046). Two different defects produce that and they need opposite
## fixes:
##
##   (a) the READBACK is linear and the screen is fine -- `get_image()` on a
##       float target returns pre-encode data. Cosmetic; fix the probe, and
##       every PNG statistic in Phase 1 audit section 8b with it.
##   (b) the PRESENTED IMAGE really is linear -- the post stack keys its
##       contrast pivot, palette zones and quantization off 0.5, and mid-grey
##       in a linear target is 0.2140, so every threshold in the pass lands in
##       the wrong place whenever film is on. Then `film_manage_hdr_2d = true`
##       is wrong as a shipped default.
##
## Only the screen can answer that, so the HUD asks a question the eye can
## actually answer in a dark scene -- see NULL_SOLIDS below for why it is a
## match test and not a brightness test. P prints the readback half, which is
## automatic; the null test is the screen half, which is not.
##
const DIRP := "res://walk/headless"
const PRESETS: Array[StringName] = [&"Gothic Street Night", &"Blue Hour",
	&"Gas Station Fluorescent", &"Mission Goes Hot"]

## Same composition as walk_night_strip.gd's STORES and film_walk_probe's
## default site. A staged site is a COMPOSITION: the fixtures GLB holds only
## the lamp hardware, and loading it alone renders lit lamp faces in a void.
const STORES: Array = [
	{"stem": "night_deli.patina.glb", "extra": "night_deli_dressing.glb",
		"pos": Vector3(-34, 0, -21)},
	{"stem": "night_pawn.patina.glb", "extra": "night_pawn_dressing.glb",
		"pos": Vector3(0, 0, -9)},
	{"stem": "night_auto.patina.glb", "extra": "night_auto_dressing.glb",
		"pos": Vector3(28, 0, -11)},
]

#: THE GAMMA NULL TEST, and why it replaced a strip of grey swatches.
#:
#: The first version drew 0.50 above 0.214 and asked which was brighter. That
#: is an ABSOLUTE judgement of two dark greys on an unknown monitor in a scene
#: that is mostly black, and it is not answerable -- the honest response to it
#: was "it's hard to tell because it's so dark", which is the instrument's
#: fault and not the observer's.
#:
#: This asks a MATCH question instead, which the eye is good at even when it
#: cannot judge absolute brightness at all. A fine checkerboard of pure black
#: and pure white averages, IN LIGHT, to 0.5 linear. Squint or step back and it
#: blends into a flat grey. The question is only: WHICH of the two solid
#: patches beside it does that grey blend into?
#:
#:   blends into 0.735  ->  the presented image is sRGB-encoded. Correct.
#:                          Only the CAPTURE path is linear, so section 8b's
#:                          PNG statistics are what need fixing.
#:   blends into 0.500  ->  the presented image is LINEAR. The post stack keys
#:                          its contrast pivot, palette zones and quantization
#:                          off 0.5, so every threshold lands wrong whenever
#:                          film is on, and film_manage_hdr_2d = true is wrong
#:                          as a shipped default.
#:
#: 0.735 because sRGB-encoding 0.5 linear gives 0.7354. The test is
#: self-normalising: it compares patches to their own neighbour, so it does not
#: care how dark the room, the monitor or the level is.
const NULL_SOLIDS: Array = [
	{"v": 0.7354, "label": "0.735  -- if the dither blends HERE, screen is sRGB (fine)"},
	{"v": 0.5000, "label": "0.500  -- if the dither blends HERE, screen is LINEAR (bug)"},
]

var _lux: LuxRoot
var _stage: Node3D
var _preset: LuxPreset
var _label: Label
var _swatch_rects: Array[ColorRect] = []
var _film_state: int = 0          # 0 off, 1 per-channel, 2 shared
var _preset_i: int = 0
var _hdr_override: int = 0        # 0 follow film, 1 force on, 2 force off
var _shots: int = 0
var _start_fog: float = 0.004
var _fog_touched: bool = false
var _out_dir: String = ""


func _initialize() -> void:
	_main()


func _log(s: String) -> void:
	print("[film_walk_live] " + s)


func _fail(why: String) -> void:
	push_error("[film_walk_live] " + why)
	print("[film_walk_live] FAILED: " + why)
	quit(2)


func _exists(p: String) -> bool:
	return ResourceLoader.exists(p)


func _main() -> void:
	await process_frame
	var fog_env := OS.get_environment("LUX_WALK_BASE_FOG")
	if fog_env != "":
		_start_fog = clampf(float(fog_env), 0.0, 0.10)
	_out_dir = OS.get_environment("LUX_WALK_OUT")
	if _out_dir == "":
		_out_dir = "user://film_walk_live"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	_stage = Node3D.new()
	_stage.name = "FilmWalkLive"
	root.add_child(_stage)

	_build_ground()

	var placed := 0
	for s: Dictionary in STORES:
		for key: String in ["stem", "extra"]:
			var p: String = DIRP + "/" + String(s[key])
			if not _exists(p):
				_log("WARN: missing " + p)
				continue
			var ps := load(p) as PackedScene
			if ps == null:
				continue
			var inst: Node3D = ps.instantiate()
			_stage.add_child(inst)
			inst.global_position = s["pos"]
			placed += 1
	var fixtures := DIRP + "/night_strip_fixtures.glb"
	if _exists(fixtures):
		# World transforms baked in, so it goes at the origin as-is.
		_stage.add_child((load(fixtures) as PackedScene).instantiate())
		placed += 1
	else:
		_log("WARN: no fixtures GLB -- this is a preset test, not a night walk")
	if placed == 0:
		_fail("nothing staged from " + DIRP)
		return
	_log("staged %d piece(s)" % placed)

	_lux = LuxRoot.new()
	_lux.name = "LuxRoot"
	_stage.add_child(_lux)
	await process_frame

	var lights := DIRP + "/night_strip.site.lights.json"
	if _exists(lights) or FileAccess.file_exists(lights):
		_log("site lights: " + str(LuxLightLoader.bake(lights, _stage)))
	else:
		_log("WARN: no site lights manifest")
	_lux.bind_fixture_emissives(_stage)
	_log("fixtures: " + str(LuxFixtureSpawner.spawn(_stage)))

	_lux.blend_to_preset(PRESETS[0], 0.0)
	await process_frame
	_preset = _lux.get_current_preset()
	if _preset == null:
		_fail("preset %s did not resolve -- is the preset library scanning "
			% String(PRESETS[0]) + "the directory?")
		return

	_build_overlay()
	_build_player()
	_apply_film()
	_refresh()
	_log("walk ready. F film, V hdr_2d, N coherence, G preset, P shot, F8 quit")

	# LUX_WALK_SELFTEST: shoot both render targets and quit. This exists
	# because the calibration readback depends on `get_global_rect()` of a
	# ColorRect nested two containers deep, which is zero until the layout
	# pass has run -- a silent way for every swatch to sample pixel (0,0) and
	# report nonsense that looks like data. It is also the CI-able path.
	if OS.get_environment("LUX_WALK_SELFTEST") != "":
		# FREEZE THE VIEWPOINT. The player is a CharacterBody3D under gravity,
		# so it settles between captures and every shot sees a different scene.
		var pl: Node = _stage.get_node_or_null(^"Player")
		if pl != null:
			pl.set_physics_process(false)
			pl.set_process_input(false)
			(pl as Node3D).global_position = Vector3(-46, 1.95, 6)
		for i in range(16):
			await process_frame

		# ONE PAIRED A/B, AND NOTHING ELSE.
		#
		# The sweep this replaces walked a dozen configurations and reported
		# figures that did not move when its parameters did -- filenames said
		# 0.025 for every density in a 0.025..0.200 sweep. A harness that
		# cannot be shown to be applying its own settings cannot be used to
		# attribute anything, and several conclusions this session were drawn
		# through it before that was noticed.
		#
		# So: two frames, every parameter pinned and PRINTED at capture, the
		# render target held identical across both. Whatever differs between
		# these two images is the film shader and nothing else.
		var vp0: Viewport = root
		if vp0 != null and "use_hdr_2d" in vp0:
			vp0.use_hdr_2d = false
		_lux.film_manage_hdr_2d = false
		# LUX FILM MODE, exercised as the single switch it claims to be: the
		# preset is NOT touched here, only the mode. If the shipped defaults
		# and the override are wired correctly this is all a caller needs.
		for on: bool in [false, true]:
			_film_state = 2 if on else 0
			_lux.set_film_mode(on)
			_lux.apply_preset(_preset, 0.0)
			for i in range(6):
				await process_frame
			_log(("AB film_mode=%s active=%s hdr=%s | preset untouched: "
				+ "fog=%.4f density=%.4f coherence=%.2f octaves=%d scale=%.2f")
				% [on, _lux.is_film_emulsion_active(),
				   bool(vp0.use_hdr_2d), _preset.film_base_fog,
				   _preset.film_grain_strength,
				   _preset.dither_chroma_coherence,
				   _preset.film_grain_octaves, _preset.film_grain_scale])
			await _shoot()
		quit(0)


## The staged set has no site ground plane -- give the player one to stand on,
## or the walk is a fall.
func _build_ground() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	var mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.16, 0.19)
	pm.material = mat
	mesh.mesh = pm
	mesh.position = Vector3(0, 0.001, 0)
	_stage.add_child(body)
	_stage.add_child(mesh)


func _build_player() -> void:
	var script := GDScript.new()
	script.source_code = _player_source()
	if script.reload() != OK:
		_fail("player controller did not compile")
		return
	var player := CharacterBody3D.new()
	player.name = "Player"
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	col.shape = cap
	player.add_child(col)
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.75, 0)
	var cam := Camera3D.new()
	cam.fov = 72.0
	cam.near = 0.05
	cam.far = 600.0
	head.add_child(cam)
	player.add_child(head)
	player.set_script(script)
	# West end of the strip, on the street, facing the deli.
	player.position = Vector3(-46, 1.2, 6)
	_stage.add_child(player)
	cam.current = true


## Layer 3: above Lux's post pass on -1, so the readout is never itself graded,
## dithered or grained. A HUD the effect under test also processes is a HUD
## that lies about the effect under test.
##
## THE TEST PATCHES ARE ON THE SAME LAYER FOR A DELIBERATE REASON. They are not
## trying to escape the post pass -- they are trying to share the RENDER TARGET,
## which is the thing under suspicion. Everything drawn into the 2D target,
## post pass and HUD alike, lands in the same buffer and is presented the same
## way, so a swatch that changes when only `use_hdr_2d` changes is evidence
## about the target and not about the shader.
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	root.add_child(layer)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_TOP_LEFT)
	col.position = Vector2(16, 16)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(col)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(panel)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 15)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_label)

	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(strip)

	var how := Label.new()
	how.text = ("\nGAMMA NULL TEST -- squint, or lean back from the screen.\n"
		+ "The striped bar blends to a flat grey. Which solid patch does it\n"
		+ "match? Press V to swap the render target and watch it move.\n"
		+ "If the bar shows moire or uneven stripes the window is being\n"
		+ "rescaled and this test is INVALID -- say so rather than reading it.")
	how.add_theme_font_size_override("font_size", 13)
	how.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(how)

	# The dither bar: alternating black and white columns. Its average IN
	# LIGHT is 0.5 linear regardless of the display's transfer, which is what
	# makes it a reference the monitor cannot move.
	var row0 := HBoxContainer.new()
	row0.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bars := HBoxContainer.new()
	bars.add_theme_constant_override("separation", 0)
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in range(60):
		var b := ColorRect.new()
		b.color = Color(0, 0, 0) if i % 2 == 0 else Color(1, 1, 1)
		b.custom_minimum_size = Vector2(3, 34)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bars.add_child(b)
	row0.add_child(bars)
	var lab0 := Label.new()
	lab0.text = "  black/white dither = 0.5 in LIGHT, whatever the display does"
	lab0.add_theme_font_size_override("font_size", 13)
	lab0.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row0.add_child(lab0)
	strip.add_child(row0)

	for s: Dictionary in NULL_SOLIDS:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rect := ColorRect.new()
		var v: float = float(s["v"])
		rect.color = Color(v, v, v, 1.0)
		rect.custom_minimum_size = Vector2(180, 34)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(rect)
		_swatch_rects.append(rect)
		var lab := Label.new()
		lab.text = "  " + String(s["label"])
		lab.add_theme_font_size_override("font_size", 13)
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lab)
		strip.add_child(row)


func _want_hdr() -> bool:
	if _hdr_override == 1:
		return true
	if _hdr_override == 2:
		return false
	return _film_state != 0 and _lux.film_manage_hdr_2d


func _apply_film() -> void:
	_preset.film_emulsion_enabled = _film_state != 0
	if _film_state != 0:
		_preset.grain_mode = 2
		_preset.dither_chroma_coherence = 0.0 if _film_state == 1 else 1.0
		# The SHIPPED preset default for base fog is 0.0 -- the feature is
		# inert until a preset asks. This walk is a demo, so it starts the
		# knob somewhere you can see it, and the HUD says which is which.
		if not _fog_touched:
			_preset.film_base_fog = _start_fog
	_lux.set_film_emulsion_enabled(_film_state != 0)
	_lux.apply_preset(_preset, 0.0)
	# V forces the target independently of film. Safe to write directly ONLY
	# while Lux is not holding a raise: _sync_film_precision is edge-triggered
	# on its own flag, and writing under it is how the probe once rendered a
	# film state at the wrong target without noticing.
	var vp: Viewport = root
	if _hdr_override != 0 and vp != null and "use_hdr_2d" in vp:
		if _film_state == 0:
			vp.use_hdr_2d = (_hdr_override == 1)


func _refresh() -> void:
	if _label == null:
		return
	var vp: Viewport = root
	var hdr: bool = bool(vp.use_hdr_2d) if (vp != null
		and "use_hdr_2d" in vp) else false
	var names := ["OFF", "ON, per-channel quantization", "ON, SHARED quantizer"]
	var active: bool = _lux.is_film_emulsion_active()
	_label.text = "\n".join([
		"film      %s" % names[_film_state],
		"active    %s%s" % [active, "" if (active == (_film_state != 0))
			else "   <<< " + _why_not_film()],
		"use_hdr_2d %s%s%s   <- V forces it OFF even with film on;" % [hdr,
			"" if _hdr_override == 0 else "  (FORCED)",
			"   <<< RAISED WITH FILM OFF -- leaked, not a control"
			if (hdr and not active and _hdr_override == 0) else ""],
		"preset    %s" % String(_preset.preset_name),
		"grain     %.3f   coherence %.2f   luma_scale %.2f"
			% [_preset.film_grain_strength, _preset.dither_chroma_coherence,
			   _preset.dither_luma_scale],
		"base_fog  %.4f  ; '  -- projection flare, TENTHS of a percent."
			% _preset.film_base_fog,
		"          Stops the void being a dead hole. It is NOT the grain and",
		"          it is not a lift of the picture -- [ ] density is the grain.",
		"res lock  %s   R     -- grain sized to FRAME WIDTH (2048 ref)."
			% ("ON " if _preset.film_grain_ref_width > 1.0 else "OFF"),
		"          Toggle, then resize the window: locked, a crystal stays",
		"          the same fraction of frame; unlocked, the same pixels.",
		"octaves   %d      O     -- crystal SIZES summed. 1 = one speck size,"
			% _preset.film_grain_octaves,
		"          which is fizz. 2-3 is where it starts to dance.",
		"grain_sz  %.2f  K L   -- crystal footprint. 1.00 was chosen by eye"
			% _preset.film_grain_scale,
		"          at density 0.20; coarsening was only wanted back when the",
		"          density was too low to see the grain at all.",
		"boil      %d fps  9 0" % _preset.film_grain_fps,
		"",
		"exposure  %.2f   (- and = to change; the strip is genuinely dark)"
			% _preset.exposure,
		"",
		"F film  V hdr_2d  N coherence  , . luma_scale  G preset  - = exposure",
		"[ ] density  ; ' fog  O octaves  K L size  R reslock  P shot",
	])


## Reads the swatches back out of the frame it just saved. If a swatch drawn at
## 0.50 comes back as 0.214, the READBACK is linear -- which is a different
## defect from the SCREEN being linear, and only a human looking at the window
## can tell those apart. So this prints, and does not conclude.
## A readout that says a feature is on and inactive without saying WHICH of the
## five conditions is closed is a readout that leaves an operator guessing, and
## 0.28.1 already learned that on `film_demo`. Carried here because this tool
## reproduced the same failure by a different route.
func _why_not_film() -> String:
	if not _lux.film_emulsion_enabled:
		return "film master is OFF"
	if not _preset.film_emulsion_enabled:
		return "this preset does not ask for film (did G just overwrite it?)"
	if _preset.grain_mode != 2:
		return "grain mode is not Film Emulsion"
	var q: LuxQualityProfile = _lux.get_quality_profile()
	if q != null and not q.allow_film_emulsion:
		return "this quality tier refuses film (Low / Compatibility)"
	return "film assets unavailable -- reimport the project"


func _shoot() -> void:
	await RenderingServer.frame_post_draw
	var vp: Viewport = root
	var img: Image = vp.get_texture().get_image()
	var hdr: bool = bool(vp.use_hdr_2d) if "use_hdr_2d" in vp else false
	# The knob that matters differs by state, so the filename names the one
	# that is actually in play rather than a constant that means nothing here.
	var knob: float = (_preset.film_grain_strength if _film_state != 0
		else _preset.grain_strength)
	var path := "%s/live_%02d_film%d_hdr%s_k%.3f.png" % [_out_dir.rstrip("/"),
		_shots, _film_state, "1" if hdr else "0", knob]
	img.save_png(path)
	_shots += 1
	_log("shot -> " + path)
	_log("  calibration readback (drawn -> captured):")
	var linear_hits := 0
	for i in range(_swatch_rects.size()):
		var rect: ColorRect = _swatch_rects[i]
		var drawn: float = rect.color.r
		var r2: Rect2 = rect.get_global_rect()
		if r2.size.x < 4.0 or r2.size.y < 4.0:
			_log("    swatch %d has no laid-out rect -- NOT SAMPLED. A "
				% i + "zero rect samples pixel (0,0) and reports the sky.")
			continue
		var p: Vector2 = r2.get_center()
		var x: int = clampi(int(p.x), 0, img.get_width() - 1)
		var y: int = clampi(int(p.y), 0, img.get_height() - 1)
		var got: float = img.get_pixel(x, y).r
		var lin: float = pow(drawn, 2.2)
		var note := ""
		if drawn > 0.05 and absf(got - lin) < absf(got - drawn):
			note = "  <- matches linear(%.3f)=%.3f, NOT the drawn value" % [
				drawn, lin]
			linear_hits += 1
		_log("    %.3f -> %.3f%s" % [drawn, got, note])
	if linear_hits >= 2:
		_log("  READBACK IS LINEAR. That is half the answer. The other half is")
		_log("  the GAMMA NULL TEST in the window: squint at the striped bar")
		_log("  and see which solid patch it blends into. 0.735 means the")
		_log("  screen is fine and only this capture path is affected. 0.500")
		_log("  means the presented image is linear too, and")
		_log("  film_manage_hdr_2d = true is wrong as a shipped default.")
	else:
		_log("  Readback matches the drawn values -- this frame's target is")
		_log("  behaving. Press V and shoot again to compare.")


func on_key(code: int) -> void:
	match code:
		KEY_F:
			_film_state = (_film_state + 1) % 3
			_hdr_override = 0
			_apply_film()
		KEY_V:
			# V MUST BE ABLE TO TURN THE RAISE OFF WHILE FILM IS RUNNING, and
			# it could not before: _apply_film only wrote the viewport when
			# film was off, so with film on the target was whatever
			# film_manage_hdr_2d wanted and there was no way to A/B it.
			#
			# That made the most important question in this feature
			# unanswerable from inside the walk. Measured on the night strip:
			# a pixel at [0,0,0] with film OFF reads [0.0118, 0.0118, 0.0118]
			# with film STILL OFF and only use_hdr_2d raised. The render target
			# lifts the blacks by itself. Turning the master off is what tells
			# you how much of any brightness change is the film and how much is
			# the target it silently switched to.
			_hdr_override = (_hdr_override + 1) % 3
			_lux.film_manage_hdr_2d = (_hdr_override != 2)
			_apply_film()
			var v2: Viewport = root
			if _hdr_override == 2 and v2 != null and "use_hdr_2d" in v2:
				v2.use_hdr_2d = false
		KEY_N:
			_preset.dither_chroma_coherence = (
				0.0 if _preset.dither_chroma_coherence > 0.5 else 1.0)
			_lux.apply_preset(_preset, 0.0)
		KEY_G:
			_preset_i = (_preset_i + 1) % PRESETS.size()
			# INSTANT, not a 0.5 s blend. A blend keeps applying interpolated
			# presets built from the LIBRARY resource for its whole duration,
			# and every shipped preset has film_emulsion_enabled = false and
			# grain_mode != FILM_EMULSION -- so a film state applied during the
			# blend is overwritten one frame later. The visible symptom is the
			# HUD reading "film ON" and "active false" at the same time, which
			# is how this was found: a walk that looked good while the feature
			# under test was not running.
			_lux.blend_to_preset(PRESETS[_preset_i], 0.0)
			await process_frame
			var p := _lux.get_current_preset()
			if p != null:
				_preset = p
				_apply_film()
		KEY_MINUS:
			_preset.exposure = maxf(0.25, _preset.exposure - 0.15)
			_lux.apply_preset(_preset, 0.0)
		KEY_EQUAL:
			# The night strip at Gothic Street Night is genuinely dark, and a
			# look cannot be judged in near-black. This lifts the scene without
			# touching anything the film path reads, so the comparison stays
			# honest while being visible.
			_preset.exposure = minf(4.0, _preset.exposure + 0.15)
			_lux.apply_preset(_preset, 0.0)
		KEY_R:
			# Resolution lock on/off. Without an A/B this change is invisible:
			# at ~1440p it is deliberately a no-op, and the whole point is what
			# happens when the frame is a DIFFERENT size. Toggle it, then
			# resize the window -- locked, a crystal stays the same fraction of
			# the frame; unlocked, it stays the same number of pixels and the
			# emulsion changes character with the window.
			_preset.film_grain_ref_width = (
				0.0 if _preset.film_grain_ref_width > 1.0 else 2048.0)
			_lux.apply_preset(_preset, 0.0)
		KEY_O:
			# CRYSTAL SIZES. One octave is a field of identically-sized specks;
			# real emulsion is a distribution, many fine plus sparser large.
			# Each octave carries its own per-frame transform so the scales
			# move against each other rather than as one sheet -- which is the
			# difference between grain dancing and a screen door shimmering.
			_preset.film_grain_octaves = (
				_preset.film_grain_octaves % 3) + 1
			_lux.apply_preset(_preset, 0.0)
		KEY_K, KEY_L:
			# GRAIN SIZE, and the reason "too much fizz" is usually this and
			# not amplitude. film_grain_scale divides FRAGCOORD, so at the
			# default 1.0 one grain texel covers one PIXEL -- the finest
			# structure the screen can hold, which reads as electronic sparkle
			# rather than silver. Real emulsion has a clump size. Raising this
			# trades fizz for grain without giving up any density.
			_preset.film_grain_scale = clampf(
				_preset.film_grain_scale + (-0.25 if code == KEY_K else 0.25),
				0.5, 3.0)
			_lux.apply_preset(_preset, 0.0)
		KEY_9, KEY_0:
			# BOIL RATE. The whole grain field re-randomises every film frame
			# (offset + one of 8 dihedral transforms), so at 24 fps it
			# reshuffles 24 times a second. That is what film does; combined
			# with a one-pixel grain size it is also what fizz is.
			_preset.film_grain_fps = clampi(
				_preset.film_grain_fps + (-2 if code == KEY_9 else 2), 4, 60)
			_lux.apply_preset(_preset, 0.0)
		KEY_SEMICOLON, KEY_APOSTROPHE:
			# Base fog: the additive shadow term. This is the knob that puts
			# grit back in the void, which the multiplicative density cannot.
			_fog_touched = true
			var bf: float = -0.001 if code == KEY_SEMICOLON else 0.001
			_preset.film_base_fog = clampf(
				_preset.film_base_fog + bf, 0.0, 0.02)
			_lux.apply_preset(_preset, 0.0)
		KEY_COMMA, KEY_PERIOD:
			# `dither_luma_scale`: how many times finer than the palette the
			# luminance is quantized when chroma coherence is on.
			#
			# THIS IS NOT THE GRIT KNOB, and the comment here said it was.
			# Measured, film SHARED, dark region of a night frame: luma_scale
			# 3.0 -> 0.00018 high-frequency energy, 1.0 -> 0.00017. Inert.
			# The speckle belongs to the LEGACY additive grain, which the film
			# shader does not carry at all -- see the note on KEY_BRACKETLEFT.
			var d: float = -0.25 if code == KEY_COMMA else 0.25
			_preset.dither_luma_scale = clampf(
				_preset.dither_luma_scale + d, 1.0, 4.0)
			_lux.apply_preset(_preset, 0.0)
		KEY_BRACKETLEFT:
			# WHERE THE SPECKLE LIVES, measured, because an operator liked it
			# and it turned out not to be this feature at all.
			#
			# High-frequency energy in the dark, one night frame, by state:
			#   film OFF, legacy grain 0.05   0.00589   (62% of px pure black)
			#   film OFF, legacy grain 0.00   0.00018   (98% pure black)
			#   film OFF, legacy grain 0.08   0.00970   (59% pure black)
			#   film SHARED, film grain 0.025 0.00018   (98% pure black)
			#   film SHARED, film grain 0.100 0.00019   (98% pure black)
			#
			# The speckle is the legacy ADDITIVE grain, entirely: remove it and
			# the baseline matches film exactly. And film cannot reproduce it,
			# not because the strength is low but because the density model is
			# MULTIPLICATIVE -- `col *= exp2(-density)` is zero wherever col is
			# zero, so 98% of a night frame stays perfectly flat no matter how
			# far this key is pushed. Additive grain LIFTS pixels off black,
			# which is why only it puts texture in the void.
			#
			# This key is not useless: in the 0.05-0.15 band, where there is
			# light to modulate, 0.025 -> 0.100 moves grit 0.00579 -> 0.00678.
			# It works exactly where the model says it can and nowhere else.
			_preset.film_grain_strength = maxf(
				0.0, _preset.film_grain_strength - 0.01)
			_lux.apply_preset(_preset, 0.0)
		KEY_BRACKETRIGHT:
			_preset.film_grain_strength = minf(
				0.30, _preset.film_grain_strength + 0.01)
			_lux.apply_preset(_preset, 0.0)
		KEY_P:
			await _shoot()
	_refresh()


## Keycode-only, source-built: no input map, so this runs in any project.
func _player_source() -> String:
	return """
extends CharacterBody3D

var yaw := 0.0
var pitch := 0.0

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= e.relative.x * 0.0022
		pitch = clampf(pitch - e.relative.y * 0.0022, -1.4, 1.4)
		rotation.y = yaw
		$Head.rotation.x = pitch
	if e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif e.keycode == KEY_F8:
			get_tree().quit()
		else:
			get_tree().on_key(e.keycode)

func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += transform.basis.x
	dir.y = 0.0
	var speed := 7.5 if Input.is_key_pressed(KEY_SHIFT) else 3.6
	var flat := dir.normalized() * speed
	velocity.x = flat.x
	velocity.z = flat.z
	if not is_on_floor():
		velocity.y -= 18.0 * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = 6.5
	move_and_slide()
"""
