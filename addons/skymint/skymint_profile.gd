@tool
class_name SkyMintProfile
extends Resource

## Drives how light/dark the sky is across a 24h day.
## All curves/gradients are sampled with t in [0,1], where:
##   0.00 = midnight, 0.25 = sunrise (6h), 0.50 = noon (12h),
##   0.75 = sunset (18h), 1.00 = midnight again.
## A SkyMint node feeds time_of_day/24.0 into these.

# --- Colors over the day (Gradient) ---
@export var sky_tint : Gradient
@export var sun_color : Gradient
@export var light_color : Gradient        ## DirectionalLight3D color
@export var cloud_bright_color : Gradient
@export var cloud_mid_color : Gradient
@export var cloud_dark_color : Gradient

# --- Scalars over the day (Curve) ---
@export var sky_exposure : Curve
@export var cloud_brightness : Curve
@export var sun_intensity : Curve
@export var light_energy : Curve          ## DirectionalLight3D energy
@export var night_blend : Curve           ## 0 = day skybox, 1 = night skybox


func sample_color(g: Gradient, t: float) -> Color:
	return g.sample(t) if g else Color.WHITE


func sample_scalar(c: Curve, t: float, fallback: float) -> float:
	return c.sample(t) if c else fallback


# ----------------------------------------------------------------------
# A complete, good-looking default cycle built entirely in code.
# Used automatically when a SkyMint has no profile assigned.
# ----------------------------------------------------------------------
static func make_default() -> SkyMintProfile:
	var p := SkyMintProfile.new()

	# Times:  midnight  dawn      noon      dusk      midnight
	#  t:     0.00 0.22 0.27 0.33 0.50 0.67 0.73 0.78 1.00
	p.sky_tint = _grad([
		[0.00, Color(0.30, 0.38, 0.62)],   # cool night
		[0.24, Color(0.55, 0.45, 0.55)],   # pre-dawn
		[0.28, Color(1.05, 0.70, 0.55)],   # sunrise warm
		[0.40, Color(1.00, 0.97, 0.95)],   # morning
		[0.50, Color(1.00, 1.00, 1.00)],   # noon neutral
		[0.62, Color(1.00, 0.96, 0.92)],   # afternoon
		[0.72, Color(1.10, 0.66, 0.48)],   # sunset warm
		[0.80, Color(0.60, 0.42, 0.55)],   # post-dusk
		[1.00, Color(0.30, 0.38, 0.62)],
	])

	p.sun_color = _grad([
		[0.25, Color(1.0, 0.55, 0.35)],    # low sun = warm/red
		[0.38, Color(1.0, 0.85, 0.7)],
		[0.50, Color(1.0, 0.97, 0.9)],     # white-ish noon
		[0.62, Color(1.0, 0.85, 0.7)],
		[0.75, Color(1.0, 0.5, 0.32)],
	])

	p.light_color = _grad([
		[0.00, Color(0.45, 0.55, 0.85)],   # moonlight blue
		[0.27, Color(1.0, 0.6, 0.4)],      # warm dawn
		[0.50, Color(1.0, 0.97, 0.92)],    # white noon
		[0.73, Color(1.0, 0.55, 0.38)],    # warm dusk
		[1.00, Color(0.45, 0.55, 0.85)],
	])

	p.cloud_bright_color = _grad([
		[0.00, Color(0.40, 0.46, 0.62)],
		[0.27, Color(1.0, 0.85, 0.78)],
		[0.50, Color(1.0, 1.0, 1.0)],
		[0.73, Color(1.0, 0.82, 0.72)],
		[1.00, Color(0.40, 0.46, 0.62)],
	])
	p.cloud_mid_color = _grad([
		[0.00, Color(0.26, 0.30, 0.45)],
		[0.27, Color(0.85, 0.70, 0.68)],
		[0.50, Color(0.82, 0.84, 0.88)],
		[0.73, Color(0.85, 0.66, 0.60)],
		[1.00, Color(0.26, 0.30, 0.45)],
	])
	p.cloud_dark_color = _grad([
		[0.00, Color(0.12, 0.15, 0.26)],
		[0.27, Color(0.45, 0.36, 0.42)],
		[0.50, Color(0.50, 0.54, 0.62)],
		[0.73, Color(0.45, 0.34, 0.38)],
		[1.00, Color(0.12, 0.15, 0.26)],
	])

	# brightness of the whole sky/clouds (multiplier)
	p.sky_exposure = _curve(0.1, 1.6, [
		[0.00, 0.30], [0.22, 0.40], [0.30, 0.95],
		[0.50, 1.25], [0.70, 0.95], [0.80, 0.45], [1.00, 0.30],
	])
	p.cloud_brightness = _curve(0.0, 2.0, [
		[0.00, 0.45], [0.27, 1.0], [0.50, 1.25],
		[0.73, 1.0], [0.80, 0.55], [1.00, 0.45],
	])

	# sun disc / glow strength (0 below horizon)
	p.sun_intensity = _curve(0.0, 20.0, [
		[0.23, 0.0], [0.27, 6.0], [0.40, 12.0],
		[0.50, 15.0], [0.60, 12.0], [0.73, 6.0], [0.77, 0.0],
	])

	# directional light energy for the actual 3D scene
	p.light_energy = _curve(0.0, 1.4, [
		[0.00, 0.06], [0.23, 0.06], [0.30, 0.55],
		[0.50, 1.10], [0.70, 0.55], [0.78, 0.10], [1.00, 0.06],
	])

	# day skybox (0) -> night skybox (1)
	p.night_blend = _curve(0.0, 1.0, [
		[0.00, 1.0], [0.20, 1.0], [0.30, 0.0],
		[0.70, 0.0], [0.80, 1.0], [1.00, 1.0],
	])

	return p


static func _grad(stops: Array) -> Gradient:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s in stops:
		offs.append(s[0])
		cols.append(s[1])
	g.offsets = offs
	g.colors = cols
	return g


static func _curve(lo: float, hi: float, pts: Array) -> Curve:
	var c := Curve.new()
	c.min_value = lo
	c.max_value = hi
	for pt in pts:
		c.add_point(Vector2(pt[0], pt[1]))
	return c
