extends SceneTree
## A baked level's lightmap follows the level's state (0.66.0).
##
##     godot --headless --path lux -s res://tools/lightmap_switch_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds, as state (headless draws nothing; what the states LOOK
## like was measured on the baked gas station lot and is on
## `LuxLighting.set_baked_lighting`): a LightmapGI with data beside the site
## is bound after ready and baked lighting is on; the power cut takes the
## lightmap off with the lamps and restoring power brings it back; switching
## to real time clears the lightmap and turns every static rig light dynamic,
## and switching back restores both; a preset other than the baked one falls
## back to real time and baked lighting cannot be turned on under it; a
## level with no lightmap is untouched by all of it.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"

var _fails: int = 0


func _initialize() -> void:
	_main.call_deferred()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _lamp(rig: Node) -> Light3D:
	for c in rig.get_children():
		if c is Light3D:
			return c
	return null


func _frames(n: int) -> void:
	for _i in range(n):
		await process_frame


func _main() -> void:
	print("lightmap switch selftest")
	var loader: Script = load(LOADER)
	if loader == null:
		print("  FAIL could not load the loader")
		quit(2)
		return
	# a level: a site holding the LuxRoot and a steady fluorescent rig baked
	# static, and a LightmapGI beside the site, as the bake step writes it
	var level := Node3D.new()
	level.name = "Level"
	get_root().add_child(level)
	var site := Node3D.new()
	site.name = "Site"
	level.add_child(site)
	var lux := LuxRoot.new()
	site.add_child(lux)
	var rig: Node3D = loader.rig_for_anchor({"id": "sales_floor_ceiling", "type": "fluorescent",
		"pos": [0.0, 0.0, 3.8], "rot_y": 0.0, "drop": 3.8, "row": {"count": 1, "spacing": 0.0}})
	(rig.get("rig") as LuxLightRig).bake_mode = 1
	site.add_child(rig)
	var lm := LightmapGI.new()
	lm.name = "Lightmap"
	var data := LightmapGIData.new()
	lm.light_data = data
	level.add_child(lm)
	await _frames(4)
	var lamp: Light3D = _lamp(rig)
	_check("the rig's lamp is static", lamp.light_bake_mode, Light3D.BAKE_STATIC)
	_check("the lightmap beside the site is bound: baked lighting on", lux.baked_lighting(), true)
	_check("and drawn", lm.light_data == data, true)
	# the power cut
	lux.set_fixtures_powered(false)
	_check("a power cut hides the lamp", lamp.visible, false)
	_check("...and takes the lightmap off", lm.light_data == null, true)
	lux.set_fixtures_powered(true)
	_check("power back: the lamp", lamp.visible, true)
	_check("...and the lightmap", lm.light_data == data, true)
	# real time and back
	lux.set_baked_lighting(false)
	_check("real time: the lightmap off", lm.light_data == null, true)
	_check("...the static lamp dynamic", lamp.light_bake_mode, Light3D.BAKE_DYNAMIC)
	_check("...and still lit", lamp.visible, true)
	_check("...and the level says so", lux.baked_lighting(), false)
	lux.set_baked_lighting(true)
	_check("baked again: the lightmap", lm.light_data == data, true)
	_check("...the lamp static again", lamp.light_bake_mode, Light3D.BAKE_STATIC)
	# a cut while in real time, and power back, stays in real time
	lux.set_baked_lighting(false)
	lux.set_fixtures_powered(false)
	lux.set_fixtures_powered(true)
	_check("a cut in real time leaves the lightmap off", lm.light_data == null, true)
	_check("...and the lamp lit and dynamic", [lamp.visible, lamp.light_bake_mode], [true, Light3D.BAKE_DYNAMIC])
	lux.set_baked_lighting(true)
	# a preset other than the baked one
	var other := LuxPreset.new()
	other.preset_name = &"selftest_other"
	lux.apply_preset(other)
	_check("another preset falls back to real time", lux.baked_lighting(), false)
	_check("...lightmap off", lm.light_data == null, true)
	lux.set_baked_lighting(true)
	_check("baked lighting is refused under it", lux.baked_lighting(), false)
	# a level with no lightmap
	var bare := Node3D.new()
	get_root().add_child(bare)
	var lux2 := LuxRoot.new()
	bare.add_child(lux2)
	await _frames(3)
	_check("no lightmap: baked lighting off", lux2.baked_lighting(), false)
	lux2.set_baked_lighting(true)
	_check("...and switching does nothing", lux2.baked_lighting(), false)
	print("lightmap switch selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
