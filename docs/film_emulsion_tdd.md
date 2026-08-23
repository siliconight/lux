# Technical Design Document: Optional Color-Preserving Film Emulsion for Lux

**Status:** Proposed  
**Engine:** Godot 4.7  
**System:** Lux Lighting and Rendering Layer  
**Feature:** Optional Runtime Film Emulsion / Photographic Color
Response  
**Priority:** Color fidelity and runtime performance

# 1. Purpose

Add an optional photographic film-emulsion rendering mode to Lux.

The primary purpose is **not simply to add film grain**.

The primary purpose is to preserve and present the continuous color
relationships created by Godot and Lux lighting in a more photographic
manner.

The system must reduce the appearance of:

- Artificial RGB-channel breakup.
- Digital color speckle.
- Unwanted color quantization.
- Posterization.
- Grain that creates unrelated red, green, or blue pixels.
- Digital-looking noise applied independently to RGB channels.

The system must instead produce:

- Smooth color transitions.
- Grain that remains related to the underlying surface color.
- Exposure-based variation.
- Continuous lighting color.
- Film-like density response.
- Restrained chromatic variation.
- A result that feels closer to photographed light than digital RGB
  noise.

Film Emulsion must remain completely optional.

Lux and the Godot scene must render and play correctly when the feature
is disabled.

# 2. Primary Visual Objective

The most important requirement is:

> **Preserve the true color relationships produced by Lux lighting for
> as long as possible in the rendering pipeline.**

Film Emulsion must not first reduce the scene to coarse RGB values and
then attempt to make that reduced image look photographic.

Required principle:

    Preserve color precision
            ↓
    Apply photographic response
            ↓
    Apply film density variation
            ↓
    Optional artistic reduction afterward

Not:

    Quantize RGB
            ↓
    Lose color information
            ↓
    Attempt to restore a photographic appearance

Once color information has been removed through quantization, clipping,
or palette reduction, Film Emulsion cannot recover it.

# 3. Terminology

The visual issue may be described conversationally as “RGB compression.”

In this TDD, use more precise engineering terms:

- RGB-channel breakup.
- Per-channel noise.
- Color quantization.
- Posterization.
- Channel divergence.
- Color precision loss.

RGB itself is not compression.

The problem is unnecessary independent manipulation or reduction of the
individual channels.

# 4. Desired Color Behavior

Consider a surface illuminated as warm orange.

Example scene color:

    R = 0.72
    G = 0.41
    B = 0.19

Film-like variation should produce nearby colors:

    0.70, 0.40, 0.19
    0.73, 0.42, 0.20
    0.71, 0.40, 0.18

The perceived color remains warm orange.

The system should avoid variations such as:

    0.76, 0.35, 0.24
    0.65, 0.48, 0.14
    0.78, 0.37, 0.13

where channels independently move enough to create visible hue breakup.

Primary grain must therefore affect a shared density or exposure signal.

# 5. Core Product Requirement

Film Emulsion is an enhancement to the rendered image.

It is not required for:

- Gameplay.
- Physics.
- Networking.
- AI.
- Lighting simulation.
- Material evaluation.
- Scene loading.
- Collision.
- Input.
- Camera behavior.

The scene must render normally without it.

With Film Emulsion:

    Godot Scene
        ↓
    Lux Lighting
        ↓
    High-Precision Scene Color
        ↓
    Lux Photographic Response
        ↓
    Optional Film Emulsion
        ↓
    Optional Retro Effects
        ↓
    Final Display

Without Film Emulsion:

    Godot Scene
        ↓
    Lux Lighting
        ↓
    Lux Existing Render
        ↓
    Final Display

# 6. Performance Is a Functional Requirement

Performance is part of the feature definition.

The implementation is not acceptable if visual quality is correct but
runtime cost exceeds its budget.

Priority order:

1.  Preserve lighting color fidelity.
2.  Preserve frame time.
3.  Preserve memory bandwidth.
4.  Minimize VRAM use.
5.  Minimize RAM use.
6.  Avoid CPU work.
7.  Avoid runtime allocations.
8.  Avoid shader compilation during play.
9.  Improve photographic appearance.
10. Add secondary film characteristics.

If performance and visual fidelity conflict, reduce visual complexity
first.

