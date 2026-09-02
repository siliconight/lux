shader_type canvas_item;

// Lux post pass, FILM EMULSION variant (film_emulsion_tdd.md).
//
// This is lux_ordered_dither.gdshader with the film response inserted, and it
// exists as a SEPARATE shader on purpose. TDD section 35 asks for two variants
// and section 36 makes the disabled cost an acceptance test: zero film texture
// reads, zero film exp2 operations, zero film-frame updates when the feature is
// off. A branch inside one shader cannot promise that -- the sampler is still
// bound and the uniform block still grows. Two shaders can, because the film
// one is never bound unless film is active.
//
// The cost of that choice is duplication: everything outside the FILM block is
// a copy of the baseline shader and has to be changed in both places. That is
// the deliberate trade, and it is why the film block is fenced by comment
// banners rather than scattered.
//
// THREE ORDER CHANGES FROM THE BASELINE, all required by section 16:
//
//   1. Film runs BEFORE palette zones and before dither/quantize. The baseline
//      applies its grain last, after quantization -- which is exactly what
//      section 2 forbids, since quantization has already thrown away the
//      information the grain is supposed to modulate.
//   2. The grade's trailing clamp is DEFERRED until after the film block, so
//      film sees the graded value at whatever precision the render target
//      actually carries. Under the shipped configuration that target is 8-bit
//      and the clamp is a no-op; under `rendering/viewport/hdr_2d` it is not.
//      See docs/film_emulsion_phase1_audit.md section 2.
//   3. The baseline's Simple grain is ABSENT, not disabled. Section 11: never
//      run Simple and Film Emulsion simultaneously. Removing the code is a
//      stronger guarantee than setting its strength to zero.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float strength : hint_range(0.0, 1.0) = 0.3;
uniform int color_levels : hint_range(2, 64) = 24;
uniform int cell_size : hint_range(1, 8) = 1;

uniform bool distance_fade_enabled = true;
uniform float fade_start = 25.0;
uniform float fade_end = 70.0;
uniform float cam_near = 0.05;
uniform float cam_far = 500.0;

uniform float palette_influence : hint_range(0.0, 1.0) = 0.0;
uniform vec3 palette_shadow = vec3(0.5);
uniform vec3 palette_mid = vec3(0.5);
uniform vec3 palette_highlight = vec3(0.5);

