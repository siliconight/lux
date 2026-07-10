@tool
@icon("res://addons/skymint/icon.svg")
class_name SkyMint
extends WorldEnvironment

## Drop-in dynamic skybox for Godot 4.
##
## One node = a runtime sky built from the Velvet Katana fake-volumetric
## cloud shader layered over the retro skybox panoramas. Drives a full
## day/night cycle (sun arc + colors + brightness) and can sync the
## time-of-day / look across clients in multiplayer.
##
## Plug & play:
##   1. Add a SkyMint node to your 3D scene.
##   2. (optional) Drag a DirectionalLight3D into "Sun Light".
##   3. Press play. Tweak time_of_day / day_length / colors live.
##
## Multiplayer:  the look is a pure function of `time_of_day` + the
## shared profile, so syncing time_of_day syncs the whole sky. It is
## client-side only and does NOT need to be deterministic — clouds
## drift independently per client; only the time/colors line up.

# ---------------------------------------------------------------------
enum SkyBox {
	TECHNO, APOCALYPSE, APOCALYPSE_LAND, APOCALYPSE_OCEAN,
	CLASSIC, CLASSIC_LAND, CLEAR, CLEAR_OCEAN, DAWN, DUSK,
	DUSK_LAND, DUSK_OCEAN, EMPTY_SPACE, GRAY, MOODY, NETHERWORLD,
	SINISTER, SINISTER_LAND, SINISTER_OCEAN, SUNSHINE,
}

const _SLUGS := [
	"techno", "apocalypse", "apocalypse_land", "apocalypse_ocean",
	"classic", "classic_land", "clear", "clear_ocean", "dawn", "dusk",
	"dusk_land", "dusk_ocean", "empty_space", "gray", "moody", "netherworld",
	"sinister", "sinister_land", "sinister_ocean", "sunshine",
]
const _PANO_DIR := "res://addons/skymint/panoramas/"
const _SHADER_PATH := "res://addons/skymint/skymint_sky.gdshader"

# ---------------------------------------------------------------------
@export_group("Time of Day")
## 0-24 hour clock. 0 = midnight, 12 = noon. Drives the whole look.
@export_range(0.0, 24.0, 0.001) var time_of_day := 9.0:
	set(v):
		time_of_day = wrapf(v, 0.0, 24.0)
		_dirty = true
@export var paused := false
## Real seconds for one full 24h cycle (600 = a 10 minute day).
@export var day_length_seconds := 600.0
## Let the cycle advance inside the editor too (off by default).
@export var animate_in_editor := false

@export_group("Skyboxes")
## Retro skybox shown during the day.
@export var day_sky: SkyBox = SkyBox.CLEAR:
	set(v): day_sky = v; _textures_dirty = true; _dirty = true
## Retro skybox shown at night (crossfaded via the profile's night_blend).
@export var night_sky: SkyBox = SkyBox.EMPTY_SPACE:
	set(v): night_sky = v; _textures_dirty = true; _dirty = true

@export_group("Look")
## Day/night curves + gradients. Leave empty for the built-in default.
@export var profile: SkyMintProfile:
	set(v): profile = v; _dirty = true
## Extra overall brightness multiplier on top of the profile.
@export_range(0.0, 4.0) var brightness := 1.0

@export_group("Sun")
## Optional. The node points this light along the sun's arc and tints
## it from the profile, so your 3D scene lighting matches the sky.
@export var sun_light: DirectionalLight3D
## South/north lean of the sun's path (-1..1).
@export_range(-1.0, 1.0) var sun_axis_tilt := -0.35
## Rotate which compass direction the sun rises from (radians).
@export_range(-3.1416, 3.1416) var sun_path_offset := 0.0

@export_group("Clouds")
@export_range(0.0, 1.0) var cloud_density := 0.52:
	set(v): cloud_density = v; _dirty = true
@export var cloud_scale := 1.9:
	set(v): cloud_scale = v; _dirty = true
@export var cloud_speed := 0.01:
	set(v): cloud_speed = v; _dirty = true
@export var cloud_direction := Vector2(0.0, -1.0):
	set(v): cloud_direction = v; _dirty = true
@export_range(0.0, 1.0) var cloud_softness := 0.16:
	set(v): cloud_softness = v; _dirty = true
@export_range(0.0, 2.0) var cloud_coverage_at_zenith := 1.0:
	set(v): cloud_coverage_at_zenith = v; _dirty = true

@export_group("Color Overrides")
## When on, these freeze a value regardless of time of day. They are
## included in the sync state, so overrides stay consistent across clients.
@export var override_sky_tint := false
@export var sky_tint_override := Color.WHITE
@export var override_cloud_bright := false
@export var cloud_bright_override := Color.WHITE