# 7. Architecture

Film Emulsion will use the existing Lux post-processing architecture.

Existing conceptual structure:

    LuxRoot
        ↓
    LuxPostFX
        ↓
    Existing BackBufferCopy
        ↓
    Lux Post Shader
        ↓
    Optional CRT

Film Emulsion will be integrated inside the existing Lux post shader.

Required architecture:

    Existing Lux BackBufferCopy
            ↓
    Lux Post Shader
            │
            ├─ Lux color response
            ├─ Optional Film Emulsion
            ├─ Optional palette/dither
            └─ Vignette
            ↓
    Optional CRT Pass

Film Emulsion must not create another mandatory full-screen pass.

# 8. Prohibited Architecture

Do not implement:

    Lux Post Pass
        ↓
    Film BackBufferCopy
        ↓
    Film Render Target
        ↓
    Film Pass
        ↓
    CRT Pass

V1 must not allocate:

- A full-resolution film framebuffer.
- A full-resolution grain buffer.
- A density buffer.
- A frame-history buffer.
- A motion-vector buffer.
- A depth copy.
- A normals copy.
- A full-resolution blur texture.
- A dedicated film SubViewport.

# 9. Lux Integration Points

The implementation will extend:

    LuxPreset
    LuxQualityProfile
    LuxRoot
    LuxRuntimeAPI
    LuxPostFX
    lux_ordered_dither.gdshader

Responsibilities:

### `LuxPreset`

Defines artistic intent.

Example:

    Does this preset want Film Emulsion?

### `LuxQualityProfile`

Defines hardware permission.

Example:

    Can the current quality tier afford Film Emulsion?

### `LuxRoot`

Defines global enablement.

Example:

    Has the player disabled Film Emulation?

### `LuxRuntimeAPI`

Allows the feature to be changed during play.

### `LuxPostFX`

Owns runtime post-processing state.

### Lux shader

Performs the actual color-preserving film calculation.

# 10. Enablement Logic

Film Emulsion is active only when all conditions are true:

    Film Active =
        Global Setting
        AND
        Preset Requests Film
        AND
        Quality Allows Film

Implementation:

    var film_active := (
        film_emulsion_master_enabled
        and preset.film_emulsion_enabled
        and quality.allow_film_emulsion
    )

This separation is mandatory.

# 11. Grain Modes

Lux should support three modes:

    enum GrainMode {
        OFF,
        SIMPLE,
        FILM_EMULSION
    }

Meaning:

### OFF

No grain.

### SIMPLE

Existing low-cost Lux grain.

### FILM_EMULSION

New density-aware color-preserving implementation.

Never run Simple and Film Emulsion simultaneously.

# 12. LuxPreset Changes

Add:

    @export_group("Film Emulsion")

    @export var film_emulsion_enabled: bool = false

    @export_enum(
        "Off",
        "Simple",
        "Film Emulsion"
    )
    var grain_mode: int = 0

    @export_range(0.0, 0.10, 0.001)
    var film_grain_strength: float = 0.025

    @export_range(0.0, 0.25, 0.01)
    var film_chroma_ratio: float = 0.12

    @export_range(1.0, 60.0, 1.0)
    var film_grain_fps: float = 24.0

    @export_range(0.5, 3.0, 0.05)
    var film_grain_scale: float = 1.0

Existing presets must remain unchanged.

Default:

    film_emulsion_enabled = false

# 13. LuxQualityProfile Changes

Add:

    @export var allow_film_emulsion: bool = true

Recommended defaults:

| Quality       | Film Emulsion |
|---------------|---------------|
| High          | Allowed       |
| Medium        | Allowed       |
| Low           | Disabled      |
| Compatibility | Disabled      |

Example:

    match tier:
        HIGH:
            allow_film_emulsion = true

        MEDIUM:
            allow_film_emulsion = true

        LOW:
            allow_film_emulsion = false

        COMPATIBILITY:
            allow_film_emulsion = false

# 14. LuxRoot Runtime Switch

Add:

    @export_group("Optional Rendering Features")

    @export var film_emulsion_enabled: bool = true

Add:

    func set_film_emulsion_enabled(
        enabled: bool
    ) -> void:

        film_emulsion_enabled = enabled

        if _post != null:
            _post.set_film_emulsion_master_enabled(
                enabled
            )

