class_name CarVisual
extends Node2D
## Draws a car from its own numbers.
##
## The silhouette comes from wheelbase and track width, the wheels sit at the
## real axle positions, and the shape comes from the car's category. That means
## 57 cars look like 57 cars without 57 sprites, and a Trabant is visibly
## shorter and narrower than an F-150 because it actually is.
##
## Seen from directly above, a car is mostly roof, and roof is a big flat area
## of one colour. So what makes it read as a car rather than a coloured lozenge
## is everything at its edges: the arches standing proud of the doors, the glass
## set into the roofline, the shut lines between bonnet, doors and boot, the
## bumpers, the mirrors sticking out either side. Those are drawn here in layers,
## in the order a car is actually built.
##
## Everything is drawn rather than loaded, so this is the one file to replace
## when real artwork arrives. Nothing else knows how a car looks.

## Body length as a multiple of wheelbase, i.e. how much overhang there is.
## Measured off the real cars: a Lada 2101 is 4.07 m on a 2.42 m wheelbase, a
## Golf GTI 3.99 on 2.48, a 992 4.52 on 2.45. They cluster tightly around 1.65
## because a car needs a boot behind the rear axle and a crumple zone ahead of
## the front one whatever else it is. Group B cars are the exception: they were
## superminis with the wheels pushed out, so they really are stubby.
const OVERHANG := {
	"classic": 1.65,
	"road": 1.66,
	"rally": 1.58,
	"offroad": 1.63,
	"hyper": 1.72,
}
## But overhang is not purely proportional either: a nose and a tail contain a
## radiator, a boot and a crash structure, and those are about the same size
## whatever they are bolted to. Homologation specials make the point — a Stratos
## is 3.71 m on a 2.18 m wheelbase and a Sport quattro 4.24 m on 2.20 m, because
## both had their wheelbases cut without their bodies shrinking to match. So the
## ratio sets the length and this sets a floor under it, and the floor is what
## bites on anything with a short wheelbase for its size.
const MIN_OVERHANG_M := 1.68
## How much air there is between the outside of a tyre and the outside of the
## arch above it, per side, in metres. Rally and off-road cars carry flares, so
## they get more; a supercar is drawn tight over its wheels, so it gets less.
const ARCH_CLEARANCE_M := {
	"classic": 0.045,
	"road": 0.040,
	"rally": 0.055,
	"offroad": 0.055,
	"hyper": 0.030,
}
## Tyres are sized to carry the load they are asked to hold: a contact patch is
## roughly square, its area goes with the vertical load, so width goes with the
## square root of it. Calibrated against the real fitments — a 2CV on 125s, a
## Lada on 165s, a Golf GTI on 185s, a 992 on 245/305 — and it lands within
## about ten percent on all of them.
const TYRE_WIDTH_COEFF := 0.0058
## Rally and off-road cars deliberately run more tyre than the load calls for.
const TYRE_WIDTH_BONUS := {
	"classic": 1.0,
	"road": 1.0,
	"rally": 1.10,
	"offroad": 1.12,
	"hyper": 1.06,
}
## Glass from directly above is the sky reflected in it, so it is a cool pale
## grey rather than a colour of its own. It used to be a saturated blue, which
## worked until a blue car came along and its windscreen vanished into its
## bonnet. Every pane is outlined in the near-black of the rubber seal, which is
## what actually separates glass from bodywork on a real car seen from above.
const GLASS := Color(0.56, 0.63, 0.70)
const GLASS_DARK := Color(0.40, 0.46, 0.53)
const GLASS_SIDE := Color(0.48, 0.55, 0.62)
const GLASS_SEAL := Color(0.07, 0.08, 0.09, 0.9)
const TYRE := Color(0.09, 0.09, 0.10)
const RIM := Color(0.62, 0.64, 0.68)
const TRIM := Color(0.17, 0.18, 0.20)
const HEADLIGHT := Color(1.0, 0.96, 0.80)
const TAILLIGHT := Color(0.75, 0.12, 0.10)
const BRAKELIGHT := Color(1.0, 0.25, 0.16)
const SHUT_LINE := Color(0.0, 0.0, 0.0, 0.28)

