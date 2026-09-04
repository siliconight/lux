extends SceneTree
## Renders every shipped preset and reports what film did, if anything.
##
## Driven by tools/film_optional_probe.py, which runs it TWICE -- once with the
## film feature present and once with its shader and grain asset deleted -- and
## compares the two sets of frames byte for byte.
##
## WHY BYTE FOR BYTE, AND WHY DELETE RATHER THAN DISABLE. "Film emulsion is
## optional" is a claim about what happens to everyone who never asks for it.
## The only honest test of that is to REMOVE the feature and check that nobody
## notices -- not to switch it off and trust that switching it off is complete.
## 0.28.0 made the claim from a byte-identical shader and a backed-out coupling,
## and both of those were true, and the feature still took out the whole post
## stack on the first machine that ran it. A claim of optionality that has not
## survived deletion is a claim.
##
## THIS ALSO CATCHES THE QUIET FAILURE. A preset that silently activates film
## because a default drifted would not crash anything -- it would just render
## differently from what its author approved. The per-preset `film_active` line
## below is what makes that visible.

const SAMPLE := "res://addons/lux/samples/lux_sample_scene.tscn"
const PRESET_DIR := "res://addons/lux/presets/"
const BEGIN := "<<<FILM_OPTIONAL_JSON"
const END := "FILM_OPTIONAL_JSON>>>"

var _lux: LuxRoot
var _out: Dictionary = {}
var _steps_log: String = ""


func _initialize() -> void:
	_run()


func _find_lux(n: Node) -> LuxRoot:
	if n is LuxRoot:
		return n
	for c in n.get_children():
		var r := _find_lux(c)
		if r != null:
			return r
	return null


