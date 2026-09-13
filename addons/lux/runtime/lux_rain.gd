class_name LuxRain
extends GPUParticles3D
## Falling rain over the active camera, built from a LuxWeatherProfile.
##
## LuxRoot creates one of these while the applied preset's weather has
## `rain_enabled`, and frees it when the weather clears. It is runtime state:
## it has no owner, so `PackedScene.pack` never writes it into a level, and the
## level's rain comes back from the preset every time LuxRoot applies it.
##
## WHAT THE SHIPPED RENDERER CAN DO, measured by tools/rain_renderer_probe.gd
## on Godot 4.7 under GL Compatibility (0.35.0 changelog has the table):
##   * particle trails: NOT supported ("The Compatibility renderer does not
##     support particle trails"), so the streak is a vertical billboard quad,
##     not a ribbon trail. One path, the same look on every renderer.
##   * collision boxes, spheres and heightfields hide drops on contact.
##   * sub-emitters: NOT supported, so there are no splash rings here.
##   * volumetric fog: NOT supported; the preset's depth fog is what thickens
##     the air.
##
## THE EMITTER FOLLOWS `get_viewport().get_camera_3d()`, the camera the frame
## is drawn from, whatever node owns it. Particles live in world space
## (`local_coords` false) so a person walking through rain does not drag the
## drops along; a camera that jumps further than half the emitter radius in
## one frame restarts the system, and `preprocess` refills the column on the
## first drawn frame (measured: 60 bright pixels without it, 12,904 with it,
## 0.1 s after start).
##
## A camera far above the site (an overview) sees no rain: the column hangs
## `rain_emitter_height` over the camera and ends `rain_fall_below` under it.

## Set by tests to follow a camera that is not the viewport's.
var camera_override: Camera3D

var _profile: LuxWeatherProfile
var _drops: int = 0
var _signature: String = ""
var _last_anchor := Vector3.INF


## Drops this profile gets on this tier: min(profile, tier cap), never negative.
static func drops_for(profile: LuxWeatherProfile, quality: LuxQualityProfile) -> int:
	if profile == null or not profile.rain_enabled:
		return 0
	var cap: int = profile.rain_amount
	if quality != null:
		cap = mini(cap, quality.max_rain_drops)
	return maxi(cap, 0)


## Metres of fall a drop lives through: emitter height plus the fall below.
static func fall_column_m(profile: LuxWeatherProfile) -> float:
	return profile.rain_emitter_height + profile.rain_fall_below


func get_drops() -> int:
	return _drops


func get_profile() -> LuxWeatherProfile:
	return _profile


## Build or rebuild from a profile. Returns true when anything changed. Cheap
## to call every frame of a blend: an unchanged profile and count is one string
## compare and no restart. Compared by VALUE, not by resource: every
## `make_override` deep-copies the preset and its weather, and a restart per
## copy would refill the column visibly each time set_time_of_day runs.
func configure(profile: LuxWeatherProfile, quality: LuxQualityProfile) -> bool:
	var drops: int = drops_for(profile, quality)
	var sig: String = _signature_of(profile, drops)
	if sig == _signature:
		return false
	_signature = sig
	_profile = profile
	_drops = drops
	if drops <= 0:
		emitting = false
		return true

	var speed_max: float = profile.rain_fall_speed * (1.0 + profile.rain_speed_randomness)
	var column: float = fall_column_m(profile)
	# Lifetime at the MEAN speed: fast drops reach the bottom slightly early,
	# slow ones expire slightly above it. Either way the column is full.
	amount = drops
	lifetime = column / profile.rain_fall_speed
	preprocess = lifetime
	fixed_fps = profile.rain_fixed_fps
	interpolate = true
	fract_delta = true
	local_coords = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	trail_enabled = false

	# THE VISIBILITY AABB IS ALSO THE COLLIDER QUERY. Colliders outside it are
	# not consulted, so it has to hold the whole column plus the sideways
	# drift the spread allows, plus a streak length at each end.
	var drift: float = column * tan(deg_to_rad(profile.rain_spread_deg))
	var half: float = profile.rain_emitter_radius + drift
	var pad: float = profile.rain_streak_length
	visibility_aabb = AABB(
		Vector3(-half, -column - pad, -half),
		Vector3(half * 2.0, column + pad * 2.0, half * 2.0))

	process_material = _process_material(profile, speed_max)
	draw_pass_1 = _streak_mesh(profile)
	emitting = true
	restart()
	return true


func _signature_of(profile: LuxWeatherProfile, drops: int) -> String:
	if profile == null:
		return "none"
	return "%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%d|%s" % [
		drops, profile.rain_fall_speed, profile.rain_speed_randomness,
		profile.rain_spread_deg, profile.rain_streak_length,
		profile.rain_streak_width, profile.rain_color.to_html(true),
		profile.rain_emitter_radius, profile.rain_emitter_height,
		profile.rain_fall_below, profile.rain_enabled, profile.rain_fixed_fps,
		profile.rain_near_fade_m]


func _process_material(profile: LuxWeatherProfile, speed_max: float) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(profile.rain_emitter_radius, 0.0,
		profile.rain_emitter_radius)
	pm.direction = Vector3.DOWN
	pm.spread = profile.rain_spread_deg
	pm.initial_velocity_min = profile.rain_fall_speed * (1.0 - profile.rain_speed_randomness)
	pm.initial_velocity_max = speed_max
	pm.gravity = Vector3.ZERO
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	pm.collision_use_scale = false
	pm.color = profile.rain_color
	# Fade in over the first tenth of the fall so drops do not pop into
	# existence at the emitter plane when a person looks up.
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	g.set_offset(0, 0.0)
	g.set_color(1, Color(1.0, 1.0, 1.0, 1.0))
	g.set_offset(1, 0.1)
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	return pm


func _streak_mesh(profile: LuxWeatherProfile) -> QuadMesh:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	# Upright and turned to face the camera about world Y. Drops fall within
	# `rain_spread_deg` of vertical, so an upright streak is the right shape;
	# looking straight up or down it thins to a line, which is also what rain
	# looks like end-on.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.disable_receive_shadows = true
	if profile.rain_near_fade_m > 0.0:
		mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
		mat.distance_fade_min_distance = 0.0
		mat.distance_fade_max_distance = profile.rain_near_fade_m
	var q := QuadMesh.new()
	q.size = Vector2(profile.rain_streak_width, profile.rain_streak_length)
	q.material = mat
	return q


func _process(_delta: float) -> void:
	if _drops <= 0 or _profile == null:
		return
	var cam: Camera3D = camera_override
	if cam == null or not is_instance_valid(cam):
		var vp := get_viewport()
		cam = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	var anchor: Vector3 = cam.global_position + Vector3(0.0, _profile.rain_emitter_height, 0.0)
	var jumped: bool = (_last_anchor == Vector3.INF
		or _last_anchor.distance_to(anchor) > _profile.rain_emitter_radius * 0.5)
	global_position = anchor
	_last_anchor = anchor
	if jumped:
		restart()
