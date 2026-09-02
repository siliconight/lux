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


## Building power on/off — kills non-alarm rig lights + bound fixture glow.
static func fixtures_powered(tree: SceneTree, on: bool) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_fixtures_powered(on)


## Bind Zoo fixture lit-face materials after the level loads.
static func bind_emissives(tree: SceneTree, search_root: Node = null) -> Dictionary:
	var r := get_root(tree)
	if r != null:
		return r.bind_fixture_emissives(search_root)
	return {"ok": false, "msg": "No LuxRoot in the tree.", "count": 0}


## Film emulsion on/off, for a graphics menu (TDD section 15). This is the
## GLOBAL key only -- a preset that never asked for film, or a quality tier that
## refuses it, is unaffected by turning this on. Ask is_film_emulsion_active()
## for what is actually running.
static func film_emulsion(tree: SceneTree, enabled: bool) -> void:
	var r := get_root(tree)
	if r != null:
		r.set_film_emulsion_enabled(enabled)


## Whether film emulsion is actually rendering right now -- all three keys open
## and the preset asking for the film grain mode. A settings screen wants this
## as well as the switch, so a toggle that legitimately does nothing on this
## tier can say so instead of looking broken.
static func is_film_emulsion_active(tree: SceneTree) -> bool:
	var r := get_root(tree)
	return r != null and r.is_film_emulsion_active()


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
