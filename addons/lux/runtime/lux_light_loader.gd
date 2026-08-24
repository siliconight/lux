@tool
class_name LuxLightLoader
extends RefCounted
## Bakes a Deli Counter `<name>.lights.json` into the open scene: one Lux rig per
## light anchor, placed at the anchor. Deli Counter emits in Blender Z-up space;
## Godot imports the level GLB as Y-up, so anchor coordinates are converted to
## match (see _place). The rigs self-register with a LuxRoot when one is present,
## so presets and the alarm pulse drive them.
##
## Editor-time tool -- driven by the Lux dock's "Bake Lights" section.
##
## The anchor `type` maps 1:1 onto a Lux rig:
##   fluorescent -> LuxFluorescentRig   window / sign -> LuxAreaLightRig
##   streetlight -> LuxStreetlightRig    wall_pack    -> LuxStreetlightRig (x1)
##   sun -> handled by the preset. Zoo's fixture pass (--fixtures) bakes the
##   matching HARDWARE at the same anchors; LuxEmissiveBinder ties its lit
##   faces to set_fixtures_powered.

const CONTAINER := "LuxLights"


## Read `path`, replace any previous bake, and spawn a rig per anchor under a
## `LuxLights` container. Returns {ok, msg, count}.
##
## `lightmap_static` (pc2000 family): spawn every rig with Light3D bake mode
## STATIC and flicker off, ready for a LightmapGI bake. Lightmapped surfaces
## then ignore these lights' realtime contribution (no double-lighting) while
## dynamic objects still receive them live. NOTE: after a bake, edits to rig
## energy/colour need a RE-BAKE to show on lightmapped geometry.
static func bake(path: String, scene_root: Node, lightmap_static: bool = false) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "Open a scene first."}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors')."}

	clear(scene_root)
	var container := Node3D.new()
	container.name = CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root

	var made := 0
	var skipped := 0
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var node := _rig_for(a)
		if node == null:
			skipped += 1
			continue
		if lightmap_static:
			_make_lightmap_static(node)
		container.add_child(node)          # _ready builds the lights here
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1

	var has_root := not scene_root.get_tree().get_nodes_in_group(
		&"lux_root").is_empty()
	var msg := "Baked %d light rig(s)" % made
	if lightmap_static:
		msg += " [lightmap static]"
	if skipped > 0:
		msg += " (%d unsupported skipped)" % skipped
	if not has_root:
		msg += ". No LuxRoot in the scene -- add one so presets drive these."
	return {"ok": true, "msg": msg, "count": made}


## The rig for an anchor dict — the one tuning table for both paths: the
## manifest bake above and LuxFixtureSpawner's marker path (v0.15). An
## anchor without a `row` is a single lamp. Returns null for daylight /
## unknown types.
static func rig_for_anchor(a: Dictionary) -> Node3D:
	return _rig_for(a)


## Remove a previous bake (the whole LuxLights container). Returns how many.
static func clear(scene_root: Node) -> int:
	if scene_root == null:
		return 0
	var n := scene_root.get_node_or_null(NodePath(CONTAINER))
	if n != null:
		n.free()
		return 1
	return 0


