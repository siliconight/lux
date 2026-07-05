@tool
class_name LuxQualityProfile
extends Resource
## Feature switches and budgets for High / Medium / Low / Compatibility tiers
## (TDD §14). LuxRoot consults this when applying a preset so expensive effects
## can be stripped while preserving the core art direction.

@export_enum("High", "Medium", "Low", "Compatibility") var tier: int = 0

@export_group("Feature Switches")
@export var allow_post_fx: bool = true
@export var allow_dithering: bool = true
@export var allow_glow: bool = true
@export var allow_sun_shadows: bool = true
@export var allow_volumetric_fog: bool = true

@export_group("Budgets")
@export var max_dynamic_lights: int = 24
@export var max_shadow_casters: int = 8
@export var shadow_max_distance: float = 100.0


static func make_tier(t: int) -> LuxQualityProfile:
	var q := LuxQualityProfile.new()
	q.tier = t
	match t:
		0:  # High
			pass
		1:  # Medium
			q.shadow_max_distance = 45.0
			q.max_dynamic_lights = 16
			q.allow_volumetric_fog = false
		2:  # Low
			q.allow_post_fx = false
			q.allow_glow = false
			q.allow_sun_shadows = false
			q.allow_volumetric_fog = false
			q.max_dynamic_lights = 8
			q.max_shadow_casters = 0
			q.dither_note()
		3:  # Compatibility
			q.allow_post_fx = false
			q.allow_dithering = false
			q.allow_glow = false
			q.allow_sun_shadows = false
			q.allow_volumetric_fog = false
			q.max_dynamic_lights = 6
			q.max_shadow_casters = 0
	return q


func dither_note() -> void:
	# Low keeps dithering available but the preset is expected to reduce strength.
	allow_dithering = true
