@tool
class_name LuxStreetlightRig
extends Node3D
## Streetlight row rig (TDD §16 rig #3). Spawns a line of downward sodium-vapor
## spotlights along local X, CENTERED on the node (v0.13.1 — matches
## LuxFluorescentRig and Lot's path-midpoint anchors) — parking lots, street blocks, the Wawa lot. Reads a
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

## THE LAMP HANGS BELOW ITS MOUNT (0.64.0). The mount is where the anchor
## puts the rig: for a Lot pole it is the lens point, 0.175 m under the
## module's top (Lot's `STREETLIGHT_LENS_DROP`), and in Zoo's recipe that
## is 5 mm above the shaft's top cap. A spot's shadow map is a perspective
## camera at the light's origin, and a disc of radius r at depth d in front
## of it subtends atan(r / d): the 0.06 m cap 5 mm under the lamp subtends
## 85 degrees, the whole 55-degree cone, and every pixel under the pole
## compares as shadowed. At or below the cap the disc is behind the camera.
## (The first reading was the shaft's SIDES filling the frustum from a
## camera on the axis; a clean cylinder with the lamp on its cap lit the
## ground fully and refuted it.)
##
## MEASURED on cold run 9139's gas station lot (survey, every other light
## off, the ground's luminance 9 m from the foot), the pole's own lamp
## against a fresh unshadowed spot on its transform:
##
##     at the lens point, shadowed   0.001     (12 of 17 poles shipped so)
##     fresh, unshadowed             0.305
##     0.02 m lower, shadowed        0.282
##     0.05 m lower, shadowed        0.239
##     0.10 m lower, shadowed        0.282     (the unshadowed figure: 0.286)
##
## And with Zoo's shapes in this project (`tools/streetlight_shadow_
## selftest.gd`): 5 mm over the cap 0.002; at or under it 0.742 whatever
## the body's cull mode; the shaft hidden 0.745; the head or the lens
## hidden, no change. The figure stops moving at 0.02; 0.10 keeps the cap
## a hand's width behind the camera. The five poles the shadow budget had
## not reached were the ones the walker saw working.
const LAMP_HANG_M := 0.10

## THE POLE'S LAMP SITS BESIDE THE POLE (0.65.0), and `LAMP_HANG_M` above
## is a wall pack's now. 0.64.0 hung a pole's lamp 0.10 below its mount to
## clear its own shadow map; the mount is 5 mm above the shaft's cap, so the
## lamp sat 9.5 cm INSIDE the steel. A shadow map culls the shaft's inside
## faces and drew the pool. The light bake ray-traces, and measured on one
## closed 6 m pole and one static spot (`patches/lightbake_probe/
## make_pole_control.py`, Godot 4.7's lightmapper, quality Low):
##
##     lamp inside the shaft (0.64.0)             0 lit texels   max 0.005
##     on the axis at the lens point (to 0.63.0)  2,815          max 0.039
##     0.2 m along the head, 1 cm under the lens  5,581          max 20.9
##     no pole at all                             5,605          max 3.0
##
## So the lamp sits POLE_LAMP_ALONG_M along the head from the pole's axis,
## and POLE_LAMP_DROP_M under the lens: clear of the 0.06 m shaft by 0.14,
## under the lens at the genome's narrowest head (0.5 m wide, a 0.4 m lens,
## so 0.2 is its end), and above nothing but the ground. The pole now
## shadows a wedge of its own pool -- 2 atan(0.06 / 0.2), 33 degrees, on
## the far side -- which a real pole does.
const POLE_LAMP_ALONG_M := 0.2
const POLE_LAMP_DROP_M := 0.01
## AND ITS SHADOW BIAS (0.65.0). A shadowed pole's lamp reads lit for about
## 30 frames, then the renderer moves it to a smaller slot of the 16-bit
## positional atlas and, at the engine's 0.03, the ground shadows itself
## (acne). Measured on the gas station lot's side-street pole, settled,
## every other light off, the ground under it (unshadowed 0.201):
##
##     bias 0.03 (default)   0.085      normal bias 2    0.157
##     bias 0.1              0.183      normal bias 4    0.178
##     bias 0.3              0.183      24-bit atlas     0.183
##
## 0.1 is where it stops moving; a 6 m pole's shadow detaches by a few cm.
## Every steady pole on the lot lit after a 90-frame settle at 0.1; one of
## 17 was dark at the default.
const POLE_SHADOW_BIAS := 0.1

