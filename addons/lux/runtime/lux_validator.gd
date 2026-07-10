@tool
class_name LuxValidator
extends RefCounted
## Scans a scene rooted at a LuxRoot and returns human-readable warnings:
## missing WorldEnvironment, excessive lights/shadow casters, expensive post FX
## combinations, unsupported renderer settings (TDD §12, §18).

enum Severity { OK, INFO, WARN, ERROR }


class Finding:
	var severity: int
	var message: String

	func _init(s: int, m: String) -> void:
		severity = s
		message = m


static func validate(root: LuxRoot) -> Array:
	var findings: Array = []
	if root == null:
		findings.append(Finding.new(Severity.ERROR, "No LuxRoot provided."))
		return findings

	# --- Preset present? ---
	var preset: LuxPreset = root.active_preset
	if root.local_override != null:
		preset = root.local_override
	if preset == null:
		findings.append(
			Finding.new(
				Severity.ERROR, "No active preset assigned. Assign a LuxPreset to see a look."
			)
		)

	# --- WorldEnvironment present? ---
	var has_world_env := false
	for c in root.get_children():
		if c is WorldEnvironment:
			has_world_env = true
		if c is LuxEnvironment and (c as LuxEnvironment).world_env != null:
			has_world_env = true
	if not _scene_has_world_environment(root) and not has_world_env:
		findings.append(
			Finding.new(Severity.WARN, "No WorldEnvironment found; Lux will create one at runtime.")
		)

	# --- Light budget ---
	var quality: LuxQualityProfile = root.get_quality_profile()
	if quality == null:
		quality = LuxQualityProfile.make_tier(root.quality_tier)
	var lights: Dictionary = _count_nodes_of_type(
		root.get_tree().edited_scene_root if Engine.is_editor_hint() and root.get_tree() else root,
		"Light3D"
	)
	var omni_spot: int = lights.omni + lights.spot
	if omni_spot > quality.max_dynamic_lights:
		findings.append(
			Finding.new(
				Severity.WARN,
				(
					"%d dynamic omni/spot lights exceed the %s-tier budget of %d."
					% [omni_spot, _tier_name(quality.tier), quality.max_dynamic_lights]
				)
			)
		)
	var shadow_casters: int = lights.shadowed
	if shadow_casters > quality.max_shadow_casters:
		findings.append(
			Finding.new(
				Severity.WARN,
				(
					"%d shadow-casting lights exceed the %s-tier budget of %d."
					% [shadow_casters, _tier_name(quality.tier), quality.max_shadow_casters]
				)
			)
		)

	# --- AreaLight3D (Godot 4.7): clustered element, unsupported on Compatibility ---
	if lights.area > 0:
		if quality.tier == 3:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							(
								"%d AreaLight3D(s) present; on the Compatibility tier Lux rigs fall back to omni lights."
								% lights.area
							)
						)
					)
				)
			)
		var clustered: int = lights.omni + lights.spot + lights.area
		if clustered > 128:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							(
								"%d clustered light elements (omni+spot+area); the Forward+ default cluster budget is 512."
								% clustered
							)
						)
					)
				)
			)

	# --- Native vertex shading (Godot 4.4+) notes ---
	if preset != null and preset.vertex_shading_mode == 1:
		if not LuxVertexShading.native_available():
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.WARN,
							"Preset asks for Native Engine vertex shading, but this engine build is pre-4.4; falling back to per-pixel."
						)
					)
				)
			)
		else:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							"Native vertex shading: only the first DirectionalLight3D casts shadows on vertex-lit surfaces (Forward+/Mobile); omni/spot rigs won't shadow."
						)
					)
				)
			)
	elif preset != null and preset.vertex_shading_mode == 2:
		(
			findings
			. append(
				(
					Finding
					. new(
						Severity.INFO,
						"Lux Stylized Gouraud keeps banding/palette but approximates from the key light only; use Native Engine mode for true multi-light vertex lighting."
					)
				)
			)
		)

	# --- Sun link (vertex world relight) ---
	if preset != null and (preset.vertex_shading_mode > 0 or preset.ps2_lighting_global >= 0.0):
		if root.sun_light != null:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							"Sun Link active: the vertex-lit look tracks a live DirectionalLight3D (e.g. SkyMint), so a moving/synced sun relights the world."
						)
					)
				)
			)
		elif root.auto_find_skymint:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							"No Sun Link assigned; Lux will borrow a SkyMint sun if present, else use the preset's static sun for vertex lighting."
						)
					)
				)
			)

	# --- Expensive post combinations ---
	if preset != null:
		if preset.dither_enabled and preset.dither_cell_size == 1 and preset.color_levels < 8:
			(
				findings
				. append(
					(
						Finding
						. new(
							Severity.INFO,
							(
								"Very low color_levels (%d) with per-pixel dithering can look muddy in motion."
								% preset.color_levels
							)
						)
					)
				)
			)
		if preset.glow_enabled and preset.dither_enabled and quality.tier >= 2:
			findings.append(
				Finding.new(
					Severity.WARN,
					"Glow + dithering are both enabled on a low tier; consider disabling glow."
				)
			)
		if preset.fog_height_density != 0.0 and quality.tier == 3:
			findings.append(
				Finding.new(
					Severity.INFO, "Height fog on Compatibility tier may not render; use flat fog."
				)
			)

	# --- Renderer hint ---
	var method: RenderingDevice = RenderingServer.get_rendering_device()
	if method == null:
		(
			findings
			. append(
				(
					Finding
					. new(
						Severity.INFO,
						"Compatibility renderer detected. Post FX and dithering are reduced; Lux falls back to material stylization."
					)
				)
			)
		)

	if findings.is_empty():
		findings.append(Finding.new(Severity.OK, "No issues found. Lux is ready."))
	return findings


static func _scene_has_world_environment(root: Node) -> bool:
	var top: Node = root
	if (
		Engine.is_editor_hint()
		and root.get_tree() != null
		and root.get_tree().edited_scene_root != null
	):
		top = root.get_tree().edited_scene_root
	return _find_type(top, "WorldEnvironment") != null


static func _find_type(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for c in node.get_children():
		var r: Node = _find_type(c, type_name)
		if r != null:
			return r
	return null


static func _count_nodes_of_type(node: Node, base: String) -> Dictionary:
	var result := {"omni": 0, "spot": 0, "directional": 0, "area": 0, "shadowed": 0}
	_walk_lights(node, result)
	return result


static func _walk_lights(node: Node, result: Dictionary) -> void:
	if node is OmniLight3D:
		result.omni += 1
	elif node is SpotLight3D:
		result.spot += 1
	elif node is DirectionalLight3D:
		result.directional += 1
	elif node.is_class(&"AreaLight3D"):
		result.area += 1
	if node is Light3D and (node as Light3D).shadow_enabled:
		result.shadowed += 1
	for c in node.get_children():
		_walk_lights(c, result)


static func _tier_name(t: int) -> String:
	return ["High", "Medium", "Low", "Compatibility"][clampi(t, 0, 3)]
