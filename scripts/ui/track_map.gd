class_name TrackMap
extends Control
## The stage, drawn small, with everyone on it.
##
## Two jobs, and the second is the one that matters. The obvious one is telling
## a driver what shape the road is about to be. The useful one is telling them
## where everybody else is: a top-down camera shows about eighty metres of road,
## which is not enough to know whether the car you are racing is ten seconds
## ahead or about to come past.
##
## The centreline is baked once into a polyline in local coordinates, so drawing
## it every frame costs almost nothing — the map redraws only because the dots
## on it move.

## Padding inside the control, in pixels.
const MARGIN := 10.0
const ROAD_WIDTH := 3.0
const DOT_RADIUS := 3.6
const PLAYER_DOT_RADIUS := 5.0

var builder: TrackBuilder
## The car this map belongs to, drawn larger and in the accent colour.
var own_car: RallyCar
## Every car in the race, in whatever order; each is drawn as a dot.
var cars: Array = []

var _points: PackedVector2Array
var _closed: bool = false
var _bounds: Rect2
var _scale: float = 1.0
var _offset := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_fit)
	set_process(true)


func bind(p_builder: TrackBuilder, p_own: RallyCar, p_cars: Array) -> void:
	builder = p_builder
	own_car = p_own
	cars = p_cars
	_bake()
	_fit()


## Samples the centreline once. The track never changes shape mid-race, so
## there is no reason to ask the curve anything after this.
func _bake() -> void:
	_points = PackedVector2Array()
	if builder == null or builder.curve == null:
		return
	_closed = builder.spec.closed if builder.spec != null else false
	var length := builder.curve.get_baked_length()
	# About two hundred samples regardless of track length: enough that a
	# hairpin still reads as a hairpin at map scale.
	var steps := 220
	for i in range(steps + 1):
		_points.append(builder.curve.sample_baked(length * float(i) / float(steps)))
	if _points.is_empty():
		return
	_bounds = Rect2(_points[0], Vector2.ZERO)
	for p in _points:
		_bounds = _bounds.expand(p)


func _fit() -> void:
	if _points.is_empty() or size.x <= 0.0:
		return
	var usable := size - Vector2(MARGIN, MARGIN) * 2.0
	_scale = minf(usable.x / maxf(_bounds.size.x, 1.0),
		usable.y / maxf(_bounds.size.y, 1.0))
	var drawn := _bounds.size * _scale
	_offset = (size - drawn) * 0.5 - _bounds.position * _scale
	queue_redraw()


func _process(_delta: float) -> void:
	if not cars.is_empty():
		queue_redraw()


func _to_map(world: Vector2) -> Vector2:
	return world * _scale + _offset


func _draw() -> void:
	if _points.is_empty():
		return
	var line := PackedVector2Array()
	for p in _points:
		line.append(_to_map(p))

	# Drawn twice: a wide dark stroke for the verge and a lighter one on top for
	# the road, so the map reads against any background.
	draw_polyline(line, Color(0, 0, 0, 0.55), ROAD_WIDTH + 3.0, true)
	draw_polyline(line, Color(0.62, 0.65, 0.72, 0.85), ROAD_WIDTH, true)

	# Start and finish. On a point-to-point they are different places, and
	# knowing which end you are heading for is the whole point of the map.
	if not _closed:
		draw_circle(line[0], 4.0, Color(0.45, 0.85, 0.50))
		_finish_marker(line[line.size() - 1])
	else:
		_finish_marker(line[0])

	for entry in cars:
		var car: RallyCar = entry
		if car == null or not is_instance_valid(car):
			continue
		var point := _to_map(car.global_position)
		var is_own := car == own_car
		if car.damage != null and car.damage.wrecked:
			draw_circle(point, DOT_RADIUS, Color(0.45, 0.45, 0.48, 0.8))
			continue
		draw_circle(point, (PLAYER_DOT_RADIUS if is_own else DOT_RADIUS) + 1.5,
			Color(0, 0, 0, 0.7))
		draw_circle(point, PLAYER_DOT_RADIUS if is_own else DOT_RADIUS,
			Color(1.0, 0.78, 0.20) if is_own else Color(0.82, 0.86, 0.92))


func _finish_marker(at: Vector2) -> void:
	# A small chequered block: two dark squares on a light ground.
	var s := 4.0
	draw_rect(Rect2(at - Vector2(s, s), Vector2(s * 2.0, s * 2.0)), Color.WHITE)
	draw_rect(Rect2(at - Vector2(s, s), Vector2(s, s)), Color(0.1, 0.1, 0.12))
	draw_rect(Rect2(at, Vector2(s, s)), Color(0.1, 0.1, 0.12))