uniform float brightness : hint_range(0.5, 2.0) = 1.0;
uniform float contrast : hint_range(0.5, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float warmth : hint_range(-1.0, 1.0) = 0.0;

uniform float vignette_strength : hint_range(0.0, 1.0) = 0.15;

uniform bool hdr_passthrough = false;

// --- Film emulsion -----------------------------------------------------------
// DELIBERATELY NOT `source_color`. The packed grain holds noise, not scene
// colour, and an sRGB decode on it would skew the distribution off zero-mean
// and break the density model (section 22: "Avoid sRGB conversion"). texelFetch
// ignores filter and repeat state; the hints are here to state the intent.
uniform sampler2D film_grain_tex : filter_nearest, repeat_enable;
uniform float film_grain_strength : hint_range(0.0, 0.10) = 0.025;
uniform float film_chroma_ratio : hint_range(0.0, 0.25) = 0.12;
uniform float film_grain_scale : hint_range(0.5, 3.0) = 1.0;
// Advanced by LuxPostFX at film_grain_fps, NOT once per rendered frame
// (section 24). Integer so the per-frame transform below is exact.
uniform int film_frame = 0;

// --- Chroma-coherent quantization ------------------------------------------
// THE RAINBOW IS THE DITHER, NOT THE GRAIN. Ordered dithering quantizes R, G
// and B INDEPENDENTLY, so on a coloured surface the three channels sit at
// different fractional positions between levels and cross their boundaries at
// different screen positions. A channel that dithers alone is pure chroma
// noise, and that is the "unrelated red, green, or blue pixels" of TDD
// section 1. Measured on a flat orange patch, where nothing else can vary:
// per-channel quantization scores 1.500 on section 45's own metric and moves
// saturation by 0.0797. The Simple grain it was blamed on scores 0.0000.
//
// The fix is the same idea as the density model one stage earlier: make ONE
// decision and share it. Quantize luminance, then scale the colour by the
// ratio -- a shared multiplier, so hue and saturation come through untouched.
//
// `dither_luma_scale` exists because a shared decision is COARSER: three
// channels quantized separately interleave their boundaries and yield more
// distinct luminance values than one channel does. Measured on a coloured
// gradient, per-channel at 24 levels gives 36 luminance steps; coherent gives
// 13 at the same count, 26 at 2x and 38 at 3x. At 3x the banding is finer than
// today's (max step 0.0139 against 0.0417) AND the saturation variation is
// exactly zero, so this is not a trade at that setting.
uniform float dither_chroma_coherence : hint_range(0.0, 1.0) = 1.0;
uniform float dither_luma_scale : hint_range(1.0, 4.0) = 3.0;

// Opponent colour axes, section 31. Both unit length, so film_chroma_ratio is
// the whole of the amplitude story.
const vec3 RED_GREEN_AXIS = vec3(0.7071, -0.7071, 0.0);
const vec3 BLUE_YELLOW_AXIS = vec3(-0.4082, -0.4082, 0.8165);
// ln(2). Converts a density delta into a first-order transmission multiplier
// for the chroma term, where the exact exp2 of the neutral term is not worth
// three more transcendentals (section 31).
const float LN2 = 0.69314718;
// -----------------------------------------------------------------------------

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

// Section 23: the tile is re-placed each film frame by a hashed offset and one
// of the eight dihedral maps, so a 128 px tile does not read as a 128 px tile.
// A LINEAR offset would make the grain scroll, which section 49 rules out --
// hence the hash. Integer arithmetic throughout: an exact map, no filtering,
// and the same result on every GPU.
ivec2 film_grain_coord(vec2 frag, int frame, int size) {
	int s = max(size, 1);
	uint fh = uint(frame) * 2654435761u;          // Knuth's multiplicative hash
	int ox = int(fh % uint(s));
	int oy = int((fh >> 8u) % uint(s));
	uint t = (fh >> 16u) & 7u;                    // 8 elements: 4 rotations x 2 flips

	vec2 sp = frag / max(film_grain_scale, 0.001);
	ivec2 p = ivec2(int(floor(sp.x)) + ox, int(floor(sp.y)) + oy);
	// Positive modulo: GLSL % keeps the sign of the dividend, and a negative
	// index into texelFetch is undefined rather than wrapped.
	p = ivec2(((p.x % s) + s) % s, ((p.y % s) + s) % s);

	if ((t & 4u) != 0u) { p = ivec2(p.y, p.x); }  // transpose
	if ((t & 1u) != 0u) { p.x = s - 1 - p.x; }    // flip x
	if ((t & 2u) != 0u) { p.y = s - 1 - p.y; }    // flip y
	return p;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 col = texture(screen_tex, uv).rgb;

	// --- Grade ---
	// Identical to the baseline EXCEPT that its trailing clamp is deferred to
	// after the film block; see note 2 in the header.
	col *= brightness;
	col = (col - 0.5) * contrast + 0.5;
	float l = luma(col);
	col = mix(vec3(l), col, saturation);
	col.r += warmth * 0.06;
	col.b -= warmth * 0.06;
	col = max(col, vec3(0.0));   // negatives are meaningless; highlights survive

	// ===== FILM EMULSION =========================================================
	if (film_grain_strength > 0.0) {
		ivec2 gsz = textureSize(film_grain_tex, 0);
		// The dihedral map assumes a square tile. The shipped asset is 128x128;
		// a non-square one falls back to its shorter side rather than sampling
		// out of bounds.
		int gs = min(gsz.x, gsz.y);
		vec4 noise = texelFetch(film_grain_tex,
			film_grain_coord(FRAGCOORD.xy, film_frame, gs), 0) * 2.0 - 1.0;

		// Section 29: grain belongs to the exposure, so it is strongest in the
		// dark end and quietest in the highlights.
		float lum = luma(col);
		float exposure_mask = clamp(1.0 - 0.92 * lum + 0.20 * lum * lum, 0.28, 1.0);

		// Sections 26-28. ONE neutral density signal, ONE transmission
		// multiplier shared by all three channels. This is the whole of the
		// colour-preservation argument: a shared multiplier moves value and
		// leaves hue AND saturation untouched, where the baseline's additive
		// grain moves saturation by up to 53% in deep shadow.
		float neutral_noise = noise.r * 0.68 + noise.g * 0.32;
		float neutral_density = neutral_noise * film_grain_strength * exposure_mask;
		col *= exp2(-neutral_density);

		// Section 31: a second, deliberately weak dye signal on two opponent
		// axes -- never three independent channel randoms. The floor keeps a
		// single texel from driving a channel toward black.
		if (film_chroma_ratio > 0.0) {
			vec3 chroma = (noise.b * RED_GREEN_AXIS + noise.a * BLUE_YELLOW_AXIS)
				* film_chroma_ratio * film_grain_strength * exposure_mask;
			col *= max(vec3(1.0) - LN2 * chroma, vec3(0.90));
		}
	}
	// ===== END FILM EMULSION =====================================================

	// The grade's clamp, deferred past the film block (header note 2).
	if (!hdr_passthrough) {
		col = clamp(col, 0.0, 1.0);
	}

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
	// Deliberate colour reduction, and it runs AFTER film on purpose: film is
	// the photographic capture layer, quantization is a later presentation
	// effect (section 18). With strength 0 there is no quantization at all,
	// which is section 17's Natural Mode.
	float amt = strength;
	if (amt > 0.0001) {
		float levels = float(color_levels);
		vec2 cell = floor(FRAGCOORD.xy / float(max(cell_size, 1)));
		float threshold = bayer4(cell) * amt;

		// The baseline's per-channel path, kept so the coherence dial can be
		// turned all the way back to the classic look.
		vec3 per_channel = floor((col + threshold / levels) * levels + 0.5) / levels;

		vec3 result = per_channel;
		if (dither_chroma_coherence > 0.0) {
			// ONE decision, shared by three channels -- see the header note.
			float ll = levels * max(dither_luma_scale, 1.0);
			float l = luma(col);
			float lq = floor((l + threshold / ll) * ll + 0.5) / ll;
			// max() rather than a branch: at l == 0 the pixel is black and any
			// multiplier leaves it black, so the guard only has to avoid the
			// division itself.
			vec3 coherent = col * (lq / max(l, 0.0001));
			result = mix(per_channel, coherent, dither_chroma_coherence);
		}
		col = clamp(result, 0.0, 1.0);
	}

	// --- Vignette ---
	if (vignette_strength > 0.0) {
		vec2 d = uv - 0.5;
		float v = smoothstep(0.8, 0.35, length(d));
		col *= mix(1.0, v, vignette_strength);
	}

	// No Simple grain here -- header note 3.

	if (hdr_passthrough) {
		col = max(col, vec3(0.0));
	} else {
		col = clamp(col, 0.0, 1.0);
	}
	COLOR = vec4(col, 1.0);
}