var spec: CarSpec
var stats: VehicleStats
var paint: Color = Color(0.85, 0.2, 0.15)

## Live state, pushed in by the car each frame.
var steer_angle: float = 0.0
var braking: bool = false
var reversing: bool = false
var lights_on: bool = false
var damage_body: float = 1.0

var _length_px: float = 96.0
var _width_px: float = 44.0
var _front_axle_px: float = 0.0
var _rear_axle_px: float = 0.0
var _wheel_radius_px: float = 8.0
var _wheel_width_px: float = 5.0
var _category: String = "road"

# --- Per-car detailing, decided once from the car's own facts ---------------
var _has_scoop: bool = false
var _has_wing: bool = false
var _twin_exhaust: bool = false
var _round_lamps: bool = false
var _stripe: bool = false
var _stripe_colour: Color = Color.WHITE
var _race_number: int = 0
var _wide_arches: bool = false
var _front_engined: bool = true
var _has_side_intakes: bool = false


func setup(p_spec: CarSpec, p_stats: VehicleStats, p_paint: Color) -> void:
	spec = p_spec
	stats = p_stats
	paint = p_paint
	_category = p_spec.category if OVERHANG.has(p_spec.category) else "road"

	var ppm := GameConfig.PIXELS_PER_METRE
	_length_px = maxf(stats.wheelbase_m * float(OVERHANG[_category]),
		stats.wheelbase_m + MIN_OVERHANG_M) * ppm

	# Body width is not a ratio of track — it is track plus a tyre plus the air
	# around it, which is why real cars of wildly different sizes all come out
	# at about 1.18x their track. Building it this way means the wheels are
	# inside the bodywork by construction: they were sticking out before because
	# a ratio has no idea how wide the tyres under it are.
	var tyre_w := _tyre_width_m()
	_width_px = (stats.track_width_m + tyre_w
		+ 2.0 * float(ARCH_CLEARANCE_M[_category])) * ppm

	# The wheels go where the physics says the axles are, so a mid-engine car
	# with its mass over the rear really does look like one.
	_front_axle_px = stats.cg_to_front_axle() * ppm
	_rear_axle_px = -stats.cg_to_rear_axle() * ppm
	_wheel_radius_px = stats.wheel_radius * ppm
	_wheel_width_px = tyre_w * 0.5 * ppm

	_decide_details()
	queue_redraw()


## The bodywork's overall size in pixels. The collision box and the shadow both
## have to be this, or a car bounces off things before it touches them.
func body_size() -> Vector2:
	return Vector2(_length_px, _width_px)


## The width of one tyre, in metres, from what the car is asking it to do.
func _tyre_width_m() -> float:
	var load := stats.mass_kg * maxf(stats.grip_lat, 0.4)
	var width := TYRE_WIDTH_COEFF * sqrt(load) * float(TYRE_WIDTH_BONUS[_category])
	return clampf(width, 0.115, 0.345)


## What this particular car has bolted to it, from what it actually is. A turbo
## car gets a bonnet scoop because it needs an intercooler; a car with real
## downforce gets a wing because that is where the downforce comes from; a 1974
## saloon gets round headlamps because that is what it would have had.
func _decide_details() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(spec.id) if spec != null else 0

	# A bonnet scoop feeds an intercooler, and an intercooler lives next to the
	# engine. On a front-engined turbo car that means a hole in the bonnet; on a
	# mid- or rear-engined one the air comes in through the flanks instead, so a
	# 911 was being drawn with a scoop over an empty boot.
	var boosted := stats.turbo_boost > 1.06
	_front_engined = stats.weight_bias_front >= 0.48
	_has_scoop = boosted and _front_engined
	_has_side_intakes = boosted and not _front_engined
	_has_wing = stats.downforce > 0.6 or _category == "hyper" or _category == "rally"
	_twin_exhaust = stats.engine_torque_nm > 200.0 or spec.tier >= 3
	_round_lamps = spec != null and spec.year < 1988
	_wide_arches = _category == "rally" or _category == "offroad" or spec.tier >= 4

	# Competition cars carry a stripe and a number; road cars do not. It is the
	# cheapest thing that separates "a car" from "a car that is racing".
	_stripe = spec != null and (spec.tier >= 2 or _category == "rally")
	_stripe_colour = Color.WHITE if paint.get_luminance() < 0.55 else Color(0.12, 0.13, 0.16)
	_race_number = rng.randi_range(2, 99)


