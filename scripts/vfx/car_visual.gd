class_name CarVisual
extends Node2D
## Draws a car from its own numbers.
##
## The silhouette comes from wheelbase and track width, the wheels sit at the
## real axle positions, and the shape comes from the car's category. That means
## 33 cars look like 33 cars without 33 sprites, and a Trabant is visibly
## shorter and narrower than an F-150 because it actually is.
##
## Everything here is drawn rather than loaded, so this is the one file to
## replace when real artwork arrives. Nothing else knows how a car looks.

## Body length as a multiple of wheelbase, i.e. how much overhang there is.
const OVERHANG := {
	"classic": 1.42,
	"road": 1.38,
	"rally": 1.36,
	"offroad": 1.30,
	"hyper": 1.34,
}
## Body width as a multiple of track width.
const BODY_WIDTH := {
	"classic": 1.10,
	"road": 1.12,
	"rally": 1.20,   # arches
	"offroad": 1.22,
	"hyper": 1.16,
}

const WHEEL_WIDTH_M := 0.22
const GLASS := Color(0.32, 0.46, 0.58)
const GLASS_DARK := Color(0.20, 0.29, 0.38)
const TYRE := Color(0.09, 0.09, 0.10)
const HEADLIGHT := Color(1.0, 0.96, 0.80)
const TAILLIGHT := Color(0.75, 0.12, 0.10)
const BRAKELIGHT := Color(1.0, 0.25, 0.16)

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


func setup(p_spec: CarSpec, p_stats: VehicleStats, p_paint: Color) -> void:
	spec = p_spec
	stats = p_stats
	paint = p_paint
	_category = p_spec.category if OVERHANG.has(p_spec.category) else "road"

	var ppm := GameConfig.PIXELS_PER_METRE
	_length_px = stats.wheelbase_m * float(OVERHANG[_category]) * ppm
	_width_px = stats.track_width_m * float(BODY_WIDTH[_category]) * ppm
	# The wheels go where the physics says the axles are, so a mid-engine car
	# with its mass over the rear really does look like one.
	_front_axle_px = stats.cg_to_front_axle() * ppm
	_rear_axle_px = -stats.cg_to_rear_axle() * ppm
	_wheel_radius_px = stats.wheel_radius * ppm
	_wheel_width_px = WHEEL_WIDTH_M * ppm
	queue_redraw()


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
	_draw_glass(half_l, half_w)
	_draw_lights(half_l, half_w)
	if damage_body < 0.7:
		_draw_damage(half_l, half_w)
	_draw_outline(half_l, half_w)


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
	# A slim rim down the middle, so the steering angle is readable at a glance.
	var rim := PackedVector2Array([
		Vector2(-r * 0.55, -w * 0.34), Vector2(r * 0.55, -w * 0.34),
		Vector2(r * 0.55, w * 0.34), Vector2(-r * 0.55, w * 0.34)])
	for i in rim.size():
		rim[i] = rim[i].rotated(angle) + centre
	draw_colored_polygon(rim, Color(0.34, 0.35, 0.38))


## A dark stroke around the silhouette. Cars sit on grey tarmac and brown
## gravel; without an outline the darker paints disappear into the road.
func _draw_outline(half_l: float, half_w: float) -> void:
	var body := _silhouette(half_l, half_w)
	var closed := PackedVector2Array(body)
	closed.append(body[0])
	draw_polyline(closed, Color(0.06, 0.06, 0.07, 0.85), 1.6, true)


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


func _draw_glass(half_l: float, half_w: float) -> void:
	# Roof between the axles, with a windscreen and a rear screen either side.
	var roof_front: float = half_l * (0.10 if _category == "hyper" else 0.22)
	var roof_rear := -half_l * 0.40
	var roof_w := half_w * 0.74
	draw_colored_polygon(PackedVector2Array([
		Vector2(roof_rear, -roof_w), Vector2(roof_front, -roof_w),
		Vector2(roof_front, roof_w), Vector2(roof_rear, roof_w)]),
		paint.darkened(0.55))

	draw_colored_polygon(PackedVector2Array([
		Vector2(roof_front, -roof_w * 0.96), Vector2(half_l * 0.52, -half_w * 0.58),
		Vector2(half_l * 0.52, half_w * 0.58), Vector2(roof_front, roof_w * 0.96)]), GLASS)
	draw_colored_polygon(PackedVector2Array([
		Vector2(roof_rear, -roof_w * 0.96), Vector2(-half_l * 0.66, -half_w * 0.60),
		Vector2(-half_l * 0.66, half_w * 0.60), Vector2(roof_rear, roof_w * 0.96)]), GLASS_DARK)


func _draw_lights(half_l: float, half_w: float) -> void:
	var lamp := _wheel_radius_px * 0.30
	var front_colour := HEADLIGHT if lights_on else HEADLIGHT.darkened(0.45)
	for side in [-1.0, 1.0]:
		draw_circle(Vector2(half_l * 0.90, half_w * 0.60 * side), lamp, front_colour)

	# Tail lights only light up under braking. A permanent red bar across the
	# tail reads as "braking" all the time and makes the one signal that
	# matters in traffic useless.
	var rear_colour := BRAKELIGHT if braking else TAILLIGHT.darkened(0.30)
	var size := lamp * (1.35 if braking else 1.0)
	for side in [-1.0, 1.0]:
		draw_circle(Vector2(-half_l * 0.90, half_w * 0.60 * side), size, rear_colour)
	# Reversing lights, because knowing a car ahead is backing up matters.
	if reversing:
		draw_circle(Vector2(-half_l * 0.90, 0.0), lamp * 0.9, Color(0.95, 0.95, 0.92))


## Panel damage, drawn as bites taken out of the silhouette rather than as an
## overlay, so a battered car reads as battered at a glance.
func _draw_damage(half_l: float, half_w: float) -> void:
	var severity := 1.0 - damage_body
	var scar := Color(0.16, 0.15, 0.15, clampf(severity, 0.0, 0.85))
	var bite := half_w * 0.45 * severity
	draw_colored_polygon(PackedVector2Array([
		Vector2(half_l * 0.70, -half_w), Vector2(half_l, -half_w * 0.5),
		Vector2(half_l - bite, -half_w * 0.5), Vector2(half_l * 0.70 - bite, -half_w)]), scar)
	if severity > 0.5:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-half_l * 0.55, half_w), Vector2(-half_l * 0.15, half_w),
			Vector2(-half_l * 0.15, half_w - bite), Vector2(-half_l * 0.55, half_w - bite)]), scar)
