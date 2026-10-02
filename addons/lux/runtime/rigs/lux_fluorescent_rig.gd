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

var _lights: Array[Light3D] = []
var _flicker_phase: float = 0.0
## A failing fixture's clock and its lenses (0.62.0): one
## ``[MeshInstance3D, surface, material, base emission]`` a lamp, each its
## own override so no other fixture dims with it.
var _fail_t: float = 0.0
var _lenses: Array = []
## The preset's `fluorescent_energy_scale`, handed in by LuxLighting (0.55.0):
## every lamp is `rig.energy * energy_scale`, flicker included. 1.0 until a
## preset says otherwise, and only for a rig that `scales_with_preset`.
var energy_scale: float = 1.0


## A fluorescent row scales with the preset; a bare bulb -- the same class,
## wearing an incandescent costume -- does not (the walker, 2026-09-28).
func scales_with_preset() -> bool:
	return rig != null and (rig.preset_scaled
		or String(rig.rig_name).to_lower().contains("fluorescent"))


func set_energy_scale(s: float) -> void:
	energy_scale = s if scales_with_preset() else 1.0
	var r := rig if rig != null else _default_rig()
	for l in _lights:
		if is_instance_valid(l):
			l.light_energy = r.energy * energy_scale


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_rebuild()
	var root := _find_lux_root()
	if root != null:
		for l in _lights:
			root.register_lux_light(l)
	# DEFERRED, not now: the spawner places a rig AFTER add_child, so at
	# ready its lamps still sit at the container's origin and the nearest
	# lens is nowhere (measured: 0 of 9 tubes bound on the first probe)
	_bind_lenses.call_deferred()
	set_process(rig != null and rig.bake_mode != 1
		and (rig.flicker_amount > 0.0 or rig.failing_kind != LuxFailing.NONE))


## A failing fixture dims the lit face nearest each of its lamps (0.62.0).
## The lamp sits inside its own hardware, so the nearest lens within a metre
## and a half is its own. The face gets a material of its own, so the rest of
## the row -- which shares the lens material -- stays steady. Once, at ready.
func _bind_lenses() -> void:
	_lenses.clear()
	if rig == null or rig.failing_kind == LuxFailing.NONE or rig.bake_mode == 1:
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


func _rebuild() -> void:
	# Free EVERY lamp child, not just what this instance's `_lights` tracks.
	# The lux bake saves built lamps into the scene (they are given an owner,
	# so they serialize), and a rig LOADED from that scene arrives with its
	# lamps already as children and a fresh, EMPTY `_lights` -- the old loop
	# freed nothing, built a second set beside the first, and the per-mesh
	# light census read every fixture TWICE (272 visible against an authored
	# 136, each within 10 cm of its twin). The file said one lamp; the running
	# level had two -- Sun Link's disease, one rig down. Immediate free(), not
	# queue_free(): a deferred corpse still holds its name for the rest of the
	# frame, so the replacement would be renamed @OmniLight3D@N and become
	# unaddressable (item 55 documents what @-names cost downstream).
	# By Light3D, not OmniLight3D: a downlight rig (0.34.0) saves SpotLight3D
	# lamps, and sweeping only omnis would double those exactly the way the
	# census above describes.
	for c in get_children():
		if c is Light3D:
			remove_child(c)
			c.free()
	_lights.clear()
	var r := rig if rig != null else _default_rig()
	var start := -(r.count - 1) * 0.5 * r.spacing
	for i in r.count:
		var lamp: Light3D
		if r.downlight_angle_deg > 0.0:
			var spot := SpotLight3D.new()
			spot.spot_range = r.light_range
			spot.spot_attenuation = r.attenuation
			spot.spot_angle = minf(r.downlight_angle_deg, 89.0)
			spot.spot_angle_attenuation = r.downlight_rim
			if r.downlight_tilt_deg > 0.0:
				# Tilted toward local +X (0.57.0): the yaw turns -Z onto +X,
				# then the pitch lowers it to `tilt` off straight down.
				spot.rotation_degrees = Vector3(-(90.0 - r.downlight_tilt_deg), -90.0, 0.0)
			else:
				spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)  # straight down
			lamp = spot
		else:
			var omni := OmniLight3D.new()
			omni.omni_range = r.light_range
			omni.omni_attenuation = r.attenuation
			lamp = omni
		lamp.name = &"Fluoro_%d" % i
		lamp.light_color = r.light_color
		lamp.light_energy = r.energy * energy_scale
		lamp.shadow_enabled = r.shadows_enabled
		lamp.position = Vector3(start + i * r.spacing, r.mount_height, 0.0)
		r.apply_bake_mode(lamp)
		add_child(lamp)
		if Engine.is_editor_hint() and get_tree() != null:
			lamp.owner = get_tree().edited_scene_root
		_lights.append(lamp)


func _process(delta: float) -> void:
	var r := rig if rig != null else null
	if r == null or r.bake_mode == 1:
		return
	if r.failing_kind != LuxFailing.NONE:
		_fail_t += delta
		var lvl := LuxFailing.level(r.failing_kind, r.failing_seed, _fail_t)
		for l in _lights:
			if is_instance_valid(l):
				l.light_energy = r.energy * energy_scale * lvl
		# the lens follows the lamp -- unless the level's power is cut, when
		# the binder has zeroed it and it stays zeroed
		var root := _find_lux_root()
		if root == null or root.fixtures_powered():
			for e in _lenses:
				(e[2] as BaseMaterial3D).emission_energy_multiplier = float(e[3]) * lvl
		return
	if r.flicker_amount <= 0.0:
		return
	_flicker_phase += delta * r.flicker_speed
	# Two-tone noise for that ballast-buzz instability.
	var n := sin(_flicker_phase) * 0.5 + sin(_flicker_phase * 3.7) * 0.5
	var flick := 1.0 - maxf(0.0, n) * r.flicker_amount * 0.5
	for l in _lights:
		if is_instance_valid(l):
			l.light_energy = r.energy * energy_scale * flick


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
