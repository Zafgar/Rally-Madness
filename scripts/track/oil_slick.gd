class_name OilSlick
extends Area2D
## A patch of somebody's engine oil on the racing line.
##
## Dropped by a car with no oil pressure, one blob at a time, so a car that
## limps a whole lap leaves a trail rather than a puddle. It is a real surface
## zone, so anything that drives through it loses grip exactly the way the tyre
## model says it should — including the AI, which has no idea it is there.
##
## Slicks fade rather than persisting forever: a stage carpeted in oil after
## eight laps is a different game from the one this is meant to be.

## How long a slick lasts and how long it spends fading out, in seconds.
const LIFETIME := 45.0
const FADE_TIME := 8.0

## Radius in metres, before the small random variation each drop gets.
const RADIUS_M := 1.5

var _age: float = 0.0
var _radius_px: float = 36.0
var _wobble: PackedVector2Array


static func create(position_px: Vector2, seed_value: int) -> OilSlick:
	var slick := OilSlick.new()
	slick.position = position_px
	slick._radius_px = RADIUS_M * GameConfig.PIXELS_PER_METRE
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# An irregular blob, because a perfect circle of oil reads as a decal.
	var points := PackedVector2Array()
	for i in 10:
		var a := TAU * float(i) / 10.0
		points.append(Vector2(cos(a), sin(a)) * rng.randf_range(0.62, 1.0))
	slick._wobble = points
	return slick


func _ready() -> void:
	z_index = -2
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	var shape := CircleShape2D.new()
	shape.radius = _radius_px
	var collider := CollisionShape2D.new()
	collider.shape = shape
	add_child(collider)
	body_entered.connect(_on_entered)
	body_exited.connect(_on_exited)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		# Anything still standing in it gets its grip back on the way out.
		for body in get_overlapping_bodies():
			var car := body as RallyCar
			if car != null:
				car.pop_surface(TireModel.Surface.ICE)
		queue_free()
		return
	if _age > LIFETIME - FADE_TIME:
		queue_redraw()


func _draw() -> void:
	var fade := clampf((LIFETIME - _age) / FADE_TIME, 0.0, 1.0)
	var points := PackedVector2Array()
	for p in _wobble:
		points.append(p * _radius_px)
	draw_colored_polygon(points, Color(0.05, 0.045, 0.06, 0.72 * fade))
	# A slight sheen, so it reads as liquid rather than as a hole in the road.
	var inner := PackedVector2Array()
	for p in _wobble:
		inner.append(p * _radius_px * 0.55)
	draw_colored_polygon(inner, Color(0.16, 0.13, 0.10, 0.55 * fade))


## Oil is treated as ice by the tyre model. That is not a shortcut — the grip
## curve for ice is exactly the shape wanted here, and having one "almost no
## friction" surface rather than two means every car, tyre and assist already
## behaves correctly on it.
func _on_entered(body: Node2D) -> void:
	var car := body as RallyCar
	if car != null:
		car.push_surface(TireModel.Surface.ICE)


func _on_exited(body: Node2D) -> void:
	var car := body as RallyCar
	if car != null:
		car.pop_surface(TireModel.Surface.ICE)
