@tool
class_name LuxLeakMeter
extends RefCounted
## Light-leak instrument: how much of each positional light's range reaches
## surfaces it has no line of sight to. A measurement, not a verdict -- it
## returns numbers and names no cause.
##
## WHY IT EXISTS. An unshadowed light illuminates every surface in range with
## walls never consulted: collision never blocks light, only a shadow map does.
## A person walking cold run 9048 saw "light coming from a basement fixture
## through the wall" -- a basement pendant 0.70 m under its slab with a 3.6 m
## range lights the lobby's walls from below. Nothing counted it, so nothing
## could say whether a change made it better.
##
## WHAT IS MEASURED, AND IN WHAT FRAME. From each light, `samples` rays on a
## Fibonacci sphere (a spot keeps only those inside its cone) are cast against
## the PHYSICS space -- colliders, not render meshes -- out to the light's
## range, one-sided (`hit_back_faces = false`). The first hit is a surface the
## light sees. The ray is then continued 1 cm past it; the next front face
## within range is a surface the light reaches THROUGH a collider -- a leak
## sample. Each sample is weighted by the engine's own falloff,
##
##     E = energy * (1 - (d / range)^4)^2 * d^-attenuation * max(N.L, 0)
##
## (Godot's `get_omni_attenuation`), so a sample at the rim of the range counts
## for what it lights, not for existing; a spot also carries its measured rim
## factor (`spot_rim_factor`). Units: that E, per light, summed over its
## samples -- comparable between runs of this meter at the same `samples`, not
## a photometric quantity. Near-field hits dominate `e_seen` (a ceiling 0.25 m
## over a lamp), so compare `e_seen` with itself, not with the leak sums.
##
## THE OCCLUDER'S NORMAL NAMES THE BOUNDARY. |n.y| >= SLAB_NORMAL_Y at the first
## hit is a horizontal surface -- a slab, so the leak is into another STOREY;
## otherwise a wall, so into another ROOM (or out of the building). A prop's
## top counts as a slab and a prop's side as a wall: the meter does not know
## what a room is, and says so here rather than in a number.
##
## LOWER BOUND: only the first surface behind the first occluder is counted.
##
## A LEAKED SURFACE MUST BE EXPOSED. RETRACTED, kept above what replaced it:
## the first run of this meter on cold run 9048's walk copy counted 45 of
## basement pendant_012's 46 through-slab samples on the UNDERSIDE of the
## sidewalk collider, which rests flush on the basement slab's top -- a face
## nobody can see -- and filled the ground floor's lights with the bottoms of
## chairs and tables standing on the slab above them, and the stair block
## beside the basement with the faces between its touching sub-blocks. The
## count was a census of coplanar contacts. A leak sample now counts only
## when the 3 cm in front of the surface is free of any other body: see
## `_exposed`.

const SLAB_NORMAL_Y := 0.7
## How far past an occluding hit the continued ray starts, metres. Enough to
## leave a one-sided trimesh face and to start inside a box (which a ray from
## inside does not report); far less than any wall or slab is thick.
const STEP_THROUGH := 0.01
## Free space a leaked surface needs in front of it to count, metres. A gap
## thinner than this is a contact, not a lit face anyone can see.
const EXPOSED_CLEARANCE := 0.03


## Measure every visible positional light under `scene_root`. Returns
## {samples, lights: [per-light], summary: {...}} -- see `_summarise`.
## `shadow_budget` is echoed into the summary for comparison (-1 = unknown).
static func measure(scene_root: Node, space: PhysicsDirectSpaceState3D,
		samples: int = 128, shadow_budget: int = -1) -> Dictionary:
	var lights: Array = []
	_collect_lights(scene_root, lights)
	var dirs: Array[Vector3] = fibonacci_directions(samples)
	var rows: Array = []
	for l in lights:
		rows.append(measure_light(l as Light3D, space, dirs))
	return {"samples": samples, "lights": rows,
		"summary": _summarise(rows, shadow_budget)}