@export_group("Multiplayer Sync")
## Turn on to auto-broadcast time/look from the authority to all peers.
@export var sync_enabled := false
## Seconds between broadcasts (clients smoothly correct between them).
@export var sync_interval := 2.0
## If true, the server (peer 1) is the authority. If false, this node's
## multiplayer authority is used (set it yourself with set_multiplayer_authority).
@export var sync_is_server_authority := true

# ---------------------------------------------------------------------
signal time_changed(time_of_day: float)
signal state_applied(state: Dictionary)

var _mat: ShaderMaterial
var _sky: Sky
var _noise: NoiseTexture2D
var _default_profile: SkyMintProfile
var _dirty := true
var _textures_dirty := true
var _built := false
var _sync_accum := 0.0
var _net_target := -1.0          # smoothing target time_of_day from network


# =====================================================================
func _ready() -> void:
	_ensure_built()
	if not Engine.is_editor_hint() and sync_enabled and sync_is_server_authority:
		# server drives the sky for everyone
		set_multiplayer_authority(1)
	_dirty = true
	_textures_dirty = true


func _process(delta: float) -> void:
	_ensure_built()

	var advancing := not paused and (not Engine.is_editor_hint() or animate_in_editor)
	if advancing:
		time_of_day = wrapf(time_of_day + delta / max(day_length_seconds, 0.001) * 24.0, 0.0, 24.0)

	# smoothly correct toward the last network time (clients only)
	if _net_target >= 0.0:
		time_of_day = _ring_lerp(time_of_day, _net_target, clamp(delta * 1.5, 0.0, 1.0))
		if absf(_ring_diff(time_of_day, _net_target)) < 0.01:
			_net_target = -1.0

	_apply()

	# authority broadcasts on an interval
	if not Engine.is_editor_hint() and sync_enabled and _is_authority() \
			and multiplayer.has_multiplayer_peer():
		_sync_accum += delta
		if _sync_accum >= sync_interval:
			_sync_accum = 0.0
			_net_recv.rpc(get_sync_state())


# =====================================================================
#  BUILD
# =====================================================================
func _ensure_built() -> void:
	if _built:
		if _textures_dirty:
			_assign_textures()
		return

	if environment == null:
		environment = Environment.new()
	environment.background_mode = Environment.BG_SKY

	_mat = ShaderMaterial.new()
	_mat.shader = load(_SHADER_PATH)

	_noise = NoiseTexture2D.new()
	_noise.width = 512
	_noise.height = 512
	_noise.seamless = true
	_noise.generate_mipmaps = true
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_PERLIN
	fn.frequency = 0.012
	fn.fractal_octaves = 5
	_noise.noise = fn
	_mat.set_shader_parameter("cloud_noise_texture", _noise)

	_sky = Sky.new()
	_sky.sky_material = _mat
	_sky.process_mode = Sky.PROCESS_MODE_REALTIME   # animated clouds in reflections
	_sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment.sky = _sky

	_built = true
	_assign_textures()


func _assign_textures() -> void:
	_mat.set_shader_parameter("base_sky_texture", _load_pano(day_sky))
	_mat.set_shader_parameter("base_sky_texture_2", _load_pano(night_sky))
	_textures_dirty = false


func _load_pano(s: SkyBox) -> Texture2D:
	return load(_PANO_DIR + _SLUGS[int(s)] + ".png") as Texture2D


func _active_profile() -> SkyMintProfile:
	if profile:
		return profile
	if _default_profile == null:
		_default_profile = SkyMintProfile.make_default()
	return _default_profile


# =====================================================================
#  DRIVE THE LOOK
# =====================================================================
func _apply() -> void:
	if not _built:
		return
	var p := _active_profile()
	var t := time_of_day / 24.0

	# --- sun arc ---
	var sun_dir := _sun_direction_for(time_of_day)
	_mat.set_shader_parameter("sun_direction", sun_dir)

	# --- colors / scalars from the profile ---
	var tint := p.sample_color(p.sky_tint, t)
	if override_sky_tint:
		tint = sky_tint_override
	_mat.set_shader_parameter("sky_tint", tint)

	var exposure := p.sample_scalar(p.sky_exposure, t, 1.0) * brightness
	_mat.set_shader_parameter("sky_exposure", exposure)

	_mat.set_shader_parameter("sun_color", p.sample_color(p.sun_color, t))
	_mat.set_shader_parameter("sun_intensity", p.sample_scalar(p.sun_intensity, t, 14.0))

	var cb := p.sample_color(p.cloud_bright_color, t)
	if override_cloud_bright:
		cb = cloud_bright_override
	_mat.set_shader_parameter("cloud_bright_color", cb)
	_mat.set_shader_parameter("cloud_mid_color", p.sample_color(p.cloud_mid_color, t))
	_mat.set_shader_parameter("cloud_dark_color", p.sample_color(p.cloud_dark_color, t))
	_mat.set_shader_parameter("cloud_brightness", p.sample_scalar(p.cloud_brightness, t, 1.15))

	_mat.set_shader_parameter("base_sky_blend", p.sample_scalar(p.night_blend, t, 0.0))

	# --- cloud passthrough ---
	_mat.set_shader_parameter("cloud_density", cloud_density)
	_mat.set_shader_parameter("cloud_scale", cloud_scale)
	_mat.set_shader_parameter("cloud_speed", cloud_speed)
	_mat.set_shader_parameter("cloud_direction", cloud_direction)
	_mat.set_shader_parameter("cloud_softness", cloud_softness)
	_mat.set_shader_parameter("zenith_density", cloud_coverage_at_zenith)

	# --- drive the real scene light ---
	if sun_light:
		if sun_light.is_inside_tree():
			_aim_light(sun_light, sun_dir)
		sun_light.light_color = p.sample_color(p.light_color, t)
		sun_light.light_energy = p.sample_scalar(p.light_energy, t, 1.0)
		# below the horizon? dim to a moonlight floor
		if sun_dir.y > 0.02:
			sun_light.light_energy = minf(sun_light.light_energy, 0.06)

	emit_signal("time_changed", time_of_day)
	_dirty = false


