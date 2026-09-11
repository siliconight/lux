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
## Range of the Compatibility-tier omni approximation, metres. 0 = derive
## from the panel (4 x its longer side). The light loader sets it for
## windows (roadmap 137); see _build for why the rig resource's own
## light_range is deliberately not read here.
@export var omni_range: float = 0.0

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
	# Sweep the built children of any PREVIOUS build first -- including the
	# ones a baked scene saved (they are given an owner, so they serialize)
	# that a fresh instance's `_light` / `_quad` know nothing about. Without
	# this, a loaded rig builds a second panel light and a second surface
	# quad beside the saved pair; the census measured the light half of that
	# doubling on every fixture rig, and the runtime-renamed leftovers are
	# item 55's unaddressable @-nodes. Immediate free() so the saved names
	# are released before the rebuilt children claim them.
	for c in get_children():
		if c is Light3D or (c is MeshInstance3D
				and String(c.name).contains("AreaPanel")):
			remove_child(c)
			c.free()
	_light = null
	_quad = null

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
		# RANGE: `omni_range` when the placer set one, else `4 x panel` --
		# this rig's own guess, 6.4 m for a 1.6 m window, 9.6 for a 2.4. A
		# window sits ON the envelope, so half that sphere is inside the
		# building: the first level to light its windows (roadmap 96) went
		# from 2 to 12 meshes over the per-mesh light budget, every one an
		# interior plate two rooms in (roadmap 137). The loader derives a
		# window's range the way it derives every other type's; the
		# panel-size rule stays for signs and for hand-placed rigs. NOT
		# `rig.light_range`: that resource defaults to 12.0, which this rig
		# has never read, and honouring it would have made every window a
		# 12 m sphere the day it started being consulted.
		if omni_range > 0.0:
			omni.omni_range = omni_range
		else:
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
	# DOUBLE-SIDED. A window's panel faces the room (that is where the light
	# goes), and a single-sided quad is back-face culled from the street --
	# so the first person to walk a level with lit windows (2026-09-11, cold
	# run 9005) saw white panes from the ward and black rectangles from the
	# road, the wrong way round for the viewer who judges a facade at night
	# (roadmap 138). An emissive, unshaded panel has no wrong side.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
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