Changing this setting must not reload:

- Scene.
- WorldEnvironment.
- Materials.
- Lux preset.
- Lighting.
- Gameplay state.

# 15. Runtime API

Expose:

    static func film_emulsion(
        tree: SceneTree,
        enabled: bool
    ) -> void:

        var lux := get_root(tree)

        if lux != null:
            lux.set_film_emulsion_enabled(
                enabled
            )

Usage:

    LuxRuntimeAPI.film_emulsion(
        get_tree(),
        true
    )

Disable:

    LuxRuntimeAPI.film_emulsion(
        get_tree(),
        false
    )

# 16. Preferred Render Order

Because the primary objective is color fidelity, Film Emulsion should
operate before deliberate retro color destruction.

Recommended default:

    High-Precision Scene Color
            ↓
    Lux Grade / Exposure
            ↓
    Film Color Response
            ↓
    Film Emulsion
            ↓
    Optional Palette Reduction
            ↓
    Optional Dither / Quantization
            ↓
    Vignette
            ↓
    Optional CRT

This preserves the real lighting relationships before stylistic
reduction.

# 17. Natural Mode

Lux should support a photographic configuration where palette reduction
and quantization are not required.

    Scene
    ↓
    Lux Lighting
    ↓
    Lux Grade
    ↓
    Film Emulsion
    ↓
    Output

This is the preferred mode when the objective is:

> Preserve natural or photographic color.

# 18. Retro Mode

For Lux’s retro visual identity:

    Scene
    ↓
    Lux Lighting
    ↓
    Film Emulsion
    ↓
    Palette
    ↓
    Dither
    ↓
    Output

This treats Film Emulsion as the photographic capture layer and retro
quantization as a later presentation effect.

# 19. Alternative Artistic Ordering

Lux may optionally support:

    Dither
    ↓
    Film Emulsion

This produces analog-looking variation over a deliberately digital
image.

It can be artistically useful.

It must not be the default for the natural photographic mode because the
original continuous color has already been reduced.

# 20. Preserve Scene Precision

Film Emulsion must operate directly on the precision of the existing
Lux/Godot scene color.

The system must not convert scene color to RGB8 before processing.

Required:

    High-precision scene color
            ↓
    Film math
            ↓
    High-precision output

Not:

    High-precision scene color
            ↓
    RGB8
            ↓
    Film math

The packed grain texture may use RGBA8.

This is acceptable because the texture contains noise values, not scene
color.

# 21. Packed Grain Texture

Use one small precomputed texture:

    addons/lux/resources/film/
        grain_balanced.png

Recommended:

    128 × 128
    RGBA8

Channels:

| Channel | Purpose                   |
|---------|---------------------------|
| R       | Fine neutral grain        |
| G       | Coarse neutral grain      |
| B       | Red-green dye variation   |
| A       | Blue-yellow dye variation |

Raw memory:

    128 × 128 × 4 bytes
    ≈ 64 KiB

One fetch provides all grain signals.

# 22. Grain Asset Requirements

The texture must:

- Tile seamlessly.
- Use no mipmaps.
- Avoid sRGB conversion.
- Use repeat addressing.
- Be generated offline.
- Never be regenerated during gameplay.
- Never be uploaded every frame.
- Contain no visible repeating macro pattern.

# 23. Grain Coordinate Variation

Do not solve repetition with a full-resolution noise texture.

Use deterministic transformations:

- X offset.
- Y offset.
- Horizontal flip.
- Vertical flip.
- 90-degree rotation.
- 180-degree rotation.
- 270-degree rotation.

Example:

    Film Frame 0
    Normal

    Film Frame 1
    Flip X

    Film Frame 2
    Rotate 90°

    Film Frame 3
    Flip Y

All transformation must occur inside the shader.

# 24. Film Grain Cadence

Default:

    24 grain states per second

The grain must not change continuously every rendered frame.

At 120 FPS:

    Game Rendering:
    120 FPS

    Film Grain:
    24 FPS

This gives a photographic temporal cadence and reduces CPU-side uniform
changes.

# 25. LuxPostFX Temporal State

