@tool
class_name LuxLightLoader
extends RefCounted
## Bakes a Deli Counter `<name>.lights.json` into the open scene: one Lux rig per
## light anchor, placed at the anchor. Deli Counter emits in Blender Z-up space;
## Godot imports the level GLB as Y-up, so anchor coordinates are converted to
## match (see _place). The rigs self-register with a LuxRoot when one is present,
## so presets and the alarm pulse drive them.
##
## Editor-time tool -- driven by the Lux dock's "Bake Lights" section.
##
## The anchor `type` maps 1:1 onto a Lux rig:
##   fluorescent -> LuxFluorescentRig   window / sign -> LuxAreaLightRig
##   streetlight -> LuxStreetlightRig    wall_pack    -> LuxStreetlightRig (x1)
##   sun -> handled by the preset. Zoo's fixture pass (--fixtures) bakes the
##   matching HARDWARE at the same anchors; LuxEmissiveBinder ties its lit
##   faces to set_fixtures_powered.
##   club_wash / neon -> LuxFluorescentRig in a coloured costume (0.37.0)
##   canopy_wash -> LuxStreetlightRig, mercury vapour, a few under a fuel
##                  canopy; `canopy_lights` is hardware and gets NO light
##                  (DC light manifest v1.3, 0.41.0)
##   stage_light      -> LuxStageLightRig      room_ambient -> ReflectionProbe
##   (the club set: see CLUB_PALETTE and _club_rig below)
##
## TWO CALLERS, TWO CONTAINERS. `bake` is the editor's: everything in the
## manifest under `LuxLights`. `bake_daylight` is the pipeline's (0.30.0,
## roadmap 96): only the anchors that have NO hardware and therefore no
## `LuxEmit_*` marker for LuxFixtureSpawner to find -- `window` today --
## under `LuxDaylight`, beside the spawner's `LuxFixtureLights`. Before it,
## Deli Counter derived a window anchor per opening, Lot merged them, the
## manifest shipped them, and no built level ever turned one into light: the
## only caller of `bake` was the dock button.
##
## A THIRD CONTAINER FOR THE ROOMS (0.38.0). `bake_room_ambient` derives one
## interior ReflectionProbe per room from the ceiling anchors' `room` and
## `room_box_local`, under `LuxRoomAmbient`. It is the pipeline's default,
## beside the daylight bake, and `bake` runs it too. See ROOM_BOX_FIELD.

const CONTAINER := "LuxLights"
const DAYLIGHT_CONTAINER := "LuxDaylight"
const ROOM_AMBIENT_CONTAINER := "LuxRoomAmbient"

## THE FIELD A ROOM'S BOX ARRIVES IN, and why it is relative (0.38.0).
## Deli Counter writes it on every ceiling anchor that names a `room`:
##
##     "room_box_local": [x0, y0, z0, x1, y1, z1]
##
## metres, RELATIVE TO THE ANCHOR'S `pos`, in the anchor's own frame -- x
## along `rot_y` (the row), y across it, z up (Deli Counter's Z-up axes) --
## z0 the room's floor and z1 the underside of the slab that caps it. So a
## fluorescent row's box has z0 = -drop and z1 = +0.1 (the ceiling gap it
## hangs by); a pendant's z1 is its cord plus the gap.
##
## Relative, not world, because of what Lot does to a building manifest:
## `merge_lights` transforms `pos` and `rot_y` by the building's placement
## and copies EVERY other field verbatim (`wa = dict(a)`). A world box would
## ship in building-local coordinates on a site whose buildings are turned
## 180 degrees, and a reader would place every probe in the wrong room with
## no error. A box that rides on the anchor's frame is placed by the same
## two numbers Lot already transforms, so it needs no Lot change and cannot
## drift from the lamp it belongs to. (The 0.37.0 `stage_light` `target` has
## exactly the world-frame problem this avoids; it is noted, not fixed here.)
##
## Absent on an anchor: that room gets no derived probe, and the bake counts
## it (`without_box`) rather than guessing a box from the row -- a row's
## count and spacing say how LONG a room is and nothing about how wide.
const ROOM_BOX_FIELD := "room_box_local"

## A DERIVED probe's ambient: neutral and low. The environment's ambient in
## Heavy Rain is (0.5, 0.52, 0.55) at energy 1.0 -- roughly ten times what one
## fluorescent lamp puts on the floor beneath it (office_floor_value, 0.057
## at 3.2 m), which is why every interior read as lit by the sky and not by
## its fixtures. Inside a probe, with the preset's `room_probes_replace_ambient`
## on, this replaces that ambient entirely. MEASURED on the walk of cold run
## 9054 (Heavy Rain, RTX 2060, 1600 x 900, GL Compatibility, sun shadowed,
## fog on; tools/club_walk_probe.py, whole-frame luma of the 8-bit frame at
## five interior stations, `ambient_color_energy` set on all 16 probes):
##
##     energy   spawn  vault  office  lobby  antechamber      p05 (lobby)
##     0.00       4.8   20.1    17.6   21.1     18.2           0  (crushed)
##     0.04      20.5   33.9    37.8   31.4     36.5           6
##     0.08      32.3   44.9    52.0   39.3     49.3           8
##     (sky, contribution 0.5, the 0.37.0 room)
##               34.0   46.0    53.5   40.1     50.7           8
##
## 0.08 hands back what the sky was giving through the roof; 0.0 crushes
## the far floor to black. 0.04 is a floor under the fixtures so an unlit
## corner is dark grey rather than a hole, and no more.
const ROOM_AMBIENT_DERIVED_COLOR := Color(1.0, 1.0, 1.0)
const ROOM_AMBIENT_DERIVED_ENERGY := 0.04

## The anchor types daylight owns. `sun` is the preset's and is never baked
## here; `window` is the one with no hardware and no marker.
const DAYLIGHT_TYPES: Array[String] = ["window"]

## A WINDOW'S CONE, AND WHY IT IS EXACTLY 45 (0.40.0). Not a taste: the
## opening's head cuts everything above horizontal and the wall under the
## sill cuts everything behind, so what a vertical opening passes is a
## quarter of the sphere. A cone is symmetric about its axis, so an upper rim
## on the horizon and a lower rim straight down fix BOTH the half-angle and
## the pitch at 45 degrees with nothing left to choose. See the window branch
## of `_rig_for` and LuxAreaLightRig.cone_angle_deg.
const WINDOW_CONE_HALF_ANGLE_DEG := 45.0

const CLUB_CONTAINER := "LuxClub"

## The club set (0.37.0). They reach a level only through a manifest bake --
## `bake_club` below -- and that stays true in 0.40.0 even though two of them
## now HAVE hardware. Zoo 0.94.0 builds a recessed can at every `club_wash`
## and a par can at every `stage_light`, and deliberately emits NO
## `LuxEmit_*` marker for either, because the marker path hands
## `rig_for_anchor` only {type, id, drop}: a club_wash would lose the zone
## colour and the pool radius Deli Counter measured and take a hash pick
## instead, and a stage_light would lose its `target` and be refused
## outright. Hardware from the fixture pass, light from the manifest bake,
## both at the same anchor -- so they co-locate by construction. Moving the
## club set onto markers means widening the marker payload first; until then
## a marker here would DOUBLE every club light.
## 0.39.0 adds `back_bar`: the warm practical inside a club's back bar, the
## bulbs behind its glass shelves and the lit porthole in its centre bay
## (Zoo 0.92.0's `back_bar`). It is the club set's only WARM light and the
## only one that is a lamp somebody could point at rather than a wash.
const CLUB_TYPES: Array[String] = ["club_wash", "stage_light", "neon", "room_ambient",
	"back_bar"]

## THE CLUB TYPES A ZOO FIXTURE BAKE BUILDS HARDWARE FOR (0.40.0), named
## here so a caller that wants to check "is there a lamp where this light
## comes from" does not have to guess the list -- Level Factory's lux_apply
## driver reads it off this script exactly as it reads CLUB_TYPES, and says
## it could not evaluate when an older Lux has no such constant.
##
## The other three are not omissions and must not be added: a `neon` IS its
## sign and `sign_box` builds it, a `back_bar` is the bar's own bulbs and
## porthole, and a `room_ambient` is a ReflectionProbe with nothing to hang.
## The pairing lives in Zoo's `core.fixtures.FIXTURES` (0.94.0), where these
## two are the rows marked `marker: False`; if that file and this line
## disagree, that file is the one that builds geometry.
const CLUB_HARDWARE_TYPES: Array[String] = ["club_wash", "stage_light"]

## EVERY TYPE THE MANIFEST BAKE OWNS, which is no longer only the club's.
##
## `bake_club` was named for the only thing it did. What it actually is, and
## always was, is "build these types from the WHOLE anchor instead of from a
## marker" -- it calls the same `_rig_for` the marker path does, and the only
## club-specific thing about it is the container's name.
##
## A type belongs here when its rig needs a field the marker payload does not
## carry. `LuxFixtureSpawner` hands `rig_for_anchor` only {type, id, drop}, so
## a `club_wash` would lose its zone colour and pool radius, a `stage_light`
## its target, and a `canopy_wash` the POOL Deli Counter sized for it -- which
## is the whole of its range derivation.
##
## `CLUB_TYPES` is deliberately left alone rather than renamed: Level Factory
## reads that symbol by name, and a rename whose reader has no fallback is
## exactly how cold run 9081 shipped a forecourt with no light in it.
##
## `storefront_spill` (0.57.0) for the same reason as the canopy wash: its
## level is derived from the ROOM's row (`drop`, `reach`) and its throw from
## `head`, and none of the three is in the marker payload. It has no
## hardware either -- the light is the store's.
const MANIFEST_BAKE_TYPES: Array[String] = ["club_wash", "stage_light", "neon",
	"room_ambient", "back_bar", "canopy_wash", "streetlight", "storefront_spill"]
## What Zoo names the meshes it builds for them. A prefix, because Blender
## dedupes repeats (`.001`) and Godot's importer swaps the dot for an
## underscore -- the same reason `LuxFixtureSpawner` matches markers by
## prefix.
const CLUB_HARDWARE_PREFIX := "ClubFixture"

## THE CLUB PALETTE, and its names are a contract: Deli Counter writes them
## into an anchor's `color`. Saturated on purpose -- the walker's references
## (GTA IV's Triangle Club) are a room lit almost entirely by coloured light,
## with next to no white in it. Values are `light_color`, which Godot treats
## as an sRGB multiplier, each with its largest channel at 1.0 so that
## `energy` means the same thing for every colour. NOT luminance-matched: a
## blue pool at the same energy reads darker than an amber one, which is what
## the references show too.
const CLUB_PALETTE := {
	"magenta": Color(1.0, 0.0, 0.8),
	"hot_pink": Color(1.0, 0.12, 0.5),
	"red": Color(1.0, 0.04, 0.06),
	"violet": Color(0.55, 0.1, 1.0),
	"blue": Color(0.1, 0.2, 1.0),
	"cyan": Color(0.0, 0.8, 1.0),
	"amber": Color(1.0, 0.55, 0.08),
	# 0.39.0: a 1997 tungsten bulb, and the one entry here that is not a
	# saturated colour -- it is the light a bar's own lamps make, matched to
	# the emissive colour Zoo paints on the back bar's bulbs
	# (`back_bar_forms.BULB_COLOUR`, linear (1.0, 0.72, 0.42)) so the glow
	# and the spill are the same light. NOT IN `CLUB_COLOR_ORDER`, and that
	# is deliberate: the order is the sequence a colourless anchor is
	# hashed into, and appending to it moves every derived pick in every
	# club already shipped. A palette entry outside the order is reachable
	# by NAME and by nothing else, which is what a practical wants.
	"tungsten": Color(1.0, 0.72, 0.42),
}
## The order a colour is picked in when an anchor names none. Appending keeps
## every existing pick where it was only if the list length does not change,
## so it does not: a new colour moves every derived pick. Say so if you add one.
const CLUB_COLOR_ORDER: Array[String] = ["magenta", "hot_pink", "red", "violet",
	"blue", "cyan", "amber"]

## A storey's drop when an anchor carries none: the 3.2 m ceiling Deli Counter
## writes for the strip clubs, less the 0.2 m slab gap. Only a fallback.
const CLUB_DEFAULT_DROP := 3.0