func _draw() -> void:
	if stats == null:
		return
	var half_l := _length_px * 0.5
	var half_w := _width_px * 0.5

	# Wheels go on top of the body, not under it. Under it they are hidden by
	# the bodywork exactly as they would be in real life, which is realistic
	# and useless: from directly above, a car with no visible wheels is a
	# coloured brick and its heading is much harder to read.
	_draw_body(half_l, half_w)
	_draw_wheels()
	_draw_arches(half_l, half_w)
	_draw_bumpers(half_l, half_w)
	_draw_panel_lines(half_l, half_w)
	_draw_livery(half_l, half_w)
	_draw_greenhouse(half_l, half_w)
	_draw_number(half_l, half_w)
	_draw_mirrors(half_l, half_w)
	if _has_scoop:
		_draw_scoop(half_l, half_w)
	if _has_side_intakes:
		_draw_side_intakes(half_l, half_w)
	if _has_wing:
		_draw_wing(half_l, half_w)
	_draw_lights(half_l, half_w)
	_draw_exhaust(half_l, half_w)
	if damage_body < 0.7:
		_draw_damage(half_l, half_w)
	_draw_outline(half_l, half_w)


# --- Wheels -----------------------------------------------------------------

func _draw_wheels() -> void:
	var track := stats.track_width_m * GameConfig.PIXELS_PER_METRE * 0.5
	for side in [-1.0, 1.0]:
		_draw_wheel(Vector2(_rear_axle_px, track * side), 0.0)
		_draw_wheel(Vector2(_front_axle_px, track * side), steer_angle)


func _draw_wheel(centre: Vector2, angle: float) -> void:
	var r := _wheel_radius_px
	var w := _wheel_width_px
	var corners := PackedVector2Array([
		Vector2(-r, -w), Vector2(r, -w), Vector2(r, w), Vector2(-r, w)])
	for i in corners.size():
		corners[i] = corners[i].rotated(angle) + centre
	draw_colored_polygon(corners, TYRE)

	# From directly above, a wheel is tread. The rim is vertical and facing
	# sideways, so you cannot see it at all — drawing one put a bright bar down
	# the middle of every tyre that read as a slot cut into the wheel. What is
	# actually visible is the blocks of the tread pattern and the shoulder
	# catching the light along the outer edge.
	var grooves := 3
	for i in grooves:
		var along: float = lerpf(-r * 0.62, r * 0.62, float(i) / float(grooves - 1))
		var a := Vector2(along, -w * 0.78).rotated(angle) + centre
		var b := Vector2(along, w * 0.78).rotated(angle) + centre
		draw_line(a, b, TYRE.lightened(0.10), maxf(1.0, w * 0.18))
	var shoulder := PackedVector2Array([
		Vector2(-r * 0.88, -w), Vector2(r * 0.88, -w),
		Vector2(r * 0.88, -w * 0.74), Vector2(-r * 0.88, -w * 0.74)])
	for i in shoulder.size():
		shoulder[i] = shoulder[i].rotated(angle) + centre
	draw_colored_polygon(shoulder, TYRE.lightened(0.16))


## Flares standing proud of the doors, over each wheel. On a rally car these are
## the most recognisable thing about it from above.
func _draw_arches(half_l: float, half_w: float) -> void:
	if not _wide_arches:
		return
	var flare := Color(paint.darkened(0.42), 1.0)
	var length := _wheel_radius_px * 1.5
	for axle in [_front_axle_px, _rear_axle_px]:
		for side in [-1.0, 1.0]:
			draw_colored_polygon(PackedVector2Array([
				Vector2(axle - length, half_w * 0.72 * side),
				Vector2(axle + length, half_w * 0.72 * side),
				Vector2(axle + length * 0.72, half_w * 1.02 * side),
				Vector2(axle - length * 0.72, half_w * 1.02 * side)]), flare)