Add:

    var _film_active: bool = false
    var _film_frame: int = 0
    var _film_accumulator: float = 0.0
    var _film_grain_fps: float = 24.0

Update only when Film Emulsion is active.

    func process(delta: float) -> void:
        if not _film_active:
            return

        _film_accumulator += delta

        var interval := 1.0 / _film_grain_fps

        if _film_accumulator >= interval:
            _film_accumulator = fmod(
                _film_accumulator,
                interval
            )

            _film_frame += 1

            _mat.set_shader_parameter(
                &"film_frame",
                _film_frame
            )

No Film Emulsion means no film-frame updates.

# 26. Primary Grain Principle

Primary grain must not independently modify red, green, and blue.

Do not do:

    col.r += random_r;
    col.g += random_g;
    col.b += random_b;

Primary grain must instead calculate one neutral density signal:

    One grain value
        ↓
    One density change
        ↓
    One shared RGB transmission multiplier

This is the central color-preservation technique.

# 27. Neutral Density Model

Conceptually:

    D = -log2(C)

    D' = D + grain

    C' = 2^(-D')

Do not calculate this literally for all RGB channels.

Use the algebraic identity:

    C' = C × 2^(-grain)

Shader:

    float transmission =
        exp2(-neutral_density);

    col *= transmission;

One scalar transmission changes all three channels proportionally.

# 28. Why This Preserves Color

Given:

    Dark Orange

    0.72
    0.41
    0.19

Multiplying by:

    0.97

produces:

    0.698
    0.398
    0.184

The color remains orange.

Multiplying by:

    1.03

produces:

    0.742
    0.422
    0.196

It remains orange.

This is fundamentally different from generating three independent RGB
random values.

# 29. Exposure-Dependent Grain

Film grain should not have identical strength everywhere.

Calculate scene luminance:

    float lum = dot(
        col,
        vec3(
            0.2126,
            0.7152,
            0.0722
        )
    );

Approximate exposure response:

    float exposure_mask = clamp(
        1.0
        - 0.92 * lum
        + 0.20 * lum * lum,
        0.28,
        1.0
    );

Result:

    Dark regions
    → stronger grain

    Midtones
    → moderate grain

    Bright regions
    → quieter grain

This helps grain appear embedded in exposure rather than painted over
the screen.

# 30. Neutral Grain Construction

Decode:

    vec4 noise =
        texelFetch(
            film_grain_texture,
            grain_coord,
            0
        ) * 2.0 - 1.0;

Combine:

    float neutral_noise =
          noise.r * 0.68
        + noise.g * 0.32;

Calculate density:

    float neutral_density =
        neutral_noise
        * film_grain_strength
        * exposure_mask;

Apply:

    float transmission =
        exp2(-neutral_density);

    col *= transmission;

# 31. Chromatic Grain

Real color film is not perfectly neutral.

Lux may add a weak secondary chromatic signal.

It must remain restrained.

Default:

    Chromatic amplitude
    ≈ 12% of neutral grain

Use opponent color axes rather than independent RGB random channels.

    const vec3 RED_GREEN_AXIS =
        vec3(
            0.7071,
            -0.7071,
            0.0
        );

    const vec3 BLUE_YELLOW_AXIS =
        vec3(
            -0.4082,
            -0.4082,
            0.8165
        );

Calculate:

    vec3 chroma =
        (
            noise.b * RED_GREEN_AXIS
            +
            noise.a * BLUE_YELLOW_AXIS
        )
        * film_chroma_ratio
        * film_grain_strength
        * exposure_mask;

Approximate transmission:

    col *= max(
        vec3(1.0)
        - 0.69314718 * chroma,
        vec3(0.90)
    );

This produces restrained dye variation without RGB confetti.

# 32. Color Authority

V1 must have one clear owner for photographic color response.

Lux already controls:

- Exposure.
- Contrast.
- Saturation.
- Warmth.
- Palette response.
- Shadow color.
- Midtone color.
- Highlight color.

Do not immediately add a second major 3D LUT system.

V1 should use:

    Existing Lux color response
    +
    Color-preserving Film Emulsion

A film-stock LUT may be added in V2 only if Lux’s existing grading
cannot reproduce the required stock behavior.

# 33. Optional V2 Film LUT

