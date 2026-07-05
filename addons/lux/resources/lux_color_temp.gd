@tool
class_name LuxColorTemp
extends Object
## Color-temperature helpers so light rigs use physically-grounded colors instead
## of eyeballed RGB. Kelvin values and the fluorescent green cast come from real
## light-source behavior (mercury-phosphor fluorescents sit ~3500-4100K with a
## slight green spike; high-pressure sodium ~2000K amber; mercury vapor ~4000-
## 5000K blue-green). Approximation uses the Tanner Helland piecewise fit, which
## is accurate enough for art direction across ~1000-40000K.
##
## Reference points baked in as named constants for the common Delco fixtures.

const SODIUM_VAPOR := 2000  # amber street/parking lot lamps
const INCANDESCENT := 2700  # warm household bulb
const HALOGEN := 3000
const WARM_FLUORESCENT := 3000  # "warm white" tube
const COOL_FLUORESCENT := 4100  # "cool white" convenience-store tube
const MERCURY_VAPOR := 5000  # blue-green industrial/warehouse
const DAYLIGHT := 6500
const OVERCAST := 7000


## Kelvin -> linear-ish RGB Color (values in 0..1, not gamma-corrected — fine for
## light_color which Godot treats as an sRGB multiplier).
static func kelvin(temp: float) -> Color:
	var t: float = clampf(temp, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float

	# Red
	if t <= 66.0:
		r = 255.0
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
	# Green
	if t <= 66.0:
		g = 99.4708025861 * log(t) - 161.1195681661
	else:
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	# Blue
	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307

	return Color(
		clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0, clampf(b, 0.0, 255.0) / 255.0
	)


## Cool-white fluorescents have a characteristic slight green cast from the
## mercury emission spike that a pure blackbody Kelvin value misses. This nudges
## a base color toward green by `amount` (0..1) to reproduce that convenience-
## store / office tint.
static func add_fluorescent_cast(base: Color, amount: float = 0.06) -> Color:
	return Color(
		clampf(base.r * (1.0 - amount * 0.5), 0.0, 1.0),
		clampf(base.g * (1.0 + amount), 0.0, 1.0),
		clampf(base.b * (1.0 - amount * 0.5), 0.0, 1.0),
		base.a
	)


## Convenience: the exact tint for a standard cool-white fluorescent tube.
static func cool_fluorescent() -> Color:
	return add_fluorescent_cast(kelvin(COOL_FLUORESCENT), 0.07)


static func warm_fluorescent() -> Color:
	return add_fluorescent_cast(kelvin(WARM_FLUORESCENT), 0.04)
