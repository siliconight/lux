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
## Distance-falloff exponent (Omni/Spot `*_attenuation`). 1.0 is the engine
## default and what every rig shipped with -- near-linear, which cuts to zero
## AT the range and draws the pool's edge as a visible circle on any surface
## the light grazes. 2.0 is the physical inverse-square shape: the pool fades
## out well inside the range and the edge disappears. Walked 2026-08-23 on
## the zoo corridor: the hard-rimmed ceiling pools are this number, not the
## range.
@export_range(0.5, 3.0) var attenuation: float = 1.0
@export var shadows_enabled: bool = false

@export_group("Layout")
## Streetlight/fluorescent rows: how many fixtures and how far apart (meters).
@export_range(1, 32) var count: int = 4
@export var spacing: float = 6.0
@export var mount_height: float = 4.0

@export_group("Downlight")
## Ceiling rigs only (LuxFluorescentRig). 0 = each lamp is an OmniLight3D,
## every rig before Lux 0.34.0. > 0 = each lamp is a SpotLight3D pointing
## straight down with this half-angle, so nothing ABOVE the lamp's own plane
## is lit -- in particular nothing in the storey above, through the slab,
## which no unshadowed omni can avoid (see LuxLightLoader's fluorescent
## branch for the measurement). Held below 90: Godot 4.7 sizes a spot's
## culling box as a half-box of `range * sin(angle)` up to 89.x degrees and
## returns the omni's FULL box at 90 and above, so 90 would keep pairing
## the light with every mesh above it.
@export_range(0.0, 89.0) var downlight_angle_deg: float = 0.0
## The cone's rim softness, written straight to `spot_angle_attenuation`.
## MEASURED, GL Compatibility, Godot 4.7: the engine's rim factor is
## `1 - rim^(1 / value)` with rim = (1 - cos t) / (1 - cos angle) -- the
## RECIPROCAL of the property is the exponent. 1.0 is a cosine (Lambertian)
## falloff from the axis; 0.125 holds the full omni value to 60 degrees off
## axis and fades over the last ~20.
@export_range(0.01, 4.0) var downlight_rim: float = 1.0

@export_group("Flicker")
## Subtle instability for fluorescents / failing bulbs. 0 = steady.
@export_range(0.0, 1.0) var flicker_amount: float = 0.0
@export_range(0.1, 30.0) var flicker_speed: float = 8.0

@export_group("Lightmap Baking")
## How spawned lights participate in a LightmapGI bake (pc2000 family):
##   Realtime — leave the engine default untouched (existing scenes render
##              byte-identical).
##   Static   — direct + indirect light are baked; lightmapped surfaces then
##              ignore the light's realtime contribution (no double-lighting)
##              while dynamic objects (characters, guns) still receive it live.
##   Dynamic  — only indirect is baked; direct stays realtime everywhere.
## Flicker on a Static light only shows on dynamic objects (the lightmap is
## frozen), so rigs disable flicker when Static.
@export_enum("Realtime (engine default)", "Static (baked)", "Dynamic (indirect only)")
var bake_mode: int = 0


## Applies this rig's bake_mode to a spawned light. Duck-typed (`set`) so it
## also covers AreaLight3D instantiated via ClassDB. Mode 0 touches nothing.
func apply_bake_mode(light: Object) -> void:
	if light == null or bake_mode == 0:
		return
	var mode: int = Light3D.BAKE_STATIC if bake_mode == 1 else Light3D.BAKE_DYNAMIC
	light.set(&"light_bake_mode", mode)
