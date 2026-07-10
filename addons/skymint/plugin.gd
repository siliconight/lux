@tool
extends EditorPlugin

# SkyMint and SkyMintProfile register themselves globally via their
# `class_name` declarations, and SkyMint's icon comes from its @icon
# annotation, so there's nothing to wire up here. This file exists so the
# addon can be enabled/disabled from Project Settings > Plugins.

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
