extends SceneTree
## Falsification test for rain (Lux 0.35.0): LuxRain, the preset's weather,
## the tier caps, and LuxRainCollision.
##
##     godot --headless --path lux --import
##     godot --headless --path lux -s res://tools/rain_selftest.gd
##
## Exit 0 = every case behaved. Exit 1 = a case failed (the message says
## which). Exit 2 = could not run at all, which is never reported as a pass.
## The import pass is not optional, for the reason colocation_selftest.gd
## gives.
##
## Headless has no renderer, so nothing here says a drop is VISIBLE or that a
## box STOPS one -- tools/rain_renderer_probe.gd measures those in pixels and
## needs a window. What this holds is the wiring: the right node exists with
## the right settings when a preset asks for rain, goes away when it does not,
## follows the camera, and the colliders cover what they claim at the
## thickness they claim. Each "exists" is tested against its "does not".

const ROOT := "res://addons/lux/runtime/lux_root.gd"
const RAIN := "res://addons/lux/runtime/lux_rain.gd"
const COLLISION := "res://addons/lux/runtime/lux_rain_collision.gd"
const QUALITY := "res://addons/lux/resources/lux_quality_profile.gd"
const HEAVY := "res://addons/lux/presets/heavy_rain.tres"
const DRY := "res://addons/lux/presets/delco_summer_afternoon.tres"

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fails += 1
	print("  %s %s: %s%s" % ["ok  " if ok else "FAIL", label, str(got),
		"" if ok else "   (wanted %s)" % str(want)])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _rain_child(lux: Node) -> Node:
	for c in lux.get_children():
		if c is GPUParticles3D:
			return c
	return null


func _with(r: Resource, key: String, value: Variant) -> Resource:
	var c: Resource = r.duplicate(true)
	c.set(key, value)
	return c


