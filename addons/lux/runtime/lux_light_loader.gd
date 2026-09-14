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
##   club_wash / neon -> LuxFluorescentRig in a coloured costume (0.37.0)
##   stage_light      -> LuxStageLightRig      room_ambient -> ReflectionProbe
##   (the club set: see CLUB_PALETTE and _club_rig below)
##
## TWO CALLERS, TWO CONTAINERS. `bake` is the editor's: everything in the
## manifest under `LuxLights`. `bake_daylight` is the pipeline's (0.30.0,
## roadmap 96): only the anchors that have NO hardware and therefore no
## `LuxEmit_*` marker for LuxFixtureSpawner to find -- `window` today --
## under `LuxDaylight`, beside the spawner's `LuxFixtureLights`. Before it,
## Deli Counter derived a window anchor per opening, Lot merged them, the
## manifest shipped them, and no built level ever turned one into light: the
## only caller of `bake` was the dock button.

const CONTAINER := "LuxLights"
const DAYLIGHT_CONTAINER := "LuxDaylight"

## The anchor types daylight owns. `sun` is the preset's and is never baked
## here; `window` is the one with no hardware and no marker.
const DAYLIGHT_TYPES: Array[String] = ["window"]

const CLUB_CONTAINER := "LuxClub"

## The club set (0.37.0). No hardware and no marker today, so like `window`
## they reach a level only through a manifest bake -- `bake_club` below.
const CLUB_TYPES: Array[String] = ["club_wash", "stage_light", "neon", "room_ambient"]

## THE CLUB PALETTE, and its names are a contract: Deli Counter writes them
## into an anchor's `color`. Saturated on purpose -- the walker's references
## (GTA IV's Triangle Club) are a room lit almost entirely by coloured light,
## with next to no white in it. Values are `light_color`, which Godot treats
## as an sRGB multiplier, each with its largest channel at 1.0 so that
## `energy` means the same thing for every colour. NOT luminance-matched: a
## blue pool at the same energy reads darker than an amber one, which is what
## the references show too.
const CLUB_PALETTE := {
	"magenta": Color(1.0, 0.0, 0.8),
	"hot_pink": Color(1.0, 0.12, 0.5),
	"red": Color(1.0, 0.04, 0.06),
	"violet": Color(0.55, 0.1, 1.0),
	"blue": Color(0.1, 0.2, 1.0),
	"cyan": Color(0.0, 0.8, 1.0),
	"amber": Color(1.0, 0.55, 0.08),
}
## The order a colour is picked in when an anchor names none. Appending keeps
## every existing pick where it was only if the list length does not change,
## so it does not: a new colour moves every derived pick. Say so if you add one.
const CLUB_COLOR_ORDER: Array[String] = ["magenta", "hot_pink", "red", "violet",
	"blue", "cyan", "amber"]

## A storey's drop when an anchor carries none: the 3.2 m ceiling Deli Counter
## writes for the strip clubs, less the 0.2 m slab gap. Only a fallback.
const CLUB_DEFAULT_DROP := 3.0