## HOW BRIGHT, AS A MULTIPLE OF THE OFFICE THE CLUB REPLACES. Every club
## energy below is solved from the falloff Godot applies (measured against
## this closed form under GL Compatibility, 4.7, RTX 2060: an omni and an
## 89-degree spot at 2.95 m over a matte floor, R 5.0, attenuation 2 and 1,
## 13 radii each, within 2% at every lit sample):
##
##     value(d) = energy * (1 - (d / R)^4)^2 / d^attenuation * cos(incidence)
##
## so that a club light puts LEVEL x what ONE fluorescent lamp from this
## loader puts on the floor straight below it at the same drop
## (`office_floor_value`). A number of that kind holds when the drop, the
## pool radius or the throw moves; a flat energy does not.
##
## The levels themselves are a LOOK, set against frames of a scratch copy of
## the vault_surface walk: country club_a01's grand lounge, 17 x 40 m, lamps
## at 3.39 m over a dark purple carpet, Heavy Rain, GL Compatibility, RTX
## 2060, the room's five fluorescents replaced by five washes, a two-spot
## stage light and two neons. RETRACTED FIRST GUESS, kept: the wash level was
## 1.0 -- "the office's own floor value, in colour" -- and in those frames it
## was invisible. Hiding every club light moved mean luma 57.8 -> 57.7;
## scaling the washes x4 and x8 at runtime moved it 49.0 -> 49.3 and 49.5, and chroma
## >= 40 stayed at 0.0% of the frame. The office row it replaced was just as
## invisible on that carpet: the room was lit by the environment (sky
## ambient, the unshadowed preset sun, fog), not by its fixtures. With the sun
## shadowed and fog off, washes read as coloured pools on the carpet and walls at x12
## (0.6% of the frame >= 40 chroma looking down the room, 1.3% at the stage)
## and the stage and neons already read at 3 and 1.5. So the wash level is
## 12. It is tuned to a dark floor; on a light one it will be loud.
## A FUEL CANOPY'S WASH (DC light manifest v1.3). PROVISIONAL, and said so
## rather than presented as derived: nobody has walked a lit forecourt yet.
## What sets it is that the canopy's emissive lamp grid carries the APPARENT
## brightness -- a player looking up sees lit fixtures whatever this is -- so
## the wash only has to put a believable pool on the tarmac. Judge it on a
## walk and write the measured value here.
## THE ONE POOL IN THIS FILE ANYBODY HAS TUNED AND WALKED, and therefore the
## unit the two outdoor levels below are written in.
##
## A `club_wash` on a 3.2 m ceiling delivers `CLUB_WASH_LEVEL *
## office_floor_value(3.2)` = 12.0 * 0.0570 = 0.684 on the floor. Every level
## constant in this file except the two below passes a value already
## multiplied by `office_floor_value`, which is what the comment on that
## function means by "the unit every club level is in".
##
## THE TWO BELOW DID NOT, AND THAT IS WHY A FORECOURT BLEW OUT. Written as raw
## 10.0 and 5.0, they delivered 15x and 7x a tuned club wash -- measured on
## cold run 9084 as saturated sodium discs on black ground, the walker: "so
## dark now". Neither number was ever judged against anything; they were
## invented.
##
## So both are now multiples of the tuned one, and the multiples are the only
## thing invented: a forecourt under a lit deck is brighter than a club floor,
## an open road is darker than one. Two ratios to argue with instead of two
## magnitudes to guess at.
const REFERENCE_POOL := 0.684

## A forecourt under a lit canopy: four and a half club floors (0.61.0).
##
## WALKED AND MEASURED, which the paragraph above asked for. 1.5 was the
## provisional ratio; on cold run 9125's walk copy, with Deli Counter 0.167.0's
## washes over the lanes, the four canopy washes' baked energies were scaled
## by k and fixed forecourt stations re-shot (k = 1 twice, the control,
## identical to the decimal). Median luminance of 255:
##
##     k   level   the pad under the deck   a pump's lane face   pad clipped
##     1   1.5            10.7                    23.0               0.03%
##     2   3.0            42.9                    44.2               0.05%
##     3   4.5            53.8                    54.4               0.05%
##     4   6.0            62.5                    57.7               0.06%
##
## At 1.5 the pad read black and the walk found the forecourt dark; the first
## doubling is most of the gain and the returns shrink after it; nothing
## clipped at any of them -- far under the raw 10.0 that blew out (15x a club
## wash). The walker chose k = 3 from the frames, 2026-10-01. Energy only:
## the range is the geometry's (`canopy_wash` below), so no light reaches any
## further and the light count is unchanged.
const CANOPY_WASH_LEVEL := REFERENCE_POOL * 4.5
## A STREETLIGHT'S POOL ON THE ROAD, in the same unit as the canopy above so
## the two are comparable at a glance. Half, because an open road is not a
## forecourt under a lit deck -- a ratio, not an independent number, so there
## is one value to tune and the relationship survives tuning it.
##
## It replaces a flat `energy = 6.0`, which delivered 0.156 at a 6 m pole
## against the canopy's 10.0 -- 64x darker, which nobody chose. PROVISIONAL
## like the canopy's: judge the pair on a walk and write the measured values in.
## An open road under sodium: three quarters of a club floor, half the
## forecourt. It replaces a flat `energy = 6.0` that delivered 0.156 -- and
## then, briefly, a raw 5.0 that delivered thirty times that.
const STREETLIGHT_LEVEL := REFERENCE_POOL * 0.75
## The pool one wash owns when the anchor names none, metres. DC always sends
## `size`; this is the floor under a hand-authored anchor.
const CANOPY_POOL_FALLBACK := 6.0
## A canopy wash reaches no further than this however big its deck is. An
## outdoor spot that overreaches claims a per-mesh light-budget slot on tiles
## it barely lights, which is the same law the wall pack was trimmed to 5.5
## for and the fluorescent before it.
const CANOPY_RANGE_MAX := 12.0

## THE STOREFRONT SPILL (0.57.0). The walker, 2026-09-29: "do the outward
## spill next" -- the lit store throwing its light out through the glass onto
## the pavement, the fourth lever in docs/proposals/INTERIOR_EXTERIOR_
## BALANCE.md. The rule: the pavement just outside the glass reads as the lit
## floor inside it does, less the glass.
##
## What clear float glass passes (Zoo 1.20.0's storefront, 1 - 0.12).
const SPILL_GLASS_T := 0.88
## THE ONE MEASURED NUMBER, and why the rule above could not be met without
## it. The physical reading -- the floor under a sales-floor lamp, less the
## glass, 0.378 at Delco Night -- was stood outside gas_station_a02 on cold
## run 9104's walk copy and did not register at all: the pavement in front of
## the glass read luma 0.8 with it and without it. The room's floor is lifted
## by its reflection probe's ambient and a carpet's albedo; the pavement has
## neither, and the night grade crushes its toe. So the level was matched in
## FRAMES: pavement luma against the carpet seen through the same glass
## (20.0, so 17.6 wanted), over three lamps at x1 / x5 / x10 / x20 the
## physical level -- 0.8 / 8.8 / 21.9 / 44.0, linear above the toe -- which
## crosses 17.6 at x8.4. Measured at Delco Night, on delco_1997's forecourt
## pad, with the room probes of Lux 0.56.0: when any of the three moves, so
## does this, and the frame match is the thing to repeat.
const SPILL_FRAME_MATCH := 8.4
## The source's height over the pavement when an anchor names none: the top
## of Zoo's storefront glass (`arch.SF_GLASS_TOP`).
const SPILL_HEAD_FALLBACK := 3.0

const CLUB_WASH_LEVEL := 12.0
## THE STAGE IS WHERE A CLUB'S LIGHT GOES (0.69.0, roadmap 213). *As first
## set:* 3, which read on the grand-lounge tuning frames above. In cold run
## 9204's club it read as a dim platform, baked or live -- a stage lit at a
## quarter of the room's own wash pools. The walker, 2026-10-08: "Stage can
## be brighter". Live frames of that stage at 4x, 8x and 10x the old level
## (`docs/findings/club_stage_live_price/` at the factory root):
##   4x (12) -- lit, but no brighter than the room;
##   8x (24) -- the brightest thing in the room, the pole lit, no clipping;
##   10x (30) -- hardly different from 8x, the tonemapper's shoulder.
## So 24, twice the wash: chosen against frames, not derived.
const CLUB_STAGE_LEVEL := 24.0
const CLUB_NEON_LEVEL := 1.5
## The back bar's practical, priced the same way. Between the neon's spill
## (1.5) and the stage's throw (3.0): it has to put a bartender's face and
## the bottles in front of it above the room's own darkness -- the club
## rooms it stands in are lit at CLUB_WASH_LEVEL in POOLS with dark between
## them -- without becoming a second room light. Set against frames of the
## 9059 walk; see the 0.39.0 changelog for the numbers.
const CLUB_BACKBAR_LEVEL := 2.5
## How far past the lit face a back bar's spill has to reach: the working
## aisle, so a body in it is lit. Deli Counter writes the aisle it measured
## on the anchor (`aisle`); this is the fallback when it does not.
const BACKBAR_AISLE := 1.25
## ...and the window the range is held to. The lower bound is a body's
## depth in the aisle; the upper is the neon's 2.5 plus the deepest aisle
## Deli Counter's rule can produce, so a back bar never lights a room.
const BACKBAR_RANGE := Vector2(1.5, 4.0)
## HOW MANY SOURCES A BACK BAR'S LIT FACE GETS, AND WHY NOT ONE (0.40.0).
## A back bar is metres of luminous shelving, and 0.39.0 stood ONE omni in
## for all of it at the middle of that face -- which is a point where an area
## belongs, and the near field says so. MEASURED on the walk of cold run 9060
## (Heavy Rain, GL Compatibility, RTX 2060; anchor `b0/back_bar_..._niche`,
## energy 4.711, range 3.826 as baked), with the closed form above:
##
##   surface                         d (m)   value   x the shelves
##   the niche's own lit disc         0.596   13.25       6.6
##   the shelf front                  1.0      4.62       2.3
##   the bottles / design point       1.91     1.13       1.0
##
## and in frames at the walker's station 4.0 m out, the disc's 0.74 m face
## came back at mean luma 200.8 with 1.57% of it pinned at 250+ and a
## channel maximum of 255 -- white, not tungsten. Killing the omni alone took
## the same face to 121.5 with nothing above 239, so the omni owned the
## clipping and the disc's own emission owned the rest (Zoo 0.94.0 has that
## half).
##
## So the row: one source per SQUARE of the lit face, `round(width / lit
## height)`, at a pitch of `width / count`, and the per-lamp energy solved so
## the ROW's value at half the range on the face's normal is still
## CLUB_BACKBAR_LEVEL x the office unit -- the design point does not move,
## only the hot spot. Held to this cap because every lamp is a real
## per-mesh light in the renderer's budget; 6 covers a 7.4 m bar at a
## 1.24 m lit height and nothing Deli Counter emits is wider.
const BACKBAR_LAMP_CAP := 6
## A room_ambient probe's ambient energy on its palette colour.
const ROOM_AMBIENT_ENERGY := 0.05
## How far a room_ambient probe's box stands proud of `size` on every side.
## MEASURED (GL Compatibility, a 10 x 3 x 10 m room of six planes, flat grey
## ambient, a black interior probe): a box exactly the room's size left the
## walls at the full environment ambient (RGB sum 317 of 317), the ceiling at
## 278 and the floor at 104 -- the faces ON the boundary fall outside it. Any
## margin from 0.05 m up took all three to 0, and blend_distance 1.0 or 0.1
## changed nothing. 0.1 is twice the smallest margin that worked.
const ROOM_AMBIENT_MARGIN := 0.1
## A wash's floor pool radius when the anchor carries none, per metre of drop.
const CLUB_WASH_RADIUS_PER_DROP := 1.25

## The fluorescent branch's energy and hang, named so the club rigs price
## themselves against the lamp that is actually built rather than a copy.
const FLUORESCENT_ENERGY := 1.0
## The counter accent's level, in troffers (0.60.0). THE WALKER'S CALL FROM
## THE FRAME, 2026-09-29: the register counter at night, full scale, at 0x /
## 1x / 2x / 3x (cold run 9113, `counter_accent_0x_1x_2x_3x.png`; counter
## red 55 / 59 / 61 / 64) -- "2x". At 1x the warm band was easy to miss,
## at 3x it read as a spotlight. One light either way: the level is free.
const COUNTER_ACCENT_LEVEL := 2.0
## THE HEAT LAMP (0.63.0). The walker, 2026-10-03, on the roller grill at
## night: "a dim but warm warming light to bring a bit more light to the
## dogs". Zoo 1.57.0 hangs an infrared element under the grill's hood and
## emits `LuxEmit_heat_lamp` just below it; this is its lamp. An OMNI, not
## a downlight: the rod hangs under the hood's top above the bun shelf,
## and the buns under it and the dogs through the glass shelf both get it
## (the walker, on the first cut: "light should show the buns too"). A
## fraction of a fluorescent -- a glow, not a room light -- in a reach that
## ends at the hood. 1,900 K: an infrared element glows red-orange, redder
## than any bulb. Not preset scaled: it is its own source and does not
## brighten with the wash.
##
## MEASURED on the rebuilt gas station lot, the grill shot from the
## customer's side, the pan's three columns' luminance left / middle /
## right. First with the rod 16 cm over the dogs, a downlight (the first
## cut), then with the rod under the hood's top, 36 cm over the dogs and
## 12 over the buns, an omni (this one):
##
##     under the shelf, level 0.35, falloff 2      blown out: the dogs white
##     under the shelf, level 0.035, falloff 2     0.106 / 0.216 / 0.084
##     under the shelf, level 0.035, falloff 1     0.095 / 0.131 / 0.080
##     under the hood,  level 0.08,  falloff 1     0.096 / 0.136 / 0.079
##     under the hood,  level 0.16,  falloff 1     0.100 / 0.154 / 0.077
##     under the hood,  level 0.16,  falloff 0.6   0.115 / 0.140 / 0.084
##     under the hood,  level 0.24,  falloff 0.6   0.109 / 0.162 / 0.090
##     off                                         0.089 / 0.104 / 0.072
##
## A third of a troffer at a hand's width is a floodlight. Under the hood,
## 0.16 with the falloff flattened to 0.6 is the evenest: the outer columns
## up a quarter, the middle a third, the buns under the rod warmed, and
## nothing white. The walker's eye sets it from here.
const HEAT_LAMP_LEVEL := 0.16
const HEAT_LAMP_RANGE_M := 0.9
const HEAT_LAMP_KELVIN := 1900.0
const HEAT_LAMP_ATTENUATION := 0.6
const FLUORESCENT_MOUNT := -0.25

