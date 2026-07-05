@tool
class_name LuxRole
extends Object
## One-call PS2 material setup by object role. Each role returns a pre-tuned
## LuxMaterialProfile that picks a sensible vertex-lighting path and quality for
## that kind of object, so a developer says "this is a level / character / gun"
## instead of hand-dialing a dozen sliders.
##
## Roles and why they're tuned the way they are (goal: authentic PS2 look with
## multiplayer-friendly cost):
##   LEVEL      — bulk static world geo. Cheapest path (native vertex shading),
##                subtle jitter/affine. This is most of the scene, so it must be
##                the lightest.
##   CHARACTER  — animated, must read clearly. Native vertex shading, no jitter
##                (looks broken on skinned meshes), a touch more banding/rim.
##   GUN        — first-person viewmodel, always close and always on screen. Can
##                afford the Lux stylized Gouraud path for nicer banding/palette;
##                zero jitter (a wobbling gun reads as a bug up close).
##   PROP       — small, numerous, mid-distance. Native vertex shading, tolerates
##                more jitter/affine for authenticity; lowest quality priority.
##   UI_UNLIT   — decals/screens that shouldn't be lit. Full-bright, no vertex
##                lighting.

enum Role { LEVEL, CHARACTER, GUN, PROP, UI_UNLIT }

# Vertex path this role wants, matching LuxPreset.vertex_shading_mode:
#   1 = Native Engine (StandardMaterial3D per-vertex; cheapest, multi-light+shadow)
#   2 = Lux Stylized Gouraud (Lux shader path; nicer, key-light only)
#   0 = per-pixel / unlit


static func role_from_name(name: String) -> int:
	match name.to_lower():
		"level", "world", "environment", "map":
			return Role.LEVEL
		"character", "char", "player", "npc", "enemy":
			return Role.CHARACTER
		"gun", "weapon", "viewmodel", "fp", "firstperson":
			return Role.GUN
		"prop", "item", "pickup", "decoration":
			return Role.PROP
		"ui", "unlit", "decal", "screen":
			return Role.UI_UNLIT
		_:
			return Role.PROP


## Which vertex-lighting path a role uses. 1 = Native Engine, 2 = Lux Stylized
## Gouraud, 0 = per-pixel/unlit. Native is the cheap multi-light path; Stylized is
## reserved for the gun because only one is ever on screen.
static func vertex_mode_for(role: int) -> int:
	match role:
		Role.LEVEL, Role.CHARACTER, Role.PROP:
			return 1
		Role.GUN:
			return 2
		_:
			return 0


## Builds a pre-tuned LuxMaterialProfile for a role.
static func make_profile(role: int) -> LuxMaterialProfile:
	var p := LuxMaterialProfile.new()
	match role:
		Role.LEVEL:
			p.profile_name = &"Level"
			p.band_count = 3.0
			p.band_softness = 0.1
			p.shade_min = 0.2
			p.specular_strength = 0.1
			p.rim_strength = 0.06
			p.palette_influence = 0.3
			p.affine_amount = 0.35
			p.vertex_snap_enabled = false
			# Native path: engine lights this per-vertex; ps2_lighting (shader) off.
			p.ps2_lighting = 0.0
			p.mach_band_emphasis = 0.4
		Role.CHARACTER:
			p.profile_name = &"Character"
			p.band_count = 4.0
			p.band_softness = 0.08
			p.shade_min = 0.24
			p.specular_strength = 0.2
			p.rim_strength = 0.18
			p.palette_influence = 0.2
			p.affine_amount = 0.0  # skinned meshes: no affine warp
			p.vertex_snap_enabled = false
			p.ps2_lighting = 0.0
			p.mach_band_emphasis = 0.25
		Role.GUN:
			p.profile_name = &"Gun"
			p.band_count = 4.0
			p.band_softness = 0.06
			p.shade_min = 0.22
			p.specular_strength = 0.35
			p.specular_shininess = 40.0
			p.rim_strength = 0.22
			p.palette_influence = 0.15
			p.affine_amount = 0.0  # close-up: no wobble
			p.vertex_snap_enabled = false
			# Stylized Gouraud on the viewmodel — nicer banding, only one on screen.
			p.ps2_lighting = 1.0
			p.mach_band_emphasis = 0.5
		Role.PROP:
			p.profile_name = &"Prop"
			p.band_count = 3.0
			p.band_softness = 0.12
			p.shade_min = 0.2
			p.specular_strength = 0.15
			p.rim_strength = 0.1
			p.palette_influence = 0.3
			p.affine_amount = 0.5
			p.vertex_snap_enabled = true
			p.vertex_snap_resolution = 200.0
			p.ps2_lighting = 0.0
			p.mach_band_emphasis = 0.35
		Role.UI_UNLIT:
			p.profile_name = &"Unlit"
			p.band_count = 1.0
			p.band_softness = 0.0
			p.shade_min = 1.0  # full-bright
			p.specular_strength = 0.0
			p.rim_strength = 0.0
			p.palette_influence = 0.0
			p.affine_amount = 0.0
			p.vertex_snap_enabled = false
			p.ps2_lighting = 0.0
			p.mach_band_emphasis = 0.0
	return p


static func role_name(role: int) -> String:
	return ["Level", "Character", "Gun", "Prop", "Unlit"][clampi(role, 0, 4)]
