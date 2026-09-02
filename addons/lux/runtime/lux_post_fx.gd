@tool
class_name LuxPostFX
extends Node
## Full-screen post pass: ordered dithering, quantization, grade, palette zones,
## vignette, and grain (TDD §13). Implemented as a CanvasLayer + ColorRect that
## samples the world via BackBufferCopy/screen texture. UI is excluded by keeping
## this layer below UI layers and only sampling the 3D backbuffer.
##
## NOTE: A production build often routes the world through a SubViewport so the
## quantization sees only 3D. For MVP simplicity and drop-in behavior, Lux uses
## a screen-reading canvas pass placed on a low CanvasLayer; UI drawn on higher
## layers is untouched. See docs/getting_started.md for the SubViewport variant.

const DITHER_SHADER := preload("res://addons/lux/shaders/post/lux_ordered_dither.gdshader")
const CRT_SHADER := preload("res://addons/lux/shaders/post/lux_crt_mask.gdshader")
## Film emulsion runs as a SEPARATE shader rather than a branch, so the
## baseline path pays nothing for it (TDD section 35/36). See the film
## shader's own header for why.
const FILM_SHADER := preload("res://addons/lux/shaders/post/lux_ordered_dither_film.gdshader")
const FILM_GRAIN_TEX := preload("res://addons/lux/resources/film/grain_balanced.png")

## LuxPreset.grain_mode
enum GrainMode { OFF = 0, SIMPLE = 1, FILM_EMULSION = 2 }

var layer: CanvasLayer
var rect: ColorRect
var back_buffer: BackBufferCopy
var _mat: ShaderMaterial

# Second pass: CRT mask, stacked above the dither pass on the same low layer so
# it samples the already-dithered/graded image and stays off the UI.
var crt_back_buffer: BackBufferCopy
var crt_rect: ColorRect
var _crt_mat: ShaderMaterial

var _enabled: bool = true
var _time: float = 0.0

# --- Film emulsion state (TDD section 25) ---
# The material for the film variant is built alongside the baseline one so a
# toggle never allocates. Note that Godot compiles a shader on its first DRAW,
# not on material creation, so "precompiled" in section 35 is only true here in
# the common case where film is decided at level load. A mid-play toggle can
# still cost one compile; a warm-up draw would close that and is not built.
var _film_mat: ShaderMaterial
## Master switch pushed down from LuxRoot -- the third of the three keys.
var _film_master: bool = true
## All three keys agreed AND the preset asked for the film grain mode.
var _film_active: bool = false
var _film_frame: int = 0
var _film_accumulator: float = 0.0
var _film_grain_fps: float = 24.0


func ensure_pass(parent: Node) -> void:
	if layer != null and is_instance_valid(layer):
		return
	layer = CanvasLayer.new()
	layer.name = &"LuxPostFX"
	layer.layer = -1  # below default UI (layer 0+), so HUD stays crisp
	parent.add_child(layer)

	back_buffer = BackBufferCopy.new()
	back_buffer.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	layer.add_child(back_buffer)

	rect = ColorRect.new()
	rect.name = &"LuxPostRect"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = DITHER_SHADER
	_film_mat = ShaderMaterial.new()
	_film_mat.shader = FILM_SHADER
	_film_mat.set_shader_parameter(&"film_grain_tex", FILM_GRAIN_TEX)
	rect.material = _mat
	# Screen texture is fed via hint in the shader through the backbuffer.
	rect.color = Color(0, 0, 0, 0)
	layer.add_child(rect)

	if Engine.is_editor_hint() and parent.get_tree() != null:
		var root := parent.get_tree().edited_scene_root
		layer.owner = root
		back_buffer.owner = root
		rect.owner = root
	# The dither shader binds Godot's screen/depth textures via hint_screen_texture
	# and hint_depth_texture, so no manual ViewportTexture wiring is needed here.

	# --- Second pass: CRT mask ---
	# A fresh BackBufferCopy captures the dither pass's output, then a second
	# ColorRect applies the phosphor mask on top. Both live under the same low
	# CanvasLayer, so UI on layer >= 0 is still untouched.
	crt_back_buffer = BackBufferCopy.new()
	crt_back_buffer.name = &"LuxCRTBackBuffer"
	crt_back_buffer.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	layer.add_child(crt_back_buffer)

	crt_rect = ColorRect.new()
	crt_rect.name = &"LuxCRTRect"
	crt_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	crt_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crt_mat = ShaderMaterial.new()
	_crt_mat.shader = CRT_SHADER
	crt_rect.material = _crt_mat
	crt_rect.color = Color(0, 0, 0, 0)
	layer.add_child(crt_rect)

	if Engine.is_editor_hint() and parent.get_tree() != null:
		var root2 := parent.get_tree().edited_scene_root
		crt_back_buffer.owner = root2
		crt_rect.owner = root2


