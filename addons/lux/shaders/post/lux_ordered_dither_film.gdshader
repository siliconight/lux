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
// RANGE 0..0.30, DEFAULT 0.20, AND BOTH USED TO BE ABOUT 8x SMALLER.
//
// The old default of 0.025 puts the density modulation at roughly +/-0.75% of
// transmission, which is invisible: anyone who turned film on saw nothing and
// would reasonably conclude the feature was broken. A default nobody can see is
// not a conservative default, it is a broken one.
//
// 0.20 is where the first person to actually WALK a level and look at it put
// the knob. That is one judgement, on one night scene, and it is also the only
// look judgement this feature has ever had -- so it is the default, and a
// brighter preset may well want less.
//
// Section 45 is unaffected at any of these values: the ratio it measures is
// chroma-to-luma noise, and film_chroma_ratio is a fraction OF the neutral
// signal, so both scale together. Measured 0.1881 at 0.025, 0.1882 at 0.200 and
// 0.1884 at 0.300 -- inside both the hard 0.40 bar and the preferred 0.20 one
// throughout.
uniform float film_grain_strength : hint_range(0.0, 0.30) = 0.20;
uniform float film_chroma_ratio : hint_range(0.0, 0.25) = 0.12;
uniform float film_grain_scale : hint_range(0.5, 3.0) = 1.0;
// GRAIN SIZE IS RELATIVE TO FRAME WIDTH, NOT TO PIXELS.
//
// A crystal is a physical object on a strip of film; how many pixels it covers
// depends on how finely that strip was scanned. Pinning one grain texel to one
// PIXEL makes the emulsion change character with output resolution -- the same
// preset gives grain 1.42 px across at every resolution, which against film
// sized as a fraction of the frame is 2x too coarse at 720p and 1.45x too fine
// at 4K. Too fine is the one that hurts: it lands near Nyquist and fizzes.
//
// So the tile is scaled by width / film_grain_ref_width. 2048 is the reference
// because that is where the shipped asset's fine band (radius 1.42 px) already
// sits closest to a real fine crystal (1.38 px at 2.5K on the filmify
// photochemical profile's 1.1 px-at-2K figure) -- i.e. the asset was in effect
// authored for ~1440p, and this makes that intent hold everywhere.
//
// 0.0 disables the correction and restores the old pixel-locked behaviour.
uniform float film_grain_ref_width = 2048.0;
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
uniform float film_base_fog : hint_range(0.0, 0.02) = 0.0;
// MULTI-SCALE CRYSTALS. A real emulsion is not one grain size: it is a
// distribution -- many fine crystals plus sparser large ones. Sampling the
// tile at ONE scale gives every grain the same footprint, and a field of
// identical-sized specks at one texel each is what reads as electronic fizz
// rather than silver. Summing a few octaves at different scales, each with its
// own per-frame transform, is what makes the field look like crystals moving
// against each other instead of a screen door shimmering.
uniform int film_grain_octaves : hint_range(1, 3) = 1;
// How much coarser each successive octave is, and how much less it contributes.
// 2.1 rather than 2.0 keeps the octaves from landing on a common multiple and
// beating into a visible lattice.
uniform float film_grain_lacunarity : hint_range(1.5, 4.0) = 2.1;
uniform float film_grain_persistence : hint_range(0.1, 1.0) = 0.55;
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

	float res_scale = 1.0;
	if (film_grain_ref_width > 1.0) {
		// textureSize on the screen sampler, NOT SCREEN_PIXEL_SIZE: that
		// builtin does not exist in a Godot 4 canvas_item shader and the
		// compile error it produces does not stop the material being created,
		// so the feature fails by rendering wrong rather than by refusing.
		res_scale = float(textureSize(screen_tex, 0).x) / film_grain_ref_width;
	}
	vec2 sp = frag / max(film_grain_scale * res_scale, 0.001);
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
	// EITHER term, not just the density. base_fog inside a guard on
	// film_grain_strength would be silently inert at grain 0 -- a preset that
	// wanted shadow grit and no density would get nothing and no diagnostic.
	// Both inner terms scale by film_grain_strength, so entering this block
	// with grain 0 costs one texture fetch and changes nothing else.
	if (film_grain_strength > 0.0 || film_base_fog > 0.0) {
		ivec2 gsz = textureSize(film_grain_tex, 0);
		// The dihedral map assumes a square tile. The shipped asset is 128x128;
		// a non-square one falls back to its shorter side rather than sampling
		// out of bounds.
		int gs = min(gsz.x, gsz.y);

		// One octave is the original single-scale behaviour, bit for bit:
		// amp starts at 1.0, the loop runs once, and norm divides by 1.0.
		// Nothing changes for a preset that does not ask for more.
		// SINGLE-OCTAVE FAST PATH, AND IT IS NOT A MICRO-OPTIMISATION.
		//
		// A `for` bounded by a UNIFORM cannot be unrolled by the compiler: it
		// becomes a real loop with a per-fragment branch, on a full-screen
		// pass, at 4K. Section 41's budget went from met at every cell to OVER
		// at 90 and 120 fps between 0.28.0 and 0.29.0 -- film's cost at 4K
		// roughly doubled, 0.1340 ms to 0.2540 ms -- and this loop is the only
		// structural change in the hot path large enough to explain it. The
		// default is one octave, so the overwhelmingly common case should not
		// pay for a loop it never iterates.
		vec4 noise;
		if (film_grain_octaves <= 1) {
			noise = texelFetch(film_grain_tex,
				film_grain_coord(FRAGCOORD.xy, film_frame * 7, gs),
				0) * 2.0 - 1.0;
		} else {
		vec4 acc = vec4(0.0);
		float amp = 1.0;
		float norm = 0.0;
		float oct_scale = 1.0;
		for (int i = 0; i < film_grain_octaves; i++) {
			// FULL TURNOVER EVERY FILM FRAME, AT EVERY SCALE, AND THAT IS
			// CORRECT -- an attempt to make coarse crystals PERSIST was tried
			// here and both the physics and the measurement rejected it.
			//
			// The idea was that big clumps should hold across frames while
			// fine silver scintillates. It is wrong twice. Physically, every
			// frame of motion picture film is a DIFFERENT PIECE OF EMULSION
			// with its own crystals -- grain does not carry over from one
			// frame to the next, because the crystals are not the same
			// crystals. And empirically, dividing the frame counter per octave
			// changed nothing measurable: coarse turnover against fine came
			// out at 1.02, i.e. every scale still turned over together.
			//
			// So the organic quality is NOT temporal persistence. It is
			// spatial structure -- a distribution of crystal sizes -- turning
			// over completely at the projection cadence. Each octave still
			// gets its own offset so the scales are independent samples of the
			// tile rather than the same pattern at three magnifications.
			int oct_frame = film_frame * 7 + i * 131;
			acc += amp * (texelFetch(film_grain_tex,
				film_grain_coord(FRAGCOORD.xy / oct_scale, oct_frame, gs),
				0) * 2.0 - 1.0);
			norm += amp;
			amp *= film_grain_persistence;
			oct_scale *= film_grain_lacunarity;
		}
		noise = acc / max(norm, 0.0001);
		}

		// ONE neutral density signal, declared here because BOTH the fog
		// floor and the transmission multiply below are built from it. Sharing
		// it is not an optimisation -- it is what keeps the two terms from
		// being independent noise sources, which is how colour breakup gets
		// back in.
		float neutral_noise = noise.r * 0.68 + noise.g * 0.32;

		// BASE FOG: a floor that is itself GRAINY, and that only exists
		// where there is no picture.
		//
		// TWO WRONG VERSIONS PRECEDED THIS ONE, AND BOTH ARE INSTRUCTIVE.
		//
		// (1) `col += neutral_noise * film_base_fog` after the density. Noise
		//     symmetric about zero, landing on a channel already at zero: the
		//     negative half clips at black and only the POSITIVE half
		//     survives. Half-wave rectified white noise -- bright specks on
		//     pure black. Salt noise, and it reads as digital because no
		//     emulsion can emit light.
		//
		// (2) `col += film_base_fog` before the density, a FLAT pedestal. That
		//     is what base fog does to a strip of film, but a strip of film is
		//     then printed through a stock that crushes it back. Applied to a
		//     finished picture it lifts EVERY pixel, so the whole image goes
		//     milky and the blacks lose their depth. Correct physics, wrong
		//     place in the chain.
		//
		// What is wanted is the thing fog actually looks like on screen: the
		// void is not flat black, it has a faint texture, and the picture
		// above it is untouched. So the lift is
		//
		//   * MODULATED, not flat -- fog IS developed silver, and its
		//     distribution is grain. This is what puts movement in the black.
		//   * NON-NEGATIVE, so it cannot rectify the way (1) did. It runs
		//     0..film_base_fog with mean film_base_fog/2, which means the
		//     deepest parts of the void still reach true black.
		//   * SHADOW-GATED by a smoothstep that closes as soon as there is any
		//     real light, so it is a treatment of the void and not a pedestal
		//     under the image. This is what (2) got wrong.
		//
		// AND THE RANGE IS 0..0.02, NOT 0..0.10, BECAUSE THE FIRST DEFAULT WAS
		// 15x TOO LARGE. The filmify photochemical profile, which models the
		// same thing from measured film, puts projection flare at 0.004 and
		// the black floor at 0.002 -- a few TENTHS of a percent of peak. A
		// 0.03 lift is not a film black, it is a washed one, and that is
		// exactly what it looked like.
		//
		// Depth of black is therefore preserved twice over: the lift is a
		// fraction of a percent, its mean is half of that, its minimum is
		// zero, and anything brighter than a few times the fog level is not
		// lifted at all. The visible grain does NOT come from here -- it comes
		// from the density multiply below, acting on everything that has any
		// light in it at all. This term only stops the void being a dead flat
		// hole in the middle of a grained picture.
		if (film_base_fog > 0.0) {
			float fog_gate = 1.0 - smoothstep(0.0, 4.0 * film_base_fog,
				luma(col));
			col += film_base_fog * (0.5 + 0.5 * neutral_noise) * fog_gate;
		}

		// Section 29: grain belongs to the exposure, so it is strongest in the
		// dark end and quietest in the highlights. Computed AFTER the lift, so
		// the mask describes the tone the grain will actually act on.
		float lum = luma(col);
		float exposure_mask = clamp(1.0 - 0.92 * lum + 0.20 * lum * lum, 0.28, 1.0);

		// Sections 26-28. ONE neutral density signal, ONE transmission
		// multiplier shared by all three channels. This is the whole of the
		// colour-preservation argument: a shared multiplier moves value and
		// leaves hue AND saturation untouched, where the baseline's additive
		// grain moves saturation by up to 53% in deep shadow.
		//
		// It is also what makes the fog floor shimmer rather than speckle: a
		// fixed density change is a fixed RATIO change in transmission, so the
		// lifted black is modulated by the same percentage as a lit surface
		// and reads as a dark field breathing, not as dots.
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
			// THE DENOMINATOR IS FLOORED AT ONE QUANTIZATION STEP, NOT AT
			// 1e-4, AND THAT IS A BUG FIX, NOT A TWEAK.
			//
			// The old guard was `max(l, 0.0001)` with the reasoning that at
			// l == 0 the pixel is black so any multiplier leaves it black.
			// True for EXACTLY zero and false either side of it. The dither
			// threshold can round a near-black pixel UP to a whole step, so a
			// pixel at luma 1e-4 could come out with lq = 0.0139 and a ratio
			// of 139 -- the near-black parts of the frame multiplied by two
			// orders of magnitude.
			//
			// Measured on the night strip: film ON with base_fog at ZERO gave
			// mean luminance 0.0481 against the baseline's 0.0306, p5 0.0157
			// against 0.0000, and 4.1% pure black against 62.6%. The blacks
			// were being lifted by the quantizer, not by anything anyone had
			// dialled, and every "film on" figure taken this session carries
			// it.
			//
			// Flooring at one step (1.0 / ll) makes the ratio at most 1 where
			// the numerator is at most one step, so the shared decision can
			// darken a near-black pixel to black but can never amplify it.
			// True black stays true black because col is still a factor.
			vec3 coherent = col * (lq / max(l, 1.0 / ll));
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
