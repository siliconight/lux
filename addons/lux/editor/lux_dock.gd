@tool
extends Control
## Lux editor dock. Drives the selected LuxRoot: pick a preset, preview it live
## in-editor, tune art-facing sliders, save a level-local override, and run the
## validation panel (TDD §12, §18).

var _editor: EditorInterface

var _preset_option: OptionButton
var _apply_button: Button
var _save_override_button: Button
var _validate_button: Button
var _status_label: RichTextLabel
var _slider_box: VBoxContainer

var _presets: Array[LuxPreset] = []
var _preset_paths: Array[String] = []
var _sliders := {}

const PRESET_DIR := "res://addons/lux/presets/"


func set_editor_interface(ei: EditorInterface) -> void:
	_editor = ei


func _ready() -> void:
	name = "Lux"
	custom_minimum_size = Vector2(280, 0)
	_build_ui()
	_scan_presets()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var title := Label.new()
	title.text = "LUX"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Rendering Framework"
	subtitle.modulate = Color(1, 1, 1, 0.6)
	root.add_child(subtitle)

	root.add_child(HSeparator.new())

	var preset_label := Label.new()
	preset_label.text = "Preset"
	root.add_child(preset_label)

	_preset_option = OptionButton.new()
	_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_preset_option)

	var button_row := HBoxContainer.new()
	root.add_child(button_row)
	_apply_button = Button.new()
	_apply_button.text = "Apply / Preview"
	_apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_button.pressed.connect(_on_apply_pressed)
	button_row.add_child(_apply_button)

	_save_override_button = Button.new()
	_save_override_button.text = "Save Level Override"
	_save_override_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_override_button.pressed.connect(_on_save_override_pressed)
	root.add_child(_save_override_button)

	root.add_child(HSeparator.new())

	var slider_label := Label.new()
	slider_label.text = "Art Sliders"
	root.add_child(slider_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 220)
	root.add_child(scroll)
	_slider_box = VBoxContainer.new()
	_slider_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_slider_box)

	_add_slider("Warmth", "warmth", -1.0, 1.0, 0.01)
	_add_slider("Fog Density", "fog_density", 0.0, 0.05, 0.0005)
	_add_slider("Dither Strength", "dither_strength", 0.0, 1.0, 0.01)
	_add_slider("Palette Influence", "palette_influence", 0.0, 1.0, 0.01)
	_add_slider("Glow Intensity", "glow_intensity", 0.0, 2.0, 0.01)
	_add_slider("Contrast", "contrast", 0.5, 2.0, 0.01)
	_add_slider("Saturation", "saturation", 0.0, 2.0, 0.01)
	_add_slider("Exposure", "exposure", 0.25, 4.0, 0.01)
	_add_slider("Sun Energy", "sun_energy", 0.0, 8.0, 0.05)
	_add_slider("CRT Mask", "crt_mask_strength", 0.0, 1.0, 0.01)
	_add_slider("Scanlines", "scanline_strength", 0.0, 1.0, 0.01)
	_add_slider("PS2 Lighting", "ps2_lighting_global", -1.0, 1.0, 0.01)

	root.add_child(HSeparator.new())

	_validate_button = Button.new()
	_validate_button.text = "Validate Scene"
	_validate_button.pressed.connect(_on_validate_pressed)
	root.add_child(_validate_button)

	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.custom_minimum_size = Vector2(0, 120)
	_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_status_label)
	_set_status(
		"[color=gray]Select a LuxRoot in the scene, choose a preset, and press Apply.[/color]"
	)


func _add_slider(label_text: String, property: String, mn: float, mx: float, step: float) -> void:
	var row := VBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	row.add_child(l)
	var h := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var val := Label.new()
	val.custom_minimum_size = Vector2(48, 0)
	val.text = "--"
	s.value_changed.connect(func(v): _on_slider_changed(property, v, val))
	h.add_child(s)
	h.add_child(val)
	row.add_child(h)
	_slider_box.add_child(row)
	_sliders[property] = {"slider": s, "value": val}


func _scan_presets() -> void:
	_presets.clear()
	_preset_paths.clear()
	_preset_option.clear()
	var dir := DirAccess.open(PRESET_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".tres"):
			var res := ResourceLoader.load(PRESET_DIR + f)
			if res is LuxPreset:
				_presets.append(res)
				_preset_paths.append(PRESET_DIR + f)
				_preset_option.add_item(String(res.preset_name))
		f = dir.get_next()
	dir.list_dir_end()


