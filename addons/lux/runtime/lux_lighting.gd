@tool
class_name LuxLighting
extends Node
## Creates and manages art-directed lights. In the MVP it owns the sun/moon
## DirectionalLight3D driven by the preset, tracks registered LuxLightRig nodes,
## and runs the alarm pulse. Child of LuxRoot.

var sun: DirectionalLight3D
var _registered: Array[Node3D] = []
# Fixture lit-face materials bound by LuxEmissiveBinder (v0.14), and the
# building-power state that gates them together with the non-alarm lights.
var _emissives: Array[BaseMaterial3D] = []
var _fixtures_powered: bool = true

# Alarm pulse state
var _alarm_active: bool = false
var _alarm_intensity: float = 0.0
var _alarm_time_left: float = 0.0
var _alarm_phase: float = 0.0
var _alarm_color: Color = Color(1.0, 0.15, 0.22)


func ensure_sun(parent: Node) -> void:
	if sun != null and is_instance_valid(sun):
		return
	sun = DirectionalLight3D.new()
	sun.name = &"LuxSun"
	parent.add_child(sun)
	if Engine.is_editor_hint() and parent.get_tree() != null:
		sun.owner = parent.get_tree().edited_scene_root


func apply(preset: LuxPreset, quality: LuxQualityProfile) -> void:
	if preset == null or sun == null:
		return
	sun.visible = preset.sun_enabled
	if not preset.sun_enabled:
		return
	# Orient from elevation/azimuth (degrees).
	var elev := deg_to_rad(preset.sun_elevation_deg)
	var azim := deg_to_rad(preset.sun_azimuth_deg)
	var basis := Basis.IDENTITY
	basis = basis.rotated(Vector3.UP, azim)
	basis = basis.rotated(basis.x, -elev)
	sun.transform.basis = basis
	sun.light_color = preset.sun_color
	sun.light_energy = preset.sun_energy
	sun.shadow_enabled = preset.sun_shadows and quality.allow_sun_shadows
	sun.directional_shadow_max_distance = quality.shadow_max_distance
	_alarm_color = preset.alarm_color


func register_light(light: Node3D) -> void:
	if light != null and not _registered.has(light):
		_registered.append(light)


func unregister_light(light: Node3D) -> void:
	_registered.erase(light)


func register_emissive(mat: BaseMaterial3D) -> void:
	if mat != null and not _emissives.has(mat):
		_emissives.append(mat)
		_apply_emissive_power(mat)


## The power-cut heist beat: kills every registered rig light AND the bound
## fixture glow (lenses, diffusers, sign faces). Lights in the "lux_alarm"
## group stay — alarm strobes run on battery. Restoring power brings each
## material back to the base energy the binder stamped into its meta.
func set_fixtures_powered(on: bool) -> void:
	_fixtures_powered = on
	for n in _registered:
		if is_instance_valid(n) and n is Light3D and not n.is_in_group(&"lux_alarm"):
			(n as Light3D).visible = on
	for m in _emissives:
		if m != null:
			_apply_emissive_power(m)


func fixtures_powered() -> bool:
	return _fixtures_powered


func _apply_emissive_power(mat: BaseMaterial3D) -> void:
	var base: float = 1.0
	if mat.has_meta(LuxEmissiveBinder.BASE_META):
		base = float(mat.get_meta(LuxEmissiveBinder.BASE_META))
	mat.emission_energy_multiplier = base if _fixtures_powered else 0.0


func pulse_alarm(intensity: float, duration: float) -> void:
	_alarm_active = true
	_alarm_intensity = clampf(intensity, 0.0, 1.0)
	_alarm_time_left = maxf(duration, 0.0)
	_alarm_phase = 0.0


func process(delta: float) -> void:
	if not _alarm_active:
		return
	_alarm_time_left -= delta
	_alarm_phase += delta * TAU * 2.5
	var env := 1.0
	if _alarm_time_left < 1.0:
		env = maxf(_alarm_time_left, 0.0)
	var pulse := (sin(_alarm_phase) * 0.5 + 0.5) * _alarm_intensity * env
	# Drive any registered rig lights that opt in via "lux_alarm" group.
	for n in _registered:
		if is_instance_valid(n) and n is Light3D and n.is_in_group(&"lux_alarm"):
			var lt := n as Light3D
			lt.light_color = _alarm_color
			lt.light_energy = 4.0 * pulse
	if _alarm_time_left <= 0.0:
		_alarm_active = false
		for n in _registered:
			if is_instance_valid(n) and n is Light3D and n.is_in_group(&"lux_alarm"):
				(n as Light3D).light_energy = 0.0