If required later:

    @export var film_stock_lut: Texture3D

    @export_range(0.0, 1.0, 0.01)
    var film_stock_strength: float = 0.0

The LUT must operate before palette quantization.

It must not force the scene through RGB8.

# 34. Existing Simple Grain

Existing Lux grain should remain for compatibility.

Legacy:

    Random scalar
    ↓
    RGB add

New Film Emulsion:

    Exposure-aware grain
    ↓
    Density transmission
    ↓
    Shared color-preserving multiplier
    ↓
    Optional restrained chroma

Existing presets continue using Simple grain unless explicitly migrated.

# 35. Shader Variants

Preferred implementation:

    lux_ordered_dither.gdshader

    lux_ordered_dither_film.gdshader

Baseline shader:

- No film texture.
- No film exponent.
- No film grain math.
- No chromatic grain.

Film shader:

- Film Emulsion support.
- Grain texture.
- Density calculation.

Switching the graphics setting changes the active precompiled
material/shader.

Do not compile shaders during gameplay.

# 36. Disabled Performance Requirement

When Film Emulsion is disabled:

    0 Film Emulsion texture reads

    0 Film Emulsion exp2 operations

    0 Film Emulsion chromatic operations

    0 Film-frame updates

    0 Film Emulsion render passes

    0 Film render targets

Lux must return to its normal rendering path.

# 37. Enabled Runtime Cost

V1 expected additional per-pixel work:

    1 packed grain texture fetch

    1 luminance dot product

    1 exposure-response calculation

    1 scalar exp2

    several inexpensive vector operations

    optional chromatic calculations

No additional framebuffer traversal should occur.

# 38. VRAM Budget

Primary V1 resource:

    128 × 128 RGBA8 grain texture
    ≈ 64 KiB

Hard deterministic Film Emulsion target:

    < 0.25 MiB VRAM

No full-resolution Film Emulsion buffer is allowed.

For comparison:

    1920 × 1080 RGBA16F
    ≈ 15.8 MiB

    3840 × 2160 RGBA16F
    ≈ 63.3 MiB

One unnecessary full-resolution buffer would cost orders of magnitude
more memory than the grain asset.

# 39. RAM Budget

Persistent RAM:

    < 1 MiB

Do not:

- Generate grain on CPU.
- Store framebuffer copies.
- Create image arrays each frame.
- Analyze rendered pixels on CPU.
- Upload image data every frame.
- Maintain film frame history.

# 40. CPU Budget

Allowed CPU work:

- Update 24 FPS grain frame counter.
- Respond to settings.
- Respond to quality changes.
- Respond to preset changes.

Target:

    Average gameplay-thread cost:
    ≤ 0.01 ms

# 41. GPU Budget

Film Emulsion must use no more than approximately:

    2% of target frame budget

Initial limits:

| Target FPS | Total Frame | Film Budget |
|------------|-------------|-------------|
| 30         | 33.33 ms    | ≤ 0.67 ms   |
| 60         | 16.67 ms    | ≤ 0.33 ms   |
| 90         | 11.11 ms    | ≤ 0.22 ms   |
| 120        | 8.33 ms     | ≤ 0.17 ms   |

Use 95th-percentile measurements.

# 42. Memory Bandwidth Requirement

Lux already reads and writes the screen for post-processing.

Film Emulsion must reuse that traversal.

Desired:

    Existing Lux screen traversal
    +
    small amount of additional shader math

Prohibited:

    Existing Lux screen traversal
    +
    second full-screen Film traversal

This is one of the most important performance requirements.

# 43. Color Continuity Test

This test is a primary acceptance test.

Render smooth Lux-lit gradients:

    Red → dark red

    Orange → dark orange

    Blue → dark blue

    Green → dark green

    Warm skin-like gradient

    Neutral gray gradient

Capture:

    Film OFF

    Film ON

Requirements:

- Smooth gradients remain smooth.
- Neighboring pixels remain within the expected color family.
- Film Emulsion introduces no new banding.
- Film Emulsion introduces no visible RGB-channel breakup.
- Neutral grain causes minimal hue rotation.
- Film ON does not reduce effective scene-color precision.

# 44. Lighting Fidelity Test

Create a test scene containing:

