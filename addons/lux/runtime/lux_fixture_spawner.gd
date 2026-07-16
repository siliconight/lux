@tool
class_name LuxFixtureSpawner
extends RefCounted
## Spawns Lux light rigs at Zoo's emitter markers (v0.15, pairs with Zoo v0.30).
##
## Zoo's fixture builds (`zoo --fixtures`) export one `LuxEmit_<type>` empty
## per lamp at the EMITTER point, with the placement payload in glTF extras
## (imported by Godot as node metadata: `lux_type`, `lux_anchor_id`,
## `lux_slot`, `lux_reacts_to_alarm`). This walks a scene for those markers
## and puts the matching rig — count 1, markers are per-lamp; Zoo already
## expanded rows — at each marker's transform. The fixture GLB is the single
## source of placement truth: drag it anywhere (Level Factory assembly or by
## hand) and call spawn(); the light lands inside the hardware, always.
##
## Division of labor is unchanged: Zoo owns WHERE (geometry + markers), Lux
## owns HOW BRIGHT (rig tuning per type via LuxLightLoader.rig_for_anchor).
## Daylight (window/sun) has no hardware, no markers, and stays on the
## manifest bake path — which also means spawned lights are exactly the set
## `set_fixtures_powered(false)` SHOULD kill: interior/exterior building
## power, never light coming in through glass.
##
## Editor: the Lux dock's "Spawn From Fixtures" button.
## Runtime: `LuxFixtureSpawner.spawn(level_root)` once after the level loads.

const MARKER_PREFIX := "LuxEmit"
const CONTAINER := "LuxFixtureLights"


## Walk `scene_root` for emitter markers, replace any previous spawn, and
## put one rig per marker under a `LuxFixtureLights` container (parented to
## `parent`, default `scene_root`). Returns {ok, msg, count, skipped}.
static func spawn(scene_root: Node, parent: Node = null) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "Open a scene first.", "count": 0}
	var host := parent if parent != null else scene_root
	clear(host)

	var markers: Array = []
	collect_markers(scene_root, markers)
	if markers.is_empty():
		return {"ok": true, "count": 0, "skipped": [],
			"msg": "No %s_* fixture markers in the scene. Import a Zoo v0.30+ fixtures GLB first." % MARKER_PREFIX}

	var container := Node3D.new()
	container.name = CONTAINER
	host.add_child(container)
	var edited_root: Node = null
	if Engine.is_editor_hint() and host.get_tree() != null:
		edited_root = host.get_tree().edited_scene_root
	if edited_root != null:
		container.owner = edited_root

	var made := 0
	var skipped: Array = []
	for m in markers:
		var mk := m as Node3D
		var t := marker_type(mk)
		if t == "" or t == "window" or t == "sun":
			skipped.append({"marker": String(mk.name),
				"reason": "no spawnable type ('%s')" % t})
			continue
		# Markers are per-lamp: no row. Zoo carried DC's sizing into the
		# hardware itself, so type + transform is the whole contract here.
		# The rig gets a Spawned_ name, NOT the marker's — the loader names
		# rigs after the anchor id, and reusing the marker name would give
		# spawned rigs the LuxEmit prefix, double-counting them in every
		# prefix-based scan (validator counted 40 "markers" for 20 on the
		# first hardware run).
		var rig := LuxLightLoader.rig_for_anchor({"type": t,
			"id": "Spawned_" + String(mk.name).trim_prefix(MARKER_PREFIX).trim_prefix("_")})
		if rig == null:
			skipped.append({"marker": String(mk.name),
				"reason": "no rig for type '%s'" % t})
			continue
		container.add_child(rig)
		if edited_root != null:
			rig.owner = edited_root
		rig.global_transform = mk.global_transform
		made += 1

	var msg := "Spawned %d fixture light(s) from %d marker(s)" % [made, markers.size()]
	if not skipped.is_empty():
		msg += " (%d skipped)" % skipped.size()
	return {"ok": true, "msg": msg, "count": made, "skipped": skipped}


## Remove a previous spawn (the whole LuxFixtureLights container).
static func clear(host: Node) -> int:
	if host == null:
		return 0
	var n := host.get_node_or_null(NodePath(CONTAINER))
	if n != null:
		n.free()
		return 1
	return 0


## Every emitter-marker Node3D under `node`, by name prefix. Blender dedupes
## repeats (.001) and Godot's importer swaps the dot for an underscore, so
## prefix is the only stable part of the name.
static func collect_markers(node: Node, out: Array) -> void:
	if node is Node3D and String(node.name).begins_with(MARKER_PREFIX):
		out.append(node)
	for c in node.get_children():
		collect_markers(c, out)


## A marker's anchor type: metadata first (glTF extras -> node meta, exact),
## name parse second (strip prefix, drop numeric dedup suffixes).
static func marker_type(mk: Node) -> String:
	if mk.has_meta(&"lux_type"):
		return String(mk.get_meta(&"lux_type"))
	var s := String(mk.name).trim_prefix(MARKER_PREFIX).trim_prefix("_")
	var parts := s.split("_")
	while parts.size() > 1 and parts[parts.size() - 1].is_valid_int():
		parts.remove_at(parts.size() - 1)
	return "_".join(parts)