## A BARE BULB'S LAMP HANGS UNDER ITS GLASS (0.67.0). A pendant's anchor is
## the BULB point, and Zoo's `pendant_fixture` mounts 'above' it: the bulb is
## an ellipsoid whose centre sits one radius over the anchor, stretched 1.15x
## upright, so its glass reaches 0.15 of a radius BELOW the anchor -- 6 to
## 12 mm over the genome's 0.08-0.16 m bulbs. The lamp hung AT the anchor
## sat inside that closed glass. Real time draws an unshadowed lamp straight
## through it, so nobody saw; the lightmapper ray-traces, and every steady
## bulb baked to nothing -- the pole's disease (0.65.0), one fixture down.
## A counter accent wears the same hardware and had the same lamp.
##
## Measured on cold run 9190's restaurant row, re-baked by Level Factory's
## own bake with only the 33 bulb lamps moved, one station a room
## (`docs/findings/night_interiors/`): the eight bulb-lit rooms' mean luma
## 3.8 -> 9.6 of 255, cold storage 0.8 -> 15.1, the deli counter room
## 6.6 -> 12.4. The sixteen fluorescent rooms 15.5 -> 15.7, all of it the
## customer floor (12.8 -> 15.1), whose register has the counter accent.
##
## DERIVED: the widest bulb's reach under its anchor, 0.15 x 0.08 = 0.012,
## plus the centimetre the pole's lamp keeps under its lens
## (`LuxStreetlightRig.POLE_LAMP_DROP_M`). Zoo owns the first number: a
## wider bulb or a longer stretch moves it.
const BULB_LAMP_DROP_M := 0.022


## Bake ONLY the daylight anchors of `path` under a `LuxDaylight` container,
## leaving whatever the marker path spawned alone. Returns {ok, msg, count,
## in_manifest} -- `in_manifest` is how many daylight anchors the file
## carried, so a caller can tell "none asked for" from "none made".
static func bake_daylight(path: String, scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "no scene root", "count": 0, "in_manifest": 0}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path, "count": 0,
			"in_manifest": 0}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors').",
			"count": 0, "in_manifest": 0}
	var old := scene_root.get_node_or_null(NodePath(DAYLIGHT_CONTAINER))
	if old != null:
		old.free()
	var container := Node3D.new()
	container.name = DAYLIGHT_CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root
	var made := 0
	var in_manifest := 0
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		if not DAYLIGHT_TYPES.has(String(a.get("type", ""))):
			continue
		in_manifest += 1
		var node := _rig_for(a)
		if node == null:
			continue
		container.add_child(node)
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1
	return {"ok": true, "count": made, "in_manifest": in_manifest,
		"msg": "Baked %d daylight rig(s) from %d window anchor(s)" % [made, in_manifest]}


## Bake ONLY the club anchors of `path` (CLUB_TYPES) under a `LuxClub`
## container, the same shape as `bake_daylight`: nothing else is touched, and
## the result says how many the file asked for. `refused` lists the ids the
## tuning table would not build -- an unknown colour name, a stage light with
## no target -- so a caller can tell a typo from an empty manifest. A caller
## that packs the scene must re-own the container's children, as Level
## Factory's driver already does for `LuxDaylight`.
static func bake_club(path: String, scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "no scene root", "count": 0, "in_manifest": 0,
			"refused": []}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path, "count": 0,
			"in_manifest": 0, "refused": []}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors').",
			"count": 0, "in_manifest": 0, "refused": []}
	var old := scene_root.get_node_or_null(NodePath(CLUB_CONTAINER))
	if old != null:
		old.free()
	var container := Node3D.new()
	container.name = CLUB_CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root
	var made := 0
	var in_manifest := 0
	var refused: Array = []
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		if not MANIFEST_BAKE_TYPES.has(String(a.get("type", ""))):
			continue
		in_manifest += 1
		var node := _rig_for(a)
		if node == null:
			refused.append(String(a.get("id", "?")))
			continue
		container.add_child(node)
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1
	var msg := "Baked %d club rig(s) from %d club anchor(s)" % [made, in_manifest]
	if not refused.is_empty():
		msg += "; refused %s" % ", ".join(refused)
	return {"ok": refused.is_empty(), "count": made, "in_manifest": in_manifest,
		"refused": refused, "msg": msg}


## ONE INTERIOR PROBE PER ROOM, DERIVED (0.38.0). Every room the manifest's
## ceiling anchors name gets a ReflectionProbe the size of its
## `room_box_local` plus ROOM_AMBIENT_MARGIN a side, under `LuxRoomAmbient`,
## the shape of `bake_daylight`. Inside the box the probe's flat, low ambient
## replaces the environment's -- ALL of it when the preset sets
## `room_probes_replace_ambient` (which writes ambient_light_sky_contribution
## 1.0; the share replaced IS the contribution, measured in 0.37.0), and the
## sky's share otherwise. That, sun shadows and fog are what decide whether a
## room reads dark: the probe owns exactly one of the three.
##
## A room whose anchors carry no box is SKIPPED AND COUNTED (`without_box`),
## never guessed. A room that also has an explicit `room_ambient` anchor (the
## club set) is left to `bake_club` (`explicit`). Two runs of one room's row
## (`<room>_ceiling_0`, `_1`) are one room and one probe: the first anchor by
## id supplies the box, and the two agree by construction because each is
## relative to its own lamp. Returns {ok, count, rooms, without_box,
## explicit, msg}; `rooms` is how many distinct rooms the anchors named, so a
## caller can tell "none asked for" from "none made".
static func bake_room_ambient(path: String, scene_root: Node) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "no scene root", "count": 0, "rooms": 0,
			"without_box": [], "explicit": []}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path, "count": 0,
			"rooms": 0, "without_box": [], "explicit": []}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors').",
			"count": 0, "rooms": 0, "without_box": [], "explicit": []}
	var plan: Dictionary = room_probe_plan(data["anchors"])
	var old := scene_root.get_node_or_null(NodePath(ROOM_AMBIENT_CONTAINER))
	if old != null:
		old.free()
	var container := Node3D.new()
	container.name = ROOM_AMBIENT_CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root
	var made := 0
	var boxed: Dictionary = plan["boxed"]
	var ids: Array = boxed.keys()
	ids.sort()
	for room in ids:
		var probe: ReflectionProbe = room_probe_for(boxed[room])
		if probe == null:
			continue
		container.add_child(probe)
		probe.owner = scene_root
		made += 1
	var without: Array = plan["without_box"]
	var explicit: Array = plan["explicit"]
	var msg := "Baked %d room probe(s) for %d room(s)" % [made, int(plan["rooms"])]
	if not without.is_empty():
		msg += "; %d without %s: %s" % [without.size(), ROOM_BOX_FIELD, ", ".join(without)]
	if not explicit.is_empty():
		msg += "; %d left to an explicit room_ambient: %s" % [explicit.size(), ", ".join(explicit)]
	return {"ok": true, "count": made, "rooms": int(plan["rooms"]),
		"without_box": without, "explicit": explicit, "msg": msg}


## The rooms of an anchor list, sorted into what can be baked. Pure, so a
## test can ask it about a dictionary rather than a file. Returns
## {rooms: int, boxed: {room: anchor}, without_box: [room], explicit: [room]}.
static func room_probe_plan(anchors: Array) -> Dictionary:
	var explicit_rooms := {}
	for a in anchors:
		if typeof(a) == TYPE_DICTIONARY and String(a.get("type", "")) == "room_ambient" \
				and typeof(a.get("room")) == TYPE_STRING:
			explicit_rooms[String(a.get("room"))] = true
	var boxed := {}
	var seen := {}
	var unboxed := {}
	var sorted: Array = []
	for a in anchors:
		if typeof(a) == TYPE_DICTIONARY and typeof(a.get("room")) == TYPE_STRING \
				and String(a.get("type", "")) != "room_ambient":
			sorted.append(a)
	# By id, so "the first anchor supplies the box" is the same anchor in
	# every build rather than whichever the file listed first.
	sorted.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return String(x.get("id", "")) < String(y.get("id", "")))
	for a in sorted:
		var room := String(a.get("room"))
		seen[room] = true
		if explicit_rooms.has(room) or boxed.has(room):
			continue
		if _room_box_ok(a.get(ROOM_BOX_FIELD)):
			boxed[room] = a
		else:
			unboxed[room] = true
	var without: Array = []
	for room in unboxed:
		if not boxed.has(room) and not explicit_rooms.has(room):
			without.append(room)
	without.sort()
	var explicit: Array = []
	for room in seen:
		if explicit_rooms.has(room):
			explicit.append(room)
	explicit.sort()
	return {"rooms": seen.size(), "boxed": boxed, "without_box": without,
		"explicit": explicit}


static func _room_box_ok(b: Variant) -> bool:
	if typeof(b) != TYPE_ARRAY or (b as Array).size() < 6:
		return false
	for v in b:
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			return false
	return float(b[3]) > float(b[0]) and float(b[4]) > float(b[1]) and float(b[5]) > float(b[2])


## The probe for one boxed anchor, PLACED: its transform is the anchor's
## (`pos`, `rot_y`, the same swap and yaw as _place) carried onto the box's
## centre, so a box that is off-centre from its lamp -- a split run, a row
## nudged off a partition -- still lands on the room. Named after the room,
## with the "/" Lot's namespacing puts in a room id made a "_": a "/" in a
## node name is a path separator and Godot renames the node.
##
## Frames: the box is Deli Counter Z-up in the anchor's frame, (x along the
## row, y across, z up). Godot local is (x, z, -y) -- the swap `_godot_point`
## applies to every anchor coordinate -- and rotation.y = rot_y turns local
## +X onto the row's world direction, exactly as it does for the lamps the
## row rig lays along local +X (see _place). The box's own x axis follows.
static func room_probe_for(a: Dictionary) -> ReflectionProbe:
	var b: Variant = a.get(ROOM_BOX_FIELD)
	if not _room_box_ok(b):
		return null
	var lo := Vector3(float(b[0]), float(b[1]), float(b[2]))
	var hi := Vector3(float(b[3]), float(b[4]), float(b[5]))
	var centre_dc := (lo + hi) * 0.5
	var size_dc := hi - lo
	var yaw := deg_to_rad(float(a.get("rot_y", 0.0)))
	var probe := ReflectionProbe.new()
	probe.name = String(a.get("room", a.get("id", "room"))).replace("/", "_")
	probe.size = Vector3(size_dc.x, size_dc.z, size_dc.y) + Vector3.ONE * 2.0 * ROOM_AMBIENT_MARGIN
	probe.interior = true
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = ROOM_AMBIENT_DERIVED_COLOR
	probe.ambient_color_energy = ROOM_AMBIENT_DERIVED_ENERGY
	probe.blend_distance = 0.1
	var anchor_pos := _godot_point(a.get("pos"))
	var local_centre := Vector3(centre_dc.x, centre_dc.z, -centre_dc.y)
	probe.position = anchor_pos + Basis(Vector3.UP, yaw) * local_centre
	probe.rotation = Vector3(0.0, yaw, 0.0)
	return probe


