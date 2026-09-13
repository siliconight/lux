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
## Hardware permission for film emulsion (TDD section 13). The middle of the
## three keys: a preset may ask for film and the player may leave it on, and
## this still refuses on a tier that cannot afford it. Allowed on High and
## Medium, disabled on Low and Compatibility.
@export var allow_film_emulsion: bool = true

@export_group("Budgets")
@export var max_dynamic_lights: int = 24
## FIXTURE SHADOW MAPS THE TIER MAY SPEND (roadmap 60). An unshadowed light
## illuminates everything in range with walls never consulted -- collision
## never blocks light, only a shadow map does -- and GL Compatibility pays
## per shadowed light, so a level cannot shadow all of its ~60. LuxLighting
## ranks every rig light by how much its through-wall wash is worth
## stopping (area rigs on the envelope first, then bare bulbs, then wall
## packs and streetlights, then the fluorescent rows) and enables shadows on
## the first `max_shadow_casters`, disabling the rest. Low and Compatibility
## keep 4: the area rigs, the class item 60 measured as affordable first.
##
## PRICED, 2026-09-11, RTX 2060, GL Compatibility, 1600x900, cold run 9005's
## export (58 lights), GPU ms per frame from the engine's own timestamps:
##
##     casters   elev_N   elev_S   elev_E   elev_W   interior x3
##           0     5.5      3.1      2.8      2.7    2.0  2.7  3.3
##           4     7.7      4.2      3.9      4.2    3.1  3.3  3.4
##          24    13.3      9.1      8.4      8.7    7.8  4.1  4.6
##
## About 0.3 ms per shadowed omni on an exterior view, ~0.5 for the first
## few. 24 casters put an exterior at 8-13 ms -- half to three quarters of a
## 60 fps frame at a modest resolution -- so "High shadows everything" is not
## a tier, it is a slideshow. High spends 12 (+3.9 ms, under a quarter of the
## 60 fps frame), Medium 8 (+2.6), Low and Compatibility 4 (+1.3).
@export var max_shadow_casters: int = 12
@export var shadow_max_distance: float = 100.0
## RAIN DROPS THE TIER MAY KEEP ALIVE AT ONCE. The applied count is
## min(weather.rain_amount, this); 0 turns rain off on the tier.
## High 9000, Medium 6000, Low 3000, Compatibility 2000.
##
## NOT PRICED WHERE IT MATTERS. On an RTX 2060, GL Compatibility, 1600x900,
## cold run 9048's walk copy, vsync off, median of 4 rounds x 400 frames
## (lux/tools/rain_walk_probe.py), rain against no rain:
##
##     station          drops   frame ms   viewport GPU ms
##     looking up        9000    +0.055       +0.016
##     looking up       36000    +0.023       +0.060
##     street, facade    2000    +0.67        +0.21
##     street, facade    9000    +0.12        +0.07
##     street, facade   36000    +0.46        +0.20
##
## The street rows are inside that station's own run-to-run spread (0.5 ms),
## so this card cannot tell 2000 drops from 36000. The caps below High are
## a guess for weaker GPUs, and no weaker GPU has measured them.
@export var max_rain_drops: int = 9000


static func make_tier(t: int) -> LuxQualityProfile:
	var q := LuxQualityProfile.new()
	q.tier = t
	match t:
		0:  # High
			q.max_shadow_casters = 12
		1:  # Medium
			q.shadow_max_distance = 45.0
			q.max_dynamic_lights = 16
			q.max_shadow_casters = 8
			q.allow_volumetric_fog = false
			q.max_rain_drops = 6000
		2:  # Low
			q.allow_post_fx = false
			q.allow_glow = false
			q.allow_sun_shadows = false
			q.allow_volumetric_fog = false
			q.max_dynamic_lights = 8
			q.max_shadow_casters = 4
			q.allow_film_emulsion = false
			q.max_rain_drops = 3000
			q.dither_note()
		3:  # Compatibility
			q.allow_post_fx = false
			q.allow_dithering = false
			q.allow_glow = false
			q.allow_sun_shadows = false
			q.allow_volumetric_fog = false
			q.max_dynamic_lights = 6
			q.max_shadow_casters = 4
			q.allow_film_emulsion = false
			q.max_rain_drops = 2000
	return q


func dither_note() -> void:
	# Low keeps dithering available but the preset is expected to reduce strength.
	allow_dithering = true
