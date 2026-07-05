@tool
class_name LuxPalette
extends Resource
## Named color family used by presets, the post stack, and material profiles.
## Colors are authored around mid gray (0.5): the post shader multiplies by
## palette * 2.0, so a value of (0.5, 0.5, 0.5) is neutral / no tint.

@export var palette_name: StringName = &"Untitled Palette"

## Tint applied to bright screen regions.
@export var highlight: Color = Color(0.5, 0.5, 0.5)
## Tint applied to midtones.
@export var midtone: Color = Color(0.5, 0.5, 0.5)
## Tint applied to dark screen regions.
@export var shadow: Color = Color(0.5, 0.5, 0.5)
## Suggested fog color companion (used by preset authors, not applied automatically).
@export var fog: Color = Color(0.5, 0.5, 0.5)
## Accent color for signage, alarms, and rim highlights.
@export var accent: Color = Color(1.0, 0.45, 0.2)
