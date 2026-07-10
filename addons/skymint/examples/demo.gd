extends Node3D

## Self-contained SkyMint demo.
## Attach to a Node3D (the demo.tscn already does this) and press play.
## Builds a SkyMint, a sun light, a camera, a ground plane, and a small
## UI to scrub the time of day, change skyboxes, and pause the cycle.

var sky: SkyMint
var time_label: Label


func _ready() -> void:
	# --- the one node you actually need ---
	sky = SkyMint.new()
	sky.day_length_seconds = 60.0          # fast 1-minute day for the demo
	sky.time_of_day = 7.5
	add_child(sky)

	# --- a sun that follows the sky ---
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	add_child(sun)
	sky.sun_light = sun                     # let the sky steer + tint it

	# --- camera ---
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.7, 0)
	cam.rotation_degrees = Vector3(-5, 0, 0)
	add_child(cam)

	# --- a little ground so the lighting reads ---
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.4, 0.32)
	ground.material_override = mat
	ground.position.y = -1.5
	add_child(ground)

	for i in 12:
		var box := MeshInstance3D.new()
		box.mesh = BoxMesh.new()
		box.position = Vector3(randf_range(-20, 20), -1.0, randf_range(-25, -5))
		box.scale = Vector3.ONE * randf_range(0.6, 2.5)
		add_child(box)

	_build_ui()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	panel.add_child(box)

	time_label = Label.new()
	box.add_child(time_label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 24.0
	slider.step = 0.01
	slider.value = sky.time_of_day
	slider.value_changed.connect(func(v):
		sky.paused = true
		sky.time_of_day = v)
	box.add_child(slider)

	var pause := CheckButton.new()
	pause.text = "Pause cycle"
	pause.button_pressed = sky.paused
	pause.toggled.connect(func(on): sky.paused = on)
	box.add_child(pause)

	box.add_child(_sky_picker("Day skybox", sky.day_sky, func(idx):
		sky.day_sky = idx))
	box.add_child(_sky_picker("Night skybox", sky.night_sky, func(idx):
		sky.night_sky = idx))


func _sky_picker(label: String, current: int, on_pick: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new(); l.text = label; l.custom_minimum_size.x = 100
	row.add_child(l)
	var opt := OptionButton.new()
	for name in SkyMint.SkyBox.keys():
		opt.add_item(str(name).capitalize())
	opt.selected = current
	opt.item_selected.connect(on_pick)
	row.add_child(opt)
	return row


func _process(_dt: float) -> void:
	if time_label:
		var h := int(sky.time_of_day)
		var m := int((sky.time_of_day - h) * 60.0)
		time_label.text = "Time: %02d:%02d   (drag to scrub)" % [h, m]


# ---------------------------------------------------------------------
# MULTIPLAYER NOTE
# ---------------------------------------------------------------------
# This demo is single-player. In a real game you have two easy options:
#
# A) Automatic — set these on the SkyMint and you're done:
#       sky.sync_enabled = true
#       sky.sync_is_server_authority = true   # server drives the sky
#    The server broadcasts time/look to everyone every sync_interval.
#
# B) Manual — pipe it through your own netcode:
#       # on the host, periodically:
#       var state := sky.get_sync_state()       # small Dictionary
#       send_to_clients(state)
#       # on each client:
#       sky.apply_sync_state(received_state)     # eases in smoothly
#
# Clouds drift independently per client (that's fine and intended) —
# only the time of day and colors are kept in lockstep.
