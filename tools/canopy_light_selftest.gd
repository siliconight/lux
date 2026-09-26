extends SceneTree
## The forecourt pair (0.41.0): `canopy_wash` and `canopy_lights`.
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/canopy_light_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## Headless has no renderer, so nothing here says a forecourt READS lit -- that
## is a frame and a walk. What this holds is the contract between Deli Counter
## 0.145.0's light manifest v1.3 and this loader:
##
##   * `canopy_lights` builds NOTHING. It is Zoo's emissive lamp grid, and a
##     light per lamp would put 12-24 of them on the forecourt ground mesh
##     against a `max_lights_per_object` of 8. A future reader who "fixes" the
##     null by adding a rig breaks that budget, so the null is pinned here.
##   * `canopy_wash` builds one downward spot whose range is the GEOMETRY's:
##     the source hangs `drop` above the tarmac and owns a pool, so its reach
##     is the half-diagonal of that pool and the drop, not a chosen number.
##   * Two different decks give two different ranges, or the derivation is
##     decorative.

const LOADER := "res://addons/lux/runtime/lux_light_loader.gd"

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
	print("  %s %s: %.5f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.5f +/- %.5f)" % [want, tol]])


## The anchors Deli Counter derives from the authored gas station, verbatim
## from `_canopy_anchors` on `specs/gas_station.json`: a 24 x 10 deck at
## z 5.0 x 0.4 thick, six columns standing at grade.
func _wash(pool_w: float, pool_d: float, drop: float) -> Dictionary:
	return {"id": "canopy_roof_wash_0", "type": "canopy_wash",
		"source": "derived", "pos": [-8.0, -18.0, 4.78], "rot_y": 0.0,
		"size": [pool_w, pool_d], "drop": drop, "reacts_to_alarm": true}


func _main() -> void:
	var loader: Script = load(LOADER)
	if loader == null:
		push_error("[canopy_selftest] could not load %s" % LOADER)
		quit(2)
		return
	print("canopy light selftest")

	# ---------------------------------------------------- the grid is hardware
	var grid := {"id": "canopy_roof_lights", "type": "canopy_lights",
		"source": "derived", "pos": [0.0, -18.0, 4.78], "rot_y": 0.0,
		"size": [24.0, 10.0], "drop": 4.78, "reacts_to_alarm": true}
	var got_grid: Variant = loader.rig_for_anchor(grid)
	_check("canopy_lights builds no rig", got_grid == null, true)

	# ------------------------------------------------------- the wash is a rig
	var a := _wash(8.0, 10.0, 4.78)
	var node: Node3D = loader.rig_for_anchor(a)
	_check("canopy_wash builds a node", node != null, true)
	if node == null:
		_finish()
		return
	_check("named from the anchor", node.name, "canopy_roof_wash_0")
	var rig: Resource = node.get("rig")
	_check("carries a rig", rig != null, true)
	if rig == null:
		_finish()
		return
	_check("rig name", str(rig.get("rig_name")), "Canopy Wash (baked)")
	_check("one lamp, not a row", int(rig.get("count")), 1)

	# ----------------------------------------------- the range is the geometry
	# half-diagonal of an 8 x 10 pool, with the source 4.78 m above it
	var half_diag := Vector2(8.0, 10.0).length() * 0.5
	var want := sqrt(4.78 * 4.78 + half_diag * half_diag)
	_near("range is drop and half-diagonal", float(rig.get("light_range")),
		want, 0.01)

	# a smaller deck must give a smaller reach, or the derivation is decorative
	var small: Node3D = loader.rig_for_anchor(_wash(3.0, 4.0, 3.0))
	var small_rig: Resource = small.get("rig")
	var smaller := float(small_rig.get("light_range")) < float(rig.get("light_range"))
	_check("a smaller deck reaches less", smaller, true)

	# and it never overreaches, whatever the deck
	var huge: Node3D = loader.rig_for_anchor(_wash(60.0, 40.0, 9.0))
	var huge_rig: Resource = huge.get("rig")
	_check("range is capped", float(huge_rig.get("light_range")) <= 12.0001, true)

	# ------------------------------------------------------------ the colour
	# THE GREEN SPIKE, NOT THE KELVIN. The first version of this case asserted
	# b > r on `kelvin(MERCURY_VAPOR)` and FAILED, which was the test being
	# right and the rig being wrong: `kelvin()` is a blackbody fit, every
	# value below 6500K comes back redder than blue, and the "blue-green"
	# in the constant's comment is a spectral spike a blackbody cannot have.
	# `add_fluorescent_cast` is what puts it there -- its own docstring calls
	# the result the convenience-store tint -- so what this pins is the cast.
	var col: Color = rig.get("light_color")
	_check("carries the green spike (g > r and g > b)",
		col.g > col.r and col.g > col.b, true)
	var plain: Color = LuxColorTemp.kelvin(LuxColorTemp.MERCURY_VAPOR)
	_check("greener than the bare blackbody", col.g / col.r > plain.g / plain.r,
		true)

	# ------------------------------------------------- an anchor with no size
	# DC always sends one; a hand-authored anchor may not, and the fallback
	# must be a pool rather than a zero-range light that lights nothing.
	var bare := {"id": "hand", "type": "canopy_wash", "pos": [0, 0, 5.0],
		"drop": 5.0}
	var bare_node: Node3D = loader.rig_for_anchor(bare)
	_check("a sizeless anchor still builds", bare_node != null, true)
	if bare_node != null:
		var br: Resource = bare_node.get("rig")
		_check("and reaches the ground", float(br.get("light_range")) >= 5.0, true)

	_finish()


func _finish() -> void:
	if _fails == 0:
		print("canopy light selftest: OK")
		quit(0)
	else:
		print("canopy light selftest: %d FAILURE(S)" % _fails)
		quit(1)