- White light.
- Warm tungsten-like light.
- Cool blue light.
- Red light.
- Green light.
- Mixed colored lights.
- Smooth light falloff.
- Specular surfaces.
- Matte surfaces.

Film Emulsion passes when:

- The intended light color remains recognizable.
- Smooth illumination remains continuous.
- Shadow transitions remain smooth.
- Mixed-color boundaries do not break into RGB speckle.
- Saturated lighting remains saturated when appropriate.

# 45. Rainbow Speckle Test

Render a constant neutral patch.

Measure:

    Luma noise =
    std((R + G + B) / 3)

    Chroma noise =
    average(
        std(R-G),
        std(B-G)
    )

Hard requirement:

    chroma_noise
    <
    0.4 × luma_noise

Preferred:

    chroma_noise
    <
    0.2 × luma_noise

# 46. Hue Preservation Test

Render:

    Red
    Orange
    Yellow
    Green
    Cyan
    Blue
    Magenta

Apply neutral Film Emulsion.

Requirements:

- Mean hue remains stable.
- Grain primarily changes exposure.
- Isolated opponent-color pixels are not visible.
- Chroma variation remains secondary.

# 47. Exposure Response Test

Render patches at:

    5%
    20%
    50%
    80%
    100%

luminance.

Required:

    Dark Grain RMS
    >
    Midtone Grain RMS
    >
    Highlight Grain RMS

This confirms grain belongs to the photographic exposure model.

# 48. Banding Test

Render large smooth gradients.

Compare:

    Lux baseline

    Film Emulsion

    Film + Dither

    Film + Palette

Requirements:

- Film Emulsion alone must not introduce visible banding.
- Film Emulsion must not lower the effective precision of the underlying
  gradient.
- Palette/dither effects may intentionally reduce precision only when
  explicitly enabled.

# 49. Temporal Test

Test:

- 30 FPS.
- 60 FPS.
- 90 FPS.
- 120 FPS.
- Variable FPS.
- Static camera.
- Moving camera.
- Rapid camera rotation.

Requirements:

- Grain changes at the configured film cadence.
- Grain does not scroll continuously.
- Grain does not attach to surfaces.
- Grain does not visibly pulse.
- Grain does not produce obvious tile repetition.

# 50. Performance Test Matrix

Test:

    1280 × 720
    1280 × 800
    1920 × 1080
    2560 × 1440
    3840 × 2160

Modes:

    Film OFF

    Simple Grain

    Film Emulsion

Collect:

- GPU frame time.
- CPU frame time.
- Render-thread time.
- VRAM.
- RAM.
- GPU bandwidth.
- Power use on handheld hardware.
- Shader stalls.
- 95th-percentile frame time.
- 99th-percentile frame time.

Run at least:

    1,000 frames

per configuration.

# 51. Hardware Qualification

At minimum test:

- Integrated GPU.
- Low-end discrete GPU.
- Mid-range GPU.
- AMD.
- NVIDIA.
- Intel.
- Steam Deck-class handheld.
- Minimum supported production target.

Film Emulsion should not be enabled by default on a platform that cannot
meet the defined budget.

# 52. Quality Behavior

Recommended:

## High

    Film available

    Neutral grain

    Chromatic grain

    128 or 256 texture

## Medium

    Film available

    Neutral grain

    Restrained chromatic grain

    128 texture

## Low

    Film disabled

    Optional Simple grain

## Compatibility

    Film disabled

    Optional Simple grain

# 53. Graphics Settings

Example:

    RENDERING

    Lux Effects             ON
    Photographic Color      ON
    Film Emulsion           ON
    Retro Palette           OFF
    CRT Effect              OFF

Optional simplified version:

    Film Emulation          ON/OFF

Turning Film Emulation off must not change gameplay or lighting
calculations.

It only removes the photographic post response.

# 54. Failure Behavior

If Film Emulsion cannot run:

    Normal Lux rendering continues.

Do not:

- Fail the scene.
- Disable Lux.
- Render black.
- Drop materials.
- Change gameplay state.

# 55. Implementation Phases

## Phase 1: Color Pipeline Audit

Inspect the current Lux shader order.

Identify:

- Where scene precision is preserved.
- Where color is clamped.
- Where color is quantized.
- Where palette reduction occurs.
- Where dithering occurs.
- Where existing grain is added.

