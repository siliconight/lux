// =====================================================
// SkyMint  —  fake volumetric clouds + retro skybox
// =====================================================
// Cloud system by VELVET KATANA STUDIOS
//   "no copyrights but please support if you can, thank you"
//   source: godotshaders.com/shader/aaa-fake-volumetric-clouds
//
// Modifications for the SkyMint addon (kept minimal):
//   * base_sky_texture_2 + base_sky_blend  -> crossfade two
//     retro skyboxes across the day/night cycle.
//   * everything else is the original shader, driven at
//     runtime from skymint.gd (sun_direction, tints,
//     exposure, sun + cloud colors, brightness).
// =====================================================

shader_type sky;

// =====================================================
// TEXTURES
// =====================================================

uniform sampler2D base_sky_texture   : source_color;   // "day"   panorama (equirect)
uniform sampler2D base_sky_texture_2 : source_color;   // "night" panorama (equirect)
uniform sampler2D cloud_noise_texture : source_color;  // seamless noise (built at runtime)

// blends base_sky_texture (0.0) -> base_sky_texture_2 (1.0)
uniform float base_sky_blend : hint_range(0.0, 1.0) = 0.0;

// =====================================================
// SKY
// =====================================================

uniform float sky_exposure : hint_range(0.1, 5.0) = 1.0;
uniform vec3  sky_tint : source_color = vec3(1.0);

// =====================================================
// CLOUD SHAPE
// =====================================================

uniform float cloud_scale = 1.9;
uniform float cloud_density  : hint_range(0.0, 1.0) = 0.52;
uniform float cloud_softness : hint_range(0.01, 1.0) = 0.16;
uniform float detail_strength : hint_range(0.0, 2.0) = 0.7;
uniform float cloud_contrast  : hint_range(0.5, 3.0) = 1.35;

// =====================================================
// CLOUD COLORS
// =====================================================

uniform vec3 cloud_bright_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_mid_color    : source_color = vec3(0.82, 0.84, 0.88);
uniform vec3 cloud_dark_color   : source_color = vec3(0.50, 0.54, 0.62);
uniform float cloud_brightness : hint_range(0.0, 3.0) = 1.15;

// =====================================================
// ATMOSPHERIC CLOUD BLENDING
// =====================================================

uniform float atmosphere_blend : hint_range(0.0, 1.0) = 0.22;
uniform float atmosphere_horizon_strength : hint_range(0.0, 2.0) = 1.0;
uniform float atmosphere_zenith_strength  : hint_range(0.0, 2.0) = 0.35;

// =====================================================
// MOVEMENT
// =====================================================

uniform vec2  cloud_direction = vec2(0.0, -1.0);
uniform float cloud_speed = 0.01;
uniform float cloud_evolution_speed : hint_range(0.0, 0.1) = 0.01;
uniform float edge_warp_strength : hint_range(0.0, 1.0) = 0.08;
uniform float edge_warp_scale = 3.0;

// =====================================================
// CLOUD DISTRIBUTION
// =====================================================

uniform float horizon_fade  : hint_range(0.0, 1.0) = 0.18;
uniform float zenith_density : hint_range(0.0, 2.0) = 1.0;
uniform float horizon_blend : hint_range(0.0, 1.0) = 0.35;

// =====================================================
// SUN  (sun_direction matches your DirectionalLight3D)
// =====================================================

uniform vec3  sun_direction = vec3(0.4, 0.5, 0.2);
uniform vec3  sun_color : source_color = vec3(1.0, 0.96, 0.88);
uniform float sun_size : hint_range(0.0005, 0.05) = 0.004;
uniform float sun_intensity : hint_range(0.0, 30.0) = 14.0;

// =====================================================
// RANDOM LIGHT PATCHES
// =====================================================

uniform float random_light_strength : hint_range(0.0, 2.0) = 0.4;
uniform float random_light_scale = 0.7;

// =====================================================

