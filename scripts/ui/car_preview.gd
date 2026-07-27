class_name CarPreview
extends Control
## A car, drawn at rest, for the garage and the showroom.
##
## It reuses CarVisual — the exact thing the player sees on track — rather than
## a separate illustration. That matters more than it sounds: a showroom picture
## that does not match the car you end up driving is a lie, and here the
## silhouette really is built from the wheelbase, track width and axle positions
## of the car being sold.
##
## The car is drawn nose-up and scaled to fit, so a Fiat 126 and an F-150 both
## fill the frame and their proportions are what differ.

## Fraction of the shorter side the car takes up, leaving a margin for the
## shadow and the ground shading.
const FIT := 0.74
## Fixed three-quarter-ish angle: straight-on reads as a floor plan, and a
## slight turn-in makes it look like a car sitting on a stand.
const ANGLE := -PI * 0.5

var _visual: CarVisual
var _ground: Color = Color(0.09, 0.10, 0.125)
var _pivot: Node2D


## Built here rather than in _ready, because callers reasonably do
## `CarPreview.new().show_owned(car)` before adding it to the tree, and a
## widget that only works once it is parented is a trap.
func _init() -> void:
	clip_contents = true
	_pivot = Node2D.new()
	add_child(_pivot)
	_visual = CarVisual.new()
	_pivot.add_child(_visual)
	resized.connect(_layout)


## Shows a car the player owns, in its own paint and with its own damage.
func show_owned(car: OwnedCar) -> void:
	var spec := car.spec()
	if spec == null:
		return
	_visual.setup(spec, car.resolved_stats(), car.loadout.paint_color)
	_visual.damage_body = float(car.damage.get("body", 1.0))
	_layout()


## Shows a car nobody owns yet, in a chosen colour.
func show_spec(spec: CarSpec, paint: Color, loadout: TuningLoadout = null) -> void:
	if spec == null:
		return
	if loadout == null:
		loadout = spec.default_loadout()
	_visual.setup(spec, TuningCalculator.resolve(spec, loadout), paint)
	_visual.damage_body = 1.0
	_layout()


func set_paint(paint: Color) -> void:
	_visual.paint = paint
	_visual.queue_redraw()


func _layout() -> void:
	if _visual == null or _visual.stats == null or size.x <= 0.0:
		return
	# Scale so the car's own length fits the frame, whatever that length is.
	var ppm := GameConfig.PIXELS_PER_METRE
	var car_length := _visual.stats.wheelbase_m * 1.45 * ppm
	var car_width := _visual.stats.track_width_m * 1.3 * ppm
	var scale := minf(size.y * FIT / maxf(car_length, 1.0),
		size.x * FIT / maxf(car_width, 1.0))
	_pivot.position = size * 0.5
	_pivot.scale = Vector2(scale, scale)
	_visual.rotation = ANGLE
	queue_redraw()


func _draw() -> void:
	# A soft pool of light under the car, so it sits on something instead of
	# floating on the panel background.
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.46
	for i in range(6, 0, -1):
		var t := float(i) / 6.0
		draw_circle(centre + Vector2(0, size.y * 0.04), radius * t,
			Color(_ground.r, _ground.g, _ground.b, 0.10 * (1.0 - t) + 0.04))
	# A ground shadow under the body itself, offset the way a high sun would.
	if _visual != null and _visual.stats != null:
		var ppm := GameConfig.PIXELS_PER_METRE
		var half := Vector2(
			_visual.stats.track_width_m * 0.62 * ppm * _pivot.scale.x,
			_visual.stats.wheelbase_m * 0.70 * ppm * _pivot.scale.y)
		draw_rect(Rect2(centre - half + Vector2(3, 6), half * 2.0),
			Color(0, 0, 0, 0.28))
