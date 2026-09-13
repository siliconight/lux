class_name LuxRainCollision
extends RefCounted
## Particle colliders that keep rain out of buildings and off the street.
##
## One GPUParticlesCollisionBox3D per building, covering its visual AABB from
## the lowest surface to `roof_clearance_m` above the roof, plus one ground box
## under the whole site.
## Built once at level-build time by a pipeline driver; the boxes are plain
## engine nodes with no script, so a packed scene carries them anywhere.
##
## WHY THE WHOLE BUILDING AND NOT A ROOF SLAB. The emitter hangs a fixed
## height over the camera. Standing on the ground floor of a building taller
## than that, the emitter plane is INSIDE the building, under its roof, and a
## roof slab cannot hide a drop born beneath it. A box from floor to roof can:
## tools/rain_renderer_probe.gd case `emit_inside_box` measured 0 bright
## pixels with the emitter inside a box, above and below. So the thickness
## question is answered with a whole storey or more, and the ground box is the
## one that has to be sized against the step.
##
## THE TUNNELLING RULE. Collision is tested once per simulation step, and a
## drop moves `step_m` between tests. A box thinner than that catches a drop
## only when a test happens to land inside it -- capture probability is
## thickness / step. Measured with the same probe, 10 m/s, GL Compatibility:
## a 5 cm box let through 60-69% of drops over four runs at fixed_fps 60
## (step 0.167 m; 70% predicted, 58% counting the 1 cm particle radius) and
## 92% or more at fixed_fps 10 (step 1.0 m); a 1.2 m box at fixed_fps 10 let
## through none. Every
## box here is at least `THICKNESS_FACTOR * step_m` thick BY CONSTRUCTION: the
## ground box exactly, a building's box by its own height plus
## `roof_clearance_m`, which alone exceeds it. So there is no thinness refusal
## -- a check that cannot fail would read as one that passed -- and the
## report carries `thinnest_m` beside `min_thickness_m` for anyone to compare.
##
## WHY THE BOX STANDS ABOVE THE ROOF. A box whose top is the roof's top leaked
## short streaks under the ceiling of cold run 9048's mansion (b1): its AABB
## top is 7.65, its top-floor ceiling 7.28. Measured with
## tools/rain_walk_probe.py from inside the master suite, pixels risen more
## than 30 codes over a rain-hidden baseline, two runs, at 3 s / 5 s (run 1)
## and 1.5 s / 5 s (run 2) after a restart:
##
##     run 1  as built, fixed_fps 30 (step 0.33 m)    362, 503  (top third only)
##     run 1  as built, fixed_fps 60 (step 0.165 m)    27,   0
##     run 2  as built, fixed_fps 30                  218, 114
##     run 2  the b1 box raised to y = 60               0,   0
##     run 2  the b1 box moved away                 6,707, 7,458 (every band)
##     run 2  b1's ceiling hidden                     224, 314
##
## So the box stops all but ~3% of the pixels, the leak scales with the step, and it
## vanishes when the top is far above the roof. The drawn geometry explains
## it: a drop is hidden at the first step that finds it INSIDE, so it is drawn
## up to one step below the box top first, and its streak hangs half a streak
## length below its centre. Lowest drawn point = top - step - length / 2:
## 7.65 - 0.33 - 0.225 = 7.095, under a 7.28 ceiling (a 0.185 m window); at
## fixed_fps 60 it is 7.26, a 0.02 m window -- the ~10x fewer pixels measured.
## An earlier guess, that the ceiling was not writing depth, was refuted by
## reading its material: opaque, depth draw on, cull disabled.
##
## BUILDINGS ARE FOUND BY NAME. Lot names each building node after its site
## spec id, and Level Factory writes those ids as `b<index>`; `name_pattern`
## is a parameter so a site laid out by anything else can say what its
## buildings are called. Only direct children of the scene root are matched.

const CONTAINER_NAME := "LuxRainColliders"
## Minimum box thickness in simulation steps. 1.0 is the measured no-leak
## threshold; 2.0 leaves a whole step of margin for a frame that runs more than
## one step, and costs nothing because the boxes are invisible.
const THICKNESS_FACTOR := 2.0


## Metres the FASTEST drop moves between two collision tests.
static func step_m(profile: LuxWeatherProfile) -> float:
	var speed_max: float = profile.rain_fall_speed * (1.0 + profile.rain_speed_randomness)
	return speed_max / float(maxi(profile.rain_fixed_fps, 1))


static func min_thickness_m(profile: LuxWeatherProfile) -> float:
	return step_m(profile) * THICKNESS_FACTOR