static func _rig_for(a: Dictionary) -> Node3D:
	var t := String(a.get("type", ""))
	var row: Dictionary = {}
	if typeof(a.get("row")) == TYPE_DICTIONARY:
		row = a.get("row")
	match t:
		"fluorescent":
			var f := LuxFluorescentRig.new()
			f.name = String(a.get("id", "fluorescent"))
			var r := LuxLightRig.new()
			r.rig_name = &"Fluorescent (baked)"
			r.light_color = LuxColorTemp.cool_fluorescent()
			r.energy = 1.0          # per-light; rooms pack 5+ so they sum — 2.2
			                        # each blew interiors to white. Tune per bake.
			# RANGE IS DERIVED FROM THE ANCHOR'S DROP TO ITS FLOOR
			# (deli_counter >= 0.97 stamps `drop`), because a flat number was
			# wrong at both ends inside one day. At a flat 8.0 the engine
			# bound every lamp to every MESH within range THROUGH WALLS --
			# each mesh renders at most `max_lights_per_object` of its
			# claimants, the worst ceiling tile had 23 for 8 slots, adjacent
			# tiles bound DIFFERENT winning sets, and the walk at the engine
			# default showed the difference as a hard-edged brightness grid
			# (roadmap 54). At a flat 4.5 the arena's ~5.7 m hall had a lit
			# ceiling over a PITCH-BLACK floor: attenuation reaches hard zero
			# at the range, so no energy value lights a floor the range does
			# not reach. drop + 1.5 lit every floor, and census #6 (the
			# first with `drop` alive end to end, 2026-08-24) priced it: 14
			# ceiling plates at 9-10 claimants for 8 slots. Plates are where
			# lamps HANG, so every lamp within range claims a slot on them,
			# the next room's included -- walls are not part of the engine's
			# binding question. Census #7's margin forensics then priced
			# the next cut exactly: at drop + 1.0 the b0 slab tiles'
			# excess claimants bound with 0.17 m to spare, so a 0.25 m trim
			# sheds them. drop + 0.75 still floors a
			# sqrt(1.5 * drop + 0.5625) m pool under each lamp (arena
			# 3.0 m against the 2.83 m a 4 m grid diagonal needs, office
			# 2.4 m against 2.0 m rows), and the clamp keeps low rooms at
			# the short trim and stops tall halls from re-claiming the
			# whole per-mesh budget. The margins the same census measured
			# on b1's tiles (0.44+) and the 52 m parapet (1.59) are NOT
			# payable in range -- those are geometry work, not tuning. If
			# interiors read too dark BETWEEN fixtures, raise `energy`,
			# never this.
			var drop := float(a.get("drop", 0.0))
			r.light_range = clampf(drop + 0.75, 4.0, 7.5) if drop > 0.0 else 4.0
			# Inverse-square falloff: at the default near-linear 1.0 the pool
			# cuts to zero AT the range and rims every ceiling with a visible
			# circle (walked 2026-08-23, zoo corridor). 2.0 fades out inside
			# the range and the edge disappears.
			r.attenuation = 2.0
			r.count = int(row.get("count", 1))
			r.spacing = float(row.get("spacing", 0.0))
			# A hand's width BELOW the anchor: a lamp sitting on the ceiling
			# plane spends half its sphere grazing the ceiling -- streaks at
			# glancing angles and a scorched ring around the fixture (same
			# walk). Real tubes hang; ours do now too.
			r.mount_height = -0.25
			r.flicker_amount = 0.12
			r.flicker_speed = 9.0
			f.rig = r
			return f
		"pendant":
			# The 90s below-grade bulb (deli_counter >= 0.98 derives the
			# type: basements and objective rooms trade the office row for
			# sparse pendants). The fluorescent rig's machinery -- a row of
			# omnis -- wearing an incandescent costume: warm, tight, and
			# wavering slightly the way a filament does, not the way a tube
			# stutters.
			var b := LuxFluorescentRig.new()
			b.name = String(a.get("id", "pendant"))
			var rb := LuxLightRig.new()
			rb.rig_name = &"Bare Bulb (baked)"
			rb.light_color = LuxColorTemp.kelvin(LuxColorTemp.INCANDESCENT)
			rb.energy = 1.3
			# Tighter clamp than the fluorescent on purpose: a bare bulb is
			# a pool, not a wash -- but the pool still has to reach the
			# floor, so the drop rule applies (see the fluorescent comment).
			var bdrop := float(a.get("drop", 0.0))
			rb.light_range = clampf(bdrop + 1.0, 3.5, 6.5) if bdrop > 0.0 else 4.0
			rb.count = int(row.get("count", 1))
			rb.spacing = float(row.get("spacing", 0.0))
			rb.mount_height = 0.0
			rb.flicker_amount = 0.06
			rb.flicker_speed = 2.5
			b.rig = rb
			return b
		"streetlight":
			var s := LuxStreetlightRig.new()
			s.name = String(a.get("id", "streetlight"))
			var rs := LuxLightRig.new()
			rs.rig_name = &"Streetlight (baked)"
			rs.light_color = LuxColorTemp.kelvin(LuxColorTemp.SODIUM_VAPOR)
			rs.energy = 6.0
			rs.light_range = 14.0
			rs.count = int(row.get("count", 1))
			rs.spacing = float(row.get("spacing", 8.0))
			rs.mount_height = 0.0
			# BUZZING POLES (90s decay): every third pole gets the dying
			# ballast. Keyed on the anchor's own id -- deterministic, so the
			# SAME pole buzzes in every build of every seed, and an authored
			# rename is the only thing that moves it. Position would drift
			# with layout; ids are the stable name for a place.
			if String(a.get("id", "")).hash() % 3 == 0:
				rs.flicker_amount = 0.22
				rs.flicker_speed = 7.0
			s.rig = rs
			return s
		"wall_pack":
			# A wall pack is one downward warm spot — the streetlight rig
			# with count 1 is exactly that. The anchor sits proud of the
			# wall in free air (DC v1.1), so the spot is never inside the
			# hardware Zoo bakes at the same anchor.
			var wp := LuxStreetlightRig.new()
			wp.name = String(a.get("id", "wall_pack"))
			var rw := LuxLightRig.new()
			rw.rig_name = &"Wall Pack (baked)"
			rw.light_color = LuxColorTemp.kelvin(LuxColorTemp.HALOGEN)
			rw.energy = 2.5
			# 5.5, down from 7.0 — same per-mesh budget law as the
			# fluorescent trim above, scaled for an outdoor pool. Wall packs
			# face exterior walls and ground tiles, and at 7.0 they stacked
			# with streetlights on the path tiles.
			rw.light_range = 5.5
			rw.count = 1
			rw.spacing = 0.0
			rw.mount_height = 0.0
			wp.rig = rw
			return wp
		"window", "sign":
			var ar := LuxAreaLightRig.new()
			ar.name = String(a.get("id", "window"))
			var size: Array = [1.4, 1.4]
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				size = a.get("size")
			ar.panel_size = Vector2(float(size[0]), float(size[1]))
			var ra := LuxLightRig.new()
			ra.rig_name = &"Window (baked)"
			ra.light_color = LuxColorTemp.kelvin(LuxColorTemp.DAYLIGHT)
			ra.energy = 3.0
			# THE ONLY SHADOWED LIGHTS IN THE PACKAGE (roadmap 60, first
			# tier). An area rig hangs ON the building envelope at energy
			# 3.0, so half its sphere is always inside the building it is
			# mounted to: walked 2026-08-24, arena_a03's interior ceiling
			# carried the wash of the sign OUTSIDE its own south wall.
			# Collision never blocks light in GL Compatibility -- a shadow
			# map is the only occlusion that exists -- and this is the one
			# class where it is affordable: lot_demo_001 ships FOUR area
			# rigs against ~128 interior fixtures. Legitimate spill
			# survives (a shadow map blocks walls, not doorways). If
			# interiors ever earn shadows, that is the quality-profile
			# decision item 60 still owns -- do not default them on there.
			ra.shadows_enabled = true
			ar.rig = ra
			return ar
		_:
			return null   # 'sun' is owned by the preset/SkyMint; others skipped