func _sun_direction_for(tod: float) -> Vector3:
	# phi: 0 at 6h (rise), PI at 18h (set); sun above horizon for phi in (0,PI)
	var phi := (tod - 6.0) / 12.0 * PI
	var sun_pos := Vector3(cos(phi), sin(phi), sun_axis_tilt)
	sun_pos = sun_pos.rotated(Vector3.UP, sun_path_offset).normalized()
	# shader sun_direction = direction the light travels (sun -> ground)
	return -sun_pos


func _aim_light(light: DirectionalLight3D, dir: Vector3) -> void:
	# DirectionalLight3D emits along its local -Z, so -Z must equal `dir`.
	var target := light.global_position + dir
	var up := Vector3.UP
	if absf(dir.normalized().dot(Vector3.UP)) > 0.99:
		up = Vector3.FORWARD
	light.look_at(target, up)


# =====================================================================
#  MULTIPLAYER  (client-side, non-deterministic)
# =====================================================================
func _is_authority() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	if sync_is_server_authority:
		return multiplayer.is_server()
	return is_multiplayer_authority()


## Compact snapshot of everything needed to reproduce the sky elsewhere.
func get_sync_state() -> Dictionary:
	var d := {
		"t": time_of_day,
		"dl": day_length_seconds,
		"p": paused,
		"ds": int(day_sky),
		"ns": int(night_sky),
		"b": brightness,
		"cd": cloud_density,
		"cs": cloud_speed,
	}
	if override_sky_tint:
		d["ost"] = sky_tint_override
	if override_cloud_bright:
		d["ocb"] = cloud_bright_override
	return d


## Apply a snapshot from get_sync_state(). When smooth is true the time
## eases in over a couple frames instead of snapping.
func apply_sync_state(state: Dictionary, smooth := true) -> void:
	if state.has("dl"): day_length_seconds = state["dl"]
	if state.has("p"):  paused = state["p"]
	if state.has("b"):  brightness = state["b"]
	if state.has("cd"): cloud_density = state["cd"]
	if state.has("cs"): cloud_speed = state["cs"]
	if state.has("ds"): day_sky = int(state["ds"])
	if state.has("ns"): night_sky = int(state["ns"])

	override_sky_tint = state.has("ost")
	if override_sky_tint: sky_tint_override = state["ost"]
	override_cloud_bright = state.has("ocb")
	if override_cloud_bright: cloud_bright_override = state["ocb"]

	if state.has("t"):
		if smooth:
			_net_target = wrapf(state["t"], 0.0, 24.0)
		else:
			time_of_day = state["t"]
			_net_target = -1.0

	_dirty = true
	emit_signal("state_applied", state)


## Bytes helpers for users who pipe their own packets.
func get_sync_bytes() -> PackedByteArray:
	return var_to_bytes(get_sync_state())


func apply_sync_bytes(bytes: PackedByteArray, smooth := true) -> void:
	var v = bytes_to_var(bytes)
	if v is Dictionary:
		apply_sync_state(v, smooth)


@rpc("authority", "call_remote", "unreliable_ordered")
func _net_recv(state: Dictionary) -> void:
	apply_sync_state(state, true)


# =====================================================================
#  HELPERS
# =====================================================================
func _ring_diff(a: float, b: float) -> float:
	# shortest signed distance a->b on a 24h ring
	var d := fmod(b - a + 36.0, 24.0) - 12.0
	return d


func _ring_lerp(a: float, b: float, w: float) -> float:
	return wrapf(a + _ring_diff(a, b) * w, 0.0, 24.0)
