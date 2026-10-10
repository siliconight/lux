@tool
class_name LuxHorizonGlow
extends MeshInstance3D
## The glow at the horizon: a town's light over dark land, past the plate's
## edge (roadmap 228, step A, from the menu in `docs/findings/edge_menu/` at
## the factory root). LuxRoot builds one beside its other modules and tunes
## it from the preset on every apply. `horizon_glow_energy` 0 hides it, so a
## preset that says nothing draws nothing.
##
## WHAT IT IS. One ring of ROWS x SEGMENTS vertices at
## `horizon_glow_radius_m`, coloured by height: opaque dark land below the
## horizon, the preset's colour at a standing eye's height, fading out by
## `horizon_glow_top_deg`. Unshaded, alpha-blended, no shadow, no GI, read
## from both sides, and FOG IGNORED: the glow is the haze, and Delco Night's
## fog (density 0.006) leaves a tenth of anything 380 m out. One draw a frame.
##
## MEASURED BEFORE IT WAS WRITTEN, on the menu's mockup. A ring that peaked at
## the horizon and was gone by 4 degrees up showed in no frame, because from
## 26 m a 3.2 m wall already covers the first 3.2 degrees. A town's sky-glow
## climbs 10 to 20 degrees, so the fade reaches `horizon_glow_top_deg`.
##
## WHAT IT COSTS. The menu priced six edges, each with this ring, at Level
## Factory's fixed stations against two controls: none moved frame time past
## the controls' own 0.65 ms spread (`price.txt` beside the mockup).
##
## The ring is centred on this node, so on the LuxRoot it hangs from; a level
## stands near its origin and no plate reaches 380 m.

## The vertex rows, as angles above a standing eye's horizon, in degrees, with
## the top row at `horizon_glow_top_deg`; `null` rows are fractions of it.
const LAND_LOW_DEG := -3.0
const LAND_DEG := -0.15
const MID_FRACTIONS: Array[float] = [0.225, 0.5, 1.0]
## The alpha the glow's colour carries at the horizon, a quarter of the way
## up, and halfway up, at energy 1; the top row is 0.
const GLOW_ALPHAS: Array[float] = [0.34, 0.24, 0.08]
const LAND_LOW_COLOR := Color(0.03, 0.03, 0.035, 1.0)
const LAND_COLOR := Color(0.05, 0.045, 0.05, 1.0)
## A standing eye, the horizon the ring is drawn around.
const EYE_M := 1.7
const SEGMENTS := 64
const ROWS := 6

var _key := ""


func _init() -> void:
	name = &"LuxHorizonGlow"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	mat.disable_fog = true
	material_override = mat


## Tune the ring to `preset`. Rebuilds the mesh only when something it is
## built from changed, so a blend rebuilds and a re-apply does not.
func apply(preset: LuxPreset) -> void:
	if preset == null:
		visible = false
		return
	var energy: float = maxf(0.0, preset.horizon_glow_energy)
	visible = energy > 0.0
	if not visible:
		return
	var key := "%s|%.4f|%.3f|%.2f" % [preset.horizon_glow_color.to_html(true), energy,
		preset.horizon_glow_top_deg, preset.horizon_glow_radius_m]
	if key == _key:
		return
	_key = key
	mesh = build_ring(preset.horizon_glow_color, energy, preset.horizon_glow_top_deg,
		preset.horizon_glow_radius_m)


## The ring's rows: (height in metres, colour) from the foot up.
static func rows(color: Color, energy: float, top_deg: float, radius_m: float) -> Array:
	var out: Array = []
	var top := maxf(0.5, top_deg)
	out.append([EYE_M + radius_m * tan(deg_to_rad(LAND_LOW_DEG)), LAND_LOW_COLOR])
	out.append([EYE_M + radius_m * tan(deg_to_rad(LAND_DEG)), LAND_COLOR])
	var horizon := Color(color.r, color.g, color.b, clampf(GLOW_ALPHAS[0] * energy, 0.0, 1.0))
	out.append([EYE_M, horizon])
	for i in range(MID_FRACTIONS.size()):
		var deg: float = top * MID_FRACTIONS[i]
		var a: float = clampf(GLOW_ALPHAS[i + 1] * energy, 0.0, 1.0) \
			if i + 1 < GLOW_ALPHAS.size() else 0.0
		out.append([EYE_M + radius_m * tan(deg_to_rad(deg)), Color(color.r, color.g, color.b, a)])
	return out


static func build_ring(color: Color, energy: float, top_deg: float, radius_m: float) -> ArrayMesh:
	var r := rows(color, energy, top_deg, radius_m)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in range(SEGMENTS + 1):
		var ang: float = TAU * float(i) / float(SEGMENTS)
		for j in range(r.size()):
			var row: Array = r[j]
			var h: float = row[0]
			verts.append(Vector3(cos(ang) * radius_m, h, sin(ang) * radius_m))
			cols.append(row[1])
	var nh := r.size()
	for i in range(SEGMENTS):
		for j in range(nh - 1):
			var a0: int = i * nh + j
			var b0: int = (i + 1) * nh + j
			idx.append_array(PackedInt32Array([a0, b0, a0 + 1, b0, b0 + 1, a0 + 1]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var ring := ArrayMesh.new()
	ring.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return ring