func apply(preset: LuxPreset, quality: LuxQualityProfile) -> void:
	if preset == null or _mat == null:
		return
	var post_on := quality.allow_post_fx
	_enabled = post_on
	if layer != null:
		layer.visible = post_on
	if not post_on:
		# Clear film state on the way out. Leaving it set means a preset that
		# was running film before the tier dropped to one with no post FX keeps
		# ticking the film frame against an invisible layer -- section 36 wants
		# zero film-frame updates when film is not running, and "the layer is
		# hidden" is not the same as "the feature is off".
		_film_active = false
		return

	# --- Which of the two post shaders runs -------------------------------
	# TDD section 10's three-key AND, literally. `grain_mode` is NOT a fourth
	# key: the keys decide whether film is PERMITTED, and grain_mode is how the
	# preset chooses among what is permitted. A preset that asks for film grain
	# on a tier that refuses it falls back to Simple, which is section 54 --
	# a feature that cannot run leaves the render alone rather than blanking it.
	var film_permitted := (
		_film_master
		and preset.film_emulsion_enabled
		and quality.allow_film_emulsion
	)
	_film_active = film_permitted and preset.grain_mode == GrainMode.FILM_EMULSION
	var mat: ShaderMaterial = _film_mat if _film_active else _mat
	if rect != null and rect.material != mat:
		rect.material = mat
	_film_grain_fps = maxf(preset.film_grain_fps, 1.0)

	var dither_on := preset.dither_enabled and quality.allow_dithering
	mat.set_shader_parameter(&"strength", preset.dither_strength if dither_on else 0.0)
	mat.set_shader_parameter(&"color_levels", preset.color_levels)
	mat.set_shader_parameter(&"cell_size", preset.dither_cell_size)
	mat.set_shader_parameter(&"distance_fade_enabled", preset.dither_distance_fade)
	mat.set_shader_parameter(&"fade_start", preset.dither_fade_start)
	mat.set_shader_parameter(&"fade_end", preset.dither_fade_end)

	mat.set_shader_parameter(&"brightness", preset.brightness)
	mat.set_shader_parameter(&"contrast", preset.contrast)
	mat.set_shader_parameter(&"saturation", preset.saturation)
	mat.set_shader_parameter(&"warmth", preset.warmth)

	mat.set_shader_parameter(&"vignette_strength", preset.vignette_strength)

	if _film_active:
		# Section 11: never Simple and Film at once. The film shader has no
		# Simple grain to disable -- it simply does not contain the code.
		mat.set_shader_parameter(&"film_grain_strength", preset.film_grain_strength)
		mat.set_shader_parameter(&"film_chroma_ratio", preset.film_chroma_ratio)
		mat.set_shader_parameter(&"film_grain_scale", preset.film_grain_scale)
		mat.set_shader_parameter(&"film_frame", _film_frame)
		# The rainbow the whole feature is aimed at lives in the quantization,
		# not the grain, so these ride with film rather than with the dither
		# group -- the baseline shader has neither uniform.
		mat.set_shader_parameter(
			&"dither_chroma_coherence", preset.dither_chroma_coherence)
		mat.set_shader_parameter(&"dither_luma_scale", preset.dither_luma_scale)
	else:
		# EXACTLY AS BEFORE, and deliberately so. `grain_mode` selects among what
		# the FILM path offers and has no vote here -- letting it gate the
		# legacy grain would make a film property change the render of a scene
		# that never asked for film, and the point of this feature is that it is
		# entirely optional. Anyone wanting no grain on this path sets
		# `grain_strength` to 0, which has always worked.
		mat.set_shader_parameter(&"grain_strength", preset.grain_strength)

	var pal := preset.get_palette_or_neutral()
	mat.set_shader_parameter(&"palette_influence", preset.palette_influence)
	mat.set_shader_parameter(&"palette_shadow", Vector3(pal.shadow.r, pal.shadow.g, pal.shadow.b))
	mat.set_shader_parameter(&"palette_mid", Vector3(pal.midtone.r, pal.midtone.g, pal.midtone.b))
	mat.set_shader_parameter(
		&"palette_highlight", Vector3(pal.highlight.r, pal.highlight.g, pal.highlight.b)
	)

	# --- CRT mask second pass ---
	if _crt_mat != null:
		var crt_on := preset.crt_mask_type > 0 and preset.crt_mask_strength > 0.0
		# mask_type: preset 1=Aperture Grille -> shader 1; 2=Shadow Mask -> shader 2
		_crt_mat.set_shader_parameter(&"mask_type", preset.crt_mask_type if crt_on else 0)
		_crt_mat.set_shader_parameter(&"mask_strength", preset.crt_mask_strength if crt_on else 0.0)
		_crt_mat.set_shader_parameter(&"mask_scale", preset.crt_mask_scale)
		_crt_mat.set_shader_parameter(&"scanline_strength", preset.scanline_strength)
		if crt_rect != null:
			crt_rect.visible = crt_on or preset.scanline_strength > 0.0
		if crt_back_buffer != null:
			crt_back_buffer.visible = crt_on or preset.scanline_strength > 0.0