## One light. `dirs` are unit vectors in world space.
static func measure_light(light: Light3D, space: PhysicsDirectSpaceState3D,
		dirs: Array[Vector3]) -> Dictionary:
	var origin: Vector3 = light.global_position
	var rng := light_range(light)
	var decay := light_decay(light)
	var energy := base_energy(light)
	var cone_cos := -2.0
	var rim_exp := 1.0
	var axis := Vector3.ZERO
	if light is SpotLight3D:
		cone_cos = cos(deg_to_rad((light as SpotLight3D).spot_angle))
		rim_exp = 1.0 / maxf((light as SpotLight3D).spot_angle_attenuation, 0.0001)
		axis = -light.global_transform.basis.z.normalized()
	var row := {
		"path": String(light.get_path()),
		"rig": rig_label(light),
		"kind": "spot" if light is SpotLight3D else "omni",
		"shadowed": light.shadow_enabled,
		"range": snappedf(rng, 0.001),
		"y": snappedf(origin.y, 0.001),
		"rays": 0, "seen": 0, "leak_slab": 0, "leak_wall": 0,
		"e_seen": 0.0, "e_leak_slab": 0.0, "e_leak_wall": 0.0,
	}
	if space == null or rng <= 0.0:
		return row
	for dir in dirs:
		var cone_w := 1.0
		if cone_cos > -1.5:
			var scos := dir.dot(axis)
			if scos < cone_cos:
				continue
			cone_w = spot_rim_factor(scos, cone_cos, rim_exp)
		row.rays += 1
		var end := origin + dir * rng
		var h1 := _ray(space, origin, end)
		if h1.is_empty():
			continue
		var p1: Vector3 = h1.position
		var d1 := (p1 - origin).length()
		row.seen += 1
		row.e_seen += energy * cone_w * falloff(d1, rng, decay) * maxf((h1.normal as Vector3).dot(-dir), 0.0)
		var h2 := _ray(space, p1 + dir * STEP_THROUGH, end)
		if h2.is_empty() or not _exposed(space, h2):
			continue
		var d2 := ((h2.position as Vector3) - origin).length()
		var e2 := energy * cone_w * falloff(d2, rng, decay) * maxf((h2.normal as Vector3).dot(-dir), 0.0)
		if absf((h1.normal as Vector3).y) >= SLAB_NORMAL_Y:
			row.leak_slab += 1
			row.e_leak_slab += e2
		else:
			row.leak_wall += 1
			row.e_leak_wall += e2
	for k in ["e_seen", "e_leak_slab", "e_leak_wall"]:
		row[k] = snappedf(float(row[k]), 0.0001)
	return row


## Godot's omni/spot distance falloff (scene_forward_lights_inc,
## `get_omni_attenuation`).
static func falloff(d: float, rng: float, decay: float) -> float:
	var nd := d / rng
	nd = nd * nd
	nd = nd * nd
	nd = maxf(1.0 - nd, 0.0)
	return nd * nd * pow(maxf(d, 0.0001), -decay)


## The rig resource's `energy` when the light belongs to a Lux rig, else the
## light's own. Rigs flicker `light_energy` every frame, and the first runs of
## this meter differed in the fourth figure between two builds of the same
## scene for no other reason.
static func base_energy(light: Light3D) -> float:
	var rig_node := light.get_parent()
	if rig_node != null:
		var r: Variant = rig_node.get(&"rig")
		if r is Resource and (r as Resource).get(&"energy") != null:
			return float((r as Resource).get(&"energy"))
	return light.light_energy


## A spot's angular falloff at `scos` = cos(angle off axis), for a cone whose
## edge is `cone_cos`: 1 - rim^exp, rim = (1 - scos) / (1 - cone_cos), where
## exp is 1 / `spot_angle_attenuation`. MEASURED, not read off the engine:
## Godot 4.7 GL Compatibility, a downward 89 degree spot against an identical
## omni on a white floor, the ratio at 20-79 degrees off axis matched this to
## within 0.02 at attenuation 1, 4, 8, 0.25 and 0.125 -- and did NOT match
## `1 - rim^attenuation`, the form first assumed (0.499 measured against 1.000
## predicted at 20 degrees, attenuation 4).
static func spot_rim_factor(scos: float, cone_cos: float, rim_exp: float) -> float:
	var rim := clampf((1.0 - scos) / maxf(1.0 - cone_cos, 0.0001), 0.0, 1.0)
	return 1.0 - pow(rim, rim_exp)


static func light_range(light: Light3D) -> float:
	if light is OmniLight3D:
		return (light as OmniLight3D).omni_range
	if light is SpotLight3D:
		return (light as SpotLight3D).spot_range
	return 0.0


static func light_decay(light: Light3D) -> float:
	if light is OmniLight3D:
		return (light as OmniLight3D).omni_attenuation
	if light is SpotLight3D:
		return (light as SpotLight3D).spot_attenuation
	return 1.0


## The rig node's name plus its resource's rig_name, lower-cased -- the same
## label LuxLighting ranks shadows by, so the two can be compared.
static func rig_label(light: Node) -> String:
	var rig_node := light.get_parent()
	if rig_node == null:
		return ""
	var label := String(rig_node.name).to_lower()
	var r: Variant = rig_node.get(&"rig")
	if r is Resource and (r as Resource).get(&"rig_name") != null:
		label += " " + String((r as Resource).get(&"rig_name")).to_lower()
	return label


## `n` near-uniform unit vectors (golden-angle spiral).
static func fibonacci_directions(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var golden := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) * 2.0 / float(n)
		var r := sqrt(maxf(1.0 - y * y, 0.0))
		var th := golden * float(i)
		out.append(Vector3(cos(th) * r, y, sin(th) * r))
	return out