## THE ROOMS' FLOOR, IN THE BAKE (0.68.0). A lightmapped surface takes its
## light from the lightmap alone, so once Level Factory baked (0.131.0, on by
## default since 0.144.0) a room probe's ambient -- the floor
## ROOM_AMBIENT_DERIVED_ENERGY was put there to be -- reached no wall and no
## floor: raised five-fold on cold run 9190's level it moved nothing, and a
## corner no lamp reaches baked to black. The bake is baked with the
## environment off, which is right for a sealed room and leaves it nothing.
##
## `add_bake_fills` puts the floor back as light that exists only while the
## lightmapper runs: static omnis over every UNTINTED room probe (a tinted
## probe is a club room, dark by design -- the walker's dens of sin), which a
## bake lays before it bakes and frees before it saves, so a level carries no
## fill at runtime: nothing to draw, nothing to price. Dynamic objects see it
## through the lightmap's own probes.
##
## OWNED, AND THE BAKE MUST FREE IT (0.68.1). 0.68.0 left the fill unowned "so
## even a save that forgot to free it cannot keep it". LightmapGI skips any
## child with no owner when it collects lights ("maybe a helper", Godot's
## `_find_meshes_and_lights`), so the first real bake -- Level Factory
## 0.151.0's, 267 fills laid on cold run 9190's level -- baked none: every
## room read the control's number. The experiments that chose the layout
## had written their fills into the bake scene, owned, which is why they lit.
## Every fill is owned by the scene's owner now, and freeing it before the
## save is the bake's job.
##
## FOUR LAYOUTS WERE BAKED ON THAT LEVEL; THE FIRST THREE ARE KEPT HERE AS
## REFUTATIONS. Mean luma of 255, 16 fluorescent rooms / 8 bulb-lit rooms:
##
##     no floor                                     15.7   9.6   85 s
##     1 fill a room, centre, 2.3 m, 0.08           32.9  19.4   86 s
##     6 m cells, 1.7 m, 0.08 a room split          32.0  28.1  172 s
##     8 m cells, the same, bulb rooms half         32.0  18.7  132 s
##     6 m cells, 1.7 m, 0.025 each, 9 m, half      39.1  22.8   94 s
##
## (the last column is the bake's time in the editor). The centre fill hung
## a quarter of the storey over the middle -- 2.3 m, where a bare bulb hangs,
## at the room's centre, where a row's middle bulb hangs: deli_a01's deli
## counter fill stood exactly on its centre bulb's anchor, inside the glass,
## and four rooms did not move. A room's energy split between its cells, each
## reaching the whole room, left a big room dark: a floor point is lit by the
## fills near it, so the split falls as 1/size (the office lobby, 34 x 12 m,
## 10.0). A fixed energy a fill, each reaching 1.5 cells and flat inside it,
## lights a floor the same whatever the room's size -- about 1.3x under a
## fill against the point between four -- and bakes nearly as fast as none.
const BAKE_FILL_CONTAINER := "LuxBakeFill"
## A person's head height over the room's floor: under every ceiling fixture
## (a bulb hangs 0.6 m under a 3.2 m storey's ceiling, a tube 0.25 under its
## lens). A low room takes 0.6 of its height instead.
const BAKE_FILL_HEIGHT_M := 1.7
## One fill per cell this wide at most, the room's cells equal.
const BAKE_FILL_CELL_M := 6.0
## Each fill reaches this many cells, flat inside it (attenuation 0).
const BAKE_FILL_REACH_CELLS := 1.5
## DENS OF SIN ARE BUILDINGS, NOT ROOMS (0.68.2). The walker, 2026-10-07: "the
## 'dens of sin' buildings that we can keep a bit dark". 0.68.0 skipped only
## the tinted probe -- a strip club's floor -- and filled the rest of the
## building: on club_block_014 at night strip_club_a02's back rooms went
## 19.5 -> 52.3, the brightest room in the level, while its floor stayed 2.8.
## A building with ANY tinted probe now keeps every room unfilled.
## `_probe_building` says which building a probe is in.
##
## A room a bare bulb lights keeps this share of the floor: "keep pendants
## moody" (the walker, 2026-09-28). 22.8 against the fluorescent rooms'
## 39.1 on the level above.
const BAKE_FILL_BULB_SHARE := 0.5


## Lay the bake-only room fills under `scene_root` and return their
## container, or null when nothing asks for one. Clears an earlier call's
## fill first, always. `energy` is each fill's; negative reads the scene's
## LuxRoot preset (`bake_fill_energy`). For a light bake to call before it
## bakes and to free before it saves; `scene_root` must be in the tree.
static func add_bake_fills(scene_root: Node, energy: float = -1.0) -> Node3D:
	if scene_root == null or not scene_root.is_inside_tree():
		return null
	var old := scene_root.get_node_or_null(NodePath(BAKE_FILL_CONTAINER))
	if old != null:
		old.free()
	if energy < 0.0:
		energy = bake_fill_energy(scene_root)
	if energy <= 0.0:
		return null
	# the rooms a bare bulb lights, by where their rigs hang
	var bulbs: Array[Vector3] = []
	for n in scene_root.find_children("*", "Node3D", true, false):
		if n is LuxFluorescentRig and (n as LuxFluorescentRig).rig != null \
				and String((n as LuxFluorescentRig).rig.rig_name).begins_with("Bare Bulb"):
			bulbs.append((n as Node3D).global_position)
	# owned, or LightmapGI passes the fill by as a helper (0.68.1)
	var owner_node: Node = scene_root if scene_root.owner == null else scene_root.owner
	# the room probes, and the buildings any tinted one makes a den
	var probes: Array[ReflectionProbe] = []
	var dens := {}
	for n in scene_root.find_children("*", "ReflectionProbe", true, false):
		var rp := n as ReflectionProbe
		if not rp.interior or rp.ambient_mode != ReflectionProbe.AMBIENT_COLOR:
			continue
		probes.append(rp)
		if not rp.ambient_color.is_equal_approx(ROOM_AMBIENT_DERIVED_COLOR):
			dens[_probe_building(rp)] = true
	var container: Node3D = null
	for p in probes:
		if not p.ambient_color.is_equal_approx(ROOM_AMBIENT_DERIVED_COLOR) \
				or dens.has(_probe_building(p)):
			continue
		var room := p.size - Vector3.ONE * 2.0 * ROOM_AMBIENT_MARGIN
		if room.x <= 0.0 or room.y <= 0.0 or room.z <= 0.0:
			continue
		var xf := p.global_transform
		var inv := xf.affine_inverse()
		var share := 1.0
		for b in bulbs:
			var l: Vector3 = inv * b
			if absf(l.x) <= p.size.x * 0.5 and absf(l.y) <= p.size.y * 0.5 \
					and absf(l.z) <= p.size.z * 0.5:
				share = BAKE_FILL_BULB_SHARE
				break
		var nx := maxi(1, ceili(room.x / BAKE_FILL_CELL_M))
		var nz := maxi(1, ceili(room.z / BAKE_FILL_CELL_M))
		var y := -room.y * 0.5 + minf(BAKE_FILL_HEIGHT_M, room.y * 0.6)
		if container == null:
			container = Node3D.new()
			container.name = BAKE_FILL_CONTAINER
			scene_root.add_child(container)
			container.owner = owner_node
		for i in nx:
			for k in nz:
				var local := Vector3(room.x * ((i + 0.5) / float(nx) - 0.5), y,
					room.z * ((k + 0.5) / float(nz) - 0.5))
				var omni := OmniLight3D.new()
				omni.name = "%s_%d" % [String(p.name), i * nz + k]
				omni.light_energy = energy * share
				omni.light_bake_mode = Light3D.BAKE_STATIC
				omni.omni_range = BAKE_FILL_REACH_CELLS * BAKE_FILL_CELL_M
				omni.omni_attenuation = 0.0
				container.add_child(omni)
				omni.owner = owner_node
				omni.global_position = xf * local
	return container


## The site building a room probe stands in. Lot's `merge_lights` ids every
## anchor `<building>/<id>` (lot.py) and a probe is named after its anchor's
## room with "/" made "_", so `b2_banking_hall_ambient` is building b2. A
## name without that prefix is a building of its own.
static func _probe_building(p: ReflectionProbe) -> String:
	var m := RegEx.create_from_string("^(b[0-9]+)_").search(String(p.name))
	return m.get_string(1) if m != null else "probe:" + String(p.name)


## The `bake_room_fill` of the preset the scene's LuxRoot starts with (its
## `local_override`, else its `active_preset`), or 0.0 when the scene has no
## LuxRoot or its preset predates the field (0.68.0).
static func bake_fill_energy(scene_root: Node) -> float:
	if scene_root == null or not scene_root.is_inside_tree():
		return 0.0
	for n in scene_root.get_tree().get_nodes_in_group(&"lux_root"):
		if n != scene_root and not scene_root.is_ancestor_of(n):
			continue
		var preset: Variant = n.get("local_override")
		if preset == null:
			preset = n.get("active_preset")
		if preset is Resource and "bake_room_fill" in preset:
			return float(preset.get("bake_room_fill"))
	return 0.0


## Read `path`, replace any previous bake, and spawn a rig per anchor under a
## `LuxLights` container. Returns {ok, msg, count}.
##
## `lightmap_static` (pc2000 family): spawn every rig with Light3D bake mode
## STATIC and flicker off, ready for a LightmapGI bake. Lightmapped surfaces
## then ignore these lights' realtime contribution (no double-lighting) while
## dynamic objects still receive them live. NOTE: after a bake, edits to rig
## energy/colour need a RE-BAKE to show on lightmapped geometry.
static func bake(path: String, scene_root: Node, lightmap_static: bool = false) -> Dictionary:
	if scene_root == null:
		return {"ok": false, "msg": "Open a scene first."}
	if not FileAccess.file_exists(path):
		return {"ok": false, "msg": "File not found: %s" % path}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("anchors"):
		return {"ok": false, "msg": "Not a .lights.json (no 'anchors')."}

	clear(scene_root)
	var container := Node3D.new()
	container.name = CONTAINER
	scene_root.add_child(container)
	container.owner = scene_root

	var made := 0
	var skipped := 0
	for a in data["anchors"]:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var node := _rig_for(a)
		if node == null:
			skipped += 1
			continue
		if lightmap_static:
			_make_lightmap_static(node)
		container.add_child(node)          # _ready builds the lights here
		node.owner = scene_root
		_reown(node, scene_root)
		_place(node, a)
		made += 1

	# The rooms' probes ride with the editor bake too (0.38.0), in their own
	# container, so the dock and the pipeline produce the same level.
	var rooms: Dictionary = bake_room_ambient(path, scene_root)

	var has_root := not scene_root.get_tree().get_nodes_in_group(
		&"lux_root").is_empty()
	var msg := "Baked %d light rig(s)" % made
	if lightmap_static:
		msg += " [lightmap static]"
	if skipped > 0:
		msg += " (%d unsupported skipped)" % skipped
	msg += "; " + String(rooms.get("msg", ""))
	if not has_root:
		msg += ". No LuxRoot in the scene -- add one so presets drive these."
	return {"ok": true, "msg": msg, "count": made,
		"room_probes": int(rooms.get("count", 0))}


## The rig for an anchor dict — the one tuning table for both paths: the
## manifest bake above and LuxFixtureSpawner's marker path (v0.15). An
## anchor without a `row` is a single lamp. Returns null for daylight /
## unknown types.
static func rig_for_anchor(a: Dictionary) -> Node3D:
	return _rig_for(a)


## Remove a previous bake (the LuxLights container and the room probes that
## `bake` made beside it). Returns how many containers went.
static func clear(scene_root: Node) -> int:
	if scene_root == null:
		return 0
	var gone := 0
	for cname in [CONTAINER, ROOM_AMBIENT_CONTAINER]:
		var n := scene_root.get_node_or_null(NodePath(cname))
		if n != null:
			n.free()
			gone += 1
	return gone


