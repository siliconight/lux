@tool
class_name LuxSunMoonRig
extends Node3D
## Reusable sun/moon rig (TDD §16 rig #1). LuxRoot already drives a primary sun
## from the preset; this node is for authors who want an explicit, art-directable
## celestial light placed in the scene (e.g. a fixed moon for a night level) that
## also registers with Lux so it can react to mission state.

@export var rig: LuxLightRig
@export var is_moon: bool = false
@export_range(-10.0, 90.0) var elevation_deg: float = 40.0
@export_range(0.0, 360.0) var azimuth_deg: float = 210.0

var _light: DirectionalLight3D


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_build()
	var root := _find_lux_root()
	if root != null:
		root.register_lux_light(_light)


func _build() -> void:
	_light = DirectionalLight3D.new()
	_light.name = &"RigDirectional"
	add_child(_light)
	var col := Color(0.55, 0.62, 0.85) if is_moon else Color(1.0, 0.95, 0.85)
	var energy := 0.4 if is_moon else 1.2
	if rig != null:
		col = rig.light_color
		energy = rig.energy
		_light.shadow_enabled = rig.shadows_enabled
	_light.light_color = col
	_light.light_energy = energy
	if rig != null:
		rig.apply_bake_mode(_light)
	var basis := Basis.IDENTITY
	basis = basis.rotated(Vector3.UP, deg_to_rad(azimuth_deg))
	basis = basis.rotated(basis.x, -deg_to_rad(elevation_deg))
	_light.transform.basis = basis


func _find_lux_root() -> LuxRoot:
	var n := get_parent()
	while n != null:
		if n is LuxRoot:
			return n
		n = n.get_parent()
	for r in get_tree().get_nodes_in_group(&"lux_root"):
		if r is LuxRoot:
			return r
	return null
