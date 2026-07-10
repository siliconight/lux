@tool
class_name LuxMaterialApplier
extends Object
## Dead-simple role-based material setup. Point it at a node and say what it is —
## Lux picks the right vertex-lighting path, quality, and registration so the
## surface gets a good PS2 look with multiplayer-friendly cost.
##
## The two paths, chosen per role (see LuxRole):
##   NATIVE (level/character/prop) — keeps StandardMaterial3D and flips
##     SHADING_MODE_PER_VERTEX. Cheapest, sees all real-time lights, casts shadows
##     from the key directional. This is the bulk of the scene.
##   STYLIZED (gun) — swaps in a Lux ShaderMaterial for the nicer banding/palette,
##     since only one viewmodel is ever on screen.
##
## Either way the mesh joins the "lux_materials" group so LuxRoot pushes palette,
## wetness, and the live Sun Link key light to it.
##
## Usage:
##   LuxMaterialApplier.apply_role(level_root, LuxRole.Role.LEVEL)
##   LuxMaterialApplier.apply_role(player.mesh, LuxRole.Role.CHARACTER)
##   LuxMaterialApplier.apply_role(viewmodel, LuxRole.Role.GUN)
## or by name from an exported string / group / metadata:
##   LuxMaterialApplier.apply_role_name(node, "gun")


## Apply a role to every MeshInstance3D under `root` (inclusive). Returns the
## number of surfaces touched. `palette` is optional look tinting.
static func apply_role(root: Node, role: int, palette: LuxPalette = null) -> int:
	if root == null:
		return 0
	var profile := LuxRole.make_profile(role)
	var mode := LuxRole.vertex_mode_for(role)
	var count := 0
	for mi in _all_mesh_instances(root):
		count += _apply_to_mesh(mi, profile, mode, palette)
	return count


static func apply_role_name(root: Node, role_name: String, palette: LuxPalette = null) -> int:
	return apply_role(root, LuxRole.role_from_name(role_name), palette)


## Applies a role to a single MeshInstance3D's surfaces.
static func _apply_to_mesh(
	mi: MeshInstance3D, profile: LuxMaterialProfile, mode: int, palette: LuxPalette
) -> int:
	if mi == null or mi.mesh == null:
		return 0
	var touched := 0
	for s in mi.mesh.get_surface_count():
		if mode == 2:
			# Stylized Gouraud: swap in a Lux ShaderMaterial carrying the profile.
			var existing := mi.get_surface_override_material(s)
			var tex: Texture2D = null
			if existing is BaseMaterial3D:
				tex = (existing as BaseMaterial3D).albedo_texture
			var mat := profile.make_material(tex, palette)
			mat.set_shader_parameter(&"ps2_lighting", profile.ps2_lighting)
			mi.set_surface_override_material(s, mat)
		elif mode == 1:
			# Native engine vertex shading: ensure a StandardMaterial3D and flip it
			# to per-vertex. Cheapest path, keeps real multi-light + shadows.
			var mat := _ensure_standard_material(mi, s)
			LuxVertexShading.set_material_per_vertex(mat, true)
		else:
			# Unlit / per-pixel: unshaded StandardMaterial3D for UI/decals.
			var mat := _ensure_standard_material(mi, s)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		touched += 1
	if not mi.is_in_group(&"lux_materials"):
		mi.add_to_group(&"lux_materials", true)
	# Tag the role so tools / re-applies / the dock can read it back.
	mi.set_meta(&"lux_role", profile.profile_name)
	return touched


## pc2000 / lightmapped path: materials stay PER-PIXEL engine-standard
## (LightmapGI owns light, Lux runs grade-only) and each mesh gets the GI mode
## it needs for a LightmapGI bake:
##   LEVEL / PROP    -> GI_MODE_STATIC   (baked into the lightmap; needs UV2 —
##                      import the GLB with Light Baking = Static Lightmaps)
##   CHARACTER / GUN -> GI_MODE_DYNAMIC  (lit by the bake's probes + realtime)
##   UI_UNLIT        -> unshaded, GI disabled
## Deliberately does NOT flip per-vertex shading and does NOT join the
## "lux_materials" group — pc2000 surfaces must stay out of preset restyling.
## The Patina form bake still multiplies through via the imported material's
## vertex_color_use_as_albedo. Returns the number of meshes touched.
static func apply_role_lightmapped(root: Node, role: int) -> int:
	if root == null:
		return 0
	var count := 0
	for mi_v in _all_mesh_instances(root):
		var mi := mi_v as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		match role:
			LuxRole.Role.LEVEL, LuxRole.Role.PROP:
				mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			LuxRole.Role.CHARACTER, LuxRole.Role.GUN:
				mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
			_:
				mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
				for s in mi.mesh.get_surface_count():
					var mat := _ensure_standard_material(mi, s)
					mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.set_meta(&"lux_role", LuxRole.role_name(role) + " (lightmapped)")
		count += 1
	return count


## Returns a writable StandardMaterial3D override for a surface, preserving an
## existing BaseMaterial3D's albedo texture/color if present.
static func _ensure_standard_material(mi: MeshInstance3D, surface: int) -> BaseMaterial3D:
	var existing := mi.get_surface_override_material(surface)
	if existing is BaseMaterial3D:
		return existing as BaseMaterial3D
	var mat := StandardMaterial3D.new()
	if existing is BaseMaterial3D:
		mat.albedo_color = (existing as BaseMaterial3D).albedo_color
		mat.albedo_texture = (existing as BaseMaterial3D).albedo_texture
	mi.set_surface_override_material(surface, mat)
	return mat


static func _all_mesh_instances(node: Node, acc: Array = []) -> Array:
	if node is MeshInstance3D:
		acc.append(node)
	for c in node.get_children():
		_all_mesh_instances(c, acc)
	return acc
