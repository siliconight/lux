@tool
class_name LuxSkyProvider
extends Node
## Puts the level's own light back in the sky when a SKY PROVIDER owns it.
##
## Created by LuxRoot only when a provider is present. Does nothing, and
## costs nothing, in a level with no provider.
##
## ## WHY THIS EXISTS
##
## `docs/skymint_integration.md` splits the scene cleanly: the provider owns
## the sky, Lux owns the grade, on one shared Environment. That works --
## measured on cold run 9088's package, one WorldEnvironment carrying
## delco_night's ambient 0.55 and exposure 1.05 with the provider's
## ShaderMaterial sky.
##
## What it does NOT cover is the DISC. Lux's own `ProceduralSkyMaterial`
## draws the `DirectionalLight3D` as a visible sun or moon; a provider's sky
## draws whatever its own profile says, and SkyMint's default profile puts
##
##     night_blend    1.0 only for t <= 0.20 and t >= 0.80
##     sun_intensity  0.0 outside t in [0.23, 0.77]
##
## in windows that never overlap -- so a night panorama can never carry a
## moon. Adopting a provider therefore takes the moon out of a night sky
## while leaving its light on the level, which is exactly what the walker
## saw: "definitely reads as night and the moons light is actually great
## now" two days before the sky went empty above it.
##
## ## WHAT IT WRITES, AND WHY FROM THE LIGHT
##
## `sun_direction` comes from the linked DirectionalLight3D, NOT from the
## provider's time-of-day. A `DirectionalLight3D` casts along -basis.z, so
## the body it stands for lies along +basis.z from the viewer. That puts the
## disc exactly where the light comes from, which is the rule the fixtures
## already follow -- light comes from a light source -- and it means a level
## can keep a tuned moon angle (delco_night: elevation 38, azimuth 300)
## without the sky arguing with it.
##
## ## NO HARD DEPENDENCY
##
## It never names SkyMint, never loads its classes and never touches its
## exports. It writes two SHADER PARAMETERS, and only after checking the
## shader actually declares them, so an unrelated sky shader is left alone
## rather than having unknown uniforms pushed at it.
##
## ## COST
##
## Two `set_shader_parameter` calls per frame, constant, independent of prop
## count and player count. The provider rewrites these every frame from its
## own profile, so they have to be rewritten after it -- `process_priority`
## is raised so this runs late in the frame.

## The parameters this drives. A shader that declares neither is not a sky
## this node can help with, and it says so once rather than every frame.
const P_INTENSITY := "sun_intensity"
const P_DIRECTION := "sun_direction"
const P_SIZE := "sun_size"

## The WorldEnvironment whose sky is owned by someone else. Set by LuxRoot.
var provider: WorldEnvironment

## The light the disc stands for. Set by LuxRoot from its resolved sun link.
var sun: DirectionalLight3D

## Brightness of the disc in the provider's sky. 0 leaves the provider's own
## value alone, which is the right default for a daylight preset where the
## provider already draws a sun.
var disc_intensity: float = 0.0

## Angular size of the disc. Godot's own reference figure for the real moon
## is about half a degree; this is a look dial, not an astronomical one.
var disc_size: float = 0.004

var _mat: ShaderMaterial
var _has_intensity := false
var _has_direction := false
var _has_size := false
var _checked := false


func _ready() -> void:
	# LATE IN THE FRAME. The provider writes these same parameters from its
	# own profile every frame, so writing them earlier would be overwritten.
	process_priority = 100
	set_process(true)


## Looks up which of the three parameters the sky shader actually declares.
## Done once, against the shader's uniform list rather than by writing and
## hoping: `set_shader_parameter` on a name the shader does not declare is
## silently ignored, so a hopeful write is indistinguishable from a working
## one.
func _check(mat: ShaderMaterial) -> void:
	_checked = true
	_mat = mat
	_has_intensity = false
	_has_direction = false
	_has_size = false
	if mat == null or mat.shader == null:
		return
	for u in mat.shader.get_shader_uniform_list():
		var n := String(u.get("name", ""))
		if n == P_INTENSITY:
			_has_intensity = true
		elif n == P_DIRECTION:
			_has_direction = true
		elif n == P_SIZE:
			_has_size = true
	if not (_has_intensity or _has_direction):
		# BUILD THE JOINED STRING FIRST. `%` binds tighter than `+`, so a
		# format split across a `+` formats each half separately -- correct
		# here by luck, and one of the four traps `tools/gdcheck.py` refuses
		# on sight. Not worth being clever in a warning.
		var msg := "Lux: the sky provider's shader declares neither %s nor %s; leaving its sky alone."
		push_warning(msg % [P_INTENSITY, P_DIRECTION])


func _process(_delta: float) -> void:
	if provider == null or provider.environment == null:
		return
	var sky: Sky = provider.environment.sky
	if sky == null:
		return
	var mat: ShaderMaterial = sky.sky_material as ShaderMaterial
	if mat == null:
		return
	if not _checked or mat != _mat:
		_check(mat)
	if _has_direction and sun != null and sun.is_inside_tree():
		# a DirectionalLight3D casts along -basis.z, so the body it stands
		# for lies along +basis.z from the viewer
		mat.set_shader_parameter(P_DIRECTION,
			sun.global_transform.basis.z.normalized())
	if disc_intensity > 0.0:
		if _has_intensity:
			mat.set_shader_parameter(P_INTENSITY, disc_intensity)
		if _has_size:
			mat.set_shader_parameter(P_SIZE, disc_size)
