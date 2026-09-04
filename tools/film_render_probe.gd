extends SceneTree
## Renders known patches through the Lux post shaders and reports what came
## back. Driven by tools/film_render_probe.py, which builds the scratch project
## this runs in -- see that file for invocation.
##
## NOT --headless: that disables rendering, and rendering is the entire point.
##
## THE FIRST QUESTION IS WHETHER THE FILM SHADER COMPILES. The identity case
## answers it better than scanning stderr for the word ERROR: with film off and
## every other stage neutral, the pass must return its input unchanged. A shader
## that failed to compile is replaced by Godot with a fallback, and the fallback
## does not reproduce the input. `luma_noise 0.0` on a constant patch is
## therefore a compile receipt, not just a quiet log.
##
## THE SECOND QUESTION IS WHETHER THE SHADER MATCHES THE MODEL.
## tools/film_math_probe.py evaluates the same math in numpy; this renders it.
## Where the two agree the model can be trusted for the cases this cannot
## cheaply render, and where they disagree one of them is wrong. Both are needed;
## neither is sufficient.
##
## WHY IT ALSO RENDERS THE BASELINE SHADER. The baseline Simple grain is
## chroma-free BY CONSTRUCTION -- one scalar added to three channels -- so its
## measured chroma noise is a direct read of the noise floor imposed by the
## output format, with no model in the way. That is what showed section 45's
## metric to be unusable at 8 bits: the baseline scores 0.0018 there and
## 0.000009 at 16, and the difference is entirely the render target.

const FILM := "res://addons/lux/shaders/post/lux_ordered_dither_film.gdshader"
const BASE := "res://addons/lux/shaders/post/lux_ordered_dither.gdshader"
const GRAIN := "res://addons/lux/resources/film/grain_balanced.png"

const BEGIN := "<<<FILM_RENDER_JSON"
const END := "FILM_RENDER_JSON>>>"

const SRC_SHADER := """
shader_type canvas_item;
uniform vec3 patch = vec3(0.5);
void fragment() { COLOR = vec4(patch, 1.0); }
"""

var _src_mat: ShaderMaterial
var _post_mat: ShaderMaterial
var _post_rect: ColorRect
var _out: Dictionary = {}


func _initialize() -> void:
	_main()


func _neutral(mat: ShaderMaterial) -> void:
	# Everything the post pass can do, switched off, so the only thing that can
	# change a pixel is the block under test.
	mat.set_shader_parameter(&"strength", 0.0)
	mat.set_shader_parameter(&"color_levels", 24)
	mat.set_shader_parameter(&"cell_size", 1)
	mat.set_shader_parameter(&"palette_influence", 0.0)
	mat.set_shader_parameter(&"brightness", 1.0)
	mat.set_shader_parameter(&"contrast", 1.0)
	mat.set_shader_parameter(&"saturation", 1.0)
	mat.set_shader_parameter(&"warmth", 0.0)
	mat.set_shader_parameter(&"vignette_strength", 0.0)
	mat.set_shader_parameter(&"hdr_passthrough", false)


func _build() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	root.add_child(layer)

	var src := ColorRect.new()
	src.set_anchors_preset(Control.PRESET_FULL_RECT)
	_src_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SRC_SHADER
	_src_mat.shader = sh
	src.material = _src_mat
	layer.add_child(src)

	var bb := BackBufferCopy.new()
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	layer.add_child(bb)

	_post_rect = ColorRect.new()
	_post_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = load(FILM)
	_post_mat.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(_post_mat)
	_post_rect.material = _post_mat
	layer.add_child(_post_rect)