# --- Body -------------------------------------------------------------------

func _draw_body(half_l: float, half_w: float) -> void:
	var body := _silhouette(half_l, half_w)
	var shade := paint.darkened(0.35) if damage_body > 0.5 else paint.darkened(0.55)
	# A darker underlay offset backwards reads as depth from above without
	# needing a normal map or a second light.
	var under := PackedVector2Array(body)
	var lift := Vector2(0.0, 2.2).rotated(-get_parent().rotation) if get_parent() != null \
		else Vector2(0.0, 2.2)
	for i in under.size():
		under[i] += lift
	draw_colored_polygon(under, shade)
	draw_colored_polygon(body, paint)

	# A band of lighter paint down the spine. Car bodies are curved, so from
	# above the middle catches the sky and the flanks fall away — without this
	# the roof is a single flat colour and looks like paper.
	var crown := PackedVector2Array()
	var inner := half_w * 0.46
	for point in body:
		crown.append(Vector2(point.x * 0.985, clampf(point.y, -inner, inner)))
	draw_colored_polygon(crown, paint.lightened(0.13))
	# And a narrow specular streak on top of that. Kept faint: at full strength
	# it stopped reading as a highlight and started reading as a painted stripe
	# down the middle of every car in the game.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-half_l * 0.55, -half_w * 0.11), Vector2(half_l * 0.62, -half_w * 0.08),
		Vector2(half_l * 0.62, half_w * 0.01), Vector2(-half_l * 0.55, half_w * 0.03)]),
		paint.lightened(0.12))


## Dark bumpers front and rear. On the road cars they are body-coloured with a
## darker cap; on the competition cars they are plain black.
func _draw_bumpers(half_l: float, half_w: float) -> void:
	var bumper := TRIM if spec != null and spec.tier >= 2 else paint.darkened(0.5)
	var depth := half_l * 0.055
	for end in [1.0, -1.0]:
		var outer: float = half_l * 0.985 * end
		var inner: float = (half_l * 0.985 - depth * 2.0) * end
		draw_colored_polygon(PackedVector2Array([
			Vector2(outer, -half_w * 0.72), Vector2(outer, half_w * 0.72),
			Vector2(inner, half_w * 0.80), Vector2(inner, -half_w * 0.80)]), bumper)


## The shut lines: bonnet, doors, boot. Four thin dark strokes, and between
## them the flat roof stops being one shape and becomes a car with panels.
func _draw_panel_lines(half_l: float, half_w: float) -> void:
	# The bonnet ends where the windscreen starts and the boot begins where the
	# rear screen does, so both shut lines come from the cabin rather than being
	# separately guessed at.
	var cabin := _cabin(half_l, half_w)
	var bonnet: float = cabin["screen_front"]
	var boot: float = cabin["screen_rear"]
	for x in [bonnet, boot]:
		draw_line(Vector2(x, -half_w * 0.86), Vector2(x, half_w * 0.86), SHUT_LINE, 1.5)
	# Door shuts, which is what gives the flank its length.
	for side in [-1.0, 1.0]:
		draw_line(Vector2(bonnet, half_w * 0.86 * side),
			Vector2(boot, half_w * 0.86 * side), SHUT_LINE, 1.2)
		draw_line(Vector2(half_l * 0.02, half_w * 0.86 * side),
			Vector2(half_l * 0.02, half_w * 0.62 * side), SHUT_LINE, 1.2)


## Where the cabin sits along the car. It occupies the middle third: roof in the
## centre, a band of windscreen ahead of it and a band of rear screen behind.
## A mid-engine car pushes the whole thing forward, because the engine is where
## the back seats would be — which is exactly what makes a Huracan read as a
## Huracan from above rather than as a wide hatchback.
func _cabin(half_l: float, half_w: float) -> Dictionary:
	var shift := 0.0
	# Weight behind the rear axle means the engine is back there, so the cabin
	# comes forward to make room for it.
	if stats != null and stats.weight_bias_front < 0.46:
		shift = half_l * (0.46 - stats.weight_bias_front) * 1.1
	return {
		"roof_front": half_l * 0.12 + shift,
		"roof_rear": -half_l * 0.34 + shift,
		"screen_front": half_l * 0.32 + shift,
		"screen_rear": -half_l * 0.52 + shift,
		"roof_w": half_w * 0.72,
	}