Exit requirement:

The team knows exactly where color information is currently lost.

## Phase 2: Reorder for Color Preservation

Create the photographic path:

    Lux Grade
    ↓
    Film Response
    ↓
    Film Grain
    ↓
    Optional Palette/Dither

Exit requirement:

Film Emulsion has access to continuous scene color before deliberate
quantization.

## Phase 3: API Integration

Implement:

- `LuxPreset`.
- `LuxQualityProfile`.
- `LuxRoot`.
- `LuxRuntimeAPI`.

Exit requirement:

Film Emulsion can be requested or disabled without changing rendering
yet.

## Phase 4: Packed Grain Asset

Create:

    128 × 128 RGBA8

with:

    R fine neutral

    G coarse neutral

    B red-green variation

    A blue-yellow variation

## Phase 5: Neutral Density Grain

Implement:

- Exposure mask.
- Fine/coarse combination.
- Scalar density signal.
- Shared RGB transmission.

Exit requirement:

Color Continuity Test passes.

## Phase 6: Restrained Chromatic Grain

Implement opponent-axis dye variation.

Exit requirement:

Rainbow Speckle Test passes.

## Phase 7: Shader Variants

Provide:

    Baseline Lux Shader

    Film Lux Shader

Precompile both.

Exit requirement:

Film OFF introduces no film-specific shader work.

## Phase 8: Runtime Toggle

Connect:

    Graphics Menu
    ↓
    LuxRuntimeAPI
    ↓
    LuxRoot
    ↓
    LuxPostFX
    ↓
    Shader Variant

Exit requirement:

Player can toggle the effect during play.

## Phase 9: Quality Integration

Implement automatic permission:

    High → allowed
    Medium → allowed
    Low → disabled
    Compatibility → disabled

## Phase 10: Performance Qualification

Measure:

- GPU.
- CPU.
- VRAM.
- RAM.
- Bandwidth.
- Power.
- Frame-time variance.

The system may not ship until budgets pass.

# 56. Definition of Done

Film Emulsion is complete when:

- It is optional.
- It can be disabled globally.
- It can be controlled per preset.
- It can be disabled by quality tier.
- Existing Lux scenes continue working with Film Emulsion off.
- It does not create a second full-screen rendering pipeline.
- It operates before deliberate color quantization in photographic mode.
- It preserves high-precision scene color.
- It does not internally quantize the scene to RGB8.
- Primary grain uses one shared density signal.
- Primary grain does not independently randomize R, G, and B.
- Chromatic variation is secondary and restrained.
- Smooth lighting gradients remain smooth.
- Film Emulsion introduces no new visible banding.
- Film Emulsion introduces no visible RGB-channel breakup.
- Neighboring grain variations remain within the underlying perceived
  color family.
- The feature adds no full-resolution render target.
- Deterministic V1 VRAM stays below 0.25 MiB.
- Persistent Film Emulsion RAM stays below 1 MiB.
- No CPU image processing occurs.
- No per-frame texture upload occurs.
- No gameplay-time shader compilation occurs.
- Disabled mode performs no Film Emulsion-specific GPU work.
- Enabled mode remains below 2 percent of the target GPU frame budget.
- Minimum target hardware passes validation.

# 57. Final Design Principle

The feature should be understood as:

> **A color-preserving photographic rendering treatment, not a noise
> overlay.**

Its first responsibility is:

    Preserve the true colors created by Lux lighting.

Its second responsibility is:

    Allow those colors to vary naturally through exposure and film-density behavior.

Its third responsibility is:

    Add restrained film grain without breaking the image into independent RGB noise.

Only after those steps should Lux optionally apply:

    Palette reduction

    Dithering

    Quantization

    CRT effects

The core engineering rule is:

> **Preserve color information first. Apply the photographic response
> second. Destroy or stylize color information only afterward and only
> when explicitly requested.**

The core performance rule is:

> **Film Emulsion must enhance a Lux render pass that already exists. It
> must not create a second rendering pipeline or require substantial new
> framebuffer memory.**

The intended result is a Lux scene whose lighting retains smooth,
continuous, believable color while gaining the subtle density variation
and texture associated with photographic film rather than digital RGB
noise.
