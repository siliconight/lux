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

	print("case D -- a sign from the loader keeps its face quad (unchanged)")
	var sign: Node3D = Loader.rig_for_anchor({"type": "sign", "id": "s1",
		"size": [1.4, 1.4]})
	_check("sign show_emissive_quad", sign.get("show_emissive_quad"), true)
	root.add_child(sign)
	await process_frame
	_check("sign has AreaPanel_Surface",
		sign.get_node_or_null(NodePath("AreaPanel_Surface")) != null, true)
	sign.queue_free()
	await process_frame

	print("")
	if _fails == 0:
		print("  window glass selftest ok: no pane in front of the glass, the")
		print("  light stays, the choice is saved, signs are untouched.")
	else:
		print("  window glass selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
