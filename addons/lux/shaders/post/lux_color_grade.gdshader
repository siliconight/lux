shader_type canvas_item;

// Lux color grade (standalone).
// The main lux_ordered_dither pass already folds grading in for the MVP single-
// pass path. This shader exists for authors who want grading on its own layer
// (e.g. compatibility tier with no dithering, or a second stylization viewport).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

uniform float brightness : hint_range(0.5, 2.0) = 1.0;
uniform float contrast : hint_range(0.5, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float warmth : hint_range(-1.0, 1.0) = 0.0;
uniform vec3 lift = vec3(0.0);
uniform vec3 gain = vec3(1.0);

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	col = col * gain + lift;
	col *= brightness;
	col = (col - 0.5) * contrast + 0.5;
	float l = luma(col);
	col = mix(vec3(l), col, saturation);
	col.r += warmth * 0.06;
	col.b -= warmth * 0.06;
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