static func _rig_for(a: Dictionary) -> Node3D:
	var t := String(a.get("type", ""))
	var row: Dictionary = {}
	if typeof(a.get("row")) == TYPE_DICTIONARY:
		row = a.get("row")
	match t:
		"fluorescent":
			var f := LuxFluorescentRig.new()
			f.name = String(a.get("id", "fluorescent"))
			var r := LuxLightRig.new()
			r.rig_name = &"Fluorescent (baked)"
			r.light_color = LuxColorTemp.cool_fluorescent()
			r.energy = FLUORESCENT_ENERGY   # per-light; rooms pack 5+ so they sum — 2.2
			                        # each blew interiors to white. Tune per bake.
			# RANGE IS DERIVED FROM THE ANCHOR'S DROP TO ITS FLOOR
			# (deli_counter >= 0.97 stamps `drop`), because a flat number was
			# wrong at both ends inside one day. At a flat 8.0 the engine
			# bound every lamp to every MESH within range THROUGH WALLS --
			# each mesh renders at most `max_lights_per_object` of its
			# claimants, the worst ceiling tile had 23 for 8 slots, adjacent
			# tiles bound DIFFERENT winning sets, and the walk at the engine
			# default showed the difference as a hard-edged brightness grid
			# (roadmap 54). At a flat 4.5 the arena's ~5.7 m hall had a lit
			# ceiling over a PITCH-BLACK floor: attenuation reaches hard zero
			# at the range, so no energy value lights a floor the range does
			# not reach. drop + 1.5 lit every floor, and census #6 (the
			# first with `drop` alive end to end, 2026-08-24) priced it: 14
			# ceiling plates at 9-10 claimants for 8 slots. Plates are where
			# lamps HANG, so every lamp within range claims a slot on them,
			# the next room's included -- walls are not part of the engine's
			# binding question. Census #7's margin forensics then priced
			# the next cut exactly: at drop + 1.0 the b0 slab tiles'
			# excess claimants bound with 0.17 m to spare, so a 0.25 m trim
			# sheds them. drop + 0.75 still floors a
			# sqrt(1.5 * drop + 0.5625) m pool under each lamp (arena
			# 3.0 m against the 2.83 m a 4 m grid diagonal needs, office
			# 2.4 m against 2.0 m rows), and the clamp keeps low rooms at
			# the short trim and stops tall halls from re-claiming the
			# whole per-mesh budget. The margins the same census measured
			# on b1's tiles (0.44+) and the 52 m parapet (1.59) are NOT
			# payable in range -- those are geometry work, not tuning. If
			# interiors read too dark BETWEEN fixtures, raise `energy`,
			# never this.
			#
			# EXCEPT TOWARD A STOREFRONT (0.56.0), where the floor the row
			# must light is not under it: Deli Counter (>= 0.155.0) stamps
			# `reach`, the horizontal metres from the row to the storefront
			# glass it faces, and the range is derived to the floor THERE
			# (see `fluorescent_range`). Only such a row carries it; every
			# other lamp is the rule above, unchanged.
			var drop := float(a.get("drop", 0.0))
			r.light_range = fluorescent_range(drop, float(a.get("reach", 0.0)))
			# Inverse-square falloff: at the default near-linear 1.0 the pool
			# cuts to zero AT the range and rims every ceiling with a visible
			# circle (walked 2026-08-23, zoo corridor). 2.0 fades out inside
			# the range and the edge disappears.
			r.attenuation = 2.0
			r.count = int(row.get("count", 1))
			r.spacing = float(row.get("spacing", 0.0))
			# A hand's width BELOW the anchor: a lamp sitting on the ceiling
			# plane spends half its sphere grazing the ceiling -- streaks at
			# glancing angles and a scorched ring around the fixture (same
			# walk). Real tubes hang; ours do now too.
			r.mount_height = FLUORESCENT_MOUNT
			# STEADY (0.62.0). Every row hummed at 12 % and 9 Hz and the walker
			# called the lights frozen: a smooth hum is invisible and a whole
			# building in step is uniform. ONE tube a room fails instead --
			# `LuxFixtureSpawner` chooses it and sets `failing_kind`.
			r.flicker_amount = 0.0
			_make_downlight(r)
			f.rig = r
			return f
		"pendant":
			# The 90s below-grade bulb (deli_counter >= 0.98 derives the
			# type: basements and objective rooms trade the office row for
			# sparse pendants). The fluorescent rig's machinery -- a row of
			# omnis -- wearing an incandescent costume: warm, tight, and
			# wavering slightly the way a filament does, not the way a tube
			# stutters.
			var b := LuxFluorescentRig.new()
			b.name = String(a.get("id", "pendant"))
			var rb := LuxLightRig.new()
			rb.rig_name = &"Bare Bulb (baked)"
			rb.light_color = LuxColorTemp.kelvin(LuxColorTemp.INCANDESCENT)
			rb.energy = 1.3
			# Tighter clamp than the fluorescent on purpose: a bare bulb is
			# a pool, not a wash -- but the pool still has to reach the
			# floor, so the drop rule applies (see the fluorescent comment).
			var bdrop := float(a.get("drop", 0.0))
			rb.light_range = clampf(bdrop + 1.0, 3.5, 6.5) if bdrop > 0.0 else 4.0
			rb.count = int(row.get("count", 1))
			rb.spacing = float(row.get("spacing", 0.0))
			# under the glass, not inside it (0.67.0): see BULB_LAMP_DROP_M
			rb.mount_height = -BULB_LAMP_DROP_M
			# steady (0.62.0): one bulb an anchor wavers, by the spawner's choice
			rb.flicker_amount = 0.0
			_make_downlight(rb)
			b.rig = rb
			return b
		"heat_lamp":
			var hl := LuxFluorescentRig.new()
			hl.name = String(a.get("id", "heat_lamp"))
			var rhl := LuxLightRig.new()
			rhl.rig_name = &"Heat Lamp (infrared)"
			rhl.light_color = LuxColorTemp.kelvin(HEAT_LAMP_KELVIN)
			rhl.energy = FLUORESCENT_ENERGY * HEAT_LAMP_LEVEL
			rhl.light_range = HEAT_LAMP_RANGE_M
			rhl.attenuation = HEAT_LAMP_ATTENUATION
			rhl.preset_scaled = false
			rhl.count = 1
			rhl.spacing = 0.0
			rhl.mount_height = 0.0
			rhl.flicker_amount = 0.0
			# no `_make_downlight`: an omni, so the buns above the shelf and the
			# dogs below it both see it
			hl.rig = rhl
			return hl
		"counter_accent":
			# A STORE COUNTER'S WARM ACCENT (0.59.0). The walker's 1990s lighting
			# reference, 2026-09-29, on the convenience store at night: "cooler
			# light on the aisles and a warmer or more saturated accent at the
			# counter". Deli Counter (>= 0.160.0) hangs one bulb over the register
			# counter, Zoo's `pendant_fixture` its hardware; this is its lamp.
			# An incandescent bulb -- the fluorescents are cool white, so the
			# counter reads warm against them -- at COUNTER_ACCENT_LEVEL times a
			# fluorescent's energy (0.60.0: twice, the walker's call from the
			# frame), with a fluorescent's range for its drop; and `preset_scaled`, so at night
			# it brightens with the wash it has to hold against. A 45-degree
			# cone: a pool on the counter, not a room light.
			var ca := LuxFluorescentRig.new()
			ca.name = String(a.get("id", "counter_accent"))
			var rca := LuxLightRig.new()
			rca.rig_name = &"Counter Accent (incandescent)"
			rca.light_color = LuxColorTemp.kelvin(LuxColorTemp.INCANDESCENT)
			rca.energy = FLUORESCENT_ENERGY * COUNTER_ACCENT_LEVEL
			rca.light_range = fluorescent_range(float(a.get("drop", 0.0)))
			rca.attenuation = 2.0
			rca.downlight_angle_deg = 45.0
			rca.downlight_rim = 1.0
			rca.preset_scaled = true
			rca.count = 1
			rca.spacing = 0.0
			# the pendant's hardware, so the pendant's clearance (0.67.0)
			rca.mount_height = -BULB_LAMP_DROP_M
			ca.rig = rca
			return ca
		"streetlight":
			var s := LuxStreetlightRig.new()
			s.name = String(a.get("id", "streetlight"))
			# beside the pole, under the lens (0.65.0): see POLE_LAMP_ALONG_M
			s.lamp_offset = Vector3(LuxStreetlightRig.POLE_LAMP_ALONG_M,
				-LuxStreetlightRig.POLE_LAMP_DROP_M, 0.0)
			s.lamp_shadow_bias = LuxStreetlightRig.POLE_SHADOW_BIAS
			var rs := LuxLightRig.new()
			rs.rig_name = &"Streetlight (baked)"
			rs.light_color = LuxColorTemp.kelvin(LuxColorTemp.SODIUM_VAPOR)
			rs.light_range = 14.0
			# DERIVED, NOT FLAT. This was `energy = 6.0`, a constant, while
			# every other outdoor light solves for what its geometry needs --
			# and at a 6 m pole through a 14 m range that constant delivered
			# 0.156 on the road against the canopy's 10.0.
			#
			# A streetlight anchor carries no `drop`: the pole runs to
			# grade, so the height above the road IS the anchor's own z, and
			# a `drop` of zero would mean a lamp lying on the tarmac.
			#
			# WHAT THAT Z IS CHANGED IN LOT 0.79.0, and the number barely
			# did. It was the POLE TOP at a flat 6.0 on a light derived from
			# the path graph; it is now the LENS of a pole the site actually
			# stands -- sidewalk height plus the module height less the
			# 0.175 m the lens sits below the module's top -- which on the
			# shipped kerb line is 5.922. Zoo's `core/fixtures.py` still
			# mounts hardware BELOW this point for a manifest that asks for
			# it; a Lot site now tags the anchor `hardware` instead, because
			# its pole is already standing.
			var pole_h := 6.0
			if typeof(a.get("pos")) == TYPE_ARRAY and (a.get("pos") as Array).size() >= 3:
				# the lamp sits POLE_LAMP_DROP_M under the lens (0.65.0): solve for where it is
				pole_h = maxf(float(a.get("pos")[2]) - LuxStreetlightRig.POLE_LAMP_DROP_M, 0.5)
			rs.energy = energy_for(STREETLIGHT_LEVEL, pole_h, rs.light_range,
				String(a.get("id", "streetlight")))
			rs.count = int(row.get("count", 1))
			rs.spacing = float(row.get("spacing", 8.0))
			rs.mount_height = 0.0
			# BUZZING POLES (90s decay): every third pole gets the dying
			# ballast. Keyed on the anchor's own id -- deterministic, so the
			# SAME pole buzzes in every build of every seed, and an authored
			# rename is the only thing that moves it. Position would drift
			# with layout; ids are the stable name for a place.
			if String(a.get("id", "")).hash() % 3 == 0:
				# 0.62.0: it CYCLES rather than buzzes -- dims, cuts out, sits
				# dark, restrikes -- and its lens goes with it (the walker's
				# call, 2026-10-02: "go with cycling streetlights")
				rs.failing_kind = LuxFailing.CYCLING
				rs.failing_seed = int(String(a.get("id", "")).hash() & 0x7fffffff)
			s.rig = rs
			return s
		"canopy_lights":
			# HARDWARE, AND DELIBERATELY NO LIGHT. Zoo's `canopy_lights`
			# species builds the whole soffit grid at this anchor with
			# emissive lenses; returning null here is the decision, not an
			# omission. The caller skips a null rig silently, which is why
			# this case exists at all rather than falling through to the
			# default: a reader finding `canopy_lights` unhandled would
			# reasonably add a light to it and break the 8-light budget on
			# the forecourt ground.
			return null
		"canopy_wash":
			# A few downward spots under a fuel canopy -- the streetlight rig
			# with count 1, the same shape the wall pack uses, because that
			# is what an outdoor downlight is.
			var cw := LuxStreetlightRig.new()
			cw.name = String(a.get("id", "canopy_wash"))
			var rc := LuxLightRig.new()
			rc.rig_name = &"Canopy Wash (baked)"
			# MERCURY VAPOUR WITH THE GREEN CAST ON TOP, and the cast is the
			# part that matters. `MERCURY_VAPOR` is commented "blue-green
			# industrial/warehouse" in the colour table, but `kelvin()` is a
			# BLACKBODY fit and a blackbody has no green spike -- measured by
			# this type's own selftest, 5000K comes back warmer in red than in
			# blue, which is the opposite of the reference. The spike is what
			# `add_fluorescent_cast` exists for, and its own docstring calls
			# the result the "convenience-store / office tint". Every night
			# reference of a 1990s forecourt reads green-cyan; Zoo's lenses
			# are emissive at (0.80, 0.95, 0.88) for the same reason.
			rc.light_color = LuxColorTemp.add_fluorescent_cast(
				LuxColorTemp.kelvin(LuxColorTemp.MERCURY_VAPOR), 0.09)
			# THE RANGE IS THE GEOMETRY'S, not a number. The source hangs at
			# the soffit, `drop` above the tarmac, and owns the pool DC sized
			# for it -- so the far corner of that pool is half its diagonal
			# out and `drop` down.
			var drop_m := float(a.get("drop", 0.0))
			if drop_m <= 0.0:
				drop_m = CLUB_DEFAULT_DROP
			var pool := Vector2(CANOPY_POOL_FALLBACK, CANOPY_POOL_FALLBACK)
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				pool = Vector2(absf(float(a.get("size")[0])),
					absf(float(a.get("size")[1])))
			var reach := sqrt(drop_m * drop_m + pow(pool.length() * 0.5, 2.0))
			rc.light_range = clampf(reach, 3.0, CANOPY_RANGE_MAX)
			rc.attenuation = 2.0
			rc.energy = energy_for(CANOPY_WASH_LEVEL, drop_m, rc.light_range,
				String(a.get("id", "canopy_wash")))
			rc.count = 1
			rc.spacing = 0.0
			rc.mount_height = 0.0
			cw.rig = rc
			return cw
		"wall_pack":
			# A wall pack is one downward warm spot — the streetlight rig
			# with count 1 is exactly that. The anchor sits proud of the
			# wall in free air (DC v1.1), so the spot is never inside the
			# hardware Zoo bakes at the same anchor.
			var wp := LuxStreetlightRig.new()
			wp.name = String(a.get("id", "wall_pack"))
			var rw := LuxLightRig.new()
			rw.rig_name = &"Wall Pack (baked)"
			rw.light_color = LuxColorTemp.kelvin(LuxColorTemp.HALOGEN)
			rw.energy = 2.5
			# 5.5, down from 7.0 — same per-mesh budget law as the
			# fluorescent trim above, scaled for an outdoor pool. Wall packs
			# face exterior walls and ground tiles, and at 7.0 they stacked
			# with streetlights on the path tiles.
			rw.light_range = 5.5
			rw.count = 1
			rw.spacing = 0.0
			rw.mount_height = 0.0
			wp.rig = rw
			return wp
		"storefront_spill":
			# THE STORE'S LIGHT ON THE PAVEMENT (0.57.0). A fluorescent rig of
			# one lamp, so the preset scales it with the room it comes from
			# (`scales_with_preset` reads "fluorescent" in the rig's name) and
			# a power cut kills it with the rest of the building. The lamp is
			# the window's opening turned around: light leaving through a
			# vertical pane from a ceiling above it arrives on the ground
			# between straight down at the glass and level with the glass
			# head, so a 45-degree cone on an axis 45 degrees below the
			# facing -- `downlight_tilt_deg` toward local +X, which `_place`
			# turns onto rot_y, the wall's outward facing.
			var sp := LuxFluorescentRig.new()
			sp.name = String(a.get("id", "storefront_spill"))
			var rsp := LuxLightRig.new()
			rsp.rig_name = &"Storefront Spill (fluorescent)"
			rsp.light_color = LuxColorTemp.cool_fluorescent()
			var head := float(a.get("head", 0.0))
			if head <= 0.0:
				head = SPILL_HEAD_FALLBACK
			# The pavement is lit out to twice the head's height from the
			# glass: the sphere reaches the ground at 2 x head, so its range
			# is hypot(2 head, head). The axis lands `head` out, sqrt(2) head
			# along it, and the level is solved there.
			rsp.light_range = head * sqrt(5.0)
			rsp.attenuation = 2.0
			rsp.downlight_angle_deg = WINDOW_CONE_HALF_ANGLE_DEG
			rsp.downlight_rim = 1.0
			rsp.downlight_tilt_deg = WINDOW_CONE_HALF_ANGLE_DEG
			rsp.energy = energy_for(
				storefront_spill_level(float(a.get("drop", 0.0)), float(a.get("reach", 0.0))),
				head * sqrt(2.0), rsp.light_range, String(a.get("id", "storefront_spill")))
			rsp.count = 1
			rsp.spacing = 0.0
			rsp.mount_height = 0.0
			sp.rig = rsp
			return sp
		"window", "sign":
			var ar := LuxAreaLightRig.new()
			ar.name = String(a.get("id", "window"))
			var size: Array = [1.4, 1.4]
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				size = a.get("size")
			ar.panel_size = Vector2(float(size[0]), float(size[1]))
			if t == "window":
				# A WINDOW'S RANGE, DERIVED LIKE EVERY OTHER TYPE'S. The rig's
				# own fallback is 4 x the panel's longer side -- 6.4 m for the
				# 1.6 m windows Deli Counter emits most, 9.6 for a 2.4 -- and
				# the anchor is the wall centreline (item 85 measured it at
				# -0.150 m by design), so half the sphere is indoors and
				# reaches two rooms of plates: cold run 9005 went from 2 to 12
				# meshes over the per-mesh budget of 8 the day its windows lit
				# (roadmap 137). What a window lights is the floor under its
				# sill and a few metres of room: twice the longer side, held
				# between 3.0 (a small window still reaches the floor from a
				# 1.6 m centre) and 4.0 (the fluorescent row's cap, item 54,
				# the same tiles). 1.6 -> 3.2, 2.4 -> 4.0.
				var longer := maxf(float(size[0]), float(size[1]))
				ar.omni_range = clampf(longer * 2.0, 3.0, 4.0)
				# The source inside the room, not on the centreline: half a
				# wall (0.15) plus the panel's own standoff (0.20), so the pool
				# lands on the floor in front of the glass rather than on the
				# ceiling and floor symmetrically at the wall (roadmap 145).
				ar.light_offset = Vector3(0.0, 0.0, 0.35)
				# AN OPENING, NOT A BULB IN THE WALL (0.40.0). Roadmap 145
				# moved the source 0.35 m inboard and the pool with it; it did
				# not stop the source being a SPHERE, so the ceiling above the
				# opening still took 1.55x the floor and the reveal 7x it (the
				# numbers are in LuxAreaLightRig.cone_angle_deg). Walked
				# 2026-09-16 on cold run 9060 as "is the light inside the wall
				# here?" -- a lit reveal and a broad wash on the ceiling above
				# and inboard of a window whose pane is the darkest thing in
				# the frame.
				#
				# THE CONE IS THE OPENING'S, so it has no free parameter: its
				# upper rim is HORIZONTAL, because the head of the opening
				# stops everything above it, and its lower rim is VERTICAL,
				# because there is wall behind the sill. That is a quarter
				# turn of sky -- half-angle 45, axis 45 below the forward --
				# and it is also where the light from an overcast sky actually
				# arrives from through a vertical opening. Nothing above the
				# window's own head is lit by it any more, the reveal is
				# behind the apex, and the pool lands on the floor in front of
				# the glass, which is what roadmap 145 asked for.
				ar.cone_angle_deg = WINDOW_CONE_HALF_ANGLE_DEG
				ar.cone_pitch_deg = WINDOW_CONE_HALF_ANGLE_DEG
				# NO PREVIEW QUAD IN A WINDOW: THE GLASS IS THE PANE. The quad
				# was the lit window while glazing was opaque (roadmap 138: a
				# near-black skin, so the room's light had to be painted on).
				# Since Pixelcoat 0.40.0 every theme's `glass` blends, and the
				# quad -- unshaded, emissive, double-sided, the size of the
				# opening, on the wall plane -- became the thing a viewer sees
				# through the glass from BOTH sides. Measured on a scratch copy
				# of walk 9050 with see-through panes, look_shots given
				# stations at the bank's west window: through the pane from the
				# street, mean RGB (177, 176, 164) std 26 -- a flat light panel
				# -- against the room's cabinet, ceiling lamp and back wall
				# once the quad is off; from inside, (191, 189, 176) std 17
				# against the sidewalk and the street. The omni is kept: it is
				# the daylight pool on the floor, and light, not a picture of
				# it, is what a lit room shows through glass at night.
				ar.show_emissive_quad = false
			else:
				# A SIGN'S SOURCE STANDS IN FRONT OF ITS CABINET. The anchor
				# is the sign's FACE plane (Deli Counter, 0.20 m proud of the
				# wall) and Zoo mounts `sign_box` CENTRED on it, 0.18 m deep
				# by its genome default -- so an omni at the anchor is inside
				# the cabinet, 0.09 m from every face of a 0.28-grey box at
				# energy 3.0. That is the "white box" walked on cold run 9005
				# (roadmap 139). Half the cabinet plus the same 0.20 standoff
				# the face itself keeps from the wall puts the source 0.29 m
				# ahead of the face: the cabinet is lit from outside like the
				# facade around it, and the pool lands on the pavement below.
				# The range is deliberately untouched here (4 x the panel's
				# longer side); a sign's reach is its own derivation.
				ar.light_offset = Vector3(0.0, 0.0, 0.18 * 0.5 + 0.20)
			var ra := LuxLightRig.new()
			ra.rig_name = &"Window (baked)"
			ra.light_color = LuxColorTemp.kelvin(LuxColorTemp.DAYLIGHT)
			ra.energy = 3.0
			# THE ONLY SHADOWED LIGHTS IN THE PACKAGE (roadmap 60, first
			# tier). An area rig hangs ON the building envelope at energy
			# 3.0, so half its sphere is always inside the building it is
			# mounted to: walked 2026-08-24, arena_a03's interior ceiling
			# carried the wash of the sign OUTSIDE its own south wall.
			# Collision never blocks light in GL Compatibility -- a shadow
			# map is the only occlusion that exists -- and this is the one
			# class where it is affordable: lot_demo_001 ships FOUR area
			# rigs against ~128 interior fixtures. Legitimate spill
			# survives (a shadow map blocks walls, not doorways). If
			# interiors ever earn shadows, that is the quality-profile
			# decision item 60 still owns -- do not default them on there.
			ra.shadows_enabled = true
			ar.rig = ra
			return ar
		"club_wash", "stage_light", "neon", "room_ambient", "back_bar":
			return _club_rig(t, a, row)
		_:
			return null   # 'sun' is owned by the preset/SkyMint; others skipped