## The outline that gives each category its character. All of them are built
## from the same measured length and width, so proportion still comes from the
## car's own numbers.
func _silhouette(half_l: float, half_w: float) -> PackedVector2Array:
	match _category:
		"classic":
			# Upright and slab-sided, barely any taper.
			return PackedVector2Array([
				Vector2(-half_l, -half_w * 0.94), Vector2(-half_l * 0.86, -half_w),
				Vector2(half_l * 0.86, -half_w), Vector2(half_l, -half_w * 0.88),
				Vector2(half_l, half_w * 0.88), Vector2(half_l * 0.86, half_w),
				Vector2(-half_l * 0.86, half_w), Vector2(-half_l, half_w * 0.94)])
		"rally":
			# Boxed arches and a squared-off tail for the wing.
			return PackedVector2Array([
				Vector2(-half_l, -half_w * 0.86), Vector2(-half_l * 0.78, -half_w),
				Vector2(-half_l * 0.30, -half_w), Vector2(-half_l * 0.22, -half_w * 0.92),
				Vector2(half_l * 0.30, -half_w * 0.92), Vector2(half_l * 0.42, -half_w),
				Vector2(half_l * 0.88, -half_w), Vector2(half_l, -half_w * 0.76),
				Vector2(half_l, half_w * 0.76), Vector2(half_l * 0.88, half_w),
				Vector2(half_l * 0.42, half_w), Vector2(half_l * 0.30, half_w * 0.92),
				Vector2(-half_l * 0.22, half_w * 0.92), Vector2(-half_l * 0.30, half_w),
				Vector2(-half_l * 0.78, half_w), Vector2(-half_l, half_w * 0.86)])
		"hyper":
			# Low, wide, and pointed at the nose.
			return PackedVector2Array([
				Vector2(-half_l, -half_w * 0.80), Vector2(-half_l * 0.70, -half_w),
				Vector2(half_l * 0.55, -half_w), Vector2(half_l * 0.92, -half_w * 0.62),
				Vector2(half_l, -half_w * 0.30), Vector2(half_l, half_w * 0.30),
				Vector2(half_l * 0.92, half_w * 0.62), Vector2(half_l * 0.55, half_w),
				Vector2(-half_l * 0.70, half_w), Vector2(-half_l, half_w * 0.80)])
		"offroad":
			# Tall and rectangular, with the bluntest possible nose.
			return PackedVector2Array([
				Vector2(-half_l, -half_w), Vector2(half_l * 0.94, -half_w),
				Vector2(half_l, -half_w * 0.86), Vector2(half_l, half_w * 0.86),
				Vector2(half_l * 0.94, half_w), Vector2(-half_l, half_w)])
		_:
			# Road: a softened hatch shape.
			return PackedVector2Array([
				Vector2(-half_l, -half_w * 0.88), Vector2(-half_l * 0.82, -half_w),
				Vector2(half_l * 0.66, -half_w), Vector2(half_l * 0.96, -half_w * 0.74),
				Vector2(half_l, -half_w * 0.40), Vector2(half_l, half_w * 0.40),
				Vector2(half_l * 0.96, half_w * 0.74), Vector2(half_l * 0.66, half_w),
				Vector2(-half_l * 0.82, half_w), Vector2(-half_l, half_w * 0.88)])


# --- The cabin --------------------------------------------------------------

