@tool
class_name LuxLightRig
extends Resource
## Describes a reusable, art-directed collection of lights (a fluorescent room,
## a streetlight row, a gas-station canopy...). The rig node reads this to
## spawn/refresh its child lights. MVP ships three rig *scenes*; this resource
## lets authors tune any of them without touching scene files.

@export var rig_name: StringName = &"Untitled Rig"

@export_group("Emission")
@export var light_color: Color = Color(1.0, 0.96, 0.88)
@export_range(0.0, 16.0) var energy: float = 2.0
## For OmniLight/SpotLight rigs.
@export_range(0.5, 60.0) var light_range: float = 12.0
@export var shadows_enabled: bool = false

@export_group("Layout")
## Streetlight/fluorescent rows: how many fixtures and how far apart (meters).
@export_range(1, 32) var count: int = 4
@export var spacing: float = 6.0
@export var mount_height: float = 4.0

@export_group("Flicker")
## Subtle instability for fluorescents / failing bulbs. 0 = steady.
@export_range(0.0, 1.0) var flicker_amount: float = 0.0
@export_range(0.1, 30.0) var flicker_speed: float = 8.0
