extends "res://addons/lux/lookdev/lookdev.gd"
## pc2000 look-dev variant — judge a LIGHTMAPPED building under the grade-only
## SoF PC2000 preset. Same controls as the base harness (orbit/walk, grade
## knobs, [ ] A/B shots, F5 dump, Space = grade on/off).
##
## THE ONE STRUCTURAL DIFFERENCE from the base harness: the building must be
## an EDITOR-TIME child of this scene named "Building" (pc2000_bake.tscn ships
## it that way). Lightmap data lives on the mesh instances that were in the
## scene when LightmapGI baked — a runtime-loaded GLB has none, which is why
## the base harness's load-at-runtime path can't be used for this family.
##
## Full bake procedure: docs/pc2000_bake_runbook.md.


func _load_building() -> void:
	_building = get_node_or_null(^"Building") as Node3D
	if _building == null:
		push_warning("pc2000 look-dev: instance the imported GLB as an editor-time "
			+ "child named 'Building', bake LightmapGI, then run. "
			+ "See docs/pc2000_bake_runbook.md.")
		return
	# pc2000 contract: NO stylized role apply. LEVEL keeps the imported
	# per-pixel StandardMaterial3D (bilinear + mipmaps, vertex-colour form bake
	# multiplying through); the lightmap owns light, Lux owns grade. GI modes
	# are set here so a bake from this scene is always correctly flagged.
	LuxMaterialApplier.apply_role_lightmapped(_building, LuxRole.Role.LEVEL)
	_frame_building()