## HOW BRIGHT, AS A MULTIPLE OF THE OFFICE THE CLUB REPLACES. Every club
## energy below is solved from the falloff Godot applies (measured against
## this closed form under GL Compatibility, 4.7, RTX 2060: an omni and an
## 89-degree spot at 2.95 m over a matte floor, R 5.0, attenuation 2 and 1,
## 13 radii each, within 2% at every lit sample):
##
##     value(d) = energy * (1 - (d / R)^4)^2 / d^attenuation * cos(incidence)
##
## so that a club light puts LEVEL x what ONE fluorescent lamp from this
## loader puts on the floor straight below it at the same drop
## (`office_floor_value`). A number of that kind holds when the drop, the
## pool radius or the throw moves; a flat energy does not.
##
## The levels themselves are a LOOK, set against frames of a scratch copy of
## the vault_surface walk: country club_a01's grand lounge, 17 x 40 m, lamps
## at 3.39 m over a dark purple carpet, Heavy Rain, GL Compatibility, RTX
## 2060, the room's five fluorescents replaced by five washes, a two-spot
## stage light and two neons. RETRACTED FIRST GUESS, kept: the wash level was
## 1.0 -- "the office's own floor value, in colour" -- and in those frames it
## was invisible. Hiding every club light moved mean luma 57.8 -> 57.7;
## scaling the washes x4 and x8 at runtime moved it 49.0 -> 49.3 and 49.5, and chroma
## >= 40 stayed at 0.0% of the frame. The office row it replaced was just as
## invisible on that carpet: the room was lit by the environment (sky
## ambient, the unshadowed preset sun, fog), not by its fixtures. With the sun
## shadowed and fog off, washes read as coloured pools on the carpet and walls at x12
## (0.6% of the frame >= 40 chroma looking down the room, 1.3% at the stage)
## and the stage and neons already read at 3 and 1.5. So the wash level is
## 12. It is tuned to a dark floor; on a light one it will be loud.
const CLUB_WASH_LEVEL := 12.0
const CLUB_STAGE_LEVEL := 3.0
const CLUB_NEON_LEVEL := 1.5
## A room_ambient probe's ambient energy on its palette colour.
const ROOM_AMBIENT_ENERGY := 0.05
## How far a room_ambient probe's box stands proud of `size` on every side.
## MEASURED (GL Compatibility, a 10 x 3 x 10 m room of six planes, flat grey
## ambient, a black interior probe): a box exactly the room's size left the
## walls at the full environment ambient (RGB sum 317 of 317), the ceiling at
## 278 and the floor at 104 -- the faces ON the boundary fall outside it. Any
## margin from 0.05 m up took all three to 0, and blend_distance 1.0 or 0.1
## changed nothing. 0.1 is twice the smallest margin that worked.
const ROOM_AMBIENT_MARGIN := 0.1
## A wash's floor pool radius when the anchor carries none, per metre of drop.
const CLUB_WASH_RADIUS_PER_DROP := 1.25

## The fluorescent branch's energy and hang, named so the club rigs price
## themselves against the lamp that is actually built rather than a copy.
const FLUORESCENT_ENERGY := 1.0
const FLUORESCENT_MOUNT := -0.25


## Bake ONLY the daylight anchors of `path` under a `LuxDaylight` container,
## leaving whatever the marker path spawned alone. Returns {ok, msg, count,
## in_manifest} -- `in_manifest` is how many daylight anchors the file
## carried, so a caller can tell "none asked for" from "none made".
static func bake_daylight(path: String, scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "no scene root", "count": 0, "in_manifest": 0}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path, "count": 0,
			"in_manifest": 0}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors').",
			"count": 0, "in_manifest": 0}
	var old := scene_root.get_node_or_null(NodePath(DAYLIGHT_CONTAINER))
	if old != null:
		old.free()
	var container := Node3D.new()
	container.name = DAYLIGHT_CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root
	var made := 0
	var in_manifest := 0
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		if not DAYLIGHT_TYPES.has(String(a.get("type", ""))):
			continue
		in_manifest += 1
		var node := _rig_for(a)
		if node == null:
			continue
		container.add_child(node)
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1
	return {"ok": true, "count": made, "in_manifest": in_manifest,
		"msg": "Baked %d daylight rig(s) from %d window anchor(s)" % [made, in_manifest]}