## The fluorescent row's range rule (see its branch), as a function so the
## club rigs can price themselves against the same lamp.
##
## `reach` (0.56.0) is the horizontal distance from the lamp to the floor it
## must light, when that floor is not under it -- a storefront's glass line.
## The same rule then measures to THAT floor point: `hypot(drop, reach)` in
## place of `drop`, plus the same 0.75 trim, under the same clamp. At zero
## it IS the rule above, so the clubs and `office_floor_value`, which never
## pass it, cannot move.
##
## MEASURED on cold run 9103's walk copy at night (gas_station_a02's sales
## floor: drop 3.8, the row 6.0 m from its storefront, so 7.5 at the clamp
## against 4.55), the player's graded frame, clear storefront glass on both
## sides of the comparison: the sales floor 9.4 -> 15.7, through the glass
## 9.0 -> 11.1 (p95 48 -> 65), the store from 8 m 30.5 -> 34.6 at the frame's
## centre. Moving the row 3.5 m toward the glass instead measured WORSE
## (through the glass 8.2): the pool moved and did not grow.
static func fluorescent_range(drop: float, reach: float = 0.0) -> float:
	if drop <= 0.0:
		return 4.0
	var to_floor := sqrt(drop * drop + reach * reach) if reach > 0.0 else drop
	return clampf(to_floor + 0.75, 4.0, 7.5)


## The attenuation window Godot multiplies every omni and spot by (see the
## closed form over CLUB_WASH_LEVEL).
static func range_window(d: float, light_range: float) -> float:
	if light_range <= 0.0:
		return 0.0
	return pow(maxf(1.0 - pow(d / light_range, 4.0), 0.0), 2.0)


## What ONE fluorescent lamp from this loader puts on the floor straight
## below it at a room drop of `drop` metres: energy 1, attenuation 2, hung a
## hand's width under its anchor, range from `fluorescent_range`. At the
## strip clubs' 3.2 m that is 0.0570. The unit every club level is in.
## `reach` (0.57.0) is the row's own, so a storefront row -- whose range
## `reach` lengthens -- is priced at the range it actually has; 0 is the rule
## every caller before it used.
static func office_floor_value(drop: float, reach: float = 0.0) -> float:
	var h := maxf(drop + FLUORESCENT_MOUNT, 0.25)
	return FLUORESCENT_ENERGY * range_window(h, fluorescent_range(drop, reach)) / (h * h)


## What a storefront spill puts on the pavement where its axis lands, at a
## preset scale of 1 (the preset's `fluorescent_energy_scale` multiplies it
## exactly as it does the room's lamps): the room's lit floor, less the glass,
## at the frame match. See SPILL_FRAME_MATCH. 0.529 for gas_station_a02's
## sales floor (drop 3.8, reach 6.0), 3.18 at Delco Night's 6.0.
static func storefront_spill_level(drop: float, reach: float) -> float:
	return SPILL_FRAME_MATCH * SPILL_GLASS_T * office_floor_value(drop, reach)


## THE CEILING ON A DERIVED ENERGY, and it is not 16 any more.
##
## 0.42.0 and earlier clamped to 16.0, described in this file as "the 16
## LuxLightRig.energy allows". That 16 is `@export_range(0.0, 16.0)` on the
## rig -- an inspector slider. Godot's `light_energy` has no such limit, and
## the required energy grows with d SQUARED, so the clamp bound at roughly
## 1.2 m of drop and every light this pipeline emits shipped truncated.
## Measured on cold run 9082, the first night package: all 125 non-directional
## lights together moved the frame by 0.5%, and a spot built by hand with a
## rig's exact numbers reproduced it while an omni at the same energy did not.
##
##     canopy_wash  drop 4.88 m   asks 331.4   was clipped 20.7x
##     club_wash    drop 3.20 m   asks 171.0   was clipped 10.7x
##
## DERIVED, NOT PICKED. The clamp's real job is the pathological case, which is
## `d` approaching `range`: the window term goes to zero and the demand goes to
## infinity. That is a RANGE fault, and clamping energy hides it rather than
## reporting it. So the ceiling sits where it cannot bind on geometry Deli
## Counter emits -- the deepest drop in a shipped manifest is 4.88 m, and a
## level-10 wash at a drop of 8 m through a 12 m range needs 995 -- and a bind
## now says so out loud.
const ENERGY_CEILING := 1024.0


