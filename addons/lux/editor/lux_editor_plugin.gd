@tool
extends EditorPlugin
## Lux editor plugin. Registers the LuxRoot custom node type and adds the Lux
## dock to the editor for applying presets, tuning art sliders, saving level
## overrides, and running validation.

const DockScene := preload("res://addons/lux/editor/lux_dock.tscn")
const RootIcon := preload("res://addons/lux/editor/icons/lux_root.svg")

var _dock: Control


func _enter_tree() -> void:
	add_custom_type("LuxRoot", "Node3D", preload("res://addons/lux/runtime/lux_root.gd"), RootIcon)
	add_custom_type(
		"LuxRoleTag", "Node", preload("res://addons/lux/runtime/lux_role_tag.gd"), RootIcon
	)
	_dock = DockScene.instantiate()
	_dock.set_editor_interface(get_editor_interface())
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.free()
		_dock = null
	remove_custom_type("LuxRoleTag")
	remove_custom_type("LuxRoot")
