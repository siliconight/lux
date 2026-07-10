@tool
class_name LuxAreaLightRig
extends Node3D
## Rectangular area-light rig built on Godot 4.7's AreaLight3D (TDD §7 LuxLighting;
## 4.7 integration). Perfect for the soft glows Lux presets ask for: TV/arcade
## screens, illuminated signage, deli display cases, gas-station canopy panels,
## and light through frosted windows — the exact cases that used to need an
## emissive material plus GI.
##
## AreaLight3D is a Forward+/Mobile feature and a clustered element (counts
## against the renderer's 512-element budget). Under the Compatibility tier it
## can fail to compile against vertex-shaded materials, so this rig falls back to
## an OmniLight3D approximation when Lux is on the Compatibility tier.

@export var rig: LuxLightRig

@export_group("Panel")
## Emitting rectangle size in meters (Godot maps this to AreaLight3D.size).
@export var panel_size: Vector2 = Vector2(1.6, 0.9)
## Optional texture projected by the light — signage art, a screen frame, etc.
@export var panel_texture: Texture2D
## Keep energy independent of panel size (AreaLight3D.normalize_energy).
@export var normalize_energy: bool = true

@export_group("Preview Surface")
## Spawn a matching emissive quad so the panel reads visually, not just as light.
@export var show_emissive_quad: bool = true

var _light: Node3D  # AreaLight3D on Forward+/Mobile, OmniLight3D on Compatibility
var _quad: MeshInstance3D


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_build()
	var root := _find_lux_root()
	if root != null:
		root.register_lux_light(_light)


func _build() -> void:
	var compat := _is_compatibility()
	var col := Color(1.0, 0.96, 0.9)
	var energy := 3.0
	var shadows := false
	if rig != null:
		col = rig.light_color
		energy = rig.energy
		shadows = rig.shadows_enabled

	if compat or not _area_light_available():
		# Fallback: approximate the panel with a short-range omni at its center.
		var omni := OmniLight3D.new()
		omni.name = &"AreaPanel_Omni"
		omni.light_color = col
		omni.light_energy = energy
		omni.omni_range = maxf(panel_size.x, panel_size.y) * 4.0
		omni.shadow_enabled = shadows
		_light = omni
	else:
		var area := ClassDB.instantiate(&"AreaLight3D")
		area.name = &"AreaPanel"
		area.set(&"light_color", col)
		area.set(&"light_energy", energy)
		area.set(&"size", panel_size)          # AreaLight3D.size (Area > Size)
		area.set(&"normalize_energy", normalize_energy)
		area.set(&"shadow_enabled", shadows)
		if panel_texture != null:
			area.set(&"texture", panel_texture)
		_light = area

	if rig != null:
		rig.apply_bake_mode(_light)
	add_child(_light)
	if Engine.is_editor_hint() and get_tree() != null:
		_light.owner = get_tree().edited_scene_root

	if show_emissive_quad:
		_build_quad(col)


func _build_quad(col: Color) -> void:
	_quad = MeshInstance3D.new()
	_quad.name = &"AreaPanel_Surface"
	var mesh := QuadMesh.new()
	mesh.size = panel_size
	_quad.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 1.5
	mat.albedo_color = col
	if panel_texture != null:
		mat.albedo_texture = panel_texture
		mat.emission_texture = panel_texture
	_quad.material_override = mat
	# AreaLight3D emits along -Z; face the quad the same way so they agree.
	add_child(_quad)
	if Engine.is_editor_hint() and get_tree() != null:
		_quad.owner = get_tree().edited_scene_root


func _area_light_available() -> bool:
	return ClassDB.class_exists(&"AreaLight3D")


func _is_compatibility() -> bool:
	# The Compatibility renderer has no RenderingDevice.
	return RenderingServer.get_rendering_device() == null


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
