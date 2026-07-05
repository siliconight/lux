@tool
class_name LuxVertexShading
extends Object
## Bridges Lux to Godot's native vertex shading (added in 4.4, PR #83360).
##
## Native vertex shading is the authentic multi-light PSX path: the engine
## evaluates lighting per vertex with the simplified 3.x light model, sees ALL
## real-time lights (so Lux's omni/spot/area rigs all contribute), integrates
## with clustering, and casts pixel shadows from the first DirectionalLight3D on
## Forward+/Mobile. It is strictly better than a shader approximation for plain
## surfaces.
##
## The catch (godot-proposals #11866): native vertex shading forces the built-in
## Lambertian model — a ShaderMaterial's custom light() is ignored in this mode.
## So Lux offers two paths, chosen per preset/profile:
##   * NATIVE  — StandardMaterial3D with SHADING_MODE_PER_VERTEX. Real multi-light
##               vertex lighting + shadows, but no Lux banding/palette/Mach-bands.
##   * STYLIZED_GOURAUD — Lux's stylized shader ps2_lighting path. Keeps the
##               stylization; approximates from the pushed key light only.
##
## Enum values mirror LuxPreset.vertex_shading_mode:
##   0 = Off, 1 = Native Engine, 2 = Lux Stylized Gouraud.

const PROJECT_OVERRIDE := "rendering/shading/overrides/force_vertex_shading"


## True if this build exposes native vertex shading (Godot 4.4+).
static func native_available() -> bool:
	# SHADING_MODE_PER_VERTEX has existed as an enum for a while, but the working
	# implementation landed in 4.4. Gate on engine version to avoid enabling a
	# no-op on older builds.
	var v := Engine.get_version_info()
	return int(v.major) > 4 or (int(v.major) == 4 and int(v.minor) >= 4)


## Sets a StandardMaterial3D/ORMMaterial3D to per-vertex or per-pixel shading.
## No-op on non-BaseMaterial3D materials (e.g. Lux ShaderMaterials).
static func set_material_per_vertex(mat: Material, per_vertex: bool) -> void:
	if mat is BaseMaterial3D and native_available():
		var mode := (
			BaseMaterial3D.SHADING_MODE_PER_VERTEX
			if per_vertex
			else BaseMaterial3D.SHADING_MODE_PER_PIXEL
		)
		(mat as BaseMaterial3D).shading_mode = mode


## Force-enables/disables native vertex shading on ALL materials in the project
## via the override setting. This is a project-wide switch (Godot warns it needs
## an engine restart to take full effect), so Lux only touches it when a preset
## explicitly asks for the project-wide override rather than per-material control.
static func set_project_override(enabled: bool) -> void:
	if not native_available():
		return
	if ProjectSettings.has_setting(PROJECT_OVERRIDE) or enabled:
		ProjectSettings.set_setting(PROJECT_OVERRIDE, enabled)
