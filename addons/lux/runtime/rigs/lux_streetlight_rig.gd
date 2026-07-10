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

@export_group("Light Cones")
## Fake-volumetric additive cone under each lamp (PS1-storm look). Off by
## default so existing scenes render byte-identical.
@export var cone_enabled: bool = false:
	set(value):
		cone_enabled = value
		if is_inside_tree():
			_rebuild()
## Cosmetic only — does not affect the SpotLight3D energy.
@export_range(0.0, 1.0) var cone_intensity: float = 0.4:
	set(value):
		cone_intensity = value
		_update_cone_params()
## Alpha 0 = inherit the rig's light colour.
@export var cone_color_override: Color = Color(0.0, 0.0, 0.0, 0.0):
	set(value):
		cone_color_override = value
		_update_cone_params()
## Visual half-angle of the cone. Intentionally tighter than spot_angle —
## a matching cone reads as a wall of light, not a beam.
@export_range(5.0, 45.0) var cone_angle_deg: float = 25.0:
	set(value):
		cone_angle_deg = value
		if is_inside_tree():
			_rebuild()

const _CONE_SHADER := preload("res://addons/lux/shaders/spatial/lux_light_cone.gdshader")

var _lights: Array[SpotLight3D] = []
var _cones: Array[MeshInstance3D] = []


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
	for c in _cones:
		if is_instance_valid(c):
			c.queue_free()
	_cones.clear()
	set_process(cone_enabled)
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
		r.apply_bake_mode(lamp)
		add_child(lamp)
		if Engine.is_editor_hint() and get_tree() != null:
			lamp.owner = get_tree().edited_scene_root
		_lights.append(lamp)
		if cone_enabled:
			_spawn_cone(i, r)
	_update_cone_params()


func _spawn_cone(index: int, r: LuxLightRig) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.12
	mesh.bottom_radius = r.mount_height * tan(deg_to_rad(cone_angle_deg))
	mesh.height = r.mount_height
	mesh.radial_segments = 12
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.name = &"Cone_%d" % index
	mi.mesh = mesh
	# Cylinder is centered on its origin: offset down so the apex sits at the lamp.
	mi.position = Vector3(index * r.spacing, r.mount_height * 0.5, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = _CONE_SHADER
	mi.material_override = mat
	add_child(mi)
	if Engine.is_editor_hint() and get_tree() != null:
		mi.owner = get_tree().edited_scene_root
	_cones.append(mi)


func _update_cone_params() -> void:
	if _cones.is_empty():
		return
	var col := cone_color_override
	if col.a <= 0.001:
		var r := rig if rig != null else _default_rig()
		col = r.light_color
	for c in _cones:
		var mat := c.material_override as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter(&"cone_color", col)
			mat.set_shader_parameter(&"intensity", cone_intensity)


func _process(_delta: float) -> void:
	# Fade each cone out as the camera walks under it (full-screen additive
	# wash otherwise). Alpha 0 inside the base radius, full at 1.5x.
	if _cones.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for c in _cones:
		if not is_instance_valid(c):
			continue
		var mat := c.material_override as ShaderMaterial
		var mesh := c.mesh as CylinderMesh
		if mat == null or mesh == null:
			continue
		var base_pos := c.global_position - global_transform.basis.y * (mesh.height * 0.5)
		var delta_v := cam.global_position - base_pos
		var horiz := Vector2(delta_v.x, delta_v.z).length()
		var fade := clampf((horiz - mesh.bottom_radius) / maxf(mesh.bottom_radius * 0.5, 0.001), 0.0, 1.0)
		mat.set_shader_parameter(&"camera_fade", fade)


func _default_rig() -> LuxLightRig:
	var r := LuxLightRig.new()
	r.rig_name = &"Streetlight Row"
	r.light_color = LuxColorTemp.kelvin(LuxColorTemp.SODIUM_VAPOR)  # ~2000K amber
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