## Where each lamp sits from its row point at the mount, in the rig's frame
## (x along the head, y up). The default is 0.64.0's, which a wall pack
## keeps; the loader's `streetlight` branch puts a pole's lamp beside the
## pole (`POLE_LAMP_ALONG_M`, `POLE_LAMP_DROP_M`).
@export var lamp_offset: Vector3 = Vector3(0.0, -LAMP_HANG_M, 0.0):
	set(value):
		lamp_offset = value
		if is_inside_tree():
			_rebuild()
## Each lamp's shadow bias; negative leaves the engine's. The loader's
## `streetlight` branch sets `POLE_SHADOW_BIAS`.
@export var lamp_shadow_bias: float = -1.0

var _lights: Array[SpotLight3D] = []
var _cones: Array[MeshInstance3D] = []
var _flicker_phase: float = 0.0
## A failing pole's clock and its lenses (0.62.0): see LuxFluorescentRig.
var _fail_t: float = 0.0
var _lenses: Array = []

## THE DUSK-TO-DAWN SWITCH (0.71.0). A rig whose resource is `dusk_to_dawn`
## goes dark under a preset with `street_lamps_lit` false: the rig hidden, so
## its lamps neither draw nor bake, and the lens nearest each lamp given a
## dark copy of its material, so a dark lamp does not glow. LuxLighting calls
## `set_lamps_lit` when a preset is applied and when a lamp registers.
var _lamps_lit: bool = true
## [mesh, surface, the override it had]
var _dark_lenses: Array = []


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_rebuild()
	var root := _find_lux_root()
	if root != null:
		for l in _lights:
			root.register_lux_light(l)
	_bind_lenses.call_deferred()        # after the spawner has placed the rig
	if rig != null and rig.failing_kind != LuxFailing.NONE and rig.bake_mode != 1:
		set_process(true)


## A cycling pole dims its own lens with its lamp (0.62.0): the nearest lit
## face to each lamp within a metre and a half, given a material of its own.
func _bind_lenses() -> void:
	_lenses.clear()
	if rig == null or rig.failing_kind == LuxFailing.NONE or rig.bake_mode == 1:
		return
	# a dark dusk-to-dawn pole binds no failing lens; it binds when it relights
	if not _lamps_lit:
		return
	var scene: Node = owner if owner != null else get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	for l in _lights:
		var hit: Array = LuxFailing.find_lens(scene, l.global_position, 1.5)
		if hit.is_empty():
			continue
		var mi: MeshInstance3D = hit[0]
		var s: int = hit[1]
		var mat: BaseMaterial3D = mi.get_active_material(s) as BaseMaterial3D
		if mat == null:
			continue
		var own: BaseMaterial3D = mat.duplicate() as BaseMaterial3D
		own.resource_name = mat.resource_name
		mi.set_surface_override_material(s, own)
		_lenses.append([mi, s, own, own.emission_energy_multiplier])


## Light or darken a dusk-to-dawn rig (0.71.0). A rig that is not one keeps
## its light: the switch is the resource's (`LuxLightRig.dusk_to_dawn`), not
## the class's, because a canopy wash is this class too.
func set_lamps_lit(lit: bool) -> void:
	if rig == null or not rig.dusk_to_dawn:
		return
	if lit == _lamps_lit and visible == lit:
		return
	_lamps_lit = lit
	visible = lit
	if lit:
		_restore_lenses()
		_bind_lenses.call_deferred()
	else:
		_darken_lenses.call_deferred()


func lamps_lit() -> bool:
	return _lamps_lit


## Deferred, as `_bind_lenses` is: the spawner places a rig after adding it,
## so when the switch first runs its lamps may still stand at the container's
## origin. The lens nearest each lamp within a metre and a half takes a dark
## copy of its material; the material it had is kept to put back.
func _darken_lenses() -> void:
	if _lamps_lit or not _dark_lenses.is_empty():
		return
	var scene: Node = owner if owner != null else get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	for l in _lights:
		if not is_instance_valid(l):
			continue
		var hit: Array = LuxFailing.find_lens(scene, l.global_position, 1.5)
		if hit.is_empty():
			continue
		var mi: MeshInstance3D = hit[0]
		var s: int = hit[1]
		var mat: BaseMaterial3D = mi.get_active_material(s) as BaseMaterial3D
		if mat == null:
			continue
		var dark: BaseMaterial3D = mat.duplicate() as BaseMaterial3D
		dark.resource_name = mat.resource_name
		dark.emission_energy_multiplier = 0.0
		_dark_lenses.append([mi, s, mi.get_surface_override_material(s)])
		mi.set_surface_override_material(s, dark)