## Render one configuration and return per-channel statistics of the result.
func _shoot(patch: Color) -> Dictionary:
	_src_mat.set_shader_parameter(&"patch", Vector3(patch.r, patch.g, patch.b))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var w: int = img.get_width()
	var h: int = img.get_height()

	# Sample the middle half in both axes -- the edges of a viewport are where
	# a stray border or a half-covered pixel would land, and one such pixel
	# would move a standard deviation more than the effect being measured.
	var x0: int = w / 4
	var x1: int = w - w / 4
	var y0: int = h / 4
	var y1: int = h - h / 4
	var n: int = 0
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var codes: Dictionary = {}
	var px: Array[Color] = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c: Color = img.get_pixel(x, y)
			px.append(c)
			sr += c.r
			sg += c.g
			sb += c.b
			codes[int(round(c.r * 255.0))] = true
			n += 1
	var mr := sr / float(n)
	var mg := sg / float(n)
	var mb := sb / float(n)

	# Second pass for the spreads the TDD's tests are written in terms of.
	var v_luma := 0.0
	var v_rg := 0.0
	var v_bg := 0.0
	var m_luma := (mr + mg + mb) / 3.0
	var m_rg := mr - mg
	var m_bg := mb - mg
	var sat_min := 2.0
	var sat_max := -1.0
	for c in px:
		var lu: float = (c.r + c.g + c.b) / 3.0
		v_luma += (lu - m_luma) * (lu - m_luma)
		v_rg += ((c.r - c.g) - m_rg) * ((c.r - c.g) - m_rg)
		v_bg += ((c.b - c.g) - m_bg) * ((c.b - c.g) - m_bg)
		var mx: float = maxf(c.r, maxf(c.g, c.b))
		var mn: float = minf(c.r, minf(c.g, c.b))
		var s: float = 0.0 if mx <= 0.0 else (mx - mn) / mx
		sat_min = minf(sat_min, s)
		sat_max = maxf(sat_max, s)
	var fn := float(n)
	return {
		"n": n, "width": w, "height": h,
		"mean": [mr, mg, mb],
		"luma_noise": sqrt(v_luma / fn),
		"chroma_noise": 0.5 * (sqrt(v_rg / fn) + sqrt(v_bg / fn)),
		"distinct_r_codes": codes.size(),
		"sat_min": sat_min, "sat_max": sat_max,
	}


func _main() -> void:
	_build()

	# --- 1. identity: film off, everything else neutral ---
	_post_mat.set_shader_parameter(&"film_grain_strength", 0.0)
	_post_mat.set_shader_parameter(&"film_chroma_ratio", 0.0)
	_post_mat.set_shader_parameter(&"film_grain_scale", 1.0)
	_post_mat.set_shader_parameter(&"film_frame", 0)
	var ident := await _shoot(Color(0.5, 0.5, 0.5))
	_out["identity_gray"] = ident
	var ident_orange := await _shoot(Color(0.72, 0.41, 0.19))
	_out["identity_orange"] = ident_orange

	# --- 2. film on, default strength ---
	_post_mat.set_shader_parameter(&"film_grain_strength", 0.025)
	_post_mat.set_shader_parameter(&"film_chroma_ratio", 0.10)
	_out["film_default_gray"] = await _shoot(Color(0.5, 0.5, 0.5))
	_out["film_default_orange"] = await _shoot(Color(0.72, 0.41, 0.19))
	_out["film_default_shadow"] = await _shoot(Color(0.06, 0.035, 0.02))

	# --- 3. film on, maximum strength -- the amplitude at which an 8-bit
	#        target can actually carry the signal, so the ratio is measurable ---
	_post_mat.set_shader_parameter(&"film_grain_strength", 0.10)
	_out["film_max_gray"] = await _shoot(Color(0.5, 0.5, 0.5))
	_out["film_max_orange"] = await _shoot(Color(0.72, 0.41, 0.19))
	_out["film_max_shadow"] = await _shoot(Color(0.06, 0.035, 0.02))

	# --- 4. the baseline shader's Simple grain, same patches, for comparison ---
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = load(BASE)
	_neutral(_post_mat)
	_post_mat.set_shader_parameter(&"grain_strength", 0.03)
	_post_mat.set_shader_parameter(&"time_seed", 0.0)
	_post_rect.material = _post_mat
	_out["baseline_gray"] = await _shoot(Color(0.5, 0.5, 0.5))
	_out["baseline_orange"] = await _shoot(Color(0.72, 0.41, 0.19))
	_out["baseline_shadow"] = await _shoot(Color(0.06, 0.035, 0.02))

	# --- 5. CONTROL: film on, chroma term completely off. Section 45's metric
	#        scores well above zero on a COLOURED patch with no chroma term at
	#        all, because std(R-G) there is driven by the shared transmission
	#        multiplying a non-zero R-G. That is why section 45 specifies a
	#        NEUTRAL patch, and why its metric must not be read as a failure on
	#        anything else. Without this control somebody eventually "fixes" a
	#        chroma term that was never the problem.
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = load(FILM)
	_post_mat.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(_post_mat)
	_post_mat.set_shader_parameter(&"film_grain_strength", 0.10)
	_post_mat.set_shader_parameter(&"film_chroma_ratio", 0.0)
	_post_mat.set_shader_parameter(&"film_grain_scale", 1.0)
	_post_mat.set_shader_parameter(&"film_frame", 0)
	_post_rect.material = _post_mat
	_out["chroma_off_gray"] = await _shoot(Color(0.5, 0.5, 0.5))
	_out["chroma_off_orange"] = await _shoot(Color(0.72, 0.41, 0.19))

	# --- 6. cost, when asked for. Off by default: it takes seconds per
	#        configuration and the correctness cases do not need it.
	if bool(ProjectSettings.get_setting("film_probe/measure_cost", false)):
		_out["cost"] = await _measure_cost(
			int(ProjectSettings.get_setting("film_probe/warmup_frames", 120)),
			int(ProjectSettings.get_setting("film_probe/timed_frames", 600)))

	_out["viewport_size"] = [root.size.x, root.size.y]
	# --- 6. THE RAINBOW, on the GPU. Dither ON, on a flat coloured patch,
	#        with the quantization decision per-channel and then shared.
	#        A flat patch has no variation before quantization, so anything
	#        measured after it was put there by the quantizer.
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = load(FILM)
	_post_mat.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(_post_mat)
	_post_mat.set_shader_parameter(&"film_grain_strength", 0.0)  # quantizer alone
	_post_mat.set_shader_parameter(&"film_chroma_ratio", 0.0)
	_post_mat.set_shader_parameter(&"film_grain_scale", 1.0)
	_post_mat.set_shader_parameter(&"film_frame", 0)
	_post_mat.set_shader_parameter(&"strength", 0.3)      # dither ON
	_post_mat.set_shader_parameter(&"color_levels", 24)
	_post_mat.set_shader_parameter(&"dither_luma_scale", 3.0)
	_post_rect.material = _post_mat
	for coh in [0.0, 1.0]:
		_post_mat.set_shader_parameter(&"dither_chroma_coherence", coh)
		var tag := "perchannel" if coh <= 0.0 else "shared"
		_out["quantize_%s_orange" % tag] = await _shoot(Color(0.72, 0.41, 0.19))
		_out["quantize_%s_red" % tag] = await _shoot(Color(0.72, 0.12, 0.10))

	_out["hdr_2d"] = bool(ProjectSettings.get_setting(
		"rendering/viewport/hdr_2d", false))
	_out["godot"] = Engine.get_version_info().get("string", "?")
	_out["adapter"] = RenderingServer.get_video_adapter_name()
	_out["rendering_method"] = str(ProjectSettings.get_setting(
		"rendering/renderer/rendering_method", "?"))
	var img: Image = root.get_texture().get_image()
	_out["readback_format"] = img.get_format()
	_out["readback_format_name"] = _format_name(img.get_format())

	print(BEGIN)
	print(JSON.stringify(_out, "  "))
	print(END)
	quit(0)