## Bake ONLY the club anchors of `path` (CLUB_TYPES) under a `LuxClub`
## container, the same shape as `bake_daylight`: nothing else is touched, and
## the result says how many the file asked for. `refused` lists the ids the
## tuning table would not build -- an unknown colour name, a stage light with
## no target -- so a caller can tell a typo from an empty manifest. A caller
## that packs the scene must re-own the container's children, as Level
## Factory's driver already does for `LuxDaylight`.
static func bake_club(path: String, scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "no scene root", "count": 0, "in_manifest": 0,
			"refused": []}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path, "count": 0,
			"in_manifest": 0, "refused": []}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors').",
			"count": 0, "in_manifest": 0, "refused": []}
	var old := scene_root.get_node_or_null(NodePath(CLUB_CONTAINER))
	if old != null:
		old.free()
	var container := Node3D.new()
	container.name = CLUB_CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root
	var made := 0
	var in_manifest := 0
	var refused: Array = []
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		if not CLUB_TYPES.has(String(a.get("type", ""))):
			continue
		in_manifest += 1
		var node := _rig_for(a)
		if node == null:
			refused.append(String(a.get("id", "?")))
			continue
		container.add_child(node)
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1
	var msg := "Baked %d club rig(s) from %d club anchor(s)" % [made, in_manifest]
	if not refused.is_empty():
		msg += "; refused %s" % ", ".join(refused)
	return {"ok": refused.is_empty(), "count": made, "in_manifest": in_manifest,
		"refused": refused, "msg": msg}


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
			r.energy = FLUORESCENT_ENERGY   # per-light; rooms pack 5+ so they sum — 2.2
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
			r.light_range = fluorescent_range(drop)
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
			r.mount_height = FLUORESCENT_MOUNT
			r.flicker_amount = 0.12
			r.flicker_speed = 9.0
			_make_downlight(r)
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
			_make_downlight(rb)
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
			if t == "window":
				# A WINDOW'S RANGE, DERIVED LIKE EVERY OTHER TYPE'S. The rig's
				# own fallback is 4 x the panel's longer side -- 6.4 m for the
				# 1.6 m windows Deli Counter emits most, 9.6 for a 2.4 -- and
				# the anchor is the wall centreline (item 85 measured it at
				# -0.150 m by design), so half the sphere is indoors and
				# reaches two rooms of plates: cold run 9005 went from 2 to 12
				# meshes over the per-mesh budget of 8 the day its windows lit
				# (roadmap 137). What a window lights is the floor under its
				# sill and a few metres of room: twice the longer side, held
				# between 3.0 (a small window still reaches the floor from a
				# 1.6 m centre) and 4.0 (the fluorescent row's cap, item 54,
				# the same tiles). 1.6 -> 3.2, 2.4 -> 4.0.
				var longer := maxf(float(size[0]), float(size[1]))
				ar.omni_range = clampf(longer * 2.0, 3.0, 4.0)
				# The source inside the room, not on the centreline: half a
				# wall (0.15) plus the panel's own standoff (0.20), so the pool
				# lands on the floor in front of the glass rather than on the
				# ceiling and floor symmetrically at the wall (roadmap 145).
				ar.light_offset = Vector3(0.0, 0.0, 0.35)
				# NO PREVIEW QUAD IN A WINDOW: THE GLASS IS THE PANE. The quad
				# was the lit window while glazing was opaque (roadmap 138: a
				# near-black skin, so the room's light had to be painted on).
				# Since Pixelcoat 0.40.0 every theme's `glass` blends, and the
				# quad -- unshaded, emissive, double-sided, the size of the
				# opening, on the wall plane -- became the thing a viewer sees
				# through the glass from BOTH sides. Measured on a scratch copy
				# of walk 9050 with see-through panes, look_shots given
				# stations at the bank's west window: through the pane from the
				# street, mean RGB (177, 176, 164) std 26 -- a flat light panel
				# -- against the room's cabinet, ceiling lamp and back wall
				# once the quad is off; from inside, (191, 189, 176) std 17
				# against the sidewalk and the street. The omni is kept: it is
				# the daylight pool on the floor, and light, not a picture of
				# it, is what a lit room shows through glass at night.
				ar.show_emissive_quad = false
			else:
				# A SIGN'S SOURCE STANDS IN FRONT OF ITS CABINET. The anchor
				# is the sign's FACE plane (Deli Counter, 0.20 m proud of the
				# wall) and Zoo mounts `sign_box` CENTRED on it, 0.18 m deep
				# by its genome default -- so an omni at the anchor is inside
				# the cabinet, 0.09 m from every face of a 0.28-grey box at
				# energy 3.0. That is the "white box" walked on cold run 9005
				# (roadmap 139). Half the cabinet plus the same 0.20 standoff
				# the face itself keeps from the wall puts the source 0.29 m
				# ahead of the face: the cabinet is lit from outside like the
				# facade around it, and the pool lands on the pavement below.
				# The range is deliberately untouched here (4 x the panel's
				# longer side); a sign's reach is its own derivation.
				ar.light_offset = Vector3(0.0, 0.0, 0.18 * 0.5 + 0.20)
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
		"club_wash", "stage_light", "neon", "room_ambient":
			return _club_rig(t, a, row)
		_:
			return null   # 'sun' is owned by the preset/SkyMint; others skipped