## Roof, screens and side glass. A roof that is simply a rectangle of darker
## paint reads as a hole; a roof with pillars between its windows reads as a
## car, and the pillars cost three polygons.
func _draw_greenhouse(half_l: float, half_w: float) -> void:
	var cabin := _cabin(half_l, half_w)
	var roof_front: float = cabin["roof_front"]
	var roof_rear: float = cabin["roof_rear"]
	var roof_w: float = cabin["roof_w"]

	# The roof panel itself, slightly lighter than the flanks so it sits above
	# them rather than being cut into them.
	draw_colored_polygon(PackedVector2Array([
		Vector2(roof_rear, -roof_w), Vector2(roof_front, -roof_w),
		Vector2(roof_front, roof_w), Vector2(roof_rear, roof_w)]),
		paint.lightened(0.06))

	# Windscreen and rear screen, raked away from the roof. A screen is glass
	# lying at an angle, so from above it is a short band, not a whole bonnet.
	var screen_front: float = cabin["screen_front"]
	_pane(PackedVector2Array([
		Vector2(roof_front, -roof_w * 0.96), Vector2(screen_front, -half_w * 0.60),
		Vector2(screen_front, half_w * 0.60), Vector2(roof_front, roof_w * 0.96)]), GLASS)
	var screen_rear: float = cabin["screen_rear"]
	_pane(PackedVector2Array([
		Vector2(roof_rear, -roof_w * 0.96), Vector2(screen_rear, -half_w * 0.58),
		Vector2(screen_rear, half_w * 0.58), Vector2(roof_rear, roof_w * 0.96)]),
		GLASS_DARK)

	# Side glass, in two panes with a B-pillar between them. It is a narrow band
	# and it has to be: a side window is very nearly vertical, so from directly
	# above almost none of it is facing you. Drawn any wider and the roof turns
	# into a targa top with a strip of paint down the middle.
	var pillar := (roof_front + roof_rear) * 0.5
	for side in [-1.0, 1.0]:
		var y_out: float = roof_w * 1.06 * side
		var y_in: float = roof_w * 0.84 * side
		_pane(PackedVector2Array([
			Vector2(roof_front - half_l * 0.03, y_in),
			Vector2(pillar - half_l * 0.03, y_in),
			Vector2(pillar - half_l * 0.03, y_out),
			Vector2(roof_front - half_l * 0.03, y_out)]), GLASS_SIDE, 0.9)
		_pane(PackedVector2Array([
			Vector2(pillar + half_l * 0.03, y_in),
			Vector2(roof_rear + half_l * 0.03, y_in),
			Vector2(roof_rear + half_l * 0.03, y_out),
			Vector2(pillar + half_l * 0.03, y_out)]), GLASS_SIDE, 0.9)

	# A roof vent on the competition cars, which is where the driver's air
	# comes from once the windows are taped up.
	if _category == "rally" or (spec != null and spec.tier >= 3):
		draw_colored_polygon(PackedVector2Array([
			Vector2(roof_front - half_l * 0.03, -roof_w * 0.30),
			Vector2(roof_front - half_l * 0.16, -roof_w * 0.22),
			Vector2(roof_front - half_l * 0.16, roof_w * 0.22),
			Vector2(roof_front - half_l * 0.03, roof_w * 0.30)]), TRIM)


## The competition number, on the roof, where a roof number goes. It is drawn
## turned a quarter turn so that its up-direction points at the car's nose:
## from directly above, a number that reads the right way up when the car is
## driving away from you is the one that tells you which car you are looking at.
func _draw_number(half_l: float, half_w: float) -> void:
	if not _stripe or _race_number <= 0:
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	# Sized to the roof, which is the panel it has to fit on — and it has to fit
	# in both directions, so whichever of the two runs out first sets the size.
	# It is deliberately well inside the roof: a number that fills the panel
	# edge to edge stops being a detail on a car and becomes the whole car.
	var size := int(clampf(minf(half_l * 0.20, half_w * 0.52), 8.0, 30.0))
	var text := str(_race_number)
	var extent := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, size)
	var cabin := _cabin(half_l, half_w)
	var centre := Vector2(lerpf(float(cabin["roof_front"]),
		float(cabin["roof_rear"]), 0.62), 0.0)

	draw_set_transform(centre, PI * 0.5, Vector2.ONE)
	# A plate behind it, because a number the same brightness as the paint is
	# no number at all. It takes the opposite tone to the digits themselves,
	# which is exactly how a real competition number plate is made up.
	var plate := Color(0.05, 0.05, 0.06, 0.60) if _stripe_colour.get_luminance() > 0.5 \
		else Color(0.94, 0.94, 0.92, 0.72)
	var pad := Vector2(size * 0.14, size * 0.02)
	draw_rect(Rect2(-extent * 0.5 - pad, extent + pad * 2.0), plate)
	draw_string(font, Vector2(-extent.x * 0.5, extent.y * 0.34), text,
		HORIZONTAL_ALIGNMENT_CENTER, extent.x, size, _stripe_colour)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## One window: the glass, and the rubber seal around it. The seal is the whole
