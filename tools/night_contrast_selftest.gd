extends SceneTree
## Delco Night's contrast leaves the dark half of a night frame alone (0.58.0).
##
##     godot --headless --path lux -s res://tools/night_contrast_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed. Exit 2 = could not run.
##
## The post stack's contrast pivots on mid-grey: a display value v becomes
## (v - 0.5) * c + 0.5, so everything below the pivot moves DOWN by
## (c - 1) * (0.5 - v). A night frame sits almost entirely near zero, where
## that is a flat (c - 1) * 0.5 off the whole image: at Delco Night's old 1.08,
## 0.04 -- ten codes of 255 -- so every pixel under about ten codes went to
## black. MEASURED on cold run 9108's walk copy: the street seen from 30 m
## 50.6% crushed to black at 1.08, 35.8% at 1.0; the store from 8 m 20.9 ->
## 25.3; the level's darkest derived shot 1.6 -> 2.1 (still night).
##
## What this holds: Delco Night carries a contrast that subtracts nothing
## below the pivot (<= 1.0), the shader's own rule reproduces the ten-code
## crush at 1.08 (the control that proves the check can see it), and the
## other night presets are REPORTED, not changed -- they are other looks.

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


## The shader's contrast about its mid-grey pivot, clamped as the frame is.
func _contrast(v: float, c: float) -> float:
	return clampf((v - 0.5) * c + 0.5, 0.0, 1.0)


## The largest display value (in codes of 255) the contrast sends to black.
func _crushed_below(c: float) -> int:
	var n := 0
	for code in 256:
		if _contrast(code / 255.0, c) <= 0.0:
			n = code
	return n


func _main() -> void:
	print("night contrast selftest")
	var night: LuxPreset = load(PRESETS + "delco_night.tres")
	if night == null:
		push_error("[night_contrast_selftest] no Delco Night")
		quit(2)
		return
	_check("the old 1.08 sent every code up to 9 to black (the control)", _crushed_below(1.08), 9)
	_check("Delco Night's contrast subtracts nothing below the pivot", night.contrast <= 1.0, true)
	_check("so it sends only zero to black", _crushed_below(night.contrast), 0)
	var dir := DirAccess.open(PRESETS)
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var p: LuxPreset = load(PRESETS + f)
		if p != null and p.sky_energy <= 0.5 and f != "delco_night.tres":
			print("  note %s: sky %.2f, contrast %.2f crushes codes up to %d (not changed here)" % [
				f, p.sky_energy, p.contrast, _crushed_below(p.contrast)])
	print("night contrast selftest: %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(0 if _fails == 0 else 1)