static func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.hit_back_faces = false
	q.hit_from_inside = false
	q.collide_with_areas = false
	return space.intersect_ray(q)


## True when the EXPOSED_CLEARANCE in front of a surface point is empty of
## every OTHER body. The ray starts 5 mm BEHIND the face: a neighbour resting
## exactly flush (the sidewalk on the slab, a chair on the floor) is a
## coplanar trimesh face, and a ray starting in front of it never crosses it
## -- measured, the first form of this test let all 45 of pendant_012's
## sidewalk-underside samples through. The leaked surface's own body is
## excluded so its face does not cover itself; a body that is ONE collider for
## a whole building therefore cannot cover its own faces, which under-reports
## contacts inside it.
static func _exposed(space: PhysicsDirectSpaceState3D, hit: Dictionary) -> bool:
	var point: Vector3 = hit.position
	var normal: Vector3 = hit.normal
	var q := PhysicsRayQueryParameters3D.create(point - normal * 0.005,
		point + normal * EXPOSED_CLEARANCE)
	q.hit_back_faces = true
	q.hit_from_inside = true
	q.collide_with_areas = false
	q.exclude = [hit.rid]
	return space.intersect_ray(q).is_empty()


static func _collect_lights(node: Node, out: Array) -> void:
	if node is Light3D and not node is DirectionalLight3D:
		var lt := node as Light3D
		if lt.is_visible_in_tree() and lt.light_energy > 0.0:
			out.append(lt)
	for c in node.get_children():
		_collect_lights(c, out)


## Counts and sums over the per-light rows. A light "leaks" when at least one
## of its samples lands behind a collider; `*_e` fields weight by falloff.
## Shadowed lights are counted apart: their shadow map is the occlusion the
## meter's geometry says they need, so their leak is reported, not summed in.
static func _summarise(rows: Array, shadow_budget: int) -> Dictionary:
	var s := {
		"lights": rows.size(), "omni": 0, "spot": 0,
		"shadowed": 0, "shadow_budget": shadow_budget,
		"unshadowed": 0,
		"unshadowed_leaking": 0,
		"unshadowed_leaking_slab": 0,
		"unshadowed_leaking_wall": 0,
		"shadowed_leaking": 0,
		"unshadowed_e_seen": 0.0,
		"unshadowed_e_leak_slab": 0.0,
		"unshadowed_e_leak_wall": 0.0,
		"unshadowed_leak_share": 0.0,
		"by_class": {},
	}
	for row in rows:
		s[String(row.kind)] = int(s[String(row.kind)]) + 1
		var leaks: bool = int(row.leak_slab) + int(row.leak_wall) > 0
		if bool(row.shadowed):
			s.shadowed += 1
			if leaks:
				s.shadowed_leaking += 1
			continue
		s.unshadowed += 1
		s.unshadowed_e_seen += float(row.e_seen)
		s.unshadowed_e_leak_slab += float(row.e_leak_slab)
		s.unshadowed_e_leak_wall += float(row.e_leak_wall)
		if leaks:
			s.unshadowed_leaking += 1
		if int(row.leak_slab) > 0:
			s.unshadowed_leaking_slab += 1
		if int(row.leak_wall) > 0:
			s.unshadowed_leaking_wall += 1
		var cls := class_of(String(row.rig))
		var c: Dictionary = s.by_class.get(cls, {"unshadowed": 0, "leaking": 0,
			"e_seen": 0.0, "e_leak": 0.0})
		c.unshadowed += 1
		if leaks:
			c.leaking += 1
		c.e_seen = snappedf(float(c.e_seen) + float(row.e_seen), 0.0001)
		c.e_leak = snappedf(float(c.e_leak) + float(row.e_leak_slab) + float(row.e_leak_wall), 0.0001)
		s.by_class[cls] = c
	var total: float = float(s.unshadowed_e_seen) + float(s.unshadowed_e_leak_slab) + float(s.unshadowed_e_leak_wall)
	if total > 0.0:
		s.unshadowed_leak_share = snappedf(
			(float(s.unshadowed_e_leak_slab) + float(s.unshadowed_e_leak_wall)) / total, 0.0001)
	for k in ["unshadowed_e_seen", "unshadowed_e_leak_slab", "unshadowed_e_leak_wall"]:
		s[k] = snappedf(float(s[k]), 0.0001)
	return s


## Coarse class for the summary, from the rig label -- same words
## LuxLighting.shadow_rank_of_name reads.
static func class_of(label: String) -> String:
	for w in ["sign", "pack", "street", "window", "bulb", "pendant", "fluorescent", "ceiling"]:
		if label.contains(w):
			return w
	return "other"