void sky() {

    vec2 uv = SKY_COORDS;

    // ---- BASE SKY (day <-> night crossfade) ----
    vec3 base_sky = mix(
        texture(base_sky_texture, uv).rgb,
        texture(base_sky_texture_2, uv).rgb,
        base_sky_blend
    );
    base_sky *= sky_tint * sky_exposure;

    vec3 dir = normalize(EYEDIR);

    // ---- CLOUD PROJECTION ----
    vec2 cloud_uv = dir.xz;
    cloud_uv /= max(dir.y + 0.15, 0.15);
    cloud_uv *= cloud_scale;
    cloud_uv += cloud_direction * TIME * cloud_speed;

    // ---- CLOUD EVOLUTION ----
    vec2 evolution_offset = vec2(
        sin(TIME * cloud_evolution_speed),
        cos(TIME * cloud_evolution_speed * 0.83)
    ) * 0.35;
    vec2 macro_shift = vec2(sin(TIME * 0.003), cos(TIME * 0.0027)) * 0.12;

    // ---- NOISE ----
    float base_noise = texture(cloud_noise_texture, cloud_uv + macro_shift).r;
    float secondary_noise = texture(cloud_noise_texture,
        cloud_uv * 0.55 + vec2(0.23, 0.37) + evolution_offset * 0.4).r;
    float detail_noise = texture(cloud_noise_texture,
        cloud_uv * 2.4 + evolution_offset).r;

    float noise = base_noise + secondary_noise * 0.5 - detail_noise * detail_strength;

    // ---- EDGE TURBULENCE ----
    float edge_noise = texture(cloud_noise_texture,
        cloud_uv * edge_warp_scale + evolution_offset * 1.7).r;
    edge_noise = (edge_noise - 0.5) * edge_warp_strength;
    noise += edge_noise * (1.0 - abs(noise - 0.5) * 2.0);

    noise = clamp(noise, 0.0, 1.0);
    noise = pow(noise, cloud_contrast);

    // ---- CLOUD MASK ----
    float clouds = smoothstep(cloud_density, cloud_density + cloud_softness, noise);
    float overhead_mask = pow(max(dir.y, 0.0), 0.35);
    clouds *= mix(horizon_fade, zenith_density, overhead_mask);

    // ---- LIGHT DIRECTION ----
    vec3 light_dir = normalize(-sun_direction);
    float sun_dot = dot(dir, light_dir);

    // ---- POINT SUN WITH CLOUD OCCLUSION ----
    float sun_core = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.35, sun_dot);
    float sun_glow = pow(clamp(sun_dot, 0.0, 1.0), 120.0);
    float wide_glow = pow(clamp(sun_dot, 0.0, 1.0), 18.0) * 0.18;

    float thickness = smoothstep(0.2, 0.9, noise);

    float glow_occlusion = 1.0 - clouds;
    glow_occlusion *= 1.0 - thickness * 0.85;
    float sun_visibility = 1.0 - clouds * 0.92;

    vec3 sun_light = sun_color * sun_core * sun_intensity * sun_visibility;
    vec3 glow_light = sun_color * (sun_glow * 1.4 + wide_glow) * glow_occlusion;

    // ---- CLOUD LIGHTING ----
    float sun_height = light_dir.y;
    float day_factor = clamp(sun_height * 3.0, 0.0, 1.0);   // 1 = day, 0 = sunset/night

    float top_light = max(dir.y, 0.0);
    float bottom_light = pow(1.0 - max(dir.y, 0.0), 1.5);
    float vertical_light = mix(bottom_light, top_light, day_factor);

    float sun_wrap = pow(clamp(dot(dir, light_dir) * 0.5 + 0.5, 0.0, 1.0), 1.5);
    float edge_light = pow(1.0 - thickness, 2.2) * vertical_light * sun_wrap;
    float body_shadow = thickness * mix(0.45, 0.75, day_factor);

    // ---- RANDOM LIGHT SCATTERING ----
    float random_light = texture(cloud_noise_texture,
        cloud_uv * random_light_scale + evolution_offset * 0.2).r;
    random_light = smoothstep(0.6, 0.92, random_light);

    // ---- FINAL LIGHTING ----
    float lighting = edge_light * 1.3 + random_light * random_light_strength
        - body_shadow - thickness * 0.15;
    lighting = clamp(lighting, 0.0, 1.0);

    // ---- CLOUD COLOR ----
    vec3 cloud_color = mix(cloud_dark_color, cloud_mid_color, lighting);
    cloud_color = mix(cloud_color, cloud_bright_color, edge_light);

    // ---- ATMOSPHERIC BLENDING ----
    float atmosphere_factor = mix(atmosphere_horizon_strength,
        atmosphere_zenith_strength, max(dir.y, 0.0));
    atmosphere_factor *= atmosphere_blend;
    cloud_color = mix(cloud_color, base_sky, atmosphere_factor);
    cloud_color *= cloud_brightness;

    // ---- HORIZON ATMOSPHERE ----
    float horizon_amount = pow(1.0 - max(dir.y, 0.0), 2.5);
    cloud_color = mix(cloud_color, base_sky, horizon_amount * horizon_blend);

    // ---- FINAL SKY ----
    vec3 sky_with_sun = base_sky + glow_light + sun_light;
    vec3 final_color = mix(sky_with_sun, cloud_color, clouds);

    COLOR = final_color;
}