func set_camera_planes(near: float, far: float) -> void:
	# Both materials, not just the active one. These are called outside apply(),
	# so setting only the live material leaves the other stale and the staleness
	# surfaces as a one-frame pop the moment film is toggled.
	for m: ShaderMaterial in [_mat, _film_mat]:
		if m != null:
			m.set_shader_parameter(&"cam_near", near)
			m.set_shader_parameter(&"cam_far", far)


## When true, the display is in HDR output (Godot 4.7) and the preset asked to
## let the retro grade follow it; when false (the default retro case), the post
## pass clamps to the SDR range so dithering/quantization read as authored.
func set_hdr_output(hdr_passthrough: bool) -> void:
	for m: ShaderMaterial in [_mat, _film_mat]:
		if m != null:
			m.set_shader_parameter(&"hdr_passthrough", hdr_passthrough)


## The third key (TDD section 14). Pushed down from LuxRoot; takes effect on the
## next apply(). Returns true when the value actually changed, so the caller can
## avoid a redundant re-apply.
func set_film_emulsion_master_enabled(enabled: bool) -> bool:
	if _film_master == enabled:
		return false
	_film_master = enabled
	return true


func is_film_active() -> bool:
	return _film_active


func process(delta: float) -> void:
	if not _enabled or _mat == null:
		return
	if _film_active:
		# Section 24: grain advances at a photographic cadence, NOT once per
		# rendered frame. At 120 fps and 24 grain fps that is one uniform write
		# every fifth frame instead of five.
		#
		# Section 36 is why this is inside the branch rather than guarded by a
		# strength test: with film off there must be zero film-frame updates.
		_film_accumulator += delta
		var interval: float = 1.0 / maxf(_film_grain_fps, 1.0)
		if _film_accumulator >= interval:
			_film_accumulator = fmod(_film_accumulator, interval)
			_film_frame += 1
			if _film_mat != null:
				_film_mat.set_shader_parameter(&"film_frame", _film_frame)
		return
	_time += delta
	_mat.set_shader_parameter(&"time_seed", fmod(_time, 1000.0))
