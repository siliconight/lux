extends SceneTree
## The morning and the high noon (0.79.0, the factory's roadmap 217).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/day_presets_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## The walker, 2026-10-07: every level is set at one of five times -- morning,
## high noon, afternoon, evening, midnight. Three had a preset; a brief asking
## for morning or noon got Gas Station Fluorescent. The walker's look review,
## 2026-10-19: "Build both". Headless has no renderer, so nothing here says a
## morning READS as a morning -- that is the frames' and the walker's. What
## this holds is what a day preset must be to stand in the day:
##
##   * both load from the preset folder under their display names, which is
##     how LuxRoot registers them (`_preset_library`) and how Level Factory
##     asks for them;
##   * each is a day: the sun on and casting, the street lamps dark;
##   * the sun keeps the day's order -- morning low in the east-southeast,
##     the afternoon's 46 degrees in the south-southwest, noon high in the
##     south -- and the morning stays well above Blue Hour's 4 degrees, the
##     angle the walker called "very hard for lighting";
##   * the sky is a day's (energy at least the afternoon's), so the
##     fluorescents stay at their daylight scale, 1.0
##     (`fluorescent_scale_selftest.gd` derives it for every preset).
##
## FAILS ON 0.78.0: neither preset exists.

const PRESETS := "res://addons/lux/presets/"
const AFTERNOON := "delco_summer_afternoon.tres"
const MORNING := "delco_morning.tres"
const NOON := "delco_high_noon.tres"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, ok: bool, got: Variant) -> void:
	if not ok:
		_fails += 1
	print("  %s %s: %s" % ["ok  " if ok else "FAIL", label, str(got)])


func _load(file: String) -> LuxPreset:
	if not ResourceLoader.exists(PRESETS + file):
		return null
	return load(PRESETS + file) as LuxPreset


func _registered() -> Dictionary:
	# the names LuxRoot's library would register, read the way it reads them
	var out := {}
	var d := DirAccess.open(PRESETS)
	if d == null:
		return out
	for fn in d.get_files():
		if fn.ends_with(".tres"):
			var p := load(PRESETS + fn) as LuxPreset
			if p != null:
				out[String(p.preset_name)] = fn
	return out


func _main() -> void:
	var afternoon := _load(AFTERNOON)
	if afternoon == null:
		print("CANNOT RUN: %s does not load" % AFTERNOON)
		quit(2)
		return
	var morning := _load(MORNING)
	var noon := _load(NOON)
	_check("Delco Morning loads", morning != null, MORNING)
	_check("Delco High Noon loads", noon != null, NOON)
	if morning == null or noon == null:
		print("%d FAILED" % _fails)
		quit(1)
		return
	var names := _registered()
	_check("registered as Delco Morning", names.get("Delco Morning", "") == MORNING, names.get("Delco Morning", ""))
	_check("registered as Delco High Noon", names.get("Delco High Noon", "") == NOON, names.get("Delco High Noon", ""))
	for p in [morning, noon]:
		var n := String(p.preset_name)
		_check(n + ": the sun on", p.sun_enabled, p.sun_enabled)
		_check(n + ": the sun casts", p.sun_shadows, p.sun_shadows)
		_check(n + ": the street lamps dark", not p.street_lamps_lit, p.street_lamps_lit)
		_check("%s: a day's sky (>= the afternoon's %.2f)" % [n, afternoon.sky_energy],
			p.sky_energy >= afternoon.sky_energy - 1e-6, p.sky_energy)
		_check(n + ": fluorescents at the daylight scale", is_equal_approx(p.fluorescent_energy_scale, 1.0),
			p.fluorescent_energy_scale)
	_check("the sun climbs: morning < afternoon < noon",
		morning.sun_elevation_deg < afternoon.sun_elevation_deg and afternoon.sun_elevation_deg < noon.sun_elevation_deg,
		[morning.sun_elevation_deg, afternoon.sun_elevation_deg, noon.sun_elevation_deg])
	_check("the morning well above Blue Hour's 4 degrees (>= 20)", morning.sun_elevation_deg >= 20.0,
		morning.sun_elevation_deg)
	_check("noon high (>= 60)", noon.sun_elevation_deg >= 60.0, noon.sun_elevation_deg)
	_check("the morning sun in the east-southeast (80-140)",
		morning.sun_azimuth_deg >= 80.0 and morning.sun_azimuth_deg <= 140.0, morning.sun_azimuth_deg)
	_check("the noon sun in the south (170-190)",
		noon.sun_azimuth_deg >= 170.0 and noon.sun_azimuth_deg <= 190.0, noon.sun_azimuth_deg)
	_check("the afternoon sun west of south (> 190)", afternoon.sun_azimuth_deg > 190.0, afternoon.sun_azimuth_deg)
	_check("noon brighter than morning", noon.sun_energy > morning.sun_energy, [morning.sun_energy, noon.sun_energy])
	if _fails:
		print("%d FAILED" % _fails)
		quit(1)
		return
	print("all day presets behaved")
	quit(0)
