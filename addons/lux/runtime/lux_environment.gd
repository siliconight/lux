@tool
class_name LuxEnvironment
extends Node
## Owns WorldEnvironment configuration: sky, ambient, fog, glow, tonemapping,
## exposure, and color correction. Builds an Environment from a LuxPreset.
## Child of LuxRoot; created automatically if missing.

var world_env: WorldEnvironment

## When true, Lux never authors the sky — it assumes a sky provider (SkyMint or
## any node that sets its own sky material) owns it, and Lux writes only the
## grade. Auto-detected per-apply when left false; set true to force.
var defer_sky := false


func _sky_is_provided(env: Environment) -> bool:
	# A provider owns the sky if it set a non-Procedural sky material (SkyMint
	# uses a ShaderMaterial). Lux authors only ProceduralSkyMaterial, so anything
	# else means "someone else is driving the sky — leave it alone."
	if defer_sky:
		return true
	if env.sky != null and env.sky.sky_material != null:
		return not (env.sky.sky_material is ProceduralSkyMaterial)
	return false


func ensure_world_environment(parent: Node) -> void:
	if world_env != null and is_instance_valid(world_env):
		return
	# Reuse an existing WorldEnvironment if the level already has one — including
	# a sky provider like SkyMint (which IS a WorldEnvironment). Check the parent's
	# children first, then the wider scene, so Lux writes its grade onto the
	# provider's environment instead of making a second, conflicting one.
	var found: WorldEnvironment = _find_world_environment(parent)
	if found != null:
		world_env = found
		return
	world_env = WorldEnvironment.new()
	world_env.name = &"LuxWorldEnvironment"
	parent.add_child(world_env)
	if Engine.is_editor_hint() and parent.get_tree() != null:
		world_env.owner = parent.get_tree().edited_scene_root


func _find_world_environment(parent: Node) -> WorldEnvironment:
	# direct children first (the common case), then the whole scene tree.
	for c in parent.get_children():
		if c is WorldEnvironment:
			return c
	var root: Node = parent.get_tree().current_scene if parent.get_tree() != null else null
	if root != null:
		return _search_world_environment(root)
	return null


func _search_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node
	for c in node.get_children():
		var r: WorldEnvironment = _search_world_environment(c)
		if r != null:
			return r
	return null


func apply(preset: LuxPreset, quality: LuxQualityProfile) -> void:
	if preset == null or world_env == null:
		return
	var env: Environment = world_env.environment
	if env == null:
		env = Environment.new()
		world_env.environment = env

	# --- Sky ---
	# When a sky *provider* (e.g. SkyMint) owns this environment, it has already
	# built the sky (panorama + clouds + day/night) as a ShaderMaterial. Lux is
	# the look authority but NOT the sky author in that case: skip the sky block
	# so we don't stomp the provider's material, and write only the grade
	# (tonemap/exposure/fog/glow/adjustment) onto the shared environment.
	if not _sky_is_provided(env):
		var sky: Sky = env.sky
		if sky == null:
			sky = Sky.new()
			env.sky = sky
		var sky_mat: Material = sky.sky_material
		if not (sky_mat is ProceduralSkyMaterial):
			sky_mat = ProceduralSkyMaterial.new()
			sky.sky_material = sky_mat
		var psm := sky_mat as ProceduralSkyMaterial
		psm.sky_top_color = preset.sky_top_color
		psm.sky_horizon_color = preset.sky_horizon_color
		psm.ground_bottom_color = preset.ground_color
		psm.ground_horizon_color = preset.sky_horizon_color
		psm.sky_energy_multiplier = preset.sky_energy
		env.background_mode = Environment.BG_SKY

	# --- Ambient ---
	match preset.ambient_mode:
		1:  # Flat Color — GI-free uniform fill, the honest PS2-era look
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = preset.ambient_color
			env.ambient_light_energy = preset.ambient_energy
		2:  # Disabled
			env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		_:  # Sky
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_color = preset.ambient_color
			env.ambient_light_energy = preset.ambient_energy
			env.ambient_light_sky_contribution = preset.ambient_sky_contribution

	# --- Tonemap / exposure ---
	env.tonemap_mode = _tonemap_mode(preset.tonemap_mode)
	env.tonemap_exposure = preset.exposure
	env.tonemap_white = preset.tonemap_white

	# --- Fog ---
	env.fog_enabled = preset.fog_enabled
	if preset.fog_enabled:
		env.fog_light_color = preset.fog_color
		env.fog_density = preset.fog_density
		env.fog_sky_affect = preset.fog_sky_affect
		if preset.fog_height_density != 0.0:
			env.fog_height = preset.fog_height
			env.fog_height_density = preset.fog_height_density

	# --- Glow ---
	var glow_on := preset.glow_enabled and quality.allow_glow
	env.glow_enabled = glow_on
	if glow_on:
		env.glow_intensity = preset.glow_intensity
		env.glow_bloom = preset.glow_bloom
		env.glow_hdr_threshold = preset.glow_hdr_threshold
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	# --- Color correction ---
	env.adjustment_enabled = true
	env.adjustment_brightness = preset.brightness
	env.adjustment_contrast = preset.contrast
	env.adjustment_saturation = preset.saturation


func _tonemap_mode(mode: int) -> int:
	match mode:
		0:
			return Environment.TONE_MAPPER_LINEAR
		1:
			return Environment.TONE_MAPPER_REINHARDT
		2:
			return Environment.TONE_MAPPER_FILMIC
		3:
			return Environment.TONE_MAPPER_ACES
		_:
			return Environment.TONE_MAPPER_FILMIC


func get_environment() -> Environment:
	return world_env.environment if world_env != null else null