## The fluorescent row's range rule (see its branch), as a function so the
## club rigs can price themselves against the same lamp.
static func fluorescent_range(drop: float) -> float:
	return clampf(drop + 0.75, 4.0, 7.5) if drop > 0.0 else 4.0


## The attenuation window Godot multiplies every omni and spot by (see the
## closed form over CLUB_WASH_LEVEL).
static func range_window(d: float, light_range: float) -> float:
	if light_range <= 0.0:
		return 0.0
	return pow(maxf(1.0 - pow(d / light_range, 4.0), 0.0), 2.0)


## What ONE fluorescent lamp from this loader puts on the floor straight
## below it at a room drop of `drop` metres: energy 1, attenuation 2, hung a
## hand's width under its anchor, range from `fluorescent_range`. At the
## strip clubs' 3.2 m that is 0.0570. The unit every club level is in.
static func office_floor_value(drop: float) -> float:
	var h := maxf(drop + FLUORESCENT_MOUNT, 0.25)
	return FLUORESCENT_ENERGY * range_window(h, fluorescent_range(drop)) / (h * h)


## The energy that puts `value` at distance `d` from a light of range
## `light_range` and attenuation 2, on a surface facing it. Capped at the 16
## LuxLightRig.energy allows; 0 when `d` is at or past the range.
static func energy_for(value: float, d: float, light_range: float) -> float:
	var w := range_window(d, light_range)
	if w <= 0.0:
		return 0.0
	return minf(value * d * d / w, 16.0)


## A stable 32-bit djb2 over the id's UTF-8 bytes. Spelled out instead of
## String.hash() so that Deli Counter can predict a derived colour in Python:
##     h = 5381
##     for b in s.encode("utf-8"): h = (h * 33 + b) & 0xFFFFFFFF
static func club_hash(s: String) -> int:
	var h := 5381
	for b in s.to_utf8_buffer():
		h = (h * 33 + b) & 0xFFFFFFFF
	return h


## The colour NAME an anchor gets: its own `color` when it has one, else the
## pick `CLUB_COLOR_ORDER[club_hash(id) % 7]`. Returns "" for a name that is
## not in CLUB_PALETTE -- a refusal, never a quiet substitute: a typo that
## silently became magenta would look like a design decision.
static func club_color_name(a: Dictionary) -> String:
	if a.has("color"):
		var n := String(a.get("color"))
		return n if CLUB_PALETTE.has(n) else ""
	return CLUB_COLOR_ORDER[club_hash(String(a.get("id", ""))) % CLUB_COLOR_ORDER.size()]


## Deli Counter Z-up [x, y, z] -> Godot Y-up (x, z, -y); see _place.
static func _godot_point(p: Variant) -> Vector3:
	if typeof(p) != TYPE_ARRAY or (p as Array).size() < 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[2]), -float(p[1]))


