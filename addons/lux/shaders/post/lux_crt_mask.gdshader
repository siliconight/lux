shader_type canvas_item;

// Lux CRT mask — optional "displayed on a CRT" layer for the PS2/6th-gen look.
// Simulates the phosphor layout of a CRT: either a shadow-mask triad-dot pattern
// or an aperture-grille vertical RGB stripe pattern (Trinitron-style), plus soft
// scanlines. Kept as a separate, subtle, toggleable pass so it never destroys
// readability (TDD §6 "Readable Retro") and can be excluded from UI by living on
// the same low world-only CanvasLayer as the dither pass.
//
// mask_type: 0 = off, 1 = aperture grille (vertical RGB stripes),
//            2 = shadow mask (staggered RGB triads).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

uniform int mask_type : hint_range(0, 2) = 1;
uniform float mask_strength : hint_range(0.0, 1.0) = 0.0;
// Triad/stripe size in physical pixels. Larger = chunkier, more visible phosphors.
uniform float mask_scale : hint_range(1.0, 8.0) = 3.0;
// How much brightness the lit phosphors regain vs. the dark gaps (keeps it from
// dimming the whole image).
uniform float mask_brightness : hint_range(1.0, 2.0) = 1.35;

uniform float scanline_strength : hint_range(0.0, 1.0) = 0.0;
uniform float scanline_count : hint_range(80.0, 1080.0) = 480.0;

// Aperture-grille RGB stripes: each screen column cycles R, G, B.
vec3 aperture_grille(vec2 frag) {
	float phase = mod(floor(frag.x / mask_scale), 3.0);
	vec3 m = vec3(0.0);
	if (phase < 1.0) {
		m = vec3(1.0, 0.0, 0.0);
	} else if (phase < 2.0) {
		m = vec3(0.0, 1.0, 0.0);
	} else {
		m = vec3(0.0, 0.0, 1.0);
	}
	return m;
}

// Shadow-mask triads: RGB cycle horizontally, offset every other row so the
// dots stagger like a real dot-trio mask.
vec3 shadow_mask(vec2 frag) {
	float row = floor(frag.y / mask_scale);
	float offset = mod(row, 2.0) * 1.5;
	float phase = mod(floor(frag.x / mask_scale) + offset, 3.0);
	vec3 m = vec3(0.0);
	if (phase < 1.0) {
		m = vec3(1.0, 0.0, 0.0);
	} else if (phase < 2.0) {
		m = vec3(0.0, 1.0, 0.0);
	} else {
		m = vec3(0.0, 0.0, 1.0);
	}
	return m;
}

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;

	if (mask_type > 0 && mask_strength > 0.0) {
		vec3 mask = (mask_type == 2) ? shadow_mask(FRAGCOORD.xy) : aperture_grille(FRAGCOORD.xy);
		// Boost the lit sub-pixels so the masked image keeps its overall
		// brightness instead of going dim.
		vec3 masked = col * mask * mask_brightness;
		col = mix(col, masked, mask_strength);
	}

	if (scanline_strength > 0.0) {
		float s = sin(SCREEN_UV.y * scanline_count * 3.14159265);
		float line = 1.0 - scanline_strength * (0.5 - 0.5 * s);
		col *= line;
	}

	COLOR = vec4(col, 1.0);
}
