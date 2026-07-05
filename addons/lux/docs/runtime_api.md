# Lux — Runtime API

Gameplay code drives Lux visuals through **LuxRoot** (TDD §11) or the static
**LuxRuntimeAPI** facade. Both blend smoothly so transitions read as intentional
lighting changes, not hard cuts.

## Direct (hold a LuxRoot reference)

```gdscript
@onready var lux: LuxRoot = $LuxRoot

func _on_alarm_tripped() -> void:
    lux.set_mission_phase(&"combat", 1.2)   # blend to "Mission Goes Hot"
    lux.pulse_alarm_lights(1.0, 6.0)         # 6s red pulse on alarm-tagged lights

func _on_all_clear() -> void:
    lux.blend_to_preset(&"Delco Summer Afternoon", 1.5)

func _on_player_hit(health01: float) -> void:
    lux.set_player_damage_intensity(1.0 - health01)  # 0 = healthy, 1 = critical
```

### Full method list

| Method | Effect |
| --- | --- |
| `apply_preset(preset, blend_time=0.0)` | Apply a LuxPreset, optionally blending. |
| `blend_to_preset(name, blend_time)` | Blend to a preset resolved by name from the library. |
| `set_mission_phase(phase, blend_time=1.0)` | Blend to the preset mapped for a phase (`calm`, `alert`, `combat`, `escape`). |
| `set_weather(profile, blend_time=5.0)` | Layer a LuxWeatherProfile over the current look. |
| `set_time_of_day(normalized_time)` | Nudge sun elevation/warmth across a 0–1 day arc. |
| `pulse_alarm_lights(intensity, duration)` | Pulse lights in the `lux_alarm` group. |
| `set_player_damage_intensity(value)` | Desaturate + red-shift + vignette for low health (0–1). |
| `set_quality_profile(profile)` | Swap the active LuxQualityProfile / tier. |
| `register_lux_light(node)` / `unregister_lux_light(node)` | Track lights for state-driven effects. |

`preset_applied(name)` and `blend_finished(name)` signals fire so other systems
(audio, UI) can sync to look changes.

## Facade (no reference needed)

`LuxRuntimeAPI` resolves the first LuxRoot in the `lux_root` group, so decoupled
systems (GOOL hooks, a mission controller) can call it with just a `SceneTree`:

```gdscript
LuxRuntimeAPI.mission_phase(get_tree(), &"combat")
LuxRuntimeAPI.alarm(get_tree(), 1.0, 6.0)
LuxRuntimeAPI.player_damage(get_tree(), 0.7)
LuxRuntimeAPI.preset(get_tree(), &"Blue Hour", 2.0)
```

## Mission phase mapping

`LuxRoot.mission_phase_presets` is a plain Dictionary you can remap per project:

```gdscript
lux.mission_phase_presets[&"stealth"] = &"Blue Hour"
lux.mission_phase_presets[&"combat"] = &"Mission Goes Hot"
```

## Alarm lights

Add any `Light3D` you want the alarm pulse to drive to the `lux_alarm` group and
register it (rigs do this pattern automatically for their fixtures). During a
pulse Lux sets those lights to the preset's `alarm_color` and modulates their
energy; when the pulse ends it returns them to zero.

## GOOL integration

GOOL's weather, indoor/outdoor zone, alarm, and mission-state events can call the
same API so audio and visuals move together — e.g. a GOOL "alarm" event fires
both the siren bus and `LuxRuntimeAPI.alarm(get_tree(), 1.0, 6.0)`.
