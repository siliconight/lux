@tool
class_name LuxFluorescentRig
extends Node3D
## Fluorescent interior light rig (TDD §16 rig #2). Spawns a row of cool omni
## lights at ceiling height with optional flicker — gas-station backrooms, office
## drop-ceilings, deli counters. Reads a LuxLightRig resource for tuning.

@export var rig: LuxLightRig:
	set(value):
		rig = value
		if is_inside_tree():
			_rebuild()

var _lights: Array[OmniLight3D] = []
var _flicker_phase: float = 0.0


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_rebuild()
	var root := _find_lux_root()
	if root != null:
		for l in _lights:
			root.register_lux_light(l)
	set_process(rig != null and rig.flicker_amount > 0.0)


func _rebuild() -> void:
	for l in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	var r := rig if rig != null else _default_rig()
	var start := -(r.count - 1) * 0.5 * r.spacing
	for i in r.count:
		var lamp := OmniLight3D.new()
		lamp.name = &"Fluoro_%d" % i
		lamp.light_color = r.light_color
		lamp.light_energy = r.energy
		lamp.omni_range = r.light_range
		lamp.shadow_enabled = r.shadows_enabled
		lamp.position = Vector3(start + i * r.spacing, r.mount_height, 0.0)
		add_child(lamp)
		if Engine.is_editor_hint() and get_tree() != null:
			lamp.owner = get_tree().edited_scene_root
		_lights.append(lamp)


func _process(delta: float) -> void:
	var r := rig if rig != null else null
	if r == null or r.flicker_amount <= 0.0:
		return
	_flicker_phase += delta * r.flicker_speed
	# Two-tone noise for that ballast-buzz instability.
	var n := sin(_flicker_phase) * 0.5 + sin(_flicker_phase * 3.7) * 0.5
	var flick := 1.0 - maxf(0.0, n) * r.flicker_amount * 0.5
	for l in _lights:
		if is_instance_valid(l):
			l.light_energy = r.energy * flick


func _default_rig() -> LuxLightRig:
	var r := LuxLightRig.new()
	r.rig_name = &"Fluorescent Interior"
	# Cool-white tube ~4100K with the mercury-spike green cast.
	r.light_color = LuxColorTemp.cool_fluorescent()
	r.energy = 2.2
	r.light_range = 10.0
	r.count = 4
	r.spacing = 4.0
	r.mount_height = 3.2
	r.flicker_amount = 0.15
	r.flicker_speed = 9.0
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
