@tool
class_name LuxStageLightRig
extends Node3D
## Coloured stage spots (0.37.0): one SpotLight3D per lamp, laid along local
## X like every other Lux row and each aimed at the same point, `aim_local`.
## The light loader builds it from a `stage_light` anchor and derives the
## cone, range and energy there; this node only lays the lamps out and, when
## asked, steps their colours.
##
## THE COLOUR CYCLE IS A PURE FUNCTION OF TIME. `colour_at` takes the rig's
## accumulated process time and returns the same colour for the same instant
## on every machine: each colour holds for 75% of `cycle_period_s` and
## crossfades into the next over the last 25%, lamp `i` running `i` colours
## ahead of lamp 0. It writes `light_color` on a few lights per frame and
## nothing else -- no range, no energy -- so a lamp's pairing with meshes
## never changes while it cycles. 0 = static, which is the default.

@export var rig: LuxLightRig:
	set(value):
		rig = value
		if is_inside_tree():
			_rebuild()

## The point every lamp aims at, in this node's own frame.
@export var aim_local: Vector3 = Vector3(0.0, -3.0, 0.0):
	set(value):
		aim_local = value
		if is_inside_tree():
			_rebuild()
## Cone half-angle, degrees (SpotLight3D.spot_angle).
@export_range(1.0, 89.0) var spot_angle_deg: float = 20.0
## Written straight to spot_angle_attenuation (see LuxLightRig.downlight_rim
## for what the engine does with it).
@export_range(0.01, 4.0) var spot_rim: float = 0.5
## The colour order: lamp i shows colors[i] when static.
@export var colors: PackedColorArray = PackedColorArray()
## Seconds per colour step; 0 = static.
@export_range(0.0, 120.0) var cycle_period_s: float = 0.0

var _lights: Array[SpotLight3D] = []
var _t: float = 0.0


func _ready() -> void:
	add_to_group(&"lux_light_rig")
	_rebuild()
	var root := _find_lux_root()
	if root != null:
		for l in _lights:
			root.register_lux_light(l)
	set_process(_cycles())


func _cycles() -> bool:
	return cycle_period_s > 0.0 and colors.size() > 1 \
		and not (rig != null and rig.bake_mode == 1)


func _rebuild() -> void:
	# Sweep every Light3D child, not just what `_lights` tracks: a rig loaded
	# from a baked scene arrives with its saved lamps as children and an empty
	# array (LuxFluorescentRig._rebuild has the census that found the doubling).
	for c in get_children():
		if c is Light3D:
			remove_child(c)
			c.free()
	_lights.clear()
	var r := rig if rig != null else _default_rig()
	var start := -(r.count - 1) * 0.5 * r.spacing
	for i in r.count:
		var spot := SpotLight3D.new()
		spot.name = &"Stage_%d" % i
		spot.position = Vector3(start + i * r.spacing, r.mount_height, 0.0)
		var dir := aim_local - spot.position
		if dir.length() < 0.01:
			dir = Vector3.DOWN
		var up := Vector3.UP
		if absf(dir.normalized().dot(up)) > 0.999:
			up = Vector3.FORWARD
		spot.basis = Basis.looking_at(dir, up)
		spot.spot_range = r.light_range
		spot.spot_attenuation = r.attenuation
		spot.spot_angle = spot_angle_deg
		spot.spot_angle_attenuation = spot_rim
		spot.light_energy = r.energy
		spot.light_color = colour_at(colors, i, 0.0, cycle_period_s) if colors.size() > 0 \
			else r.light_color
		spot.shadow_enabled = r.shadows_enabled
		r.apply_bake_mode(spot)
		add_child(spot)
		if Engine.is_editor_hint() and get_tree() != null:
			spot.owner = get_tree().edited_scene_root
		_lights.append(spot)


func _process(delta: float) -> void:
	if not _cycles():
		return
	_t += delta
	for i in _lights.size():
		if is_instance_valid(_lights[i]):
			_lights[i].light_color = colour_at(colors, i, _t, cycle_period_s)


## The colour lamp `lamp` shows at time `t` seconds. Static (period 0) is
## colors[lamp]; cycling holds each colour for 75% of the period and
## crossfades over the last 25%.
static func colour_at(cols: PackedColorArray, lamp: int, t: float, period: float) -> Color:
	var n := cols.size()
	if n == 0:
		return Color.WHITE
	if period <= 0.0 or n == 1:
		return cols[lamp % n]
	var phase := t / period
	var k := int(floor(phase))
	var f := phase - float(k)
	var fade := clampf((f - 0.75) / 0.25, 0.0, 1.0)
	return cols[(k + lamp) % n].lerp(cols[(k + lamp + 1) % n], fade)


func _default_rig() -> LuxLightRig:
	var r := LuxLightRig.new()
	r.rig_name = &"Stage Light"
	r.light_color = Color(1.0, 0.0, 0.8)
	r.energy = 2.0
	r.light_range = 4.0
	r.attenuation = 2.0
	r.count = 1
	r.spacing = 0.0
	r.mount_height = 0.0
	return r


func _find_lux_root() -> LuxRoot:
	var n := get_parent()
	while n != null:
		if n is LuxRoot:
			return n
		n = n.get_parent()
	if get_tree() == null:
		return null
	for root in get_tree().get_nodes_in_group(&"lux_root"):
		if root is LuxRoot:
			return root
	return null
