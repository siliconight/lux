class_name LuxFailing
extends RefCounted
## How a FAILING fixture's light moves over time (0.62.0): one level, 0..1,
## for a kind, a seed and a clock. Pure: no node, no state, the same answer
## for the same inputs, so a rig can ask it every frame and a test can ask
## it for any second of the next hour.
##
## WHY NOT THE WOBBLE. Every rig since 0.13 "flickered": two sines added,
## `1 - max(0, n) * amount * 0.5`, so a tube dimmed and brightened SMOOTHLY by
## at most 6 % of its energy, forever, and so did every other tube in the
## level, in step. The walker walked those levels and called the lights
## frozen (2026-10-02). The eye catches EVENTS and ignores a smooth hum; a
## failing tube is steady almost all the time and then stutters.
##
## Three characters, each keyed to the fixture it belongs to:
##
##   STUTTER  a fluorescent with a tired ballast: steady for `period`
##            seconds (4 to 15, the fixture's own), then a burst of two to
##            four drops to 60-75 %, each a few frames long, then steady.
##   CYCLING  a sodium streetlight at the end of its life: over 40 to 70
##            seconds it dims, cuts out, sits dark for several seconds, and
##            restrikes dim and warms back up -- the 90s parking lot made
##            visible. The walker's call, 2026-10-02: "go with cycling".
##   WAVER    a filament: a slow 3-5 % sway, the one character that IS a
##            wobble, because a bulb's is.
##
## Who fails is not decided here. `LuxFixtureSpawner` picks ONE fixture an
## anchor (one bad tube a room) and `LuxLightLoader` every third streetlight;
## everything else is steady, which is what makes the failing one read.

const NONE := 0
const STUTTER := 1
const CYCLING := 2
const WAVER := 3

const STUTTER_PERIOD_MIN := 4.0
const STUTTER_PERIOD_MAX := 15.0
const STUTTER_DROP_S := 0.05           # a drop lasts 3 to 6 frames at 60 Hz
const STUTTER_FLOOR := 0.60
const CYCLE_MIN_S := 40.0
const CYCLE_MAX_S := 70.0


## A deterministic 0..1 for (seed, k): a small integer hash, nothing more.
static func unit(seed: int, k: int) -> float:
	var x: int = ((seed * 73856093) ^ (k * 19349663)) & 0x7fffffff
	x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff
	x = (x ^ (x >> 16)) & 0x7fffffff
	return float(x & 0xffff) / 65535.0


static func level(kind: int, seed: int, t: float) -> float:
	match kind:
		STUTTER:
			return stutter(seed, t)
		CYCLING:
			return cycling(seed, t)
		WAVER:
			return waver(seed, t)
	return 1.0


## The fixture's own period, so two bad tubes in one building do not
## stutter together.
static func stutter_period(seed: int) -> float:
	return STUTTER_PERIOD_MIN + (STUTTER_PERIOD_MAX - STUTTER_PERIOD_MIN) * unit(seed, 1)


static func stutter(seed: int, t: float) -> float:
	var period := stutter_period(seed)
	var i := int(floor(t / period))
	var into := t - float(i) * period
	# the burst sits somewhere in the first third of its period, not at its
	# start, so the beat is not a metronome
	var at := period * 0.3 * unit(seed, 50 + i)
	var drops := 2 + int(unit(seed, 100 + i) * 3.0)
	for d in drops:
		var start := at + float(d) * 0.14 + 0.06 * unit(seed, 1000 + i * 8 + d)
		var dur := STUTTER_DROP_S + 0.05 * unit(seed, 2000 + i * 8 + d)
		if into >= start and into < start + dur:
			return STUTTER_FLOOR + 0.15 * unit(seed, 3000 + i * 8 + d)
	return 1.0


static func cycle_length(seed: int) -> float:
	return CYCLE_MIN_S + (CYCLE_MAX_S - CYCLE_MIN_S) * unit(seed, 2)


static func cycling(seed: int, t: float) -> float:
	var c := cycle_length(seed)
	var u := fmod(t + c * unit(seed, 3), c) / c
	if u < 0.45:
		return 1.0 - 0.3 * (u / 0.45)                       # warming down: 1.0 -> 0.7
	if u < 0.55:
		return 0.7 - 0.62 * ((u - 0.45) / 0.10)             # the arc gives up: 0.7 -> 0.08
	if u < 0.70:
		return 0.0                                          # dark
	var w := (u - 0.70) / 0.30                              # the restrike, warming up
	return 0.15 + 0.85 * pow(w, 1.5) + 0.04 * sin(t * 23.0) * (1.0 - w)


static func waver(seed: int, t: float) -> float:
	var p := t * 1.3 + 6.28 * unit(seed, 4)
	return 1.0 - 0.04 * (0.5 + 0.25 * sin(p) + 0.25 * sin(p * 0.37 + 1.0))


## The nearest lit face to `pos` within `radius`: ``[MeshInstance3D,
## surface]`` or an empty array. A failing fixture's lamp sits inside its
## own hardware (Zoo's markers put it there), so the lens or diffuser a
## lamp dims is the one nearest it. Walks the tree once; a rig calls it at
## ready, not per frame.
static func find_lens(scene_root: Node, pos: Vector3, radius: float) -> Array:
	var best: Array = []
	var best_d := radius
	var stack: Array = [scene_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var mat: Material = mi.get_active_material(s)
				if mat != null and LuxEmissiveBinder.matches(mat.resource_name):
					var box: AABB = mi.global_transform * mi.get_aabb()
					var d := _box_distance(box, pos)
					if d < best_d:
						best_d = d
						best = [mi, s]
					break
		for c in n.get_children():
			stack.push_back(c)
	return best


static func _box_distance(box: AABB, p: Vector3) -> float:
	var lo := box.position
	var hi := box.position + box.size
	var d := Vector3(maxf(maxf(lo.x - p.x, p.x - hi.x), 0.0),
		maxf(maxf(lo.y - p.y, p.y - hi.y), 0.0),
		maxf(maxf(lo.z - p.z, p.z - hi.z), 0.0))
	return d.length()
