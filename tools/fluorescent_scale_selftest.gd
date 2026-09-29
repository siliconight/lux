extends SceneTree
## The fluorescent practicals, scaled by the preset (0.55.0).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/fluorescent_scale_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## Headless has no renderer, so nothing here says a store READS lit at night
## -- that was measured in frames on cold run 9102's walk copy (the sales
## floor 1.9 -> 14.5 -> 15.7 -> 17.9 at scale 1 / 4 / 6 / 10, hiding every
## other light moved it 0.9, so the fluorescents carry it). What this holds:
##
##   * every shipped preset carries `fluorescent_energy_scale` at the value
##     DERIVED from its sky (1.0 at the afternoon's 1.1, 6.0 at the night's
##     0.35, linear, clamped) -- a hand-edited preset that drifts fails here;
##   * a fluorescent rig takes the scale into every lamp; a BARE BULB, the
##     same class in an incandescent costume, refuses it (the walker: "keep
##     pendants moody");
##   * LuxLighting.apply hands a preset's scale to registered rigs, and a rig
##     registering AFTER the preset is scaled too (rigs register from their
##     own _ready, often after LuxRoot applied).

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"
const PRESETS := "res://addons/lux/presets/"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _near(label: String, got: float, want: float, tol: float) -> void:
	var ok := absf(got - want) <= tol
	if not ok:
		_fails += 1
	print("  %s %s: %.4f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.4f +/- %.4f)" % [want, tol]])


func _derived(sky: float) -> float:
	return snappedf(clampf(1.0 + 5.0 * (1.1 - sky) / 0.75, 1.0, 6.0), 0.1)


func _lamp_energy(rig: LuxFluorescentRig) -> float:
	for c in rig.get_children():
		if c is Light3D:
			return (c as Light3D).light_energy
	return -1.0


func _lamps(rig: LuxFluorescentRig) -> int:
	var n := 0
	for c in rig.get_children():
		if c is Light3D:
			n += 1
	return n


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[fluorescent_scale_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("fluorescent scale selftest")

	# ------------------------------------------------- every preset, derived
	var dir := DirAccess.open(PRESETS)
	if dir == null:
		push_error("[fluorescent_scale_selftest] no presets at %s" % PRESETS)
		quit(2)
		return
	var seen := 0
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var p: LuxPreset = load(PRESETS + f)
		if p == null:
			continue
		seen += 1
		_near("%s scale from sky %.2f" % [f, p.sky_energy], p.fluorescent_energy_scale,
			_derived(p.sky_energy), 0.051)
	_check("presets read", seen >= 10, true)
	var night: LuxPreset = load(PRESETS + "delco_night.tres")
	var noon: LuxPreset = load(PRESETS + "delco_summer_afternoon.tres")
	_near("Delco Night brightens its fluorescents", night.fluorescent_energy_scale, 6.0, 0.001)
	_near("the afternoon leaves them as shipped", noon.fluorescent_energy_scale, 1.0, 0.001)

	# ---------------------------------------- a fluorescent takes it, a bulb not
	var fl: LuxFluorescentRig = loader.rig_for_anchor({"id": "sales_floor_ceiling",
		"type": "fluorescent", "pos": [0.0, 0.0, 4.0], "rot_y": 0.0, "drop": 3.5,
		"row": {"count": 3, "spacing": 2.0}})
	var bulb: LuxFluorescentRig = loader.rig_for_anchor({"id": "vault_bulbs",
		"type": "pendant", "pos": [0.0, 0.0, 4.0], "rot_y": 0.0, "drop": 3.5,
		"row": {"count": 2, "spacing": 3.5}})
	get_root().add_child(fl)
	get_root().add_child(bulb)
	# a rig builds its lamps in _ready, which has not run at _initialize time:
	# without a frame every lamp read -1 (measured, the first run of this test)
	await process_frame
	_check("a fluorescent row scales with the preset", fl.scales_with_preset(), true)
	_check("a bare bulb does not", bulb.scales_with_preset(), false)
	_check("the rigs built their lamps", _lamps(fl) > 0 and _lamps(bulb) > 0, true)
	var fl_base := _lamp_energy(fl)
	var bulb_base := _lamp_energy(bulb)
	fl.set_energy_scale(6.0)
	bulb.set_energy_scale(6.0)
	_near("fluorescent lamp at scale 6", _lamp_energy(fl), fl_base * 6.0, 1e-4)
	_near("bare bulb lamp unmoved", _lamp_energy(bulb), bulb_base, 1e-4)

	# ------------------------------------------ the preset path, both orders
	var lighting := LuxLighting.new()
	get_root().add_child(lighting)
	await process_frame
	fl.set_energy_scale(1.0)
	var lamp: Light3D = null
	for c in fl.get_children():
		if c is Light3D:
			lamp = c
	lighting.register_light(lamp)
	lighting.apply(night, LuxQualityProfile.new())
	_near("apply(Delco Night) scales a registered fluorescent", _lamp_energy(fl), fl_base * 6.0, 1e-4)
	var late: LuxFluorescentRig = loader.rig_for_anchor({"id": "late_ceiling",
		"type": "fluorescent", "pos": [0.0, 0.0, 4.0], "rot_y": 0.0, "drop": 3.5,
		"row": {"count": 1, "spacing": 0.0}})
	get_root().add_child(late)
	await process_frame
	for c in late.get_children():
		if c is Light3D:
			lighting.register_light(c)
	_near("a rig registering after the preset is scaled too", _lamp_energy(late),
		fl_base * 6.0, 1e-4)
	lighting.apply(noon, LuxQualityProfile.new())
	_near("apply(afternoon) puts it back", _lamp_energy(fl), fl_base, 1e-4)

	print("fluorescent scale selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
