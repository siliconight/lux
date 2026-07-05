@tool
class_name LuxMaterialProfile
extends Resource
## Rules for how a surface responds to Lux lighting: diffuse banding, stylized
## specular, palette influence, vertex colors, wetness/grime, and retro options.
## Produces ShaderMaterials that use lux_stylized_standard.gdshader.

const STYLIZED_SHADER := preload("res://addons/lux/shaders/spatial/lux_stylized_standard.gdshader")

@export var profile_name: StringName = &"Default Surface"

@export_group("Base")
@export var albedo_tint: Color = Color(1, 1, 1, 1)
@export var use_vertex_color: bool = true
@export var uv_scale: Vector2 = Vector2.ONE

@export_group("Diffuse Response")
@export_range(1.0, 8.0) var band_count: float = 3.0
@export_range(0.0, 0.5) var band_softness: float = 0.08
## Lifted shadow floor keeps the retro look warm and readable instead of crushed.
@export_range(0.0, 1.0) var shade_min: float = 0.18
@export var shadow_tint: Color = Color(0.62, 0.6, 0.78)

@export_group("Specular")
@export_range(0.0, 1.0) var specular_strength: float = 0.25
@export_range(2.0, 256.0) var specular_shininess: float = 24.0
@export_range(0.0, 1.0) var rim_strength: float = 0.12
@export var rim_color: Color = Color(1.0, 0.9, 0.8)

@export_group("Palette")
@export_range(0.0, 1.0) var palette_influence: float = 0.25

@export_group("Surface")
@export_range(0.0, 1.0) var wetness: float = 0.0
@export_range(0.0, 1.0) var grime: float = 0.0
@export var grime_color: Color = Color(0.16, 0.13, 0.1)

@export_group("Retro")
@export var vertex_snap_enabled: bool = false
@export_range(32.0, 512.0) var vertex_snap_resolution: float = 160.0
@export_range(0.0, 1.0) var affine_amount: float = 0.0

@export_group("PS2 Lighting")
## 0 = modern per-pixel shading, 1 = full per-vertex Gouraud PS2 hardware feel.
## The key light direction/color are pushed by LuxRoot from the active preset.
@export_range(0.0, 1.0) var ps2_lighting: float = 0.0
## Drop the N.L angle term for flat, angle-blind lighting (PS2 world-geo style).
@export var ps2_skip_ndl: bool = false
## Sharpen vertex-gradient edges so Mach banding reads as intentional.
@export_range(0.0, 1.0) var mach_band_emphasis: float = 0.0


## Builds a ready-to-use ShaderMaterial from this profile.
func make_material(albedo_texture: Texture2D = null, palette: LuxPalette = null) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = STYLIZED_SHADER
	apply_to_material(mat, palette)
	if albedo_texture != null:
		mat.set_shader_parameter(&"albedo_texture", albedo_texture)
	return mat


## Writes this profile's parameters onto an existing Lux stylized material.
func apply_to_material(mat: ShaderMaterial, palette: LuxPalette = null) -> void:
	if mat == null or mat.shader != STYLIZED_SHADER:
		return
	mat.set_shader_parameter(&"albedo_tint", albedo_tint)
	mat.set_shader_parameter(&"use_vertex_color", use_vertex_color)
	mat.set_shader_parameter(&"uv_scale", uv_scale)
	mat.set_shader_parameter(&"band_count", band_count)
	mat.set_shader_parameter(&"band_softness", band_softness)
	mat.set_shader_parameter(&"shade_min", shade_min)
	mat.set_shader_parameter(&"shadow_tint", Vector3(shadow_tint.r, shadow_tint.g, shadow_tint.b))
	mat.set_shader_parameter(&"specular_strength", specular_strength)
	mat.set_shader_parameter(&"specular_shininess", specular_shininess)
	mat.set_shader_parameter(&"rim_strength", rim_strength)
	mat.set_shader_parameter(&"rim_color", Vector3(rim_color.r, rim_color.g, rim_color.b))
	mat.set_shader_parameter(&"palette_influence", palette_influence)
	mat.set_shader_parameter(&"wetness", wetness)
	mat.set_shader_parameter(&"grime", grime)
	mat.set_shader_parameter(&"grime_color", Vector3(grime_color.r, grime_color.g, grime_color.b))
	mat.set_shader_parameter(&"vertex_snap_enabled", vertex_snap_enabled)
	mat.set_shader_parameter(&"vertex_snap_resolution", vertex_snap_resolution)
	mat.set_shader_parameter(&"affine_amount", affine_amount)
	mat.set_shader_parameter(&"ps2_lighting", ps2_lighting)
	mat.set_shader_parameter(&"ps2_skip_ndl", ps2_skip_ndl)
	mat.set_shader_parameter(&"mach_band_emphasis", mach_band_emphasis)
	if palette != null:
		mat.set_shader_parameter(
			&"palette_shadow", Vector3(palette.shadow.r, palette.shadow.g, palette.shadow.b)
		)
		mat.set_shader_parameter(
			&"palette_highlight",
			Vector3(palette.highlight.r, palette.highlight.g, palette.highlight.b)
		)


## Applies this profile to every surface of a MeshInstance3D and registers the
## node in the "lux_materials" group so LuxRoot can push wetness/palette updates.
func apply_to_mesh_instance(
	mi: MeshInstance3D, albedo_texture: Texture2D = null, palette: LuxPalette = null
) -> void:
	if mi == null or mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var existing := mi.get_surface_override_material(s)
		var tex := albedo_texture
		if tex == null and existing is BaseMaterial3D:
			tex = (existing as BaseMaterial3D).albedo_texture
		mi.set_surface_override_material(s, make_material(tex, palette))
	if not mi.is_in_group(&"lux_materials"):
		mi.add_to_group(&"lux_materials", true)
