# Lux — Runtime API

Gameplay code drives Lux visuals through **LuxRoot** (TDD §11) or the static
**LuxRuntimeAPI** facade. Both blend smoothly so transitions read as intentional
lighting changes, not hard cuts.

## Lux Film Mode

One switch for the whole film treatment, so an export can carry the look or not.

```gdscript
lux.set_film_mode(true)    # or the exported `film_mode` flag
```

That is the entire API. It composes with any preset -- film is a treatment OF a
look, not a look -- and it never mutates the preset you pass it.

- **Off by default.** With it off the render path is what it always was.
- **It does not touch the render target.** `film_manage_hdr_2d` defaults false
  because raising it is a tone change larger than the grain it serves, and it
  moves differently on different hardware. Set it true deliberately if you want
  the extra precision and have checked what it costs your look.
- **The values it applies are the LuxPreset defaults**, so a preset that does
  not override any `film_*` field gets the settled look automatically, and one
  that does keeps its own tuning.

The settled defaults, chosen by walking a level and looking at it rather than
by calculation: density 0.20, grain size 1.0, chroma coherence 1.0, luma scale
3.0, one octave, base fog 0.004.

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
| `set_film_emulsion_enabled(on)` | Global film emulsion switch. Re-applies the post stack only. |
| `is_film_emulsion_active()` | Whether film is actually rendering right now. |

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
LuxRuntimeAPI.film_emulsion(get_tree(), true)
```

## Film emulsion

A graphics-menu switch, and it is one of THREE keys -- all three must agree
before film renders (`docs/film_emulsion_tdd.md` section 10):

| Key | Where | Asks |
| --- | --- | --- |
| `LuxPreset.film_emulsion_enabled` + `grain_mode` | the preset | does this look want film? |
| `LuxQualityProfile.allow_film_emulsion` | the quality tier | can this hardware afford it? |
| `LuxRoot.film_emulsion_enabled` | the player | has it been switched off? |

```gdscript
func _on_film_toggled(on: bool) -> void:
    LuxRuntimeAPI.film_emulsion(get_tree(), on)
    # The switch is global; the preset and tier still get a veto. Ask what is
    # actually running rather than assuming the toggle took effect, so a menu
    # can grey itself out on a tier that refuses film instead of looking broken.
    %FilmRow.disabled = not LuxRuntimeAPI.is_film_emulsion_active(get_tree())
```

Turning it off changes nothing but the post pass: no scene reload, no
WorldEnvironment rebuild, no material, lighting or gameplay change. A preset
that asks for film on a tier that refuses it falls back to the Simple grain
rather than to no grain at all.

Because film is a **preset property**, everything Lux already does with presets
applies to it — including zone switching. Two presets for a level, film on the
interior one only, and a GOOL indoor/outdoor zone event blends into it:

```gdscript
func _on_entered_interior() -> void:
    LuxRuntimeAPI.preset(get_tree(), &"Row Home Interior", 1.2)
```

The blend interpolates the film parameters too, so the grain ramps in rather
than popping. And because the grain is exposure-weighted, a power cut
intensifies it with nothing scripted:

```gdscript
LuxRuntimeAPI.fixtures_powered(get_tree(), false)   # darker room, louder grain
```

`film_emulsion_authoring.md` covers where this is worth doing, and one gotcha
about toggling the render target at zone boundaries.

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
