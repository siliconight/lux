@tool
class_name LuxStreetlightRig
extends Node3D
## Streetlight row rig (TDD §16 rig #3). Spawns a line of downward sodium-vapor
## spotlights along +X — parking lots, street blocks, the Wawa lot. Reads a
## LuxLightRig resource for count/spacing/height/color.

@export var rig: LuxLightRig:
	set(value):
		rig = value
		if is_inside_tree():
			_rebuild()

var _lights: Array[SpotLight3D] = []


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_rebuild()
	var root := _find_lux_root()
	if root != null:
		for l in _lights:
			root.register_lux_light(l)


func _rebuild() -> void:
	for l in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	var r := rig if rig != null else _default_rig()
	for i in r.count:
		var lamp := SpotLight3D.new()
		lamp.name = &"Street_%d" % i
		lamp.light_color = r.light_color
		lamp.light_energy = r.energy
		lamp.spot_range = r.light_range
		lamp.spot_angle = 55.0
		lamp.spot_angle_attenuation = 1.2
		lamp.shadow_enabled = r.shadows_enabled
		lamp.position = Vector3(i * r.spacing, r.mount_height, 0.0)
		lamp.rotation_degrees = Vector3(-90.0, 0.0, 0.0)  # point straight down
		add_child(lamp)
		if Engine.is_editor_hint() and get_tree() != null:
			lamp.owner = get_tree().edited_scene_root
		_lights.append(lamp)


func _default_rig() -> LuxLightRig:
	var r := LuxLightRig.new()
	r.rig_name = &"Streetlight Row"
	r.light_color = Color(1.0, 0.72, 0.42)  # sodium vapor
	r.energy = 6.0
	r.light_range = 14.0
	r.count = 5
	r.spacing = 8.0
	r.mount_height = 6.0
	return r


func _find_lux_root() -> LuxRoot:
	var n := get_parent()
	while n != null:
		if n is LuxRoot:
			return n
		n = n.get_parent()
	for root in get_tree().get_nodes_in_group(&"lux_root"):
		if root is LuxRoot:
			return root
	return null