## Flip a freshly-built rig's resource to bake-static BEFORE it enters the
## tree (so _ready spawns the lights already carrying BAKE_STATIC). Flicker is
## zeroed — a frozen lightmap can't flicker, and half-flickering dynamic
## objects against a steady baked room reads as a bug.
static func _make_lightmap_static(node: Node3D) -> void:
	var rr: Variant = node.get(&"rig")
	if rr is LuxLightRig:
		var r := rr as LuxLightRig
		r.bake_mode = 1
		r.flicker_amount = 0.0


static func _place(node: Node3D, a: Dictionary) -> void:
	var p: Array = [0.0, 0.0, 0.0]
	if typeof(a.get("pos")) == TYPE_ARRAY and (a.get("pos") as Array).size() >= 3:
		p = a.get("pos")
	# Deli Counter is Blender Z-up; the level GLB imports as Godot Y-up. Match
	# the glTF axis swap: (x, y, z_up) -> (x, z_up, -y).
	# If a bake looks mirrored or rotated wrong, THIS line and the yaw below are
	# the two things to flip.
	node.position = Vector3(float(p[0]), float(p[2]), -float(p[1]))
	node.rotation = Vector3(0.0, deg_to_rad(float(a.get("rot_y", 0.0))), 0.0)


static func _reown(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_reown(c, root)
