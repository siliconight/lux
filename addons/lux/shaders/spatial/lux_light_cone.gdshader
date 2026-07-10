shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, specular_disabled;
// Fake-volumetric light cone (PS1-storm look). Flat vertical gradient, no
// fresnel: alpha is strongest at the apex (lamp) and fades to zero at the
// ground. camera_fade is driven per-frame by LuxStreetlightRig so the cone
// vanishes when the player walks under the lamp.

uniform vec4 cone_color : source_color = vec4(1.0, 0.72, 0.35, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.4;
uniform float apex_alpha : hint_range(0.0, 1.0) = 0.35;
uniform float camera_fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// CylinderMesh side UVs: V = 0.0 at the top (apex), 1.0 at the bottom.
	float grad = 1.0 - UV.y;
	ALBEDO = cone_color.rgb;
	ALPHA = apex_alpha * grad * intensity * camera_fade;
}
