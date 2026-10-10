extends SceneTree
## Falsification test for the horizon glow (Lux 0.73.0, roadmap 228 step A).
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/horizon_glow_selftest.gd
##
## The import pass first: the runtime scripts refer to each other by
## `class_name`, which a never-imported project cannot resolve
## (`colocation_selftest.gd` says why at length).
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## WHAT IT HOLDS. A LuxRoot applying Delco Night builds exactly one
## LuxHorizonGlow, visible, with the ring the preset describes: six rows of
## 65 vertices, the top row at `EYE_M + radius * tan(top_deg)` and
## transparent, the land rows opaque, the horizon row's alpha the glow alpha
## times the energy; unshaded, alpha-blended, fog ignored, no GI, no shadow.
## A preset at energy 0 hides it. A preset with another radius and top
## rebuilds it, and a re-apply or a rebuild of the modules leaves one ring.
## The blend carries the four fields, so a mid-blend preset does not fall
## back to the script defaults.

const PRESET := "res://addons/lux/presets/delco_night.tres"

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
	var ok: bool = absf(got - want) <= tol
	if not ok:
		_fails += 1
	print("  %s %s: %.4f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.4f within %.4f)" % [want, tol]])


func _glow_of(lux: Node) -> LuxHorizonGlow:
	var found: LuxHorizonGlow = null
	var n: int = 0
	for c in lux.get_children():
		if c is LuxHorizonGlow:
			n += 1
			found = c as LuxHorizonGlow
	_check("one glow under the LuxRoot", n, 1)
	return found


func _main() -> void:
	var preset: LuxPreset = load(PRESET) as LuxPreset
	if preset == null:
		print("FAIL: could not load " + PRESET)
		quit(2)
		return
	print("horizon glow selftest")
	# case 0: the preset asks for one, or every case below passes vacuously
	_check("delco_night asks for a glow", preset.horizon_glow_energy > 0.0, true)

	var lux := LuxRoot.new()
	lux.apply_on_ready = true
	lux.active_preset = preset
	root.add_child(lux)
	# `_ready` runs on the next frame here, as every selftest that adds a
	# LuxRoot under `_initialize` has found
	await process_frame
	var glow: LuxHorizonGlow = _glow_of(lux)
	if glow == null:
		print("FAIL: no LuxHorizonGlow was built")
		quit(1)
		return
	_check("visible at energy > 0", glow.visible, true)
	var mesh: ArrayMesh = glow.mesh as ArrayMesh
	_check("one surface", mesh.get_surface_count(), 1)
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_check("rows x segments vertices", verts.size(),
		LuxHorizonGlow.ROWS * (LuxHorizonGlow.SEGMENTS + 1))
	var top_y: float = LuxHorizonGlow.EYE_M \
		+ preset.horizon_glow_radius_m * tan(deg_to_rad(preset.horizon_glow_top_deg))
	_near("top row at the preset's angle", verts[LuxHorizonGlow.ROWS - 1].y, top_y, 0.01)
	_near("ring at the preset's radius", Vector2(verts[0].x, verts[0].z).length(),
		preset.horizon_glow_radius_m, 0.01)
	_near("horizon row at eye height", verts[2].y, LuxHorizonGlow.EYE_M, 0.001)
	_near("top row transparent", cols[LuxHorizonGlow.ROWS - 1].a, 0.0, 0.0001)
	_near("land opaque", cols[0].a, 1.0, 0.0001)
	# a mesh stores its vertex colours as 8-bit channels, so a read-back is
	# within 1/255 of what was written (0.3373 for 0.34 the first time this ran)
	_near("horizon alpha is the glow alpha times the energy", cols[2].a,
		clampf(LuxHorizonGlow.GLOW_ALPHAS[0] * preset.horizon_glow_energy, 0.0, 1.0), 0.005)
	_near("horizon colour is the preset's", cols[2].r, preset.horizon_glow_color.r, 0.005)
	var mat: StandardMaterial3D = glow.material_override as StandardMaterial3D
	_check("unshaded", mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	_check("alpha blended", mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	_check("fog ignored", mat.disable_fog, true)
	_check("read from both sides", mat.cull_mode, BaseMaterial3D.CULL_DISABLED)
	_check("no GI", glow.gi_mode, GeometryInstance3D.GI_MODE_DISABLED)
	_check("no shadow", glow.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

	# a preset that says nothing draws nothing
	var quiet: LuxPreset = preset.duplicate() as LuxPreset
	quiet.horizon_glow_energy = 0.0
	lux.apply_preset(quiet)
	_check("hidden at energy 0", glow.visible, false)

	# another radius and top rebuild the ring; a re-apply leaves one
	var wide: LuxPreset = preset.duplicate() as LuxPreset
	wide.horizon_glow_radius_m = 500.0
	wide.horizon_glow_top_deg = 10.0
	lux.apply_preset(wide)
	_check("visible again", glow.visible, true)
	var v2: PackedVector3Array = (glow.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_near("rebuilt at 500 m", Vector2(v2[0].x, v2[0].z).length(), 500.0, 0.01)
	_near("rebuilt to a 10 degree top", v2[LuxHorizonGlow.ROWS - 1].y,
		LuxHorizonGlow.EYE_M + 500.0 * tan(deg_to_rad(10.0)), 0.01)
	var mesh_before: ArrayMesh = glow.mesh as ArrayMesh
	lux.apply_preset(wide)
	_check("a re-apply keeps the mesh", glow.mesh == mesh_before, true)
	_glow_of(lux)

	# the blend carries the fields. `_lerp_preset` writes into the scratch
	# preset `_start_blend` makes, so a blend is stood up here the same way
	lux._blend_scratch = LuxPreset.new()
	var mid: LuxPreset = lux._lerp_preset(quiet, wide, 0.5)
	_near("blend: energy halfway", mid.horizon_glow_energy, wide.horizon_glow_energy * 0.5, 0.001)
	_near("blend: top halfway", mid.horizon_glow_top_deg,
		(quiet.horizon_glow_top_deg + wide.horizon_glow_top_deg) * 0.5, 0.001)
	_near("blend: radius halfway", mid.horizon_glow_radius_m,
		(quiet.horizon_glow_radius_m + wide.horizon_glow_radius_m) * 0.5, 0.001)
	_near("blend: colour carried", mid.horizon_glow_color.r, preset.horizon_glow_color.r, 0.002)

	# rebuilding the modules leaves one ring
	lux._build_modules()
	_glow_of(lux)

	print("horizon glow selftest: %s" % ["PASS" if _fails == 0 else "%d FAIL" % _fails])
	quit(1 if _fails > 0 else 0)
