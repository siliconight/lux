@tool
class_name LuxEmissiveBinder
extends RefCounted
## Binds fixture lit-face materials to the Lux runtime (v0.14).
##
## Zoo's fixture pass (zoo --fixtures, v0.28+) bakes emissive faces into the
## fixture GLBs — troffer diffusers, streetlight lenses, sign faces, wall-pack
## lenses — as glTF emissive, which Godot imports as StandardMaterial3D
## emission. Those materials follow a naming contract: `M_*` plus a `_Lens`,
## `_Diffuser`, or `_Face` suffix.
##
## This walks a scene, collects matching materials, stamps each one's base
## emission energy into resource meta (idempotent — safe to re-bind after
## re-imports), and registers them with the LuxRoot's lighting module. From
## then on `LuxRoot.set_fixtures_powered(false)` kills the glow together with
## the rig lights — the power-cut heist beat — and restoring power brings the
## stored energy back.
##
## Editor: the Lux dock's "Bind Emissives" button (verification).
## Runtime: call `LuxRoot.bind_fixture_emissives()` (or
## `LuxRuntimeAPI.bind_emissives(get_tree())`) once after the level loads.

const SUFFIXES: Array[String] = ["_Lens", "_Diffuser", "_Face"]
const BASE_META := &"lux_base_emission"


## Walk `scene_root`, bind every matching material to `root` (or the first
## LuxRoot found under `scene_root`). Returns {ok, msg, count}.
static func bind(scene_root: Node, root: LuxRoot = null) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "Open a scene first.", "count": 0}
	var lux_root := root
	if lux_root == null:
		lux_root = _find_root(scene_root)
	if lux_root == null:
		return {"ok": false, "msg": "No LuxRoot in the scene.", "count": 0}
	var found: Array[BaseMaterial3D] = []
	_collect(scene_root, found)
	for mat in found:
		if not mat.has_meta(BASE_META):
			mat.set_meta(BASE_META, mat.emission_energy_multiplier)
		lux_root.register_fixture_emissive(mat)
	var msg := "Bound %d fixture emissive material(s)" % found.size()
	if found.is_empty():
		msg += " — no M_*_Lens / _Diffuser / _Face materials in the scene. Import a Zoo fixtures GLB first."
	return {"ok": true, "msg": msg, "count": found.size()}


## Does a material name follow the fixture lit-face contract?
static func matches(mat_name: String) -> bool:
	if not mat_name.begins_with("M_"):
		return false
	for s in SUFFIXES:
		if mat_name.ends_with(s):
			return true
	return false


static func _collect(node: Node, out: Array[BaseMaterial3D]) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			var bmat := mat as BaseMaterial3D
			if bmat != null and matches(bmat.resource_name) and not out.has(bmat):
				out.append(bmat)
	for c in node.get_children():
		_collect(c, out)


static func _find_root(scene_root: Node) -> LuxRoot:
	if scene_root is LuxRoot:
		return scene_root
	var found: Array[Node] = scene_root.find_children("*", "LuxRoot", true, false)
	if not found.is_empty():
		return found[0] as LuxRoot
	return null