func _building(parent: Node3D, label: String, size: Vector3, base: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = label
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	parent.add_child(mi)
	mi.global_position = base + Vector3(0.0, size.y * 0.5, 0.0)
	return mi


func _main() -> void:
	await process_frame
	var RootScript: GDScript = load(ROOT) as GDScript
	var Rain: GDScript = load(RAIN) as GDScript
	var Collision: GDScript = load(COLLISION) as GDScript
	var Quality: GDScript = load(QUALITY) as GDScript
	var heavy: Resource = load(HEAVY)
	var dry: Resource = load(DRY)
	if RootScript == null or Rain == null or Collision == null or Quality == null \
			or heavy == null or dry == null:
		push_error("rain_selftest: lux scripts or presets not found")
		quit(2)
		return
	if not RootScript.can_instantiate() or not Rain.can_instantiate() \
			or not Collision.can_instantiate():
		push_error("rain_selftest: a lux runtime script did not COMPILE. "
			+ "Run `godot --headless --path lux --import` once, then re-run this.")
		quit(2)
		return

	print("case A -- heavy_rain carries a rain profile; the dry preset carries none")
	var w: Resource = heavy.get("weather")
	_check("heavy_rain.weather is set", w != null, true)
	if w == null:
		quit(1)
		return
	_check("rain_enabled", w.get("rain_enabled"), true)
	_check("delco_summer_afternoon.weather is null", dry.get("weather") == null, true)

	print("case B -- drops per tier are min(profile, tier cap)")
	var tiers: Array = []
	for t in 4:
		tiers.append(Rain.drops_for(w, Quality.make_tier(t)))
	_check("High / Medium / Low / Compatibility", tiers, [9000, 6000, 3000, 2000])
	_check("a disabled profile gets 0 on High", Rain.drops_for(null, Quality.make_tier(0)), 0)

	var stage := Node3D.new()
	stage.name = "RainStage"
	root.add_child(stage)
	var cam := Camera3D.new()
	stage.add_child(cam)
	cam.global_position = Vector3(5.0, 1.6, -3.0)
	cam.make_current()

	print("case C -- a rain preset gets one LuxRain, configured for streaks that hide on contact")
	var lux: Node3D = RootScript.new()
	lux.name = "LuxRoot"
	lux.set("active_preset", heavy)
	stage.add_child(lux)
	await _frames(3)
	var rain: GPUParticles3D = _rain_child(lux) as GPUParticles3D
	_check("a GPUParticles3D child exists", rain != null, true)
	if rain == null:
		quit(1)
		return
	_check("get_rain_drops()", lux.call("get_rain_drops"), 9000)
	_check("amount", rain.amount, 9000)
	_check("world-space particles", rain.local_coords, false)
	_check("no trails (unsupported under Compatibility)", rain.trail_enabled, false)
	_check("fixed_fps", rain.fixed_fps, 30)
	_check("lifetime = column / speed", snappedf(rain.lifetime, 0.001), snappedf(18.0 / 9.0, 0.001))
	_check("preprocess fills the column", snappedf(rain.preprocess, 0.001), snappedf(rain.lifetime, 0.001))
	var pm: ParticleProcessMaterial = rain.process_material as ParticleProcessMaterial
	_check("collision hides on contact", pm.collision_mode, ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT)
	_check("spread", pm.spread, 5.0)
	var q: QuadMesh = rain.draw_pass_1 as QuadMesh
	var mat: StandardMaterial3D = q.material as StandardMaterial3D
	_check("unshaded", mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	_check("alpha", mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	_check("cull disabled", mat.cull_mode, BaseMaterial3D.CULL_DISABLED)
	_check("vertex colour is albedo", mat.vertex_color_use_as_albedo, true)
	_check("streak size", q.size, Vector2(0.012, 0.45))
	_check("near fade", [mat.distance_fade_mode, mat.distance_fade_max_distance],
		[BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA, 2.0])
	var vis: AABB = rain.visibility_aabb
	_check("visibility AABB holds the column (bottom <= -18)", vis.position.y <= -18.0, true)
	_check("visibility AABB holds the emitter square (half >= 16)", vis.position.x <= -16.0 and vis.end.x >= 16.0, true)

	print("case D -- the emitter follows the active camera, across a jump too")
	_check("hangs 12 m over the camera", rain.global_position, cam.global_position + Vector3(0.0, 12.0, 0.0))
	cam.global_position = Vector3(40.0, 1.6, 30.0)
	await _frames(2)
	_check("after a 50 m jump", rain.global_position, Vector3(40.0, 13.6, 30.0))

	print("case E -- the tier moves the count on the same node")
	lux.set("quality_tier", 3)
	await _frames(1)
	_check("Compatibility drops", lux.call("get_rain_drops"), 2000)
	_check("same node", _rain_child(lux) == rain, true)
	_check("a deep copy of the same profile does not rebuild (make_override)",
		rain.call("configure", w.duplicate(true), Quality.make_tier(3)), false)
	_check("a changed value does", rain.call("configure", _with(w, "rain_streak_length", 0.5), Quality.make_tier(3)), true)
	rain.call("configure", w, Quality.make_tier(3))
	lux.set("quality_tier", 0)
	await _frames(1)

	print("case F -- a dry preset removes the rain; set_weather brings it back and takes it away")
	lux.call("apply_preset", dry)
	await _frames(2)
	_check("no GPUParticles3D under LuxRoot", _rain_child(lux) == null, true)
	_check("get_rain_drops()", lux.call("get_rain_drops"), 0)
	lux.call("set_weather", w, 0.0)
	await _frames(2)
	_check("set_weather(rain) -> drops", lux.call("get_rain_drops"), 9000)
	var clear: Resource = w.duplicate()
	clear.set("rain_enabled", false)
	lux.call("set_weather", clear, 0.0)
	await _frames(2)
	_check("set_weather(no rain) -> drops", lux.call("get_rain_drops"), 0)

	print("case G -- a blend snaps the weather at the midpoint, never before")
	var p_dry: Resource = dry
	var p_wet: Resource = heavy
	lux.call("apply_preset", p_dry)
	await _frames(1)
	# _lerp_preset writes into the scratch preset a blend allocates; outside a
	# blend there is none, so give it one.
	lux.set("_blend_scratch", (load("res://addons/lux/resources/lux_preset.gd") as GDScript).new())
	var mid_lo: Resource = lux.call("_lerp_preset", p_dry, p_wet, 0.49)
	_check("k = 0.49 keeps the dry weather", mid_lo.get("weather") == null, true)
	var mid_hi: Resource = lux.call("_lerp_preset", p_dry, p_wet, 0.5)
	_check("k = 0.50 takes the rain", mid_hi.get("weather") == w, true)

	print("case H -- colliders: one per building, floor to roof + clearance, ground exactly min thickness")
	var site := Node3D.new()
	site.name = "Site"
	root.add_child(site)
	_building(site, "b0", Vector3(10.0, 8.0, 6.0), Vector3(20.0, 0.0, 0.0))
	_building(site, "b1", Vector3(12.0, 11.0, 12.0), Vector3(-15.0, -3.0, 4.0))
	_building(site, "sign_b0", Vector3(2.0, 1.0, 0.2), Vector3(20.0, 4.0, -3.2))
	_building(site, "Ground", Vector3(80.0, 0.5, 60.0), Vector3(0.0, -0.5, 0.0))
	await _frames(1)
	var rep: Dictionary = Collision.build(site, w)
	_check("ok", rep.get("ok"), true)
	_check("step = 9.9 / 30", snappedf(float(rep.get("step_m")), 0.0001), 0.33)
	_check("min thickness = 2 steps", snappedf(float(rep.get("min_thickness_m")), 0.0001), 0.66)
	_check("roof clearance = 2 steps + half a streak", snappedf(float(rep.get("roof_clearance_m")), 0.0001), 0.885)
	_check("buildings matched", (rep.get("buildings") as Array).map(func(b: Dictionary) -> String: return String(b.name)), ["b0", "b1"])
	var boxes: Node = site.get_node_or_null(NodePath("LuxRainColliders"))
	_check("boxes (2 buildings + ground)", boxes.get_child_count() if boxes != null else -1, 3)
	if boxes != null:
		var b0: GPUParticlesCollisionBox3D = boxes.get_node_or_null(NodePath("Rain_b0"))
		_check("b0 box footprint", Vector2(b0.size.x, b0.size.z) if b0 != null else null, Vector2(10.0, 6.0))
		_check("b0 box bottom at its floor", snappedf(b0.global_position.y - b0.size.y * 0.5, 0.001) if b0 != null else null, 0.0)
		_check("b0 box top = roof 8.0 + 0.885", snappedf(b0.global_position.y + b0.size.y * 0.5, 0.001) if b0 != null else null, 8.885)
		_check("b0 box centred on the footprint", Vector2(b0.global_position.x, b0.global_position.z) if b0 != null else null, Vector2(20.0, 0.0))
		var b1: GPUParticlesCollisionBox3D = boxes.get_node_or_null(NodePath("Rain_b1"))
		_check("b1 box reaches its basement (bottom)", snappedf(b1.global_position.y - b1.size.y * 0.5, 0.001) if b1 != null else null, -3.0)
		var g: GPUParticlesCollisionBox3D = boxes.get_node_or_null(NodePath("Rain_Ground"))
		_check("ground top at 0", snappedf(g.global_position.y + g.size.y * 0.5, 0.0001) if g != null else null, 0.0)
		_check("ground thickness", snappedf(g.size.y, 0.0001) if g != null else null, 0.66)
		_check("ground covers the site in x", snappedf(g.size.x, 0.001) if g != null else null, 80.0)
		_check("boxes carry no owner (the caller owns them)", b0.owner == null if b0 != null else null, true)
	var rep2: Dictionary = Collision.build(site, w)
	boxes = site.get_node_or_null(NodePath("LuxRainColliders"))
	_check("rebuild replaces, does not stack", boxes.get_child_count() if boxes != null else -1, 3)
	_check("rebuild ok", rep2.get("ok"), true)

	print("case I -- a flat building still gets a box thicker than a step; no building is refused")
	_building(site, "b2", Vector3(6.0, 0.2, 6.0), Vector3(0.0, 0.0, 20.0))
	await _frames(1)
	var flat: Dictionary = Collision.build(site, w)
	_check("thinnest box >= min thickness", float(flat.get("thinnest_m")) + 1e-6 >= float(flat.get("min_thickness_m")), true)
	_check("the 0.2 m building's box is 0.2 + 0.885", snappedf(float((flat.get("buildings") as Array)[2].size[1]), 0.001), 1.085)
	var none: Dictionary = Collision.build(site, w, "^house_\\d+$")
	_check("no match is refused", none.get("ok"), false)
	_check("and leaves no container", site.get_node_or_null(NodePath("LuxRainColliders")) == null, true)
	var slow: Resource = w.duplicate()
	slow.set("rain_fixed_fps", 5)
	_check("fixed_fps 5 needs 3.96 m", snappedf(Collision.min_thickness_m(slow), 0.0001), 3.96)

	print("")
	if _fails == 0:
		print("  rain selftest ok: rain exists exactly when a preset asks, at the tier's")
		print("  count, over the camera; colliders cover each building and the ground")
		print("  at no less than two simulation steps.")
	else:
		print("  rain selftest FAILED: %d case(s)" % _fails)
	quit(1 if _fails > 0 else 0)
