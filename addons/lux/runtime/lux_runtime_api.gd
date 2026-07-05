@tool
class_name LuxRuntimeAPI
extends Object
## Static convenience facade over the active LuxRoot. Lets gameplay systems
## (GOOL hooks, mission controllers) drive visuals without threading a LuxRoot
## reference everywhere. Resolves the first LuxRoot in the "lux_root" group.
##
##   LuxRuntimeAPI.mission_phase(get_tree(), &"combat")
##   LuxRuntimeAPI.alarm(get_tree(), 1.0, 6.0)


static func get_root(tree: SceneTree) -> LuxRoot:
	if tree == null:
		return null
	var nodes := tree.get_nodes_in_group(&"lux_root")
	for n in nodes:
		if n is LuxRoot:
			return n
	return null


static func mission_phase(tree: SceneTree, phase: StringName, blend_time: float = 1.0) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_mission_phase(phase, blend_time)


static func preset(tree: SceneTree, preset_name: StringName, blend_time: float = 1.0) -> void:
	var r := get_root(tree)
	if r != null:
		r.blend_to_preset(preset_name, blend_time)


static func alarm(tree: SceneTree, intensity: float, duration: float) -> void:
	var r := get_root(tree)
	if r != null:
		r.pulse_alarm_lights(intensity, duration)


static func weather(tree: SceneTree, profile: LuxWeatherProfile, blend_time: float = 5.0) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_weather(profile, blend_time)


static func time_of_day(tree: SceneTree, normalized_time: float) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_time_of_day(normalized_time)


static func player_damage(tree: SceneTree, value: float) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_player_damage_intensity(value)
