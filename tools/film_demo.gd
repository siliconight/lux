extends SceneTree
## Film emulsion, running, in a real Lux scene, toggleable at runtime.
##
##     godot --path lux -s res://tools/film_demo.gd
##
## NOT --headless: there is nothing to look at without a display.
##
## WHY IT HOSTS THE SAMPLE SCENE RATHER THAN BUILDING ITS OWN. The point is to
## see film response on real Lux output -- a preset, real rigs, real stylized
## materials, the whole post stack -- and `lux_sample_scene.tscn` already is
## that, with no external assets. A hand-built demo would be a demo of itself.
##
## WHY IT DOES NOT EDIT THAT SCENE. It layers on top: its own overlay above the
## sample's UI, its own preset OVERRIDE rather than a write to the shipped
## `.tres`, and its own input handling on keys the sample does not use. Nothing
## it does survives the process, so a demo can never become the reason a
## shipped preset changed.
##
## KEYS (the sample scene keeps Space, 1-5, H, C, A, D)
##   F        film emulsion on / off          -- the before / after
##   G        grain mode: Off / Simple / Film
##   [ ]      grain strength down / up
##   ; '      chroma ratio down / up
##   N        chroma coherence: per-channel / shared -- THE RAINBOW SWITCH
##   M        dither+quantize on / off        -- section 17's Natural Mode
##   V        let Lux manage hdr_2d, or not   -- watch the target format change
##   P        screenshot to user:// (the path is printed)
##   Esc      quit
##
## WHAT TO LOOK AT, AND IN WHICH ORDER.
##
##   N is the one that removes the "harsh digital compression" look. The
##   rainbow speckle on coloured surfaces is the ORDERED DITHER quantizing R, G
##   and B independently -- not any grain. Watch a coloured wall, not a grey
##   one, because on a neutral surface the three channels quantize identically
##   and there is nothing to see.
##
##   F is the grain model, and it is deliberately not a filter you notice. It
##   is strongest in the SHADOWS, where the baseline's additive grain swings
##   saturation by ~50% and the density model moves value alone.
##
##   M turns quantization off altogether -- section 17's Natural Mode, the most
##   photographic thing Lux can do.

const SAMPLE := "res://addons/lux/samples/lux_sample_scene.tscn"
const FILM_PRESET := &"Film Demo"

var _lux: LuxRoot
var _preset: LuxPreset
var _source_name: StringName = &"?"
var _label: Label
var _driver: Node
var _shots: int = 0


func _initialize() -> void:
	_build()


func _fail(why: String) -> void:
	push_error("[film_demo] " + why)
	print("[film_demo] " + why)
	quit(1)


func _build() -> void:
	var packed: PackedScene = load(SAMPLE)
	if packed == null:
		_fail("could not load " + SAMPLE + " -- run the import pass first:\n"
			+ "  godot --headless --path lux --import")
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	# WAIT FOR THE SAMPLE SCENE'S OWN _ready BEFORE TOUCHING ANYTHING.
	# `lux_sample_scene.gd` calls `blend_to_preset(DELCO, 0.0)` from its _ready,
	# and a node added during SceneTree._initialize does not get _ready until
	# the first frame -- so a preset applied here would be silently replaced a
	# frame later by the scene's own. Cost of learning this the hard way: the
	# first version of this file captured "baseline" twice and reported it as
	# the before/after.
	await process_frame
	await process_frame

	_lux = _find_lux(scene)
	if _lux == null:
		_fail("no LuxRoot in the sample scene")
		return

	if not _lux.preset_applied.is_connected(_on_preset_applied):
		_lux.preset_applied.connect(_on_preset_applied)
	if not _filmify():
		return

	_build_overlay()

	_driver = Node.new()
	_driver.set_process(true)
	_driver.set_script(_driver_script())
	_driver.set("demo", self)
	root.add_child(_driver)

	# Environment rather than a project setting: a capture run must not have to
	# write into the project it is measuring, and a crashed run must not leave
	# a setting behind that changes what the next one does.
	var auto: String = OS.get_environment("LUX_FILM_CAPTURE")
	if auto != "":
		await _auto_capture(auto)
		return

	print("[film_demo] running. F = film on/off, G = grain mode, "
		+ "[ ] = strength, ; ' = chroma, V = hdr_2d, P = shot, Esc = quit")
	print("[film_demo] the sample scene's own keys still work: 1-5 change "
		+ "preset, and each one gets film re-applied automatically.")