## point — it is a dark line between glass and paint, so the window stays a
## window no matter what colour the car is sprayed.
func _pane(points: PackedVector2Array, colour: Color, weight: float = 1.2) -> void:
	draw_colored_polygon(points, colour)
	var closed := PackedVector2Array(points)
	closed.append(points[0])
	draw_polyline(closed, GLASS_SEAL, weight, true)


## Door mirrors. Two tiny stubs, and worth far more than their size: they are
## the only thing that sticks out sideways, so they tell you instantly which
## way round the car is.
func _draw_mirrors(half_l: float, half_w: float) -> void:
	# On the A-pillar, where a door mirror is bolted.
	var at: float = float(_cabin(half_l, half_w)["roof_front"]) + half_l * 0.04
	var stalk := _wheel_radius_px * 0.24
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(at + stalk, half_w * 0.92 * side),
			Vector2(at + stalk, (half_w + stalk * 2.2) * side),
			Vector2(at - stalk, (half_w + stalk * 2.2) * side),
			Vector2(at - stalk, half_w * 0.92 * side)]), TRIM)


# --- Bolt-on parts ----------------------------------------------------------

## A bonnet scoop, on anything with real boost. It is where the intercooler
## breathes, so it only appears on cars that have one.
func _draw_scoop(half_l: float, half_w: float) -> void:
	var front := half_l * 0.56
	var back := half_l * 0.34
	draw_colored_polygon(PackedVector2Array([
		Vector2(front, -half_w * 0.26), Vector2(front, half_w * 0.26),
		Vector2(back, half_w * 0.34), Vector2(back, -half_w * 0.34)]),
		paint.darkened(0.30))
	# The mouth, facing forward.
	draw_colored_polygon(PackedVector2Array([
		Vector2(front, -half_w * 0.22), Vector2(front, half_w * 0.22),
		Vector2(front - half_l * 0.05, half_w * 0.18),
		Vector2(front - half_l * 0.05, -half_w * 0.18)]), Color(0.05, 0.05, 0.06))


## Intakes in the flanks, ahead of the rear wheels, on a car whose engine is
## behind the driver. They are the reason a mid-engined car is instantly
## recognisable from the side, and from above they are two dark slots.
func _draw_side_intakes(half_l: float, half_w: float) -> void:
	var at := -half_l * 0.22
	var length := half_l * 0.16
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(at + length, half_w * 0.99 * side),
			Vector2(at - length, half_w * 0.99 * side),
			Vector2(at - length * 0.7, half_w * 0.76 * side),
			Vector2(at + length * 0.8, half_w * 0.76 * side)]), Color(0.06, 0.06, 0.07))


## The rear wing, sized from the downforce the car actually makes.
func _draw_wing(half_l: float, half_w: float) -> void:
	var span := half_w * (1.10 if stats.downforce > 1.2 else 0.94)
	var at := -half_l * 0.94
	var chord := half_l * 0.09
	# End plates first, so the blade sits between them.
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(at + chord, span * side), Vector2(at - chord * 0.6, span * side),
			Vector2(at - chord * 0.6, (span - chord * 0.5) * side),
			Vector2(at + chord, (span - chord * 0.5) * side)]), TRIM)
	draw_colored_polygon(PackedVector2Array([
		Vector2(at + chord, -span), Vector2(at + chord, span),
		Vector2(at - chord * 0.6, span), Vector2(at - chord * 0.6, -span)]),
		paint.darkened(0.18))
	draw_line(Vector2(at, -span), Vector2(at, span), Color(0, 0, 0, 0.3), 1.2)


