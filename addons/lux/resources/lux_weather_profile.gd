@tool
class_name LuxWeatherProfile
extends Resource
## Weather-specific overrides layered on top of a preset. In the MVP this
## resource exists so set_weather() has a stable type and presets can reference
## it; full wet-surface / particle response is a post-MVP roadmap item (TDD §17).

@export var weather_name: StringName = &"Clear"

@export_group("Overrides")
@export var override_fog: bool = true
@export var fog_color: Color = Color(0.68, 0.68, 0.7)
@export_range(0.0, 0.05, 0.0001) var fog_density: float = 0.008

@export var override_grade: bool = true
@export_range(0.0, 2.0) var saturation_scale: float = 0.85
@export_range(0.5, 2.0) var brightness_scale: float = 0.9

@export_group("Surfaces")
## Pushed to Lux materials as target wetness when this weather is active.
@export_range(0.0, 1.0) var surface_wetness: float = 0.0