## Take whatever look is current and make a film-enabled copy of it.
##
## ALWAYS AN OVERRIDE, NEVER THE LIBRARY RESOURCE. `make_override` deep-copies,
## so nothing this demo does can be written back into `presets/*.tres`.
##
## Carrying the current strength/chroma across means the sample scene's preset
## keys change the LOOK without resetting the film parameters the operator has
## been tuning -- which is the whole point of being able to see film response
## on five different looks rather than one.
func _filmify() -> bool:
	var base: LuxPreset = _lux.get_current_preset()
	if base == null:
		base = _lux.active_preset
	if base == null:
		_fail("the sample scene's LuxRoot has no preset to build on")
		return false
	var strength := _preset.film_grain_strength if _preset != null else 0.025
	var chroma := _preset.film_chroma_ratio if _preset != null else 0.10
	var mode := _preset.grain_mode if _preset != null else 2
	var coherence := _preset.dither_chroma_coherence if _preset != null else 1.0
	_source_name = base.preset_name
	_preset = base.make_override(FILM_PRESET)
	_preset.film_emulsion_enabled = true
	_preset.grain_mode = mode
	_preset.film_grain_strength = strength
	_preset.film_chroma_ratio = chroma
	_preset.dither_chroma_coherence = coherence
	_lux.local_override = _preset
	_lux.apply_preset(_preset)
	return true


## The sample scene binds 1-5, H and C to preset changes, and every one of them
## replaces the film override with a library preset that has film off. Rather
## than fight that, follow it: re-apply film on top of whatever was just
## applied. The name guard is what stops this recursing on its own work.
func _on_preset_applied(preset_name: StringName) -> void:
	if preset_name == FILM_PRESET or _lux == null:
		return
	_filmify()


## Baseline and film, from the same camera on the same frame budget, written
## side by side. Both states are captured in ONE run so nothing between them
## can drift -- a comparison assembled from two launches compares two scenes.
func _auto_capture(out_dir: String) -> void:
	var report: Dictionary = {}

	# A capture with the readout in it is a capture of the readout. Both HUDs
	# say what state they are in, so their TEXT differs between the two frames
	# -- and text pixels flip by up to 0.84, two orders of magnitude more than
	# the grain being compared. The first version of this measured its own
	# overlay and reported it as film response.
	for n in _canvas_layers(root):
		if n.layer >= 0:
			n.visible = false

	# A look with no shadows cannot show what the density model is for. The
	# capture preset is settable and defaults to a dark one for that reason;
	# "Delco Summer Afternoon" has no pixel below 0.15 luminance anywhere.
	var env_preset: String = OS.get_environment("LUX_FILM_CAPTURE_PRESET")
	var want := StringName(env_preset if env_preset != "" else "Blue Hour")
	if want != &"" and _lux != null:
		_lux.blend_to_preset(want, 0.0)
		for i in range(4):
			await RenderingServer.frame_post_draw

	# THREE states, not two, because the shipped before/after bundles two
	# changes: the grain model AND the render target, since Lux raises the
	# target whenever film runs. "baseline_hdr" is film OFF at the SAME
	# precision film gets, so:
	#     baseline     -> baseline_hdr   is the precision change alone
	#     baseline_hdr -> film           is the grain model alone
	#     baseline     -> film           is what a player actually toggles
	# Without the middle one, every difference gets attributed to the grain.
	for state: String in ["baseline", "baseline_hdr", "film_perchannel", "film"]:
		_lux.set_film_emulsion_enabled(state != "baseline" and state != "baseline_hdr")
		if state == "baseline_hdr":
			root.use_hdr_2d = true
		if state.begins_with("film"):
			# "film_perchannel" is film WITH the classic per-channel
			# quantization, so the rainbow can be seen coming from the dither
			# rather than from anything the grain does.
			_preset.dither_chroma_coherence = 0.0 if state == "film_perchannel" else 1.0
			_lux.apply_preset(_preset)
		# Several frames: the film shader compiles on its first draw and the
		# hdr_2d flip rebuilds the render target. Capturing either on the frame
		# it happens photographs the transition rather than the result.
		for i in range(8):
			await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		var key: String = state
		var path: String = out_dir.rstrip("/") + "/film_demo_" + key + ".png"
		img.save_png(path)
		report[key] = {
			"path": path,
			"preset": String(_source_name),
			"film_active": _lux.is_film_emulsion_active(),
			"format": _format_name(img.get_format()),
			"size": [img.get_width(), img.get_height()],
		}
		print("[film_demo] %-8s active=%s target=%s -> %s"
			% [key, _lux.is_film_emulsion_active(),
			   _format_name(img.get_format()), path])
	print("<<<FILM_DEMO_JSON")
	print(JSON.stringify(report, "  "))
	print("FILM_DEMO_JSON>>>")
	quit(0)