## GPU time for one material, in milliseconds, over `frames` samples.
##
## WHY THE ENGINE'S OWN COUNTER AND NOT A WALL CLOCK. The CPU submits a frame
## and moves on; `Time.get_ticks_usec()` around a draw measures submission, not
## execution, and on a fill-bound pass the two are unrelated.
## `viewport_get_measured_render_time_gpu` reads the GPU's own timestamps for
## that viewport.
##
## WHY THE WARMUP IS NOT OPTIONAL. The first draw with a material is when Godot
## compiles its shader, and the card is usually still at an idle clock for the
## first frames after that. Both land in the first samples and both are large
## enough to swamp a 0.3 ms budget. The warmup frames are rendered and thrown
## away for exactly that reason.
func _time_material(mat: ShaderMaterial, visible: bool, warmup: int,
		frames: int) -> Dictionary:
	_post_rect.visible = visible
	if mat != null:
		_post_rect.material = mat
	var rid: RID = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for i in range(warmup):
		await RenderingServer.frame_post_draw
	# WALL-CLOCK WINDOW FOR THE TIMED FRAMES ONLY, so an external power
	# sampler can attribute watts to THIS configuration. Polling nvidia-smi
	# around the whole process would average import, scene build, warmup and
	# five configurations together and call the result "film" -- which is how
	# a power column gets published without measuring anything. Warmup is
	# outside the window on purpose: it contains shader compilation and an
	# idle clock ramp, and both move watts.
	var t0: float = Time.get_unix_time_from_system()
	var samples: Array[float] = []
	for i in range(frames):
		await RenderingServer.frame_post_draw
		samples.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	samples.sort()
	var n: int = samples.size()
	var total := 0.0
	for v in samples:
		total += v

	# SECTION 50'S OTHER COLUMNS, READ AT THE SAME INSTANT AS THE TIME.
	#
	# Sampled AFTER the timed frames, with this material still bound and its
	# textures still resident, because that is the only moment the figure means
	# "what this configuration costs". Read before the loop it would name the
	# previous material; read after the rect is restored it would name none.
	#
	# VIDEO_MEM_USED is the engine's own texture + buffer total, which is what
	# a project can actually control -- it is NOT the process's total VRAM
	# footprint, which includes the driver's own allocations and the swapchain
	# and is not visible from in here. The DIFFERENCE between configurations is
	# the honest figure and the absolute number is not; that is the same
	# discipline the frame-time columns already use.
	#
	# Static memory is Godot's own heap accounting, not RSS. Same rule: the
	# delta is the claim.
	var vram_tex: int = int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED))
	var vram_buf: int = int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_BUFFER_MEM_USED))
	var vram_all: int = int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))
	var draws: int = int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var t1: float = Time.get_unix_time_from_system()

	return {
		"frames": n,
		"mean_ms": total / float(n),
		"median_ms": samples[n / 2],
		"p95_ms": samples[int(float(n) * 0.95)],
		"p99_ms": samples[int(float(n) * 0.99)],
		"min_ms": samples[0],
		"max_ms": samples[n - 1],
		"vram_texture_bytes": vram_tex,
		"vram_buffer_bytes": vram_buf,
		"vram_total_bytes": vram_all,
		"draw_calls": draws,
		"static_mem_bytes": int(OS.get_static_memory_usage()),
		"static_mem_peak_bytes": int(OS.get_static_memory_peak_usage()),
		"t_start_unix": t0,
		"t_end_unix": t1,
	}


