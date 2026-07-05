@tool
extends Node3D
## Lux sample scene driver. Builds a small self-contained blockout (floor, walls,
## crates, a counter) so the addon can be demonstrated with zero external assets,
## applies a starting preset, and wires keyboard controls to show off the look:
##
##   [Space] toggle Lux on/off (before / after)
##   [1..5]  jump between the five shipped presets
##   [H]     "Mission Goes Hot" phase blend
##   [C]     back to calm
##   [A]     pulse alarm lights
##   [D]     ramp player-damage low-health look
##
## The before/after toggle satisfies the "sample scene showing before/after"
## and "demonstrates environment, lighting, material, and post FX" criteria.

const DELCO := &"Delco Summer Afternoon"
const PRESETS := [
	&"Delco Summer Afternoon",
	&"Gas Station Fluorescent",
	&"Blue Hour",
	&"Heavy Rain",
	&"Mission Goes Hot",
]

@onready var lux: LuxRoot = $LuxRoot
@onready var hint: Label = $UI/Hint

var _lux_enabled := true
var _fallback_env: Environment
var _damage := 0.0
var _ps2 := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_build_blockout()
	_apply_lux_materials()
	# Cache a plain environment so the "before" state looks like an untreated scene.
	_fallback_env = Environment.new()
	_fallback_env.background_mode = Environment.BG_COLOR
	_fallback_env.background_color = Color(0.5, 0.5, 0.55)
	_fallback_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_fallback_env.ambient_light_color = Color(0.6, 0.6, 0.6)
	_fallback_env.ambient_light_energy = 1.0
	if lux != null:
		lux.blend_to_preset(DELCO, 0.0)
	_update_hint()


func _build_blockout() -> void:
	var world := Node3D.new()
	world.name = &"Blockout"
	add_child(world)

	# Floor
	world.add_child(_box(Vector3(24, 0.4, 24), Vector3(0, -0.2, 0), Color(0.42, 0.4, 0.38)))
	# Back + side walls
	world.add_child(_box(Vector3(24, 6, 0.4), Vector3(0, 3, -12), Color(0.55, 0.52, 0.48)))
	world.add_child(_box(Vector3(0.4, 6, 24), Vector3(-12, 3, 0), Color(0.5, 0.48, 0.46)))
	world.add_child(_box(Vector3(0.4, 6, 24), Vector3(12, 3, 0), Color(0.5, 0.48, 0.46)))
	# Deli counter
	world.add_child(_box(Vector3(8, 1.1, 1.6), Vector3(-2, 0.55, -6), Color(0.7, 0.66, 0.55)))
	# Crates
	world.add_child(_box(Vector3(1.4, 1.4, 1.4), Vector3(4, 0.7, 2), Color(0.6, 0.45, 0.3)))
	world.add_child(_box(Vector3(1.4, 1.4, 1.4), Vector3(5.6, 0.7, 2), Color(0.58, 0.44, 0.29)))
	world.add_child(_box(Vector3(1.4, 1.4, 1.4), Vector3(4.8, 2.1, 2), Color(0.62, 0.46, 0.31)))
	# Pillars
	for x in [-6, 0, 6]:
		world.add_child(_box(Vector3(0.8, 6, 0.8), Vector3(x, 3, 6), Color(0.48, 0.46, 0.44)))


func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mi.set_surface_override_material(0, mat)
	mi.set_meta(&"lux_albedo", col)
	return mi


func _apply_lux_materials() -> void:
	# Demonstrate the role-based applier: the blockout is level geometry, so give
	# it the LEVEL role (native vertex shading, cheapest multi-light path). A real
	# game would tag characters/guns/props with their own roles.
	var pal := lux.active_preset.get_palette_or_neutral() if lux.active_preset else null
	var count := LuxMaterialApplier.apply_role($Blockout, LuxRole.Role.LEVEL, pal)
	print("[Lux sample] Applied LEVEL role to %d surfaces." % count)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_SPACE:
			_toggle_lux()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var idx := key - KEY_1
			if idx < PRESETS.size():
				lux.blend_to_preset(PRESETS[idx], 0.6)
		KEY_H:
			lux.set_mission_phase(&"combat", 1.2)
		KEY_C:
			lux.blend_to_preset(DELCO, 1.2)
			_damage = 0.0
		KEY_A:
			lux.pulse_alarm_lights(1.0, 5.0)
		KEY_D:
			_damage = clampf(_damage + 0.25, 0.0, 1.0)
			lux.set_player_damage_intensity(_damage)
		KEY_P:
			_ps2 = not _ps2
			_set_ps2_lighting(1.0 if _ps2 else 0.0)
	_update_hint()


## Toggle the vertex-lit look on the sample's LEVEL-role surfaces. The LEVEL role
## uses native engine vertex shading (StandardMaterial3D), so this flips
## SHADING_MODE_PER_VERTEX to show per-vertex vs per-pixel. (Stylized ShaderMaterials,
## if any, get the ps2_lighting blend instead.)
func _set_ps2_lighting(amount: float) -> void:
	var per_vertex := amount > 0.5
	for mi in get_tree().get_nodes_in_group(&"lux_materials"):
		if mi is MeshInstance3D:
			for s in (mi as MeshInstance3D).get_surface_count():
				var mat := (mi as MeshInstance3D).get_surface_override_material(s)
				if mat is ShaderMaterial:
					(mat as ShaderMaterial).set_shader_parameter(&"ps2_lighting", amount)
					(mat as ShaderMaterial).set_shader_parameter(&"mach_band_emphasis", amount)
				elif mat is BaseMaterial3D:
					LuxVertexShading.set_material_per_vertex(mat, per_vertex)


func _toggle_lux() -> void:
	_lux_enabled = not _lux_enabled
	var we := _find_world_env()
	if we == null:
		return
	if _lux_enabled:
		lux.blend_to_preset(DELCO, 0.0)
	else:
		we.environment = _fallback_env


func _find_world_env() -> WorldEnvironment:
	for c in lux.get_children():
		if c is WorldEnvironment:
			return c
		if c is LuxEnvironment:
			return (c as LuxEnvironment).world_env
	return null


func _update_hint() -> void:
	if hint == null:
		return
	var state := "ON" if _lux_enabled else "OFF (raw scene)"
	var ps2 := "  |  PS2 lighting: %s" % ("ON" if _ps2 else "off")
	hint.text = (
		"LUX SAMPLE — Lux: %s%s\n[Space] before/after   [1-5] presets   [H] hot   [C] calm   [A] alarm   [D] damage   [P] PS2 Gouraud"
		% [state, ps2]
	)