func _canvas_layers(n: Node) -> Array[CanvasLayer]:
	var out: Array[CanvasLayer] = []
	if n is CanvasLayer:
		out.append(n)
	for c in n.get_children():
		out.append_array(_canvas_layers(c))
	return out


func _find_lux(n: Node) -> LuxRoot:
	if n is LuxRoot:
		return n
	for c in n.get_children():
		var r := _find_lux(c)
		if r != null:
			return r
	return null


func _build_overlay() -> void:
	# Layer 3: above the sample scene's own UI on layer 2, and far above Lux's
	# post pass on -1 so the readout is never itself graded, dithered or
	# grained. A HUD that the effect under test also processes is a HUD that
	# lies about the effect under test.
	var layer := CanvasLayer.new()
	layer.layer = 3
	root.add_child(layer)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.position = Vector2(16, -190)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 15)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_label)


func _format_name(f: int) -> String:
	match f:
		Image.FORMAT_RGB8:
			return "RGB8 (8-bit)"
		Image.FORMAT_RGBA8:
			return "RGBA8 (8-bit)"
		Image.FORMAT_RGBF:
			return "RGBF (32-bit float)"
		Image.FORMAT_RGBAF:
			return "RGBAF (32-bit float)"
		Image.FORMAT_RGBH:
			return "RGBH (16-bit float)"
		Image.FORMAT_RGBAH:
			return "RGBAH (16-bit float)"
		_:
			return "format id %d" % f


const MODES := ["Off", "Simple (legacy, additive)", "Film Emulsion (density)"]