## Three configurations, because only the DIFFERENCE between them means
## anything. The absolute number is the cost of drawing one ColorRect on a
## trivial scene and says nothing about a level; `film - baseline` is what the
## TDD's section 41 budget is written against.
func _measure_cost(warmup: int, frames: int) -> Dictionary:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var film_mat := ShaderMaterial.new()
	film_mat.shader = load(FILM)
	film_mat.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(film_mat)
	film_mat.set_shader_parameter(&"film_grain_strength", 0.025)
	film_mat.set_shader_parameter(&"film_chroma_ratio", 0.10)
	film_mat.set_shader_parameter(&"film_grain_scale", 1.0)
	film_mat.set_shader_parameter(&"film_frame", 0)

	var base_mat := ShaderMaterial.new()
	base_mat.shader = load(BASE)
	_neutral(base_mat)
	base_mat.set_shader_parameter(&"grain_strength", 0.03)
	base_mat.set_shader_parameter(&"time_seed", 0.0)

	# Quantization costs nothing in the three above -- `_neutral` sets dither
	# strength to 0, so the whole block is branched over. Two more materials
	# with it ON, per-channel and shared, so the coherent path is priced too:
	# it is the part of this feature most likely to actually be used, and it
	# was the one part never timed.
	var q_per := ShaderMaterial.new()
	q_per.shader = load(FILM)
	q_per.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(q_per)
	q_per.set_shader_parameter(&"film_grain_strength", 0.025)
	q_per.set_shader_parameter(&"film_chroma_ratio", 0.10)
	q_per.set_shader_parameter(&"film_grain_scale", 1.0)
	q_per.set_shader_parameter(&"film_frame", 0)
	q_per.set_shader_parameter(&"strength", 0.3)
	q_per.set_shader_parameter(&"color_levels", 24)
	q_per.set_shader_parameter(&"dither_luma_scale", 3.0)
	q_per.set_shader_parameter(&"dither_chroma_coherence", 0.0)

	var q_shared := ShaderMaterial.new()
	q_shared.shader = load(FILM)
	q_shared.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(q_shared)
	q_shared.set_shader_parameter(&"film_grain_strength", 0.025)
	q_shared.set_shader_parameter(&"film_chroma_ratio", 0.10)
	q_shared.set_shader_parameter(&"film_grain_scale", 1.0)
	q_shared.set_shader_parameter(&"film_frame", 0)
	q_shared.set_shader_parameter(&"strength", 0.3)
	q_shared.set_shader_parameter(&"color_levels", 24)
	q_shared.set_shader_parameter(&"dither_luma_scale", 3.0)
	q_shared.set_shader_parameter(&"dither_chroma_coherence", 1.0)

	# --- THE BISECT ---------------------------------------------------------
	# Section 41 is OVER budget at 90 and 120 fps and NOBODY KNOWS WHY. The one
	# hypothesis offered -- the octave loop -- was built, measured, and bought
	# three microseconds. Guessing again is not a method, so this prices each
	# film term by REMOVING it from the shipped configuration one at a time.
	#
	# Every variant carries the shipped defaults except the single term named,
	# so `film_full - variant` is that term's cost and nothing else. Dither is
	# off in all of them, as it is in `baseline`, so the delta is the film block
	# alone rather than the whole pass.
	var bisect: Dictionary = {}
	if bool(ProjectSettings.get_setting("film_probe/bisect", false)):
		# The shipped configuration, so the ladder has a top.
		var full := _film_variant({})
		# The film block branched over entirely: strength 0 AND fog 0 is the
		# only way the guard is false. Whatever this costs above `baseline` is
		# the price of binding a second shader and deferring the grade's clamp,
		# before any film arithmetic runs at all.
		var off := _film_variant({&"film_grain_strength": 0.0,
			&"film_base_fog": 0.0})
		# Resolution lock: a textureSize plus a divide, per fragment.
		var nolock := _film_variant({&"film_grain_ref_width": 0.0})
		# The opponent-axis dye term.
		var nochroma := _film_variant({&"film_chroma_ratio": 0.0})
		# Base fog is 0.0 by default, so this prices what a preset that ASKS
		# for it pays -- the gate plus one luma and a smoothstep.
		var fog := _film_variant({&"film_base_fog": 0.006})
		# And what each additional crystal scale costs, now that the
		# single-octave case is a fast path around the loop.
		var oct2 := _film_variant({&"film_grain_octaves": 2})
		var oct3 := _film_variant({&"film_grain_octaves": 3})
		bisect = {
			"full": await _time_material(full, true, warmup, frames),
			"block_off": await _time_material(off, true, warmup, frames),
			"no_reslock": await _time_material(nolock, true, warmup, frames),
			"no_chroma": await _time_material(nochroma, true, warmup, frames),
			"with_fog": await _time_material(fog, true, warmup, frames),
			"octaves_2": await _time_material(oct2, true, warmup, frames),
			"octaves_3": await _time_material(oct3, true, warmup, frames),
		}

	var none: Dictionary = await _time_material(null, false, warmup, frames)
	var base: Dictionary = await _time_material(base_mat, true, warmup, frames)
	var film: Dictionary = await _time_material(film_mat, true, warmup, frames)
	var qp: Dictionary = await _time_material(q_per, true, warmup, frames)
	var qs: Dictionary = await _time_material(q_shared, true, warmup, frames)
	_post_rect.visible = true
	var out: Dictionary = {"no_post": none, "baseline": base, "film": film,
		"quant_perchannel": qp, "quant_shared": qs}
	if not bisect.is_empty():
		out["bisect"] = bisect
	return out