## THE CLUB SET (0.37.0). The walker, with two frames of GTA IV's Triangle
## Club: "strip clubs should have a dingy lived in feel, dark with colored
## lights, couches and bars". Deli Counter gives a club's main floor the same
## five cool fluorescent lamps as an office. These are what it can write
## instead; every range and energy is derived (see CLUB_WASH_LEVEL).
##
##   club_wash    a dim saturated pool for one zone of a room. The fluorescent
##                rig's machinery, one downlight per lamp (0.34.0's reason:
##                nothing through the slab above), `row` honoured. The pool's
##                floor radius is the anchor's `radius` or 1.25 x drop, held
##                to 1.5-6.0 m; range = the lamp-to-pool-edge distance
##                sqrt(h^2 + radius^2), capped at the fluorescent's 7.5 m for
##                the same per-mesh budget; energy puts CLUB_WASH_LEVEL x the
##                office lamp's floor value on the floor below it.
##   stage_light  SpotLight3D(s) aimed at `target` [x, y, z], the same frame as
##                `pos`. Refused without one. Cone half-angle atan(radius /
##                throw), `radius` default 1.5 m; range 1.25 x throw, so the
##                attenuation window at the target is a constant 0.349; energy
##                puts CLUB_STAGE_LEVEL x the office value on the target. A
##                `row` lays several spots along rot_y, each its own colour
##                (the anchor's, then onward through CLUB_COLOR_ORDER).
##                `cycle_s` > 0 steps every spot through the palette, holding
##                each colour that many seconds (LuxStageLightRig).
##   neon         a small omni at a lit sign or LED strip, for spill. Range
##                0.5 x the sign's longer side + 1.0 m, held to 1.0-2.5; energy
##                puts CLUB_NEON_LEVEL x the office value at half the range.
##                rot_y is the sign's FACING, as for `sign`, and a `row` runs
##                ALONG the wall (so _place gives it the area rigs' quarter
##                turn). The source stands AT the anchor: Deli Counter must put
##                it in free air, never inside a cabinet (roadmap 139).
##   room_ambient a ReflectionProbe the size of the room (`size` [x, y, z],
##                Deli Counter axes, centred on `pos`) plus ROOM_AMBIENT_MARGIN
##                a side, whose ambient replaces the environment's inside it.
##                The only per-room darkness GL Compatibility offers, and only
##                PART of one. MEASURED (tools/probe_weight_probe.gd, a 17 x
##                3.48 x 40 m room): the share of ambient the probe replaces is
##                the Environment's ambient_light_sky_contribution, whatever
##                the ambient source -- 1.0 takes every face to the probe's
##                colour, 0.5 (Heavy Rain, and LuxPreset's default) about half
##                in linear light, 0.0 nothing. RETRACTED, kept: a first reading
##                said "the sky-sampled share, never a flat colour"; it came
##                from a synthetic room whose fresh Environment defaulted to
##                contribution 1.0. The sun and fog are the scene's and no probe
##                touches them (see the 0.37.0 changelog).
##                Colour defaults to violet, not a hash pick.
##
## An unknown `color` name returns null with a warning, on every path.
static func _club_rig(t: String, a: Dictionary, row: Dictionary) -> Node3D:
	var id := String(a.get("id", t))
	var cname := club_color_name(a)
	if t == "room_ambient" and not a.has("color"):
		cname = "violet"
	if cname == "":
		push_warning("LuxLightLoader: %s '%s' names colour '%s', which is not one of %s -- not built"
			% [t, id, String(a.get("color")), ", ".join(CLUB_COLOR_ORDER)])
		return null
	var col: Color = CLUB_PALETTE[cname]
	var drop := float(a.get("drop", 0.0))
	if drop <= 0.0:
		drop = CLUB_DEFAULT_DROP
	var office := office_floor_value(drop)
	match t:
		"club_wash":
			var w := LuxFluorescentRig.new()
			w.name = id
			var rw := LuxLightRig.new()
			rw.rig_name = &"Club Wash (baked)"
			rw.light_color = col
			var h := maxf(drop + FLUORESCENT_MOUNT, 0.25)
			var radius := clampf(float(a.get("radius", drop * CLUB_WASH_RADIUS_PER_DROP)), 1.5, 6.0)
			rw.light_range = minf(sqrt(h * h + radius * radius), 7.5)
			rw.attenuation = 2.0
			rw.energy = energy_for(CLUB_WASH_LEVEL * office, h, rw.light_range)
			rw.count = int(row.get("count", 1))
			rw.spacing = float(row.get("spacing", 0.0))
			rw.mount_height = FLUORESCENT_MOUNT
			rw.flicker_amount = 0.0
			_make_downlight(rw)
			w.rig = rw
			return w
		"neon":
			var n := LuxFluorescentRig.new()
			n.name = id
			var rn := LuxLightRig.new()
			rn.rig_name = &"Neon (baked)"
			rn.light_color = col
			var longer := 0.5
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				longer = maxf(float(a.get("size")[0]), float(a.get("size")[1]))
			rn.light_range = clampf(longer * 0.5 + 1.0, 1.0, 2.5)
			rn.attenuation = 2.0
			rn.energy = energy_for(CLUB_NEON_LEVEL * office, rn.light_range * 0.5, rn.light_range)
			rn.count = int(row.get("count", 1))
			rn.spacing = float(row.get("spacing", 0.0))
			rn.mount_height = 0.0
			rn.flicker_amount = 0.0
			n.rig = rn
			return n
		"stage_light":
			if typeof(a.get("target")) != TYPE_ARRAY or (a.get("target") as Array).size() < 3:
				push_warning("LuxLightLoader: stage_light '%s' has no target [x, y, z] -- not built" % id)
				return null
			var aim_parent := _godot_point(a.get("target")) - _godot_point(a.get("pos"))
			var throw := aim_parent.length()
			if throw < 0.25:
				push_warning("LuxLightLoader: stage_light '%s' target is %.2f m from its pos -- not built"
					% [id, throw])
				return null
			var s := LuxStageLightRig.new()
			s.name = id
			# _place turns the rig by rot_y AFTER this; express the aim in the
			# rig's own frame so the turn carries it back onto the target.
			s.aim_local = Basis(Vector3.UP, deg_to_rad(float(a.get("rot_y", 0.0)))).inverse() * aim_parent
			var sradius := clampf(float(a.get("radius", 1.5)), 0.5, 4.0)
			s.spot_angle_deg = clampf(rad_to_deg(atan(sradius / throw)), 3.0, 60.0)
			s.spot_rim = 0.5
			var base := CLUB_COLOR_ORDER.find(cname)
			var cols := PackedColorArray()
			for k in CLUB_COLOR_ORDER.size():
				cols.append(CLUB_PALETTE[CLUB_COLOR_ORDER[(base + k) % CLUB_COLOR_ORDER.size()]])
			s.colors = cols
			s.cycle_period_s = maxf(float(a.get("cycle_s", 0.0)), 0.0)
			var rs := LuxLightRig.new()
			rs.rig_name = &"Stage Light (baked)"
			rs.light_color = col
			rs.light_range = clampf(throw * 1.25, 2.0, 12.0)
			rs.attenuation = 2.0
			rs.energy = energy_for(CLUB_STAGE_LEVEL * office, throw, rs.light_range)
			rs.count = int(row.get("count", 1))
			rs.spacing = float(row.get("spacing", 0.0))
			rs.mount_height = 0.0
			s.rig = rs
			return s
		"room_ambient":
			var sz: Variant = a.get("size")
			if typeof(sz) != TYPE_ARRAY or (sz as Array).size() < 3:
				push_warning("LuxLightLoader: room_ambient '%s' has no size [x, y, z] -- not built" % id)
				return null
			var probe := ReflectionProbe.new()
			probe.name = id
			probe.size = Vector3(absf(float(sz[0])), absf(float(sz[2])), absf(float(sz[1]))) \
				+ Vector3.ONE * 2.0 * ROOM_AMBIENT_MARGIN
			probe.interior = true
			probe.update_mode = ReflectionProbe.UPDATE_ONCE
			probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
			probe.ambient_color = col
			probe.ambient_color_energy = ROOM_AMBIENT_ENERGY
			probe.blend_distance = 0.1
			return probe
	return null