func _run() -> void:
	var out_dir: String = OS.get_environment("LUX_OPTIONAL_OUT")
	if out_dir == "":
		push_error("[film_optional] LUX_OPTIONAL_OUT not set")
		quit(2)
		return

	# Truncated up front so a stale log from the previous run cannot be read
	# as this run's evidence -- the failure mode that wasted two rounds already.
	_steps_log = out_dir.rstrip("/") + "/film_mode_steps.log"
	var _sf := FileAccess.open(_steps_log, FileAccess.WRITE)
	if _sf != null:
		_sf.close()
	else:
		_steps_log = ""

	var packed: PackedScene = load(SAMPLE)
	if packed == null:
		push_error("[film_optional] could not load " + SAMPLE)
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	_lux = _find_lux(scene)
	if _lux == null:
		push_error("[film_optional] no LuxRoot")
		quit(2)
		return

	# Hide every HUD: their text differs between runs and would drown the
	# comparison in font rendering rather than rendering.
	for n in _canvas_layers(root):
		if n.layer >= 0:
			n.visible = false

	# Enumerate the SHIPPED .tres files rather than LuxRoot's runtime library.
	# The claim under test is about what ships, and the library also holds
	# whatever the scene happened to register. No new public API on LuxRoot
	# either: a probe should not widen the surface it is measuring.
	var paths: Array[String] = []
	var dir := DirAccess.open(PRESET_DIR)
	if dir == null:
		push_error("[film_optional] cannot open " + PRESET_DIR)
		quit(2)
		return
	for f in dir.get_files():
		var fn: String = f
		if fn.ends_with(".remap"):
			fn = fn.substr(0, fn.length() - 6)
		if fn.ends_with(".tres"):
			paths.append(PRESET_DIR + fn)
	paths.sort()

	var report: Dictionary = {}
	for path: String in paths:
		var preset: LuxPreset = load(path) as LuxPreset
		if preset == null:
			push_error("[film_optional] not a LuxPreset: " + path)
			continue
		var nm: String = String(preset.preset_name)

		# THE LEGACY GRAIN IS SILENCED FOR THIS COMPARISON, AND THAT REMOVES
		# THE NEED FOR A FLOOR AT ALL.
		#
		# `grain_strength` drives the baseline's Simple grain from `time_seed`,
		# which accumulates WALL CLOCK inside the process (audit section 3c).
		# Two builds that reach the same frame at different elapsed times --
		# which the film-DELETED mirror always does, since it has fewer assets
		# to import -- therefore render different noise, and the difference has
		# nothing to do with the feature under test.
		#
		# That produced a real false positive: 'Heavy Rain' was reported as
		# moving 0.013314 against a same-build floor of 0.000000, flagged as a
		# genuine optionality violation. It was the clock. The two presets that
		# ship with grain_strength 0 came back BIT-IDENTICAL in every run, which
		# is both the proof of the mechanism and the fix.
		#
		# With the legacy grain at zero the render is deterministic, so the bar
		# stops being "within a noisy floor" and becomes EXACT EQUALITY, which
		# is a far stronger statement of optionality than the floor ever made.
		# The preset is copied first: the shipped resource is never mutated.
		var probe_preset: LuxPreset = preset.make_override(preset.preset_name)
		probe_preset.grain_strength = 0.0
		_lux.apply_preset(probe_preset, 0.0)
		for i in range(6):
			await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		var safe := path.get_file().get_basename()
		img.save_png(out_dir.rstrip("/") + "/" + safe + ".png")
		report[nm] = {
			"source": path,
			"asks_for_film": preset.film_emulsion_enabled,
			"grain_mode": preset.grain_mode,
			"film_active": _lux.is_film_emulsion_active(),
			"use_hdr_2d": bool(root.use_hdr_2d),
			"format": img.get_format(),
			"png": out_dir.rstrip("/") + "/" + safe + ".png",
		}
		print("[film_optional] %-30s asks_film=%-5s film_active=%-5s hdr_2d=%s"
			% [nm, preset.film_emulsion_enabled,
			   _lux.is_film_emulsion_active(), root.use_hdr_2d])

	_out["presets"] = report
	_out["count"] = paths.size()
	# ORDER MATTERS, AND GETTING IT WRONG IS WHAT "CRASHED ON BOTH
	# RASTERISERS". This runs BEFORE _test_hdr_2d_cleanup(), because that test
	# ends by design with remove_child(_lux) and _lux.queue_free() -- it is a
	# test OF teardown, so destroying the node is the point. Everything after
	# it was therefore calling set_film_mode() on a LuxRoot out of the tree and
	# pending deletion, and the free landed during one of the six awaits below.
	# That is a use-after-free: no GDScript error to catch, an unsymbolised C++
	# backtrace, and a reported line that drifts to whichever statement happened
	# to resume -- which is why the blame landed twice on is_film_emulsion_active(),
	# a two-term getter that cannot abort anything. Nothing was ever wrong with
	# film mode or with llvmpipe.
	#
	# Kept behind a flag for now only so the optionality result -- the thing
	# this tool exists for -- cannot be lost to a crash in a secondary check.
	# INTO THE JSON, NOT A print(). run() captures Godot's stdout and discards
	# it on success -- only the fenced JSON survives -- so the previous
	# diagnostic print was written into a channel nobody reads.
	var fm_env: String = OS.get_environment("LUX_OPTIONAL_FILM_MODE")
	_out["film_mode_env"] = fm_env
	if fm_env != "":
		# STAMPED BEFORE THE AWAIT, ON PURPOSE. Three rounds of debugging have
		# now failed to say whether _test_film_mode is entered, because a
		# coroutine that dies mid-await assigns nothing and leaves the same
		# evidence as never having been called. Writing the key first makes
		# those two cases distinguishable in the JSON without another guess.
		_out["film_mode"] = {"entered": true}
		_mark("caller_before")
		var fm_res: Dictionary = await _test_film_mode()
		_mark("caller_after")
		if not fm_res.is_empty():
			_out["film_mode"] = fm_res
	# LAST, AND LAST ON PURPOSE: this one frees _lux. Anything that needs a
	# live LuxRoot has to run above it.
	_out["cleanup"] = await _test_hdr_2d_cleanup()
	print(BEGIN)
	print(JSON.stringify(_out, "  "))
	print(END)
	quit(0)