func _draw_exhaust(half_l: float, half_w: float) -> void:
	var pipe := _wheel_radius_px * 0.22
	var offsets: Array = [-half_w * 0.46, half_w * 0.46] if _twin_exhaust \
		else [half_w * 0.46]
	for y in offsets:
		draw_circle(Vector2(-half_l * 0.99, float(y)), pipe, Color(0.10, 0.10, 0.11))
		draw_circle(Vector2(-half_l * 0.99, float(y)), pipe * 0.55, Color(0.30, 0.31, 0.33))


## A competition stripe down the spine and a number on the roof. Only the cars
## that are actually racing get them, which is what makes them mean something.
func _draw_livery(half_l: float, half_w: float) -> void:
	if not _stripe:
		return
	var width := half_w * 0.075
	for offset in [-half_w * 0.27, half_w * 0.27]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(half_l * 0.92, float(offset) - width), Vector2(half_l * 0.92, float(offset) + width),
			Vector2(-half_l * 0.94, float(offset) + width), Vector2(-half_l * 0.94, float(offset) - width)]),
			Color(_stripe_colour, 0.7))


# --- Lights -----------------------------------------------------------------

func _draw_lights(half_l: float, half_w: float) -> void:
	var lamp := _wheel_radius_px * 0.30
	var front_colour := HEADLIGHT if lights_on else HEADLIGHT.darkened(0.45)
	for side in [-1.0, 1.0]:
		var at := Vector2(half_l * 0.90, half_w * 0.60 * float(side))
		if _round_lamps:
			# A period car has round lamps, and often four of them.
			draw_circle(at, lamp, front_colour)
			if spec != null and spec.tier >= 1:
				draw_circle(at + Vector2(-lamp * 0.2, -lamp * 1.9 * float(side)), lamp * 0.8,
					front_colour)
		else:
			# Anything modern has a swept cluster, which from above is a wedge.
			draw_colored_polygon(PackedVector2Array([
				at + Vector2(lamp * 0.7, -lamp * 1.5),
				at + Vector2(lamp * 0.7, lamp * 1.5),
				at + Vector2(-lamp * 1.1, lamp * 0.9),
				at + Vector2(-lamp * 1.1, -lamp * 0.9)]), front_colour)

	# Tail lights only light up under braking. A permanent red bar across the
	# tail reads as "braking" all the time and makes the one signal that
	# matters in traffic useless.
	var rear_colour := BRAKELIGHT if braking else TAILLIGHT.darkened(0.30)
	var size := lamp * (1.35 if braking else 1.0)
	for side in [-1.0, 1.0]:
		var at := Vector2(-half_l * 0.92, half_w * 0.60 * float(side))
		draw_colored_polygon(PackedVector2Array([
			at + Vector2(-size * 0.5, -size * 1.4), at + Vector2(-size * 0.5, size * 1.4),
			at + Vector2(size * 0.9, size * 1.0), at + Vector2(size * 0.9, -size * 1.0)]),
			rear_colour)
	# Reversing lights, because knowing a car ahead is backing up matters.
	if reversing:
		draw_circle(Vector2(-half_l * 0.90, 0.0), lamp * 0.9, Color(0.95, 0.95, 0.92))


## A dark stroke around the silhouette. Cars sit on grey tarmac and brown
## gravel; without an outline the darker paints disappear into the road.
func _draw_outline(half_l: float, half_w: float) -> void:
	var body := _silhouette(half_l, half_w)
	var closed := PackedVector2Array(body)
	closed.append(body[0])
	draw_polyline(closed, Color(0.06, 0.06, 0.07, 0.85), 1.6, true)


## Panel damage, drawn as bites taken out of the silhouette rather than as an
## overlay, so a battered car reads as battered at a glance.
func _draw_damage(half_l: float, half_w: float) -> void:
	var severity := 1.0 - damage_body
	var scar := Color(0.16, 0.15, 0.15, clampf(severity, 0.0, 0.85))
	var bite := half_w * 0.45 * severity
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(spec.id) if spec != null else 7
	for i in 3:
		var along := rng.randf_range(-half_l * 0.8, half_l * 0.8)
		var side: float = 1.0 if rng.randf() < 0.5 else -1.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(along - bite, half_w * side),
			Vector2(along + bite, half_w * side),
			Vector2(along, (half_w - bite) * side)]), scar)
