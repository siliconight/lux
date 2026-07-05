shader_type canvas_item;

// Lux ordered dithering + color-depth reduction (TDD §13).
// Runs as a full-screen post pass on a ColorRect over a SubViewport's texture.
// Ordered Bayer 4x4 is the default because it is stable under motion and
// art-directable. Strength, cell size, color levels, and distance fade are all
// exposed. UI is excluded by keeping this pass on the world viewport only.

// hint_screen_texture binds Godot's rendered frame automatically -- no manual
// ViewportTexture wiring needed. The BackBufferCopy under the post layer
// guarantees the screen texture is populated for this pass. (canvas_item shaders
// cannot read the depth buffer in 4.7, so the distance-fade path is disabled.)
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float strength : hint_range(0.0, 1.0) = 0.3;
uniform int color_levels : hint_range(2, 64) = 24;
uniform int cell_size : hint_range(1, 8) = 1;

uniform bool distance_fade_enabled = true;
uniform float fade_start = 25.0;
uniform float fade_end = 70.0;
// Camera near/far so we can linearize Godot's non-linear depth buffer.
uniform float cam_near = 0.05;
uniform float cam_far = 500.0;

// Palette tint applied per-luminance-zone (authored around 0.5 = neutral).
uniform float palette_influence : hint_range(0.0, 1.0) = 0.0;
uniform vec3 palette_shadow = vec3(0.5);
uniform vec3 palette_mid = vec3(0.5);
uniform vec3 palette_highlight = vec3(0.5);

// Grade
uniform float brightness : hint_range(0.5, 2.0) = 1.0;
uniform float contrast : hint_range(0.5, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float warmth : hint_range(-1.0, 1.0) = 0.0;

// Finish
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.15;
uniform float grain_strength : hint_range(0.0, 0.3) = 0.03;
uniform float time_seed = 0.0;

// HDR output (Godot 4.7): when false (default retro case), the pass hard-clamps
// to the SDR [0,1] range so quantization/dithering land on the authored levels.
// When true, values are allowed to exceed 1.0 so HDR displays keep their range.
uniform bool hdr_passthrough = false;

const float BAYER4[16] = float[](
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
);

float bayer4(vec2 pix) {
	int x = int(mod(pix.x, 4.0));
	int y = int(mod(pix.y, 4.0));
	return BAYER4[y * 4 + x] / 16.0 - 0.5;
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 col = texture(screen_tex, uv).rgb;

	// --- Grade ---
	col *= brightness;
	col = (col - 0.5) * contrast + 0.5;
	float l = luma(col);
	col = mix(vec3(l), col, saturation);
	// Warmth: push R up / B down (or reverse) around neutral.
	col.r += warmth * 0.06;
	col.b -= warmth * 0.06;
	col = clamp(col, 0.0, 1.0);

	// --- Palette zones ---
	if (palette_influence > 0.0) {
		float lz = luma(col);
		vec3 sh = palette_shadow * 2.0;
		vec3 md = palette_mid * 2.0;
		vec3 hi = palette_highlight * 2.0;
		vec3 tint = (lz < 0.5) ? mix(sh, md, lz * 2.0) : mix(md, hi, (lz - 0.5) * 2.0);
		col = mix(col, col * tint, palette_influence);
		col = clamp(col, 0.0, 1.0);
	}

	// --- Dither + quantize ---
	// Distance fade needs the depth buffer, which canvas_item (2D) shaders can't
	// read in Godot 4.7 -- so dither applies uniformly. A depth-aware falloff
	// would need a spatial post pass; the fade uniforms are kept for compat.
	float amt = strength;
	if (amt > 0.0001) {
		float levels = float(color_levels);
		vec2 cell = floor(FRAGCOORD.xy / float(max(cell_size, 1)));
		float threshold = bayer4(cell) * amt;
		vec3 dithered = col + threshold / levels;
		dithered = floor(dithered * levels + 0.5) / levels;
		col = clamp(dithered, 0.0, 1.0);
	}

	// --- Vignette ---
	if (vignette_strength > 0.0) {
		vec2 d = uv - 0.5;
		float v = smoothstep(0.8, 0.35, length(d));
		col *= mix(1.0, v, vignette_strength);
	}

	// --- Grain ---
	if (grain_strength > 0.0) {
		float n = fract(sin(dot(uv * (time_seed + 1.0), vec2(12.9898, 78.233))) * 43758.5453);
		col += (n - 0.5) * grain_strength;
	}

	// In the default (SDR retro) path, hard-clamp so the quantization levels the
	// dither snapped to are exactly what reaches the display. In HDR passthrough,
	// only clamp the low end and let highlights exceed 1.0 for the HDR swapchain.
	if (hdr_passthrough) {
		col = max(col, vec3(0.0));
	} else {
		col = clamp(col, 0.0, 1.0);
	}
	COLOR = vec4(col, 1.0);
}