func _restore_lenses() -> void:
	for e in _dark_lenses:
		if is_instance_valid(e[0]):
			(e[0] as MeshInstance3D).set_surface_override_material(int(e[1]), e[2])
	_dark_lenses.clear()


func _rebuild() -> void:
	# Sweep every built child by TYPE, not just what this instance's arrays
	# track. Lamps and cones saved into a baked scene arrive as children of a
	# fresh instance whose `_lights` / `_cones` are empty, so the old loops
	# freed nothing and built a second set beside the first (the fluorescent
	# rig's census-measured doubling, same mechanism). Immediate free() so the
	# saved names are released before the rebuilt children claim them.
	for c in get_children():
		if c is SpotLight3D or (c is MeshInstance3D
				and String(c.name).contains("Cone")):
			remove_child(c)
			c.free()
	_lights.clear()
	_cones.clear()
	var r := rig if rig != null else _default_rig()
	# Process when the cones need camera fade OR the rig flickers. The rig
	# resource always carried flicker fields; this rig ignored them, so a
	# "buzzing streetlight" tuned in the loader was silently steady.
	set_process(cone_enabled
			or (r.flicker_amount > 0.0 and r.bake_mode != 1))
	# Center the row on the rig node, same as LuxFluorescentRig. Lot writes
	# path-MIDPOINT anchors; an uncentered row lit half the path and overshot
	# the end. Zoo's fixture pass (v0.28) expands rows with this exact math,
	# so every pole sits under its lamp.
	var start := -(r.count - 1) * 0.5 * r.spacing
	for i in r.count:
		var lamp := SpotLight3D.new()
		lamp.name = &"Street_%d" % i
		lamp.light_color = r.light_color
		lamp.light_energy = r.energy
		lamp.spot_range = r.light_range
		lamp.spot_attenuation = r.attenuation
		lamp.spot_angle = 55.0
		lamp.spot_angle_attenuation = 1.2
		lamp.shadow_enabled = r.shadows_enabled
		if lamp_shadow_bias >= 0.0:
			lamp.shadow_bias = lamp_shadow_bias
		lamp.position = Vector3(start + i * r.spacing, r.mount_height, 0.0) + lamp_offset
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
	# Cylinder is centered on its origin: offset down so the apex sits at the
	# lamp — whose row is centered on the node (see _rebuild).
	var start := -(r.count - 1) * 0.5 * r.spacing
	mi.position = Vector3(start + index * r.spacing + lamp_offset.x, r.mount_height * 0.5, lamp_offset.z)
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
	# Dying-ballast buzz, same two-tone noise as the fluorescent rig -- a
	# sodium lamp warming and cutting is THE 90s parking-lot sound made
	# visible. Only poles the loader tuned with flicker_amount > 0 pay.
	var fr := rig if rig != null else null
	if fr != null and fr.failing_kind != LuxFailing.NONE and fr.bake_mode != 1:
		# a sodium lamp at the end of its life: dims, cuts out, restrikes
		_fail_t += _delta
		var lvl := LuxFailing.level(fr.failing_kind, fr.failing_seed, _fail_t)
		for fl in _lights:
			if is_instance_valid(fl):
				fl.light_energy = fr.energy * lvl
		var root := _find_lux_root()
		if root == null or root.fixtures_powered():
			for e in _lenses:
				(e[2] as BaseMaterial3D).emission_energy_multiplier = float(e[3]) * lvl
	elif fr != null and fr.flicker_amount > 0.0 and fr.bake_mode != 1:
		_flicker_phase += _delta * fr.flicker_speed
		var n := sin(_flicker_phase) * 0.5 + sin(_flicker_phase * 3.7) * 0.5
		var flick := 1.0 - maxf(0.0, n) * fr.flicker_amount * 0.5
		for fl in _lights:
			if is_instance_valid(fl):
				fl.light_energy = fr.energy * flick

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