func _get_selected_root() -> LuxRoot:
	if _editor == null:
		return null
	var selection := _editor.get_selection().get_selected_nodes()
	for n in selection:
		if n is LuxRoot:
			return n
	# Fall back to the first LuxRoot in the edited scene.
	var scene := _editor.get_edited_scene_root()
	if scene != null:
		return _find_lux_root(scene)
	return null


func _find_lux_root(node: Node) -> LuxRoot:
	if node is LuxRoot:
		return node
	for c in node.get_children():
		var r := _find_lux_root(c)
		if r != null:
			return r
	return null


func _on_apply_pressed() -> void:
	var root := _get_selected_root()
	if root == null:
		_set_status("[color=orange]No LuxRoot selected or found in the scene.[/color]")
		return
	var idx := _preset_option.selected
	if idx < 0 or idx >= _presets.size():
		_set_status("[color=orange]No preset selected.[/color]")
		return
	var preset := _presets[idx]
	root.active_preset = preset
	root.apply_preset(preset)
	_load_sliders_from(preset)
	_set_status("[color=lightgreen]Applied '%s'.[/color]" % preset.preset_name)


func _on_slider_changed(property: String, value: float, val_label: Label) -> void:
	val_label.text = "%.3f" % value
	var root := _get_selected_root()
	if root == null:
		return
	var preset := root.get_current_preset()
	if preset == null:
		preset = root.active_preset
	if preset == null:
		return
	# Work on a live override so we never mutate the shared library resource.
	if root.local_override == null or root.local_override.preset_name != preset.preset_name:
		root.local_override = preset.make_override(
			StringName(String(preset.preset_name) + " (Level)")
		)
	root.local_override.set(property, value)
	root.apply_preset(root.local_override)


func _load_sliders_from(preset: LuxPreset) -> void:
	for property in _sliders.keys():
		var entry = _sliders[property]
		var v = preset.get(property)
		if v != null:
			entry.slider.set_value_no_signal(v)
			entry.value.text = "%.3f" % float(v)


func _on_save_override_pressed() -> void:
	var root := _get_selected_root()
	if root == null:
		_set_status("[color=orange]No LuxRoot to save an override for.[/color]")
		return
	var base := root.local_override if root.local_override != null else root.active_preset
	if base == null:
		_set_status("[color=orange]Nothing to save; apply a preset first.[/color]")
		return
	var override := base.make_override(
		StringName(String(base.preset_name).trim_suffix(" (Level)") + " (Level)")
	)
	var scene_path := (
		_editor.get_edited_scene_root().scene_file_path if _editor.get_edited_scene_root() else ""
	)
	var dir := "res://"
	var fname := "lux_override.tres"
	if scene_path != "":
		dir = scene_path.get_base_dir() + "/"
		fname = scene_path.get_file().get_basename() + "_lux.tres"
	var out_path := dir + fname
	var err := ResourceSaver.save(override, out_path)
	if err == OK:
		root.local_override = ResourceLoader.load(out_path)
		_set_status("[color=lightgreen]Saved level override to %s[/color]" % out_path)
		if _editor != null:
			_editor.get_resource_filesystem().scan()
	else:
		_set_status("[color=red]Failed to save override (error %d).[/color]" % err)


func _on_validate_pressed() -> void:
	var root := _get_selected_root()
	if root == null:
		_set_status("[color=orange]No LuxRoot selected or found.[/color]")
		return
	var findings := LuxValidator.validate(root)
	var text := ""
	for f in findings:
		var color := "gray"
		var prefix := "•"
		match f.severity:
			LuxValidator.Severity.OK:
				color = "lightgreen"
				prefix = "✓"
			LuxValidator.Severity.INFO:
				color = "skyblue"
				prefix = "ℹ"
			LuxValidator.Severity.WARN:
				color = "orange"
				prefix = "⚠"
			LuxValidator.Severity.ERROR:
				color = "salmon"
				prefix = "✗"
		text += "[color=%s]%s %s[/color]\n" % [color, prefix, f.message]
	_set_status(text)


func _set_status(bbcode: String) -> void:
	if _status_label != null:
		_status_label.text = bbcode
