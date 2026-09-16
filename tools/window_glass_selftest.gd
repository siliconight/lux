extends SceneTree
## A window's light rig draws no pane of its own: the glass is the pane.
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/window_glass_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
##
## WHY THIS EXISTS. `LuxAreaLightRig` builds an unshaded, emissive,
## double-sided quad the size of its panel unless told not to. For a window
## that quad sits in the opening, so once the glazing blends (Pixelcoat 0.40.0)
## it is what a viewer sees through the glass from the street and from the
## room. The loader now turns it off for windows, and this holds that -- and
## holds the three things that must NOT move with it: the window still gets
## its light, a sign's loader rig still gets its face quad, and the property
## survives a PackedScene round trip, because an applied scene is saved and
## the rig rebuilds from the saved property in `_ready`.

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
	print("  %s %s: %.6f%s" % ["ok  " if ok else "FAIL", label, got,
		"" if ok else "   (wanted %.6f +/- %.6f)" % [want, tol]])


func _main() -> void:
	await process_frame
	var Loader: GDScript = load(LOADER) as GDScript
	if Loader == null:
		print("  window glass selftest could not load %s" % LOADER)
		quit(2)
		return

	print("case A -- a window rig asks for no preview quad")
	var win: Node3D = Loader.rig_for_anchor({"type": "window", "id": "w1",
		"size": [2.0, 1.4]})
	if win == null:
		print("  window glass selftest: rig_for_anchor returned null")
		quit(2)
		return
	_check("show_emissive_quad", win.get("show_emissive_quad"), false)

	print("case B -- in the tree it builds its light and no surface")
	root.add_child(win)
	await process_frame
	_check("no AreaPanel_Surface", win.get_node_or_null(NodePath("AreaPanel_Surface")) == null, true)
	var lights: int = 0
	for c in win.get_children():
		if c is Light3D:
			lights += 1
	_check("one light under the window rig", lights, 1)

	print("case C -- the choice survives being saved and loaded")
	for c in win.get_children():
		c.owner = win
	var packed := PackedScene.new()
	_check("pack ok", packed.pack(win), OK)
	win.queue_free()
	await process_frame
	var again: Node3D = packed.instantiate() as Node3D
	root.add_child(again)
	await process_frame
	_check("reloaded show_emissive_quad", again.get("show_emissive_quad"), false)
	_check("reloaded rig has no AreaPanel_Surface",
		again.get_node_or_null(NodePath("AreaPanel_Surface")) == null, true)
	again.queue_free()

	print("case C2 -- the light is an APERTURE, not a bulb in the wall (0.40.0)")
	# Walked 2026-09-16 on cold run 9060 as "is the light inside the wall
	# here?": an omni 0.35 m inboard of a 1.8 x 1.4 opening, range 3.6, in a
	# 3.7 m room put 1.55x as much on the ceiling as on the floor and 7x as
	# much on the reveal 0.35 m away. A cone whose upper rim is the opening's
	# head and whose lower rim is the wall under its sill is a quarter sphere:
	# half-angle 45, pitched 45 down, nothing left to choose.
	var half: float = Loader.get("WINDOW_CONE_HALF_ANGLE_DEG")
	var ap: Node3D = Loader.rig_for_anchor({"type": "window", "id": "w2",
		"size": [1.8, 1.4]})
	_check("half-angle", ap.get("cone_angle_deg"), half)
	_check("pitched down by the same, so the upper rim is horizontal",
		ap.get("cone_pitch_deg"), half)
	root.add_child(ap)
	await process_frame
	var lamp: Light3D = null
	for c in ap.get_children():
		if c is Light3D:
			lamp = c
	_check("the Compatibility fallback is a SpotLight3D", lamp is SpotLight3D, true)
	if lamp is SpotLight3D:
		var sp := lamp as SpotLight3D
		_check("cone half-angle reaches the engine", sp.spot_angle, half)
		# THE RANGE IS THE DERIVED ONE, not the engine's 5.0 default: a spot
		# has no `omni_range`, and setting one on it is a silent no-op.
		_near("the derived range reached spot_range, not omni_range",
			sp.spot_range, clampf(1.8 * 2.0, 3.0, 4.0), 1e-4)
		# WHICH WAY IT POINTS is the whole fix. A spot emits along local -Z;
		# the panel's forward is +Z. Forward and DOWN, and its topmost ray
		# (axis pitched up by the half-angle) no higher than horizontal.
		var dir := sp.transform.basis * Vector3(0.0, 0.0, -1.0)
		_near("aimed into the room: +Z is cos(45)", dir.z, cos(deg_to_rad(half)), 1e-5)
		_near("and downward: -Y is -sin(45)", dir.y, -sin(deg_to_rad(half)), 1e-5)
		_near("with no sideways lean", dir.x, 0.0, 1e-5)
		var top := rad_to_deg(asin(dir.y)) + half
		_near("nothing above the opening's own head: top ray at 0 deg", top, 0.0, 1e-3)
	ap.queue_free()
	await process_frame

	print("case D -- a sign from the loader keeps its face quad (unchanged)")
	var sign: Node3D = Loader.rig_for_anchor({"type": "sign", "id": "s1",
		"size": [1.4, 1.4]})
	_check("sign show_emissive_quad", sign.get("show_emissive_quad"), true)
	root.add_child(sign)
	await process_frame
	_check("sign has AreaPanel_Surface",
		sign.get_node_or_null(NodePath("AreaPanel_Surface")) != null, true)
	# ...and its source is still a sphere: a sign lights the facade around it
	# in every direction, and the aperture rule is the OPENING's, not every
	# area rig's. 0 half-angle is the untouched path.
	_check("sign cone_angle_deg is 0", sign.get("cone_angle_deg"), 0.0)
	var sign_lamp: Light3D = null
	for c in sign.get_children():
		if c is Light3D:
			sign_lamp = c
	_check("so a sign's fallback is still an OmniLight3D", sign_lamp is OmniLight3D, true)
	sign.queue_free()
	await process_frame

	print("")
	if _fails == 0:
		print("  window glass selftest ok: no pane in front of the glass, the")
		print("  light stays, the choice is saved, signs are untouched.")
	else:
		print("  window glass selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
