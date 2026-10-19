extends SceneTree
## Lux's runtime scaffolding stays ownerless in the editor unless a LuxRoot asks (0.78.0, the factory's roadmap 24).
##
##     godot --headless --path lux -s res://tools/scaffold_owner_selftest.gd
##
## Exit 0 = every check held. Exit 1 = a check failed. Exit 2 = could not run.
##
## The behaviour needs the editor, so it is proven where the defect was measured: the factory's
## docs/findings/lux_owner_24/owner_probe.py opens a shipped scene in the headless editor, saves it and diffs --
## 7 nodes added on 0.77.0, none on 0.78.0. This holds the rule in the source, outside the editor: LuxRoot carries
## `persist_scaffolding_in_editor`, off by default, and every editor-time owner assignment in the environment,
## lighting and post-FX modules asks it. Fails on 0.77.0, which has no setting.

const ROOT_SCRIPT := "res://addons/lux/runtime/lux_root.gd"
const MODULES := ["res://addons/lux/runtime/lux_environment.gd", "res://addons/lux/runtime/lux_lighting.gd",
	"res://addons/lux/runtime/lux_post_fx.gd"]

var _fails: int = 0


func _initialize() -> void:
	_main()


func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("%s  %s" % ["ok  " if ok else "FAIL", label])


func _main() -> void:
	if not ResourceLoader.exists(ROOT_SCRIPT):
		print("could not run: no %s" % ROOT_SCRIPT)
		quit(2)
		return
	var script: GDScript = load(ROOT_SCRIPT) as GDScript
	var found: bool = false
	var default_off: bool = false
	for p in script.get_script_property_list():
		if String(p.get("name", "")) == "persist_scaffolding_in_editor":
			found = true
	if found:
		default_off = script.get_property_default_value(&"persist_scaffolding_in_editor") == false
	_check("LuxRoot carries persist_scaffolding_in_editor", found)
	_check("and it is off by default", default_off)
	for path in MODULES:
		var src: String = FileAccess.get_file_as_string(path)
		var sites: int = 0
		var asked: int = 0
		var lines: PackedStringArray = src.split("\n")
		for i in range(lines.size()):
			var ln: String = lines[i]
			if ln.contains("Engine.is_editor_hint()") and ln.contains("get_tree() != null"):
				sites += 1
				var block: String = ln + (lines[i + 1] if i + 1 < lines.size() else "")
				if block.contains("persist_scaffolding_in_editor"):
					asked += 1
		_check("%s: %d editor-time owner site(s), every one asks the LuxRoot" % [path.get_file(), sites],
			sites > 0 and asked == sites)
	print("selftest: %d check(s) failed" % _fails)
	quit(1 if _fails > 0 else 0)