## One film material at the SHIPPED defaults, with the named overrides applied.
## Written as one function so a variant cannot accidentally differ from the
## others in some parameter nobody was looking at -- which is how a bisect
## turns into a set of unrelated measurements.
func _film_variant(overrides: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(FILM)
	m.set_shader_parameter(&"film_grain_tex", load(GRAIN))
	_neutral(m)
	var shipped: Dictionary = {
		&"film_grain_strength": 0.20,
		&"film_chroma_ratio": 0.10,
		&"film_grain_scale": 1.0,
		&"film_base_fog": 0.0,
		&"film_grain_ref_width": 2048.0,
		&"film_grain_octaves": 1,
		&"film_grain_lacunarity": 2.1,
		&"film_grain_persistence": 0.55,
		&"film_frame": 0,
	}
	for k: StringName in shipped:
		m.set_shader_parameter(k, overrides.get(k, shipped[k]))
	return m


## Named from the engine's own constants, never from a table in the driver.
## A hand-written {int: name} map in the Python side got this wrong once --
## it had 11 as RGBH when 11 is RGBAF and 14 is RGBH -- and reported llvmpipe's
## 32-bit float target as a 16-bit one. The engine is the only authority on its
## own enum, so the engine is asked.
func _format_name(f: int) -> String:
	match f:
		Image.FORMAT_RGB8:
			return "RGB8"
		Image.FORMAT_RGBA8:
			return "RGBA8"
		Image.FORMAT_RGBF:
			return "RGBF (32-bit float)"
		Image.FORMAT_RGBAF:
			return "RGBAF (32-bit float)"
		Image.FORMAT_RGBH:
			return "RGBH (16-bit float)"
		Image.FORMAT_RGBAH:
			return "RGBAH (16-bit float)"
		Image.FORMAT_RGBE9995:
			return "RGBE9995"
		_:
			return "format id %d" % f