func refresh() -> void:
	if _label == null or _lux == null:
		return
	var active: bool = _lux.is_film_emulsion_active()
	var fmt := "?"
	var vp := root
	if vp.get_texture() != null:
		var img: Image = vp.get_texture().get_image()
		if img != null:
			fmt = _format_name(img.get_format())
	_label.text = "\n".join([
		"LUX FILM EMULSION DEMO",
		"  look: %s   (sample scene keys 1-5 change it)" % _source_name,
		"",
		"  [F] film master     %s" % ("ON" if _lux.film_emulsion_enabled else "off"),
		"  [G] grain mode      %s" % MODES[clampi(_preset.grain_mode, 0, 2)],
		"      RUNNING NOW     %s" % ("FILM" if active
			else ("SIMPLE" if _preset.grain_mode == 1 else "no grain")),
		"",
		"  [ ] strength        %.3f   (density, stops)" % _preset.film_grain_strength,
		"  ; ' chroma ratio    %.3f" % _preset.film_chroma_ratio,
		"",
		"  [N] chroma coherence %s   <- the rainbow lives HERE, in the dither"
			% ("SHARED (no rainbow)" if _preset.dither_chroma_coherence > 0.5
			   else "per-channel (classic)"),
		"  [M] dither/quantize %s%s" % [
			"on (%d levels)" % _preset.color_levels if _preset.dither_strength > 0.0
				else "OFF", "   <- Natural Mode" if _preset.dither_strength <= 0.0 else ""],
		"",
		"  [V] manage hdr_2d   %s" % ("yes" if _lux.film_manage_hdr_2d else "no"),
		"      render target   %s" % fmt,
		"",
		"  [P] screenshot   [Esc] quit",
		"  Look at the SHADOWS -- that is where the two models differ most.",
	])


func toggle_film() -> void:
	_lux.set_film_emulsion_enabled(not _lux.film_emulsion_enabled)


func cycle_mode() -> void:
	_preset.grain_mode = (_preset.grain_mode + 1) % 3
	_lux.apply_preset(_preset)


func nudge_strength(d: float) -> void:
	_preset.film_grain_strength = clampf(_preset.film_grain_strength + d, 0.0, 0.10)
	_lux.apply_preset(_preset)


func nudge_chroma(d: float) -> void:
	_preset.film_chroma_ratio = clampf(_preset.film_chroma_ratio + d, 0.0, 0.25)
	_lux.apply_preset(_preset)


## The one that actually answers "stop it looking like harsh digital
## compression". Off is the classic per-channel quantization; on shares the
## decision across channels so the colour stops breaking up.
func toggle_coherence() -> void:
	_preset.dither_chroma_coherence = 0.0 if _preset.dither_chroma_coherence > 0.5 else 1.0
	_lux.apply_preset(_preset)


## Section 17's Natural Mode: no quantization at all. The most photographic
## configuration Lux has, and it needed no new code -- quantization already sits
## inside the dither gate, so a strength of zero removes it entirely.
func toggle_dither() -> void:
	_preset.dither_strength = 0.0 if _preset.dither_strength > 0.0 else 0.3
	_lux.apply_preset(_preset)


func toggle_hdr() -> void:
	_lux.film_manage_hdr_2d = not _lux.film_manage_hdr_2d
	_lux.apply_preset(_preset)


func shoot() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("[film_demo] no image to save")
		return
	_shots += 1
	var path := "user://film_demo_%02d_%s.png" % [
		_shots, "film" if _lux.is_film_emulsion_active() else "baseline"]
	img.save_png(path)
	print("[film_demo] wrote %s  ->  %s"
		% [path, ProjectSettings.globalize_path(path)])


## Built as source rather than a separate file so the demo is one script to
## copy and cannot half-install.
func _driver_script() -> GDScript:
	var gd := GDScript.new()
	gd.source_code = """
extends Node
var demo
func _process(_d: float) -> void:
	if demo != null:
		demo.refresh()
func _input(e: InputEvent) -> void:
	if not (e is InputEventKey) or not e.pressed or e.echo:
		return
	match e.keycode:
		KEY_F: demo.toggle_film()
		KEY_G: demo.cycle_mode()
		KEY_BRACKETLEFT: demo.nudge_strength(-0.005)
		KEY_BRACKETRIGHT: demo.nudge_strength(0.005)
		KEY_SEMICOLON: demo.nudge_chroma(-0.01)
		KEY_APOSTROPHE: demo.nudge_chroma(0.01)
		KEY_V: demo.toggle_hdr()
		KEY_N: demo.toggle_coherence()
		KEY_M: demo.toggle_dither()
		KEY_P: demo.shoot()
		KEY_ESCAPE: get_tree().quit(0)
"""
	gd.reload()
	return gd