## CEILING LAMPS LIGHT DOWNWARD, NOT THROUGH THE SLAB ABOVE (0.34.0). A person
## walking cold run 9048 saw "light coming from a basement fixture through the
## wall": a basement pendant hangs 0.70 m under its slab with a 3.6 m range,
## so as an unshadowed omni it lit the ground floor's walls up to a metre
## above that floor. Collision never blocks light; only a shadow map does.
##
## Measured with LuxLeakMeter on that walk copy, 512 rays per light, the 76
## unshadowed ceiling rigs (55 fluorescent, 21 pendant):
##
##   * 66 of 76 lit an exposed surface behind a collider; 56 of those
##     through the slab ABOVE them.
##   * (a) CLAMPING RANGE TO THE ROOM DOES NOT WORK. For 57 of the 66, the
##     largest range that leaks nothing halves or zeroes the light on the
##     lamp's own floor directly below: a lamp hangs 0.25-0.70 m under the slab
##     above and 2.6-3.2 m over its floor, and the pool has to reach the floor
##     (the drop rule above).
##   * (b) SHADOWS DO NOT FIT. 66 more casters at the ~0.3 ms each that 0.32.1
##     priced is ~20 ms on the RTX 2060, against a High budget of 12 that the
##     signs, packs and windows already spend.
##   * (c) PER-STOREY CULL LAYERS would mean re-layering geometry Lux does not
##     own, and do nothing for the lamp beside a wall.
##   * A DOWNWARD CONE, per angle and rim (energy-weighted leak / own-room
##     light below the lamp plane, omni = 125.1 / 692):
##
##         89 deg, rim 1.0     6.46 / 389  (56%)   Lambertian falloff
##         89 deg, rim 0.5     7.24 / 479  (69%)
##         89 deg, rim 0.25    7.53 / 551  (80%)
##         89 deg, rim 0.125   7.63 / 604  (87%)
##
##     Leak falls 94% at every setting and the slab-above leak to zero; the
##     rim decides how much of the room's own light survives. 0.125 keeps 87%
##     and is what ships. The 13% lost is the band just under the ceiling at
##     grazing angles. The ceiling itself is no longer lit by its own fixture
##     and reads from the environment's ambient, like a recessed troffer --
##     which for a BARE BULB is a visible change: the warm wash a basement
##     bulb threw on its own ceiling is gone (look_shots, same walk copy).
##
##     Confirmed by re-spawning that level's fixtures through this loader and
##     the one before it, same meter, 512 rays: own light below the lamp plane
##     157.9 -> 137.8 on the fluorescent rows (87.2%), 553.1 -> 482.6 on the
##     pendants (87.3%); lights leaking into the storey above 56 -> 0.
##
## Cost: no shadow maps; one positional light per lamp, as before. At 89
## degrees a spot's culling box (printed from `get_aabb()`) is the lower HALF
## of the omni's 2R cube, so a mesh wholly above the lamp plane -- the ceiling
## plate it hangs under -- should no longer be paired with it. That last part
## is the engine's pairing rule as understood, not yet measured against a
## per-mesh census (roadmap 54).
## What is left leaking (40 of 76 lights at 512 rays, 6% of the old energy)
## goes through the floor below the lamp and walls beside it -- measured, not
## fixed here.
static func _make_downlight(r: LuxLightRig) -> void:
	r.downlight_angle_deg = 89.0
	r.downlight_rim = 0.125


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
	# YAW, and which way a rig FACES. Deli Counter's rot_y is measured from
	# +X toward +Y (its docs: "rot_y 0 == +X"); under the axis swap, DC
	# (cos t, sin t) lands on Godot (cos t, 0, -sin t), and a rig that lays
	# its lamps along local +X (the fluorescent row) reaches that with
	# rotation.y = t exactly -- which is what this always did. An AREA rig
	# faces local +Z (QuadMesh's normal), and rotation.y = f turns +Z onto
	# (sin f, 0, cos f); equating gives f = t + 90. Without the quarter turn
	# every baked window panel stood PERPENDICULAR to its wall -- first seen
	# 2026-09-11, the day the pipeline first called this path (roadmap 96),
	# as white quads sticking out of cold run 9005's west facade in the S
	# elevation. The omni beneath it never cared; only the quad did.
	var yaw := float(a.get("rot_y", 0.0))
	# A neon's rot_y is its sign's facing and its row runs along the wall, so
	# it takes the area rigs' quarter turn: local +X (the row) lands on the
	# wall, local +Z on the facing (0.37.0).
	if node is LuxAreaLightRig or String(a.get("type", "")) == "neon":
		yaw += 90.0
	node.rotation = Vector3(0.0, deg_to_rad(yaw), 0.0)


static func _reown(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_reown(c, root)
