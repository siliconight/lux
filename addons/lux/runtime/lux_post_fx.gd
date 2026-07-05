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
		return

	var dither_on := preset.dither_enabled and quality.allow_dithering
	_mat.set_shader_parameter(&"strength", preset.dither_strength if dither_on else 0.0)
	_mat.set_shader_parameter(&"color_levels", preset.color_levels)
	_mat.set_shader_parameter(&"cell_size", preset.dither_cell_size)
	_mat.set_shader_parameter(&"distance_fade_enabled", preset.dither_distance_fade)
	_mat.set_shader_parameter(&"fade_start", preset.dither_fade_start)
	_mat.set_shader_parameter(&"fade_end", preset.dither_fade_end)

	_mat.set_shader_parameter(&"brightness", preset.brightness)
	_mat.set_shader_parameter(&"contrast", preset.contrast)
	_mat.set_shader_parameter(&"saturation", preset.saturation)
	_mat.set_shader_parameter(&"warmth", preset.warmth)

	_mat.set_shader_parameter(&"vignette_strength", preset.vignette_strength)
	_mat.set_shader_parameter(&"grain_strength", preset.grain_strength)

	var pal := preset.get_palette_or_neutral()
	_mat.set_shader_parameter(&"palette_influence", preset.palette_influence)
	_mat.set_shader_parameter(&"palette_shadow", Vector3(pal.shadow.r, pal.shadow.g, pal.shadow.b))
	_mat.set_shader_parameter(&"palette_mid", Vector3(pal.midtone.r, pal.midtone.g, pal.midtone.b))
	_mat.set_shader_parameter(
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
	if _mat != null:
		_mat.set_shader_parameter(&"cam_near", near)
		_mat.set_shader_parameter(&"cam_far", far)


## When true, the display is in HDR output (Godot 4.7) and the preset asked to
## let the retro grade follow it; when false (the default retro case), the post
## pass clamps to the SDR range so dithering/quantization read as authored.
func set_hdr_output(hdr_passthrough: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter(&"hdr_passthrough", hdr_passthrough)


func process(delta: float) -> void:
	if not _enabled or _mat == null:
		return
	_time += delta
	_mat.set_shader_parameter(&"time_seed", fmod(_time, 1000.0))