## How far a building's box stands above its roof: the thickness margin (two
## steps) plus half a streak, so the lowest drawn point of a drop about to be
## hidden -- top - step - length / 2 -- is still a step above the roof.
static func roof_clearance_m(profile: LuxWeatherProfile) -> float:
	return min_thickness_m(profile) + profile.rain_streak_length * 0.5


## World-space AABB of every VisualInstance3D under `node`, lights excluded
## (a light's AABB is its range, not a surface). `found[0]` is false when the
## node had nothing visual under it.
static func visual_aabb(node: Node, found: Array) -> AABB:
	var acc := AABB()
	var have: bool = false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D and not (n is Light3D) and not (n is GPUParticles3D):
			var vi := n as VisualInstance3D
			if vi.is_inside_tree():
				var a: AABB = vi.global_transform * vi.get_aabb()
				if a.size != Vector3.ZERO:
					acc = a if not have else acc.merge(a)
					have = true
		stack.append_array(n.get_children())
	found.clear()
	found.append(have)
	return acc


## Build the colliders under `scene` (which must be inside the tree, so global
## transforms are real). Replaces an existing container, so running it twice
## equals running it once. Returns a report; `ok` is false when no building
## matched, which leaves every interior wet and the caller should say so.
static func build(scene: Node3D, profile: LuxWeatherProfile,
		name_pattern: String = "^b\\d+$", ground_y: float = 0.0) -> Dictionary:
	var report := {"ok": false, "buildings": [], "ground": {}, "boxes": 0,
		"step_m": 0.0, "min_thickness_m": 0.0, "roof_clearance_m": 0.0,
		"thinnest_m": 0.0, "msg": ""}
	if scene == null or profile == null or not scene.is_inside_tree():
		report.msg = "scene not in tree, or no weather profile"
		return report
	var step: float = step_m(profile)
	var need: float = min_thickness_m(profile)
	report.step_m = step
	report.min_thickness_m = need
	var clearance: float = roof_clearance_m(profile)
	report.roof_clearance_m = clearance

	var old: Node = scene.get_node_or_null(NodePath(CONTAINER_NAME))
	if old != null:
		scene.remove_child(old)
		old.free()
	var box_root := Node3D.new()
	box_root.name = CONTAINER_NAME
	scene.add_child(box_root)

	var rx := RegEx.new()
	if rx.compile(name_pattern) != OK:
		report.msg = "name_pattern does not compile: %s" % name_pattern
		return report

	var site := AABB()
	var have_site: bool = false
	var thinnest: float = INF
	var found: Array = []
	for child in scene.get_children():
		if child == box_root:
			continue
		var a: AABB = visual_aabb(child, found)
		if not bool(found[0]):
			continue
		site = a if not have_site else site.merge(a)
		have_site = true
		if rx.search(String(child.name)) == null:
			continue
		var b := GPUParticlesCollisionBox3D.new()
		b.name = "Rain_%s" % String(child.name)
		var covered := AABB(a.position, a.size + Vector3(0.0, clearance, 0.0))
		b.size = covered.size
		box_root.add_child(b)
		b.global_position = covered.get_center()
		thinnest = minf(thinnest, covered.size.y)
		(report.buildings as Array).append({"name": String(child.name),
			"min": [covered.position.x, covered.position.y, covered.position.z],
			"size": [covered.size.x, covered.size.y, covered.size.z],
			"roof_y": a.end.y})

	if (report.buildings as Array).is_empty():
		box_root.free()
		report.msg = "no scene child matched %s -- no building is dry" % name_pattern
		return report

	# THE GROUND BOX: the site's footprint, top at the ground datum (Lot's
	# COORDINATE_CONTRACT: ground plane at 0), exactly `need` thick.
	var g := GPUParticlesCollisionBox3D.new()
	g.name = "Rain_Ground"
	g.size = Vector3(site.size.x, need, site.size.z)
	box_root.add_child(g)
	g.global_position = Vector3(site.get_center().x, ground_y - need * 0.5, site.get_center().z)
	thinnest = minf(thinnest, need)
	report.ground = {"min": [site.position.x, ground_y - need, site.position.z],
		"size": [site.size.x, need, site.size.z]}

	report.boxes = box_root.get_child_count()
	report.thinnest_m = thinnest
	report.ok = true
	report.msg = "%d building box(es) + ground; step %.3f m, thinnest %.3f m (min %.3f), roof clearance %.3f m" % [
		(report.buildings as Array).size(), step, thinnest, need, clearance]
	return report
