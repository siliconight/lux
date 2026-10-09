extends SceneTree
## Street lamps are dark by day (0.71.0).
##
##     godot --headless --path lux -s res://tools/street_lamps_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## What this holds -- the walker, 2026-10-09: "street lamps aren't usually on
## during the day":
## - the day presets say so (`street_lamps_lit` false), and the dusk and night
##   ones do not;
## - the loader marks a street pole and a wall pack `dusk_to_dawn`, and not a
##   canopy wash or a payphone;
## - applying a day preset hides the pole and the wall pack and darkens the
##   lens nearest the pole's lamp with a copy of its material, leaving the
##   material itself alone, and leaves the canopy wash and the payphone lit;
## - a power cut and its restore do not relight a dark pole;
## - applying a night preset relights both and puts the lens's material back;
## - a blend between the two snaps the switch at its middle.
## On 0.70.0 the first case fails: no preset has the field.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const PRESETS := "res://addons/lux/presets/%s.tres"
const DAY_PRESETS := ["delco_summer_afternoon", "delco_arcade", "sof_pc2000", "heavy_rain"]
const LIT_PRESETS := ["delco_night", "blue_hour", "gas_station_fluorescent", "gothic_street_night",
	"mission_goes_hot", "ps1_storm_night"]
const LENS_ENERGY := 2.0

var _fails: int = 0


func _initialize() -> void:
	_main()


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


func _settle() -> void:
	for _i in range(3):
		await process_frame


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[street_lamps_selftest] could not load the loader")
		quit(2)
		return
	print("street lamps selftest")
	var day: Resource = load(PRESETS % "delco_summer_afternoon")
	var night: Resource = load(PRESETS % "delco_night")
	var has_field: bool = day != null and "street_lamps_lit" in day
	_check("a preset carries street_lamps_lit", has_field, true)
	if not has_field:
		print("street lamps selftest: 1 FAIL (no field, so nothing else can be asked)")
		quit(1)
		return
	for p in DAY_PRESETS:
		var r: Resource = load(PRESETS % p)
		_check("%s is a day: its street lamps are dark" % p, r.get("street_lamps_lit"), false)
	for p in LIT_PRESETS:
		var r: Resource = load(PRESETS % p)
		_check("%s keeps its street lamps lit" % p, r.get("street_lamps_lit"), true)

	var pole: Node3D = loader.rig_for_anchor({"id": "pole", "type": "streetlight",
		"pos": [0.0, 0.0, 6.0], "row": {"count": 1, "spacing": 0.0}})
	var pack: Node3D = loader.rig_for_anchor({"id": "pack", "type": "wall_pack"})
	var canopy: Node3D = loader.rig_for_anchor({"id": "canopy", "type": "canopy_wash", "drop": 4.5,
		"size": [6.0, 6.0]})
	var phone: Node3D = loader.rig_for_anchor({"id": "phone", "type": "payphone_hood", "drop": 2.211})
	_check("a street pole is dusk to dawn", (pole.get("rig") as LuxLightRig).dusk_to_dawn, true)
	_check("a wall pack is dusk to dawn", (pack.get("rig") as LuxLightRig).dusk_to_dawn, true)
	_check("a canopy wash is not", (canopy.get("rig") as LuxLightRig).dusk_to_dawn, false)
	_check("a payphone is not", (phone.get("rig") as LuxLightRig).dusk_to_dawn, false)

	# a LuxRoot FIRST, so the rigs register their lamps with it at ready
	var root := LuxRoot.new()
	get_root().add_child(root)
	await process_frame
	var scene := Node3D.new()
	scene.name = "Level"
	get_root().add_child(scene)
	# the pole's lens: a lit face beside its lamp, named as Zoo names one
	var lens := MeshInstance3D.new()
	lens.mesh = BoxMesh.new()
	var lit_mat := StandardMaterial3D.new()
	lit_mat.resource_name = "M_TestPole_Lens"
	lit_mat.emission_enabled = true
	lit_mat.emission_energy_multiplier = LENS_ENERGY
	lens.material_override = null
	lens.set_surface_override_material(0, null)
	(lens.mesh as BoxMesh).material = lit_mat
	scene.add_child(lens)
	for r in [pole, pack, canopy, phone]:
		scene.add_child(r)
	pack.position = Vector3(10.0, 3.0, 0.0)
	canopy.position = Vector3(-10.0, 4.5, 0.0)
	phone.position = Vector3(0.0, 2.2, 10.0)
	await _settle()
	var pole_lamp: Light3D = _lamp(pole)
	lens.global_position = pole_lamp.global_position + Vector3(0.0, 0.06, 0.0)
	await _settle()

	root.apply_preset(day)
	await _settle()
	_check("by day the pole is dark", pole.is_visible_in_tree(), false)
	_check("by day the wall pack is dark", pack.is_visible_in_tree(), false)
	_check("the canopy wash keeps its light", canopy.is_visible_in_tree(), true)
	_check("the payphone keeps its light", phone.is_visible_in_tree(), true)
	var active: BaseMaterial3D = lens.get_active_material(0) as BaseMaterial3D
	_check("the pole's lens is dark", active != null and active.emission_energy_multiplier == 0.0, true)
	_check("by a copy: the lens's own material keeps its energy",
		lit_mat.emission_energy_multiplier == LENS_ENERGY and active != lit_mat, true)

	root.set_fixtures_powered(false)
	await _settle()
	root.set_fixtures_powered(true)
	await _settle()
	_check("a power cut and restore do not relight a dark pole", pole_lamp.is_visible_in_tree(), false)

	root.apply_preset(night)
	await _settle()
	_check("by night the pole is lit", pole.is_visible_in_tree(), true)
	_check("by night the wall pack is lit", pack.is_visible_in_tree(), true)
	_check("and the lens has its own material back", lens.get_active_material(0) == lit_mat, true)

	# a blend makes its scratch preset when it starts (`_start_blend`); this
	# asks `_lerp_preset` directly, so it hands over the scratch a blend would
	root.set(&"_blend_scratch", LuxPreset.new())
	var early: Resource = root.call("_lerp_preset", day, night, 0.4)
	_check("a blend from day to night holds dark before its middle", early.get("street_lamps_lit"), false)
	var late: Resource = root.call("_lerp_preset", day, night, 0.6)
	_check("and lights past it", late.get("street_lamps_lit"), true)
	print("street lamps selftest: %s" % ("PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)
