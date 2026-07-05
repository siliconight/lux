@tool
class_name LuxRoleTag
extends Node
## Drop-in role assignment. Add this as a child of any object (or its mesh
## subtree root) and pick a role in the inspector — Lux applies the right PS2
## material setup to every MeshInstance3D under the parent on ready. No code.
##
## For coders, LuxMaterialApplier.apply_role(node, role) does the same thing
## directly. This node is the zero-code path for level designers.

@export_enum("Level", "Character", "Gun", "Prop", "Unlit") var role: int = 0:
	set(value):
		role = value
		if Engine.is_editor_hint() and is_inside_tree():
			_apply()

## Look tinting to pass through (optional). Usually left null so the active
## LuxRoot preset's palette drives the look.
@export var palette: LuxPalette

## Apply to the parent's whole subtree (default) or only sibling meshes under the
## same parent. Applied on ready in-game; use the button in-editor.
@export var apply_on_ready: bool = true

## Editor helper: tick to (re)apply now in the editor, then it unticks itself.
@export var apply_now: bool = false:
	set(value):
		if value:
			_apply()
		apply_now = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if apply_on_ready:
		_apply()


func _apply() -> void:
	var target := get_parent()
	if target == null:
		target = self
	var n := LuxMaterialApplier.apply_role(target, role, palette)
	if Engine.is_editor_hint():
		print(
			(
				"[Lux] Applied '%s' role to %d surface(s) under %s."
				% [LuxRole.role_name(role), n, target.name]
			)
		)