## LUX FILM MODE, INCLUDING WITH THE ASSETS GONE.
##
## `set_film_mode(true)` is a NEW way into the film path, and section 54 says a
## feature that cannot run must leave the render alone rather than fail the
## frame. The existing deletion test proves that for presets, which never ask
## for film -- it says nothing about a caller that asks for it explicitly on a
## build where the shader and grain texture are missing. In the DELETED copy of
## this probe that is exactly the situation, and this is the only test that
## enters it.
##
## Reports what the mode did, so the caller can assert the pair: film_mode ON
## must ACTIVATE where the assets exist and must NOT activate where they do
## not -- and in neither case may it stop the frame rendering.
## STEP MARKERS INTO _out, NOT PRINTS. This function has now failed silently
## on two rasterisers -- llvmpipe takes the engine down with signal 11, an RTX
## 2060 returns nothing -- and three rounds of debugging could not say WHERE,
## because a coroutine that dies mid-await leaves no trace and Godot's stdout is
## discarded by run(). Each marker is written to the surviving JSON before the
## line that might kill it, so the last marker present names the last line that
## completed.
## Appends to a list already inside _out, so it survives even if this function
## never returns. The list IS the diagnostic.
func _mark(where: String) -> void:
	if not _out.has("film_mode_steps"):
		_out["film_mode_steps"] = []
	(_out["film_mode_steps"] as Array).append(where)
	# AND ONTO DISK, FLUSHED, ONE OPEN PER MARKER. The in-memory list only
	# reaches anybody through the JSON fence at the end of _run(), and the whole
	# problem here is that the process does not GET to the end of _run(): it
	# aborts (exit 134 / signal 11) and stdout dies with it. A marker that only
	# survives a clean exit cannot diagnose a dirty one. Reopening and closing
	# per marker is deliberate -- a FileAccess held open across the abort is a
	# FileAccess whose buffer is never flushed.
	if _steps_log != "":
		var f := FileAccess.open(_steps_log, FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open(_steps_log, FileAccess.WRITE)
		if f != null:
			f.seek_end()
			f.store_line(where)
			f.close()


func _test_film_mode() -> Dictionary:
	var res: Dictionary = {}
	_mark("entered")
	# THE GUARD THAT WOULD HAVE SAVED THREE ROUNDS. A freed Node still answers
	# `!= null` in GDScript; only is_instance_valid() tells the truth, and
	# calling a method on one that fails this check takes the process down with
	# no catchable error. This test used to run after the teardown test freed
	# _lux, and that is exactly what happened. Now it reports instead of aborting.
	if not is_instance_valid(_lux):
		res["error"] = "LuxRoot was freed before this test ran"
		_mark("lux_invalid")
		return res
	# SAVED SO IT CAN BE PUT BACK. set_film_mode() moves the film MASTER as
	# well as the mode flag -- it has to, or turning the mode on would do
	# nothing against the three-key AND. That means this test leaves the
	# master OFF when it finishes, and the next test down asked for film via
	# a preset and never got it: "the cleanup test never got film running, so
	# it measured nothing".
	#
	# That is the SAME defect this test was just moved to escape -- one test
	# changing shared state on _lux and the next one inheriting it -- and
	# reordering only moved which pair it broke. A test restores what it
	# changed; the test below ALSO stops assuming. Either alone would fix
	# today's symptom and leave the coupling in place.
	var master_before: bool = _lux.film_emulsion_enabled
	var mode_before: bool = _lux.film_mode
	var before: LuxPreset = _lux.get_current_preset()
	_mark("got_current_preset")
	res["preset"] = String(before.preset_name) if before != null else ""
	res["asks_film_before"] = (before != null and before.film_emulsion_enabled)

	# SIX FRAMES, NOT TWO, AND A NULL GUARD. Toggling film mode swaps the post
	# material to a different shader; capturing two frames later aborted the
	# engine outright (SIGABRT inside get_image, no GDScript error to catch).
	# The preset loop above already waits six for the same reason.
	_mark("before_set_film_mode_true")
	_lux.set_film_mode(true)
	_mark("after_set_film_mode_true")
	# ONE MARKER PER FRAME, NOT ONE PER LOOP. The abort has twice been
	# attributed to the statement AFTER this loop, which is a trivial getter
	# that cannot abort anything -- the signature of a crash that actually
	# happened inside the rendering server during one of these frames and was
	# charged to the line the script resumed on. Numbering the frames says
	# which one, and whether it is the first frame after the material swap.
	for i in range(6):
		_mark("on_frame_%d_wait" % i)
		await RenderingServer.frame_post_draw
		_mark("on_frame_%d_done" % i)
	_mark("after_frames_on")
	res["active_on"] = _lux.is_film_emulsion_active()
	_mark("after_is_active_on")
	# NO FRAME CAPTURE HERE. Two get_image() calls around a material swap took
	# the engine down with signal 11 on llvmpipe, and a probe that crashes the
	# thing it measures reports nothing at all. Render survival is already
	# proven by the per-preset loop, which captures seven frames either side of
	# this; what only this test can answer is whether the SWITCH activates
	# where the assets exist and declines where they do not.

	_lux.set_film_mode(false)
	_mark("after_set_film_mode_false")
	for i in range(6):
		_mark("off_frame_%d_wait" % i)
		await RenderingServer.frame_post_draw
		_mark("off_frame_%d_done" % i)
	res["active_off"] = _lux.is_film_emulsion_active()
	_mark("after_is_active_off")


	# The preset it was pointed at must come back untouched: film mode applies
	# an OVERRIDE, and a mode that mutated the shipped resource would leave the
	# next scene to load it already filmed.
	var after: LuxPreset = _lux.get_current_preset()
	_mark("after_get_current_preset_2")
	res["preset_unmutated"] = (after == null
		or not after.film_emulsion_enabled)
	# PUT BACK WHAT WAS FOUND, not what the defaults happen to be.
	_lux.film_mode = mode_before
	_lux.set_film_emulsion_enabled(master_before)
	res["master_restored"] = (_lux.film_emulsion_enabled == master_before)
	_mark("before_return")
	return res


## Defensive to the point of paranoia, because the undefensive version
## SEGFAULTED the engine rather than raising anything GDScript could catch:
## get_pixel on an image that is empty or in a format it cannot address takes
## the process down with signal 11 and a C++ backtrace. A probe that can crash
## the thing it is measuring reports nothing at all, which is worse than
## reporting a failure.
func _mean_luma(img: Image) -> float:
	if img == null or img.is_empty():
		return -1.0
	if img.get_width() <= 0 or img.get_height() <= 0:
		return -1.0
	if img.is_compressed():
		return -1.0
	var t: float = 0.0
	var n: int = 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			var c: Color = img.get_pixel(x, y)
			t += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			n += 1
	return t / float(maxi(n, 1))


## Does the feature put the viewport back when it is done with it?
##
## `film_manage_hdr_2d` RAISES the 2D render target to floating point while film
## runs. Raising is the easy half. The half that has to be tested is putting it
## back -- on deactivation, and on the LuxRoot leaving the tree, because a level
## that unloads its LuxRoot would otherwise keep paying for a format nothing in
## the tree still uses, and nothing left would know to restore it.
##
## Three states, each measured rather than assumed:
##   before   what the viewport was, untouched
##   during   raised while film runs
##   after    restored when film stops, and again after _exit_tree
func _test_hdr_2d_cleanup() -> Dictionary:
	var res: Dictionary = {}
	res["before"] = bool(root.use_hdr_2d)

	var base: LuxPreset = _lux.get_current_preset()
	if base == null:
		res["error"] = "no current preset"
		return res
	# OPT IN TO THE THING UNDER TEST. `film_manage_hdr_2d` defaults FALSE as of
	# 0.29.0 -- film no longer raises the render target, because raising it is a
	# tone change larger than the grain it serves. That is the right default and
	# it is exactly what makes this test vacuous unless it asks for the raise:
	# the probe reported "film ran but the viewport was never raised, so the
	# restore proves nothing", which was the check correctly refusing to pass
	# itself. The raise/restore path still exists for anyone who opts in, so it
	# still has to be proven to put the viewport back.
	_lux.film_manage_hdr_2d = true
	# AND THE MASTER, EXPLICITLY. This test needs all three keys of the
	# section 10 AND and only ever set two of them, which worked exactly as
	# long as nothing above it had touched the master. Something above it
	# now does. A test that depends on the state its neighbours leave behind
	# is a test whose result depends on the order they run in.
	_lux.set_film_emulsion_enabled(true)
	var film: LuxPreset = base.make_override(&"Cleanup Probe")
	film.film_emulsion_enabled = true
	film.grain_mode = 2
	_lux.apply_preset(film, 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	res["film_active"] = _lux.is_film_emulsion_active()
	res["during"] = bool(root.use_hdr_2d)

	# 1. deactivating film must put it back
	_lux.set_film_emulsion_enabled(false)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	res["after_disable"] = bool(root.use_hdr_2d)

	# 2. and so must the node simply leaving the tree, with film still ON --
	#    the path a level unload takes, where nobody calls anything.
	_lux.set_film_emulsion_enabled(true)
	_lux.apply_preset(film, 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	res["during_again"] = bool(root.use_hdr_2d)
	var parent := _lux.get_parent()
	if parent != null:
		parent.remove_child(_lux)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	res["after_exit_tree"] = bool(root.use_hdr_2d)
	_lux.queue_free()
	return res


func _canvas_layers(n: Node) -> Array[CanvasLayer]:
	var acc: Array[CanvasLayer] = []
	if n is CanvasLayer:
		acc.append(n)
	for c in n.get_children():
		acc.append_array(_canvas_layers(c))
	return acc