## The energy that puts `value` at distance `d` from a light of range
## `light_range` and attenuation 2, on a surface facing it. 0 when `d` is at or
## past the range. `who` names the anchor in the warning if the ceiling binds.
static func energy_for(value: float, d: float, light_range: float,
		who: String = "") -> float:
	var w := range_window(d, light_range)
	if w <= 0.0:
		return 0.0
	var want := value * d * d / w
	if want > ENERGY_CEILING:
		# NEVER SILENTLY AGAIN. The previous clamp was a `minf` with no
		# report, so a light could be short by a factor of twenty and look
		# exactly like a light that was simply dim. If this fires, the
		# geometry is past what the model can serve and the RANGE is the
		# thing to look at, not this number.
		push_warning(("LuxLightLoader: %s wants energy %.0f at %.2f m "
			+ "(range %.2f) and the ceiling is %.0f -- it will be %.0fx too "
			+ "dim. That is a range fault, not a brightness one.")
			% [who if who != "" else "a light", want, d, light_range,
				ENERGY_CEILING, want / ENERGY_CEILING])
	return minf(want, ENERGY_CEILING)


## What a ROW of `count` unit-energy lamps, `spacing` apart and centred on the
## anchor, puts on a surface `d` metres out along the row's own normal, facing
## it (0.40.0). Each lamp is `di = sqrt(d^2 + lat^2)` away and lands at
## incidence `cos = d / di`, so a row is NOT a single lamp with the energy
## divided: spreading it costs the cosine as well as the distance, and the
## loss grows as `d` shrinks. That is the whole point -- it is the near field
## the spread is for -- but it means the per-lamp energy has to be solved
## against this, not guessed. `count` 1 reduces to `range_window(d, R) / d^2`
## exactly, which is `energy_for`'s own denominator.
static func row_axis_value(count: int, spacing: float, d: float,
		light_range: float) -> float:
	if d <= 0.0 or count < 1:
		return 0.0
	var start := -(count - 1) * 0.5 * spacing
	var total := 0.0
	for i in count:
		var lat := start + i * spacing
		var di := sqrt(d * d + lat * lat)
		total += range_window(di, light_range) / (di * di) * (d / di)
	return total


## The PER-LAMP energy that puts `value` at distance `d` on the row's normal.
## Capped at the 16 LuxLightRig.energy allows, like `energy_for`; 0 when the
## whole row is at or past its range.
static func row_energy_for(value: float, count: int, spacing: float, d: float,
		light_range: float) -> float:
	var g := row_axis_value(count, spacing, d, light_range)
	if g <= 0.0:
		return 0.0
	return minf(value / g, 16.0)


## A stable 32-bit djb2 over the id's UTF-8 bytes. Spelled out instead of
## String.hash() so that Deli Counter can predict a derived colour in Python:
##     h = 5381
##     for b in s.encode("utf-8"): h = (h * 33 + b) & 0xFFFFFFFF
static func club_hash(s: String) -> int:
	var h := 5381
	for b in s.to_utf8_buffer():
		h = (h * 33 + b) & 0xFFFFFFFF
	return h


## The colour NAME an anchor gets: its own `color` when it has one, else the
## pick `CLUB_COLOR_ORDER[club_hash(id) % 7]`. Returns "" for a name that is
## not in CLUB_PALETTE -- a refusal, never a quiet substitute: a typo that
## silently became magenta would look like a design decision.
##
## `"color": null` IS NO COLOUR, NOT A NAME (0.38.1). Deli Counter 0.132.0
## writes a `room_ambient` for every room and sets `color` to null outside a
## club -- untinted, its contract says. `a.has("color")` was true for that key,
## `String(null)` is "<null>", and the name was refused: cold run 9057's bake
## refused 13 of 15 room ambients, so only the club was darkened and the bank
## and the construction site kept the sky's ambient. A null now takes the
## no-colour path (the hash pick here; `_club_rig` gives a room_ambient the
## derived neutral probe instead).
static func club_color_name(a: Dictionary) -> String:
	if a.has("color") and a.get("color") != null:
		var n := String(a.get("color"))
		return n if CLUB_PALETTE.has(n) else ""
	return CLUB_COLOR_ORDER[club_hash(String(a.get("id", ""))) % CLUB_COLOR_ORDER.size()]


## Deli Counter Z-up [x, y, z] -> Godot Y-up (x, z, -y); see _place.
static func _godot_point(p: Variant) -> Vector3:
	if typeof(p) != TYPE_ARRAY or (p as Array).size() < 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[2]), -float(p[1]))


## THE CLUB SET (0.37.0). The walker, with two frames of GTA IV's Triangle
## Club: "strip clubs should have a dingy lived in feel, dark with colored
## lights, couches and bars". Deli Counter gives a club's main floor the same
## five cool fluorescent lamps as an office. These are what it can write
## instead; every range and energy is derived (see CLUB_WASH_LEVEL).
##
##   club_wash    a dim saturated pool for one zone of a room. The fluorescent
##                rig's machinery, one downlight per lamp (0.34.0's reason:
##                nothing through the slab above), `row` honoured. The pool's
##                floor radius is the anchor's `radius` or 1.25 x drop, held
##                to 1.5-6.0 m; range = the lamp-to-pool-edge distance
##                sqrt(h^2 + radius^2), capped at the fluorescent's 7.5 m for
##                the same per-mesh budget; energy puts CLUB_WASH_LEVEL x the
##                office lamp's floor value on the floor below it.
##   stage_light  SpotLight3D(s) aimed at `target` [x, y, z], the same frame as
##                `pos`. Refused without one. Cone half-angle atan(radius /
##                throw), `radius` default 1.5 m; range 1.25 x throw, so the
##                attenuation window at the target is a constant 0.349; energy
##                puts CLUB_STAGE_LEVEL x the office value on the target. A
##                `row` lays several spots along rot_y, each its own colour
##                (the anchor's, then onward through CLUB_COLOR_ORDER).
##                `cycle_s` > 0 steps every spot through the palette, holding
##                each colour that many seconds (LuxStageLightRig).
##   neon         a small omni at a lit sign or LED strip, for spill. Range
##                0.5 x the sign's longer side + 1.0 m, held to 1.0-2.5; energy
##                puts CLUB_NEON_LEVEL x the office value at half the range.
##                rot_y is the sign's FACING, as for `sign`, and a `row` runs
##                ALONG the wall (so _place gives it the area rigs' quarter
##                turn). The source stands AT the anchor: Deli Counter must put
##                it in free air, never inside a cabinet (roadmap 139).
##   back_bar     a warm omni inside a club's back bar (0.39.0): the bulbs
##                behind its glass shelves and the lit porthole in its centre
##                bay, which Zoo paints as emissive materials and which light
##                nothing on their own under GL Compatibility. `size` is the
##                lit FACE [width, height] and `aisle` the working aisle Deli
##                Counter measured behind the bar; range is half the face's
##                diagonal plus that aisle, held to BACKBAR_RANGE, so the far
##                corner of the shelves and a bartender standing in front of
##                them are both inside it; the ROW's energy puts
##                CLUB_BACKBAR_LEVEL x the office value ON THE AISLE -- at
##                `aisle` metres out on the face's normal, where the
##                bartender the level is defined by actually stands. A row,
##                because the face is metres of lit
##                shelving and one omni in the middle of it is a hot spot at
##                point-blank range (0.40.0, BACKBAR_LAMP_CAP): the lamps are
##                derived from `size` unless the anchor lays a row itself.
##                Colour defaults to `tungsten`, not a hash pick. The source
##                stands AT the anchor, so Deli Counter puts it in free air in
##                front of the shelves and never inside the cabinet (139).
##   room_ambient a ReflectionProbe the size of the room (`size` [x, y, z],
##                Deli Counter axes, centred on `pos`) plus ROOM_AMBIENT_MARGIN
##                a side, whose ambient replaces the environment's inside it.
##                The only per-room darkness GL Compatibility offers, and only
##                PART of one. MEASURED (tools/probe_weight_probe.gd, a 17 x
##                3.48 x 40 m room): the share of ambient the probe replaces is
##                the Environment's ambient_light_sky_contribution, whatever
##                the ambient source -- 1.0 takes every face to the probe's
##                colour, 0.5 (Heavy Rain, and LuxPreset's default) about half
##                in linear light, 0.0 nothing. RETRACTED, kept: a first reading
##                said "the sky-sampled share, never a flat colour"; it came
##                from a synthetic room whose fresh Environment defaulted to
##                contribution 1.0. The sun and fog are the scene's and no probe
##                touches them (see the 0.37.0 changelog).
##                Colour defaults to violet, not a hash pick.
##
## An unknown `color` name returns null with a warning, on every path.
static func _club_rig(t: String, a: Dictionary, row: Dictionary) -> Node3D:
	var id := String(a.get("id", t))
	var cname := club_color_name(a)
	# an ABSENT colour on a room_ambient is violet (0.37.0, the club default);
	# a NULL one is untinted -- the room probe `bake_room_ambient` derives
	var untinted := t == "room_ambient" and a.has("color") and a.get("color") == null
	if t == "room_ambient" and not a.has("color"):
		cname = "violet"
	# a back bar with no colour named is a tungsten bulb, not a hash pick:
	# it is a lamp with a real colour and not a stage effect
	if t == "back_bar" and not a.has("color"):
		cname = "tungsten"
	if untinted:
		cname = "violet"   # a valid name so the palette read below cannot fail; overridden
	if cname == "":
		# the PALETTE's names, not the ORDER's: `tungsten` is a valid colour
		# that is deliberately outside the derived-pick order (0.39.0), and
		# a refusal that does not list it sends the reader to the wrong list
		var names := CLUB_PALETTE.keys()
		names.sort()
		push_warning("LuxLightLoader: %s '%s' names colour '%s', which is not one of %s -- not built"
			% [t, id, String(a.get("color")), ", ".join(names)])
		return null
	var col: Color = CLUB_PALETTE[cname]
	var drop := float(a.get("drop", 0.0))
	if drop <= 0.0:
		drop = CLUB_DEFAULT_DROP
	var office := office_floor_value(drop)
	match t:
		"club_wash":
			var w := LuxFluorescentRig.new()
			w.name = id
			var rw := LuxLightRig.new()
			rw.rig_name = &"Club Wash (baked)"
			rw.light_color = col
			var h := maxf(drop + FLUORESCENT_MOUNT, 0.25)
			var radius := clampf(float(a.get("radius", drop * CLUB_WASH_RADIUS_PER_DROP)), 1.5, 6.0)
			rw.light_range = minf(sqrt(h * h + radius * radius), 7.5)
			rw.attenuation = 2.0
			rw.energy = energy_for(CLUB_WASH_LEVEL * office, h, rw.light_range, id)
			rw.count = int(row.get("count", 1))
			rw.spacing = float(row.get("spacing", 0.0))
			rw.mount_height = FLUORESCENT_MOUNT
			rw.flicker_amount = 0.0
			_make_downlight(rw)
			w.rig = rw
			return w
		"neon":
			var n := LuxFluorescentRig.new()
			n.name = id
			var rn := LuxLightRig.new()
			rn.rig_name = &"Neon (baked)"
			rn.light_color = col
			var longer := 0.5
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				longer = maxf(float(a.get("size")[0]), float(a.get("size")[1]))
			rn.light_range = clampf(longer * 0.5 + 1.0, 1.0, 2.5)
			rn.attenuation = 2.0
			rn.energy = energy_for(CLUB_NEON_LEVEL * office, rn.light_range * 0.5, rn.light_range)
			rn.count = int(row.get("count", 1))
			rn.spacing = float(row.get("spacing", 0.0))
			rn.mount_height = 0.0
			rn.flicker_amount = 0.0
			n.rig = rn
			return n
		"back_bar":
			# THE RANGE IS THE GEOMETRY'S, not a number: the source sits at
			# the middle of the unit's lit face, so the far corner of that
			# face is half its diagonal away, and the bartender it has to
			# light is standing a working aisle in front of it. `size` is
			# [width, lit height] of the face, from Deli Counter.
			var bb := LuxFluorescentRig.new()
			bb.name = id
			var rb := LuxLightRig.new()
			rb.rig_name = &"Back Bar (baked)"
			rb.light_color = col
			var face := Vector2(2.0, 1.2)
			if typeof(a.get("size")) == TYPE_ARRAY and (a.get("size") as Array).size() >= 2:
				face = Vector2(absf(float(a.get("size")[0])), absf(float(a.get("size")[1])))
			var reach := float(a.get("aisle", BACKBAR_AISLE))
			rb.light_range = clampf(0.5 * face.length() + reach,
				BACKBAR_RANGE.x, BACKBAR_RANGE.y)
			rb.attenuation = 2.0
			# THE ROW IS THE FACE'S, not the anchor's (0.40.0; see
			# BACKBAR_LAMP_CAP). Deli Counter writes `row {count: 1,
			# spacing: 0}` on every back_bar it emits -- that is "no row
			# laid", not "one lamp asked for" -- so a count of 1 derives
			# from the geometry and a count above 1 is honoured as given.
			var lamps := int(row.get("count", 1))
			var pitch := float(row.get("spacing", 0.0))
			if lamps <= 1:
				lamps = clampi(int(round(face.x / maxf(face.y, 0.1))), 1,
					BACKBAR_LAMP_CAP)
				pitch = face.x / float(lamps)
			if lamps <= 1:
				pitch = 0.0
			rb.count = lamps
			rb.spacing = pitch
			# THE DESIGN POINT IS THE AISLE, NOT HALF THE RANGE (0.40.0).
			# CLUB_BACKBAR_LEVEL's own definition is what the bar puts on a
			# bartender's face, and `aisle` is the distance Deli Counter
			# MEASURED to where that bartender stands; half the range was a
			# stand-in for it while the source was a point. It matters now,
			# because a row spread across the face loses the cosine as well
			# as the distance and the solver pays for whatever point it is
			# given: at the 9060 club's 5.0 x 1.24 m face, solving at half
			# the range (1.91 m) asked for 8.78 total energy against the
			# 4.71 one lamp carried and brightened the whole station by 40%
			# of its mean luma; solving at the 1.25 m aisle asks for 4.30 --
			# the same light in the room, redistributed off the hot spot.
			# Clamped so an absent or silly aisle cannot land on or past the
			# range, where the attenuation window is zero.
			var design := clampf(reach, 0.5 * BACKBAR_RANGE.x,
				rb.light_range * 0.9)
			rb.energy = row_energy_for(CLUB_BACKBAR_LEVEL * office, lamps,
				pitch, design, rb.light_range)
			rb.mount_height = 0.0
			rb.flicker_amount = 0.0
			bb.rig = rb
			return bb
		"stage_light":
			if typeof(a.get("target")) != TYPE_ARRAY or (a.get("target") as Array).size() < 3:
				push_warning("LuxLightLoader: stage_light '%s' has no target [x, y, z] -- not built" % id)
				return null
			var aim_parent := _godot_point(a.get("target")) - _godot_point(a.get("pos"))
			var throw := aim_parent.length()
			if throw < 0.25:
				push_warning("LuxLightLoader: stage_light '%s' target is %.2f m from its pos -- not built"
					% [id, throw])
				return null
			var s := LuxStageLightRig.new()
			s.name = id
			# _place turns the rig by rot_y AFTER this; express the aim in the
			# rig's own frame so the turn carries it back onto the target.
			s.aim_local = Basis(Vector3.UP, deg_to_rad(float(a.get("rot_y", 0.0)))).inverse() * aim_parent
			var sradius := clampf(float(a.get("radius", 1.5)), 0.5, 4.0)
			s.spot_angle_deg = clampf(rad_to_deg(atan(sradius / throw)), 3.0, 60.0)
			s.spot_rim = 0.5
			var base := CLUB_COLOR_ORDER.find(cname)
			var cols := PackedColorArray()
			for k in CLUB_COLOR_ORDER.size():
				cols.append(CLUB_PALETTE[CLUB_COLOR_ORDER[(base + k) % CLUB_COLOR_ORDER.size()]])
			s.colors = cols
			s.cycle_period_s = maxf(float(a.get("cycle_s", 0.0)), 0.0)
			var rs := LuxLightRig.new()
			rs.rig_name = &"Stage Light (baked)"
			rs.light_color = col
			rs.light_range = clampf(throw * 1.25, 2.0, 12.0)
			rs.attenuation = 2.0
			rs.energy = energy_for(CLUB_STAGE_LEVEL * office, throw, rs.light_range)
			# A SPOT AT ENERGY ZERO IS A REFUSAL WEARING A LIGHT'S CLOTHES
			# (0.40.0). `light_range` is clamped at 12 m and `energy_for`
			# returns 0 the moment the target is at or past the range, so a
			# throw over 12 m built a SpotLight3D that emitted nothing, was
			# counted in `club_lights`, and reported `refused: []`. Walked on
			# cold run 9060: the club's `b0/main_floor_stage` came back with
			# aim_local (5.00, -1.52, 54.0), a 54.2 m throw, spot_angle at its
			# 3.0 minimum and energy 0.0 -- a black stage that every instrument
			# called a success. The throw is 54 m because Lot's `merge_lights`
			# transforms an anchor's `pos` into site coordinates and copies
			# `target` verbatim (building manifest: pos [-1.5, -5.0, 3.2],
			# target [-6.0, -5.0, 1.68]; site manifest: pos [-54.0, -9.5, 3.2],
			# target [0.0, -4.5, 1.68], where the placement is x - 52.5, y -
			# 4.5 and the transformed target would be [-58.5, -9.5, 1.68]).
			# That is Lot's to fix and this cannot fix it -- an anchor carries
			# no building transform. What it can do is stop reporting a dark
			# stage as a lit one.
			if rs.energy <= 0.0:
				push_warning(("LuxLightLoader: stage_light '%s' throws %.2f m to its target, "
					+ "past the %.2f m its range clamps to -- energy solves to 0, not built. "
					+ "A site-merged `target` that was not transformed with `pos` looks exactly "
					+ "like this.") % [id, throw, rs.light_range])
				return null
			rs.count = int(row.get("count", 1))
			rs.spacing = float(row.get("spacing", 0.0))
			rs.mount_height = 0.0
			s.rig = rs
			return s
		"room_ambient":
			var sz: Variant = a.get("size")
			if typeof(sz) != TYPE_ARRAY or (sz as Array).size() < 3:
				push_warning("LuxLightLoader: room_ambient '%s' has no size [x, y, z] -- not built" % id)
				return null
			var probe := ReflectionProbe.new()
			probe.name = id
			probe.size = Vector3(absf(float(sz[0])), absf(float(sz[2])), absf(float(sz[1]))) \
				+ Vector3.ONE * 2.0 * ROOM_AMBIENT_MARGIN
			probe.interior = true
			probe.update_mode = ReflectionProbe.UPDATE_ONCE
			probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
			probe.ambient_color = ROOM_AMBIENT_DERIVED_COLOR if untinted else col
			probe.ambient_color_energy = ROOM_AMBIENT_DERIVED_ENERGY if untinted else ROOM_AMBIENT_ENERGY
			probe.blend_distance = 0.1
			return probe
	return null


