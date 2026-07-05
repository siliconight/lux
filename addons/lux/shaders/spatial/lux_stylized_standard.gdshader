shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Lux stylized standard surface.
// Banded diffuse with a lifted, tinted shadow floor for that warm, readable,
// sixth-gen look; stylized specular + rim; palette pull in shadows/highlights;
// optional wetness, grime, vertex-snap and affine-mapping retro toggles.

uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform vec2 uv_scale = vec2(1.0);

// Diffuse banding
uniform float band_count : hint_range(1.0, 8.0) = 3.0;
uniform float band_softness : hint_range(0.0, 0.5) = 0.08;
uniform float shade_min : hint_range(0.0, 1.0) = 0.18;
uniform vec3 shadow_tint = vec3(0.62, 0.6, 0.78);

// Specular / rim
uniform float specular_strength : hint_range(0.0, 1.0) = 0.25;
uniform float specular_shininess : hint_range(2.0, 256.0) = 24.0;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.12;
uniform vec3 rim_color = vec3(1.0, 0.9, 0.8);

// Palette
uniform float palette_influence : hint_range(0.0, 1.0) = 0.25;
uniform vec3 palette_shadow = vec3(0.5, 0.5, 0.5);
uniform vec3 palette_highlight = vec3(0.5, 0.5, 0.5);

// Surface
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float grime : hint_range(0.0, 1.0) = 0.0;
uniform vec3 grime_color = vec3(0.16, 0.13, 0.1);

// Retro
uniform bool vertex_snap_enabled = false;
uniform float vertex_snap_resolution : hint_range(32.0, 512.0) = 160.0;
uniform float affine_amount : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_vertex_color;
varying float v_affine_w;

void vertex() {
	v_vertex_color = COLOR.rgb;

	if (vertex_snap_enabled) {
		// Snap in view space for the classic PS1 wobble.
		vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		float grid = vertex_snap_resolution;
		view_pos.xyz = floor(view_pos.xyz * grid) / grid;
		VERTEX = (inverse(MODELVIEW_MATRIX) * view_pos).xyz;
	}

	UV = UV * uv_scale;
	// Perspective-incorrect (affine) UVs: lerp toward a w that ignores depth.
	v_affine_w = mix(1.0, 1.0 / max(0.0001, -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z), affine_amount);
}

// Soft-stepped banding: quantizes light into `band_count` steps with a little
// smoothing so it reads as stylized shading rather than harsh posterization.
float band_light(float ndl) {
	float lifted = mix(shade_min, 1.0, clamp(ndl, 0.0, 1.0));
	float steps = max(1.0, band_count);
	float scaled = lifted * steps;
	float lower = floor(scaled);
	float frac = scaled - lower;
	float soft = smoothstep(0.5 - band_softness, 0.5 + band_softness, frac);
	return (lower + soft) / steps;
}

void fragment() {
	vec2 uv = UV / max(0.0001, v_affine_w);
	vec4 tex = texture(albedo_texture, uv);
	vec3 base = tex.rgb * albedo_tint.rgb;
	if (use_vertex_color) {
		base *= v_vertex_color;
	}
	base = mix(base, grime_color, grime * 0.6);

	ALBEDO = base;
	ROUGHNESS = mix(0.85, 0.15, wetness);
	METALLIC = 0.0;
	SPECULAR = mix(0.2, 0.6, wetness) * specular_strength * 1.6;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float shaded = band_light(ndl);

	vec3 lit = ALBEDO * LIGHT_COLOR * ATTENUATION * shaded;

	// Tint the darkest band toward the shadow/palette color.
	float shadow_mix = (1.0 - shaded) * 0.6;
	vec3 sh_col = mix(shadow_tint, palette_shadow * 2.0, palette_influence);
	lit = mix(lit, lit * sh_col, shadow_mix);

	// Palette pull in highlights.
	float hi = smoothstep(0.75, 1.0, shaded);
	lit = mix(lit, lit * (palette_highlight * 2.0), hi * palette_influence);

	// Stylized specular.
	vec3 H = normalize(LIGHT + VIEW);
	float spec = pow(max(dot(NORMAL, H), 0.0), specular_shininess);
	lit += LIGHT_COLOR * spec * specular_strength * ATTENUATION;

	// Rim.
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 2.0);
	lit += rim_color * rim * rim_strength * shaded;

	DIFFUSE_LIGHT += lit;
}
