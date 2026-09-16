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
## Where the light source sits relative to the panel, in the rig's own
## frame (+Z = the panel's forward). Zero keeps it in the panel plane; the
## loader sets a window's to stand inside the room (roadmap 145).
@export var light_offset: Vector3 = Vector3.ZERO
## AN APERTURE, NOT A BULB (0.40.0). 0 keeps the Compatibility fallback the
## OmniLight3D it has always been -- signs, hand-placed rigs and every scene
## saved before this render byte-identical. Above 0 the fallback is a
## SpotLight3D of this half-angle instead, aimed along the panel's forward
## and pitched down by `cone_pitch_deg`.
##
## WHY A WINDOW NEEDS ONE. An omni standing in an opening has no head and no
## sill, so it lights the ceiling as hard as the floor -- harder, when the
## ceiling is nearer. MEASURED off the walk of cold run 9060, `b2/ext_0_S_
## window_1`: energy 3.0, range 3.6, source at y 2.1 in a 3.7 m room (its
## own `room_ambient` box), so 1.6 m up to the ceiling and 2.1 m down to the
## floor. This rig never touches `omni_attenuation`, so the exponent is the
## engine's 1.0, NOT the 2.0 the loader's club forms use -- `E (1 -
## (d/R)^4)^2 / d` gives 1.732 up against 1.117 down: the ceiling takes
## 1.55x what the floor does. The reveal 0.35 m from the source takes 8.57,
## seven times the floor, which is the white frame a person at 4.5 m reads
## as "the light is inside the wall".
@export_range(0.0, 89.0) var cone_angle_deg: float = 0.0
## How far BELOW the panel's forward the cone's axis is aimed, degrees. Only
## read when `cone_angle_deg` > 0.
@export_range(0.0, 89.0) var cone_pitch_deg: float = 0.0
## The cone's rim softness, written to `spot_angle_attenuation` (see
## LuxLightRig.downlight_rim for the engine's own formula). 1.0 is a cosine
## falloff from the axis, which is what an opening's penumbra looks like and
## what keeps a window's pool from drawing a circle on the floor.
@export_range(0.01, 4.0) var cone_rim: float = 1.0

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
		# Fallback: approximate the panel with a short-range omni at its
		# center -- or, when the placer gave the panel an APERTURE
		# (`cone_angle_deg`, 0.40.0), with a spot of that half-angle aimed
		# along the panel's forward and pitched down.
		var omni: Light3D
		if cone_angle_deg > 0.0:
			var spot := SpotLight3D.new()
			spot.name = &"AreaPanel_Spot"
			spot.spot_angle = minf(cone_angle_deg, 89.0)
			spot.spot_angle_attenuation = cone_rim
			# A SpotLight3D emits along its own local -Z; the panel's
			# forward is +Z, so the cone turns half a circle first and THEN
			# pitches down about its own local X. Composed in that order
			# (`rotation` is YXZ-Euler and would apply the pitch in the
			# parent's frame, tilting the cone sideways once the rig itself
			# is turned to face a wall).
			# NEGATIVE, and the sign is the whole point: with
			# `basis = Ry(PI) * Rx(t)` the emitted direction in the rig's
			# frame is (0, sin t, cos t), so a positive pitch aims the cone
			# UP -- the exact failure it exists to fix. (0, -sin t, cos t)
			# is forward and down.
			spot.transform.basis = (Basis(Vector3.UP, PI)
				* Basis(Vector3.RIGHT, deg_to_rad(-cone_pitch_deg)))
			omni = spot
		else:
			omni = OmniLight3D.new()
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
		var reach := omni_range if omni_range > 0.0 \
			else maxf(panel_size.x, panel_size.y) * 4.0
		# A SpotLight3D has no `omni_range`: setting one on a spot is a
		# silent no-op in GDScript's dynamic `set`, and the spot would keep
		# the engine's 5.0 default -- a range nothing in this package
		# derived. Name the property the node actually has.
		if omni is SpotLight3D:
			(omni as SpotLight3D).spot_range = reach
		else:
			(omni as OmniLight3D).omni_range = reach
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
	# The LIGHT can stand off the panel while the panel stays in the wall
	# plane. A window's anchor is the wall centreline, so an omni placed
	# exactly there pools on the ceiling and the floor symmetrically at the
	# wall -- walked 2026-09-11 as "light coming out of this wall" (roadmap
	# 145). Local +Z is the panel's forward (the room, for a window), so a
	# positive z puts the source inside the room and the pool on the floor in
	# front of the glass, which is where a window's light lands.
	if light_offset != Vector3.ZERO:
		_light.position = light_offset
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
