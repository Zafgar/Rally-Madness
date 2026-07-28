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
## The centreline is baked once, and drawn once, into a child node of its own.
## The comment here used to claim that redrawing it every frame cost almost
## nothing; it was two two-hundred-and-twenty-point antialiased polylines per
## viewport per frame, and it was reported as the map feeling laggy. Only the
## dots move, so only the dots are redrawn.

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

## The road, drawn once into its own node so the per-frame redraw only has to
## put dots on top of it.
var _road: Node2D
var _points: PackedVector2Array
var _closed: bool = false
var _bounds: Rect2
var _scale: float = 1.0
var _offset := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_fit)
	set_process(true)
	_road = _RoadLayer.new()
	_road.map = self
	# Behind this node's own drawing, which is where the road belongs — the cars
	# are the thing you look at on a minimap and they were being painted over by
	# it. Child order is not enough: a parent draws all of its own commands
	# before any child, so being first in the list still put the road on top.
	# A negative z_index is what actually sorts it underneath.
	_road.z_index = -1
	add_child(_road)
	move_child(_road, 0)


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
	if _road != null:
		_road.queue_redraw()
	queue_redraw()


func _process(_delta: float) -> void:
	if not cars.is_empty():
		queue_redraw()


func _to_map(world: Vector2) -> Vector2:
	return world * _scale + _offset


## The road and the markers, redrawn only when the map is resized.
class _RoadLayer extends Node2D:
	var map: TrackMap

	func _draw() -> void:
		if map == null or map._points.is_empty():
			return
		var line := PackedVector2Array()
		for p in map._points:
			line.append(map._to_map(p))

		# Drawn twice: a wide dark stroke for the verge and a lighter one on top
		# for the road, so the map reads against any background.
		draw_polyline(line, Color(0, 0, 0, 0.55), TrackMap.ROAD_WIDTH + 3.0, true)
		draw_polyline(line, Color(0.62, 0.65, 0.72, 0.85), TrackMap.ROAD_WIDTH, true)

		# Start and finish. On a point-to-point they are different places, and
		# knowing which end you are heading for is the whole point of the map.
		if not map._closed:
			draw_circle(line[0], 4.0, Color(0.45, 0.85, 0.50))
			map._finish_marker_on(self, line[line.size() - 1])
		else:
			map._finish_marker_on(self, line[0])


func _draw() -> void:
	if _points.is_empty():
		return

	for entry in cars:
		var car: RallyCar = entry
		if car == null or not is_instance_valid(car):
			continue
		var point := _to_map(car.global_position)
		var is_own := car == own_car
		if car.damage != null and car.damage.wrecked:
			draw_circle(point, DOT_RADIUS, Color(0.40, 0.40, 0.43, 0.75))
			continue
		var radius := PLAYER_DOT_RADIUS if is_own else DOT_RADIUS
		# A ring of the car's own paint. Every rival used to be the same pale
		# grey dot, so the map could tell you somebody was there and never which
		# somebody — and with the field all painted red on the road as well,
		# there was no way to connect the two. Now the dot and the car match.
		draw_circle(point, radius + 2.0, Color(0, 0, 0, 0.75))
		if is_own:
			draw_circle(point, radius, Color(1.0, 0.78, 0.20))
		else:
			draw_circle(point, radius, car.paint_color)
			# A pale rim, so a dark car is still a dot against a dark map.
			draw_arc(point, radius + 0.8, 0.0, TAU, 12,
				Color(1, 1, 1, 0.55), 1.2, true)


func _finish_marker_on(into: CanvasItem, at: Vector2) -> void:
	# A small chequered block: two dark squares on a light ground.
	var s := 4.0
	into.draw_rect(Rect2(at - Vector2(s, s), Vector2(s * 2.0, s * 2.0)), Color.WHITE)
	into.draw_rect(Rect2(at - Vector2(s, s), Vector2(s, s)), Color(0.1, 0.1, 0.12))
	into.draw_rect(Rect2(at, Vector2(s, s)), Color(0.1, 0.1, 0.12))