## CEILING LAMPS LIGHT DOWNWARD, NOT THROUGH THE SLAB ABOVE (0.34.0). A person
## walking cold run 9048 saw "light coming from a basement fixture through the
## wall": a basement pendant hangs 0.70 m under its slab with a 3.6 m range,
## so as an unshadowed omni it lit the ground floor's walls up to a metre
## above that floor. Collision never blocks light; only a shadow map does.
##
## Measured with LuxLeakMeter on that walk copy, 512 rays per light, the 76
## unshadowed ceiling rigs (55 fluorescent, 21 pendant):
##
##   * 66 of 76 lit an exposed surface behind a collider; 56 of those
##     through the slab ABOVE them.
##   * (a) CLAMPING RANGE TO THE ROOM DOES NOT WORK. For 57 of the 66, the
##     largest range that leaks nothing halves or zeroes the light on the
##     lamp's own floor directly below: a lamp hangs 0.25-0.70 m under the slab
##     above and 2.6-3.2 m over its floor, and the pool has to reach the floor
##     (the drop rule above).
##   * (b) SHADOWS DO NOT FIT. 66 more casters at the ~0.3 ms each that 0.32.1
##     priced is ~20 ms on the RTX 2060, against a High budget of 12 that the
##     signs, packs and windows already spend.
##   * (c) PER-STOREY CULL LAYERS would mean re-layering geometry Lux does not
##     own, and do nothing for the lamp beside a wall.
##   * A DOWNWARD CONE, per angle and rim (energy-weighted leak / own-room
##     light below the lamp plane, omni = 125.1 / 692):
##
##         89 deg, rim 1.0     6.46 / 389  (56%)   Lambertian falloff
##         89 deg, rim 0.5     7.24 / 479  (69%)
##         89 deg, rim 0.25    7.53 / 551  (80%)
##         89 deg, rim 0.125   7.63 / 604  (87%)
##
##     Leak falls 94% at every setting and the slab-above leak to zero; the
##     rim decides how much of the room's own light survives. 0.125 keeps 87%
##     and is what ships. The 13% lost is the band just under the ceiling at
##     grazing angles. The ceiling itself is no longer lit by its own fixture
##     and reads from the environment's ambient, like a recessed troffer --
##     which for a BARE BULB is a visible change: the warm wash a basement
##     bulb threw on its own ceiling is gone (look_shots, same walk copy).
##
##     Confirmed by re-spawning that level's fixtures through this loader and
##     the one before it, same meter, 512 rays: own light below the lamp plane
##     157.9 -> 137.8 on the fluorescent rows (87.2%), 553.1 -> 482.6 on the
##     pendants (87.3%); lights leaking into the storey above 56 -> 0.
##
## Cost: no shadow maps; one positional light per lamp, as before. At 89
## degrees a spot's culling box (printed from `get_aabb()`) is the lower HALF
## of the omni's 2R cube, so a mesh wholly above the lamp plane -- the ceiling
## plate it hangs under -- should no longer be paired with it. That last part
## is the engine's pairing rule as understood, not yet measured against a
## per-mesh census (roadmap 54).
## What is left leaking (40 of 76 lights at 512 rays, 6% of the old energy)
## goes through the floor below the lamp and walls beside it -- measured, not
## fixed here.
static func _make_downlight(r: LuxLightRig) -> void:
	r.downlight_angle_deg = 89.0
	r.downlight_rim = 0.125


## Flip a freshly-built rig's resource to bake-static BEFORE it enters the
## tree (so _ready spawns the lights already carrying BAKE_STATIC). Flicker is
## zeroed — a frozen lightmap can't flicker, and half-flickering dynamic
## objects against a steady baked room reads as a bug.
static func _make_lightmap_static(node: Node3D) -> void:
	var rr: Variant = node.get(&"rig")
	if rr is LuxLightRig:
		var r := rr as LuxLightRig
		r.bake_mode = 1
		r.flicker_amount = 0.0


static func _place(node: Node3D, a: Dictionary) -> void:
	var p: Array = [0.0, 0.0, 0.0]
	if typeof(a.get("pos")) == TYPE_ARRAY and (a.get("pos") as Array).size() >= 3:
		p = a.get("pos")
	# Deli Counter is Blender Z-up; the level GLB imports as Godot Y-up. Match
	# the glTF axis swap: (x, y, z_up) -> (x, z_up, -y).
	# If a bake looks mirrored or rotated wrong, THIS line and the yaw below are
	# the two things to flip.
	node.position = Vector3(float(p[0]), float(p[2]), -float(p[1]))
	# YAW, and which way a rig FACES. Deli Counter's rot_y is measured from
	# +X toward +Y (its docs: "rot_y 0 == +X"); under the axis swap, DC
	# (cos t, sin t) lands on Godot (cos t, 0, -sin t), and a rig that lays
	# its lamps along local +X (the fluorescent row) reaches that with
	# rotation.y = t exactly -- which is what this always did. An AREA rig
	# faces local +Z (QuadMesh's normal), and rotation.y = f turns +Z onto
	# (sin f, 0, cos f); equating gives f = t + 90. Without the quarter turn
	# every baked window panel stood PERPENDICULAR to its wall -- first seen
	# 2026-09-11, the day the pipeline first called this path (roadmap 96),
	# as white quads sticking out of cold run 9005's west facade in the S
	# elevation. The omni beneath it never cared; only the quad did.
	var yaw := float(a.get("rot_y", 0.0))
	# A neon's rot_y is its sign's facing and its row runs along the wall, so
	# it takes the area rigs' quarter turn: local +X (the row) lands on the
	# wall, local +Z on the facing (0.37.0).
	if node is LuxAreaLightRig or String(a.get("type", "")) == "neon" \
			or String(a.get("type", "")) == "back_bar":
		yaw += 90.0
	node.rotation = Vector3(0.0, deg_to_rad(yaw), 0.0)


static func _reown(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_reown(c, root)
