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
	apply_shadow_policy(quality)


func register_light(light: Node3D) -> void:
	if light != null and not _registered.has(light):
		_registered.append(light)
		# A rig registers from its own _ready, which can come AFTER the
		# preset was applied (LuxRoot is an earlier sibling in a packed
		# scene), so the policy is re-run once the frame settles.
		_schedule_shadow_policy()


func unregister_light(light: Node3D) -> void:
	_registered.erase(light)


# ---------------------------------------------------------------------------
# Shadow policy (roadmap 60).
#
# An unshadowed light illuminates everything in range with walls never
# consulted: a fixture in the next room lights this one's ceiling, and a sign
# on the envelope washes the room behind the wall it hangs on. Collision never
# blocks light; only a shadow map does, and GL Compatibility pays per
# shadowed light, so the question is never "shadows or not" but WHICH of a
# level's ~60 lights get the maps the tier can afford.
#
# RANKED BY HOW MUCH THE THROUGH-WALL WASH IS WORTH STOPPING, which is the
# light's RANGE across an envelope it is mounted outside of. Signs (8 m,
# the original sighting: arena_a03's interior ceiling carried the wash of
# the sign outside its south wall), wall packs (5.5 m, proud of the face
# above a door) and streetlights (14 m) all sit outside the building and
# put half a sphere through its walls -- first. Windows are ON the envelope
# but at 3.2-4.0 m since Lux 0.31.0, and the light on both sides of glass
# is the point of them -- second. Bare bulbs are inside their objective
# rooms -- third. Fluorescent rows are inside the rooms they light, so their
# spill through a partition is the least visible of the four -- last. Within
# a class, stable by path.
#
# THE CLASS IS READ OFF THE RIG NODE'S NAME, not the resource's rig_name:
# the loader gives signs and windows the same "Window (baked)" resource,
# and the marker path names its rigs `Spawned_<type>_<n>`, so the node name
# is the one place both paths spell the type.
#
# THE RIG'S OWN `shadows_enabled` IS A REQUEST, NOT A DECISION: it is what a
# rig does with no LuxRoot in the scene. Under a LuxRoot the tier decides,
# so that changing `quality_tier` moves the whole level at once and nothing
# has to be re-baked.
# ---------------------------------------------------------------------------

var _policy_pending: bool = false
var _quality_for_policy: LuxQualityProfile


func _schedule_shadow_policy() -> void:
	if _policy_pending:
		return
	_policy_pending = true
	call_deferred(&"_run_scheduled_policy")


func _run_scheduled_policy() -> void:
	_policy_pending = false
	if _quality_for_policy != null:
		apply_shadow_policy(_quality_for_policy)


## Which shadow-priority class a registered light belongs to; lower first.
static func shadow_rank(light: Node3D) -> int:
	return shadow_rank_of_name(_rig_type_name(light))


## The rig node's name lower-cased -- `b0_ext_0_S_sign`, `ext_0_E_pack_1`,
## `Spawned_streetlight_3`, `lobby_ceiling`, `vault_bulbs` -- with the rig
## resource's name appended as a fallback for hand-built rigs.
static func _rig_type_name(light: Node3D) -> String:
	var rig_node := light.get_parent()
	if rig_node == null:
		return ""
	var name := String(rig_node.name).to_lower()
	var r: Variant = rig_node.get(&"rig")
	if r is LuxLightRig:
		name += " " + String((r as LuxLightRig).rig_name).to_lower()
	return name


static func shadow_rank_of_name(name: String) -> int:
	if name.contains("sign") or name.contains("pack") or name.contains("street"):
		return 0
	if name.contains("window"):
		return 1
	if name.contains("bulb") or name.contains("pendant"):
		return 2
	if name.contains("fluorescent") or name.contains("ceiling"):
		return 3
	return 4


## Enable shadows on the `quality.max_shadow_casters` highest-ranked registered
## lights and disable them on the rest. Returns {enabled, disabled, budget}.
func apply_shadow_policy(quality: LuxQualityProfile) -> Dictionary:
	_quality_for_policy = quality
	var budget: int = quality.max_shadow_casters if quality != null else 0
	var lights: Array = []
	for n in _registered:
		if is_instance_valid(n) and n is Light3D and not (n is DirectionalLight3D):
			lights.append(n)
	lights.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var ra := shadow_rank(a)
		var rb := shadow_rank(b)
		if ra != rb:
			return ra < rb
		return String(a.get_path()) < String(b.get_path()))
	var enabled := 0
	var disabled := 0
	for i in range(lights.size()):
		var on: bool = i < budget
		(lights[i] as Light3D).shadow_enabled = on
		if on:
			enabled += 1
		else:
			disabled += 1
	return {"enabled": enabled, "disabled": disabled, "budget": budget}


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
