extends SceneTree
## The sun is baked while the lightmap shows (0.76.0, factory roadmap 243).
##
##     godot --headless --path lux -s res://tools/sun_bake_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds, as state (headless draws nothing; what the states LOOK
## like and cost was measured in the factory's `docs/findings/lux_tiers/`):
##
##   [1] no lightmap: the sun is a dynamic light with the preset's shadows --
##       a level exported without a bake keeps its sun shadows;
##   [2] a lightmap with data bound: the sun is static and unshadowed -- the
##       lightmap carries it and its shadows;
##   [3] the power cut hides the lightmap: the sun goes back to dynamic with
##       its shadows, so daylight does not go out with the lamps; power back,
##       static and unshadowed again;
##   [4] baked lighting switched off (a preset other than the baked one): the
##       sun dynamic and shadowed; switched back on, static and unshadowed;
##   [5] a tier that forbids sun shadows (Low) keeps them off whatever the
##       lightmap does, and the sun still follows the lightmap's mode;
##   [6] the CONTROL: a preset asking no sun shadows gets none in either mode.
##
## What it cannot hold: the editor, where the sun is static WITH its shadows
## so Level Factory's bake traces them (`Engine.is_editor_hint()` cannot be
## set from a script). A cold run's bake proves that case.

var _fails: int = 0


func _initialize() -> void:
	_main.call_deferred()


func _exit(code: int) -> void:
	quit(code)
	await process_frame
	await process_frame
	OS.kill(OS.get_process_id())


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _state(sun: DirectionalLight3D) -> String:
	var mode: String = "static" if sun.light_bake_mode == Light3D.BAKE_STATIC else "dynamic"
	return "%s, %s" % [mode, "shadowed" if sun.shadow_enabled else "unshadowed"]


func _main() -> void:
	print("sun bake selftest")
	var world := Node3D.new()
	root.add_child(world)
	var lighting := LuxLighting.new()
	world.add_child(lighting)
	lighting.ensure_sun(lighting)
	var sun: DirectionalLight3D = lighting.sun
	if sun == null:
		print("  FAIL ensure_sun built no sun")
		_exit(2)
		return
	var preset := LuxPreset.new()
	preset.sun_enabled = true
	preset.sun_shadows = true
	var high: LuxQualityProfile = LuxQualityProfile.make_tier(0)
	lighting.apply(preset, high)
	await process_frame

	print("[1] no lightmap")
	_check("the sun is dynamic with the preset's shadows", _state(sun), "dynamic, shadowed")

	print("[2] a lightmap with data")
	var lm := LightmapGI.new()
	lm.light_data = LightmapGIData.new()
	world.add_child(lm)
	_check("one lightmap bound", lighting.bind_lightmaps(world), 1)
	_check("the sun is static and unshadowed: the lightmap carries it", _state(sun), "static, unshadowed")

	print("[3] the power cut")
	lighting.set_fixtures_powered(false)
	_check("the lightmap is hidden with the lamps", lm.light_data == null, true)
	_check("the sun is live again with its shadows: daylight stays", _state(sun), "dynamic, shadowed")
	lighting.set_fixtures_powered(true)
	_check("power back: static and unshadowed", _state(sun), "static, unshadowed")

	print("[4] baked lighting switched off and on")
	lighting.set_baked_lighting(false)
	_check("off: the sun dynamic and shadowed", _state(sun), "dynamic, shadowed")
	lighting.set_baked_lighting(true)
	_check("on: static and unshadowed", _state(sun), "static, unshadowed")

	print("[5] a tier that forbids sun shadows")
	var low: LuxQualityProfile = LuxQualityProfile.make_tier(2)
	lighting.apply(preset, low)
	_check("with the lightmap: static, unshadowed", _state(sun), "static, unshadowed")
	lighting.set_fixtures_powered(false)
	_check("without it: dynamic, and still unshadowed -- the tier's word holds", _state(sun), "dynamic, unshadowed")
	lighting.set_fixtures_powered(true)

	print("[6] the control: a preset that asks no sun shadows")
	var calm := LuxPreset.new()
	calm.sun_enabled = true
	calm.sun_shadows = false
	lighting.apply(calm, high)
	_check("with the lightmap: static, unshadowed", _state(sun), "static, unshadowed")
	lighting.set_fixtures_powered(false)
	_check("without it: dynamic, unshadowed", _state(sun), "dynamic, unshadowed")

	print("%s (%d failed)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	_exit(0 if _fails == 0 else 1)
