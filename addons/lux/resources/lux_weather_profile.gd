@tool
class_name LuxWeatherProfile
extends Resource
## Weather layered on top of a preset: fog and grade overrides, the target
## surface wetness, and (since 0.35.0) falling rain.
##
## A preset carries one of these in `LuxPreset.weather`, and LuxRoot builds a
## `LuxRain` emitter whenever the applied preset's profile has `rain_enabled`.
## `LuxRoot.set_weather` layers a profile over the current look at runtime.
## Wet-surface response and puddles are not part of this resource yet.

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

@export_group("Rain")
## Off by default, so every profile written before 0.35.0 stays dry.
@export var rain_enabled: bool = false
## Drops alive at once, before the quality tier's cap
## (`LuxQualityProfile.max_rain_drops`). The count is spread over the whole
## emitter column, so what a person sees is density, not this number:
## drops per cubic metre = amount / ((2 * radius)^2 * fall column).
@export_range(0, 65536, 1) var rain_amount: int = 9000
## Metres per second, straight down. Real drops fall at terminal velocity, so
## there is no gravity term: a 2 mm drop is ~6.5 m/s, a 5 mm drop ~9 m/s.
@export_range(1.0, 30.0, 0.1) var rain_fall_speed: float = 9.0
## Each drop's speed is fall_speed * (1 +/- this). The FAST end is what the
## collider thickness is derived against (`LuxRainCollision.step_m`).
@export_range(0.0, 0.5, 0.01) var rain_speed_randomness: float = 0.1
## Half-angle of the cone the fall direction is drawn from.
@export_range(0.0, 30.0, 0.1) var rain_spread_deg: float = 5.0
## Streak length and width in metres. A streak is the distance a drop covers
## while the eye integrates it; at 9 m/s, 0.45 m is 1/20 s.
@export_range(0.02, 3.0, 0.01) var rain_streak_length: float = 0.45
@export_range(0.001, 0.2, 0.001) var rain_streak_width: float = 0.012
## Vertex colour of every drop; alpha is the streak's opacity. The material is
## unshaded, so this is the colour on screen before fog and the post stack.
@export var rain_color: Color = Color(0.72, 0.76, 0.82, 0.32)
## Streaks fade out as they reach the camera, over this many metres (0 = off).
## A drop half a metre from the lens is drawn as a bar a third of the screen
## tall -- the extraction shot of cold run 9048's walk copy, standing at a
## wall, had four of them and nothing else in frame.
@export_range(0.0, 10.0, 0.1) var rain_near_fade_m: float = 2.0
## Half-width of the square emitter, centred on the active camera.
@export_range(2.0, 100.0, 0.5) var rain_emitter_radius: float = 16.0
## Height of the emitter plane above the camera.
@export_range(1.0, 60.0, 0.5) var rain_emitter_height: float = 12.0
## How far below the camera a drop lives before it expires, so rain is still
## falling past the eye when a person looks down from a roof or a stair.
@export_range(0.0, 60.0, 0.5) var rain_fall_below: float = 6.0
## Simulation steps per second. Collision is tested once per step, so a drop
## crosses up to `fall_speed * (1 + randomness) / fixed_fps` metres between
## tests; a collider thinner than that lets some drops through
## (tools/rain_renderer_probe.gd measures the leak). Lower is cheaper and needs
## thicker colliders; `interpolate` keeps motion smooth between steps.
@export_range(5, 120, 1) var rain_fixed_fps: int = 30
