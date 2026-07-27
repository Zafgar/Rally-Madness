class_name ChaseCamera
extends Camera2D
## Top-down follow camera.
##
## It leads the car rather than sitting on it: at speed the view shifts toward
## where the car is going, and the zoom pulls out, so the driver sees the
## corner before they arrive at it. That look-ahead is most of what makes a
## top-down racer readable at speed.

@export var target_path: NodePath
## Metres ahead of the car the view leads at full speed.
@export var lead_distance: float = 14.0
@export var follow_smoothing: float = 8.0
@export var lead_smoothing: float = 3.0

## Zoom at a standstill and flat out. Smaller numbers show more world.
@export var zoom_near: float = 1.35
@export var zoom_far: float = 0.85
@export var zoom_speed_ms: float = 45.0
@export var zoom_smoothing: float = 2.5

## Screen shake, driven by impacts and rough surfaces.
var _shake_amount: float = 0.0
var _shake_decay: float = 5.0

var target: RallyCar
var _lead := Vector2.ZERO
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	if not target_path.is_empty():
		target = get_node_or_null(target_path)
	# The camera is driven manually in _physics_process, in step with the car.
	position_smoothing_enabled = false
	EventBus.car_landed.connect(_on_car_landed)
	EventBus.car_damaged.connect(_on_car_damaged)


func set_target(car: RallyCar) -> void:
	target = car
	if car != null:
		global_position = car.global_position


func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return

	var ppm := GameConfig.PIXELS_PER_METRE
	# Lead along the direction of travel, not the direction the nose points —
	# during a drift those differ, and following the nose is disorienting.
	var travel := target.linear_velocity
	var lead_target := Vector2.ZERO
	if travel.length() > ppm * 2.0:
		var factor := clampf(target.speed_ms / zoom_speed_ms, 0.0, 1.0)
		lead_target = travel.normalized() * lead_distance * ppm * factor
	_lead = _lead.lerp(lead_target, clampf(delta * lead_smoothing, 0.0, 1.0))

	var desired := target.global_position + _lead
	global_position = global_position.lerp(desired, clampf(delta * follow_smoothing, 0.0, 1.0))

	if _shake_amount > 0.01:
		global_position += Vector2(
			_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _shake_amount
		_shake_amount = move_toward(_shake_amount, 0.0, _shake_decay * delta * _shake_amount)

	var speed_frac := clampf(target.speed_ms / zoom_speed_ms, 0.0, 1.0)
	# Airborne pulls out further still, so a big jump reads as a big jump.
	var height_frac := clampf(target.height * 0.05, 0.0, 0.35)
	var target_zoom := lerpf(zoom_near, zoom_far, speed_frac) - height_frac
	var z := lerpf(zoom.x, maxf(target_zoom, 0.4), clampf(delta * zoom_smoothing, 0.0, 1.0))
	zoom = Vector2(z, z)


func shake(amount: float) -> void:
	_shake_amount = maxf(_shake_amount, amount)


func _on_car_landed(car_id: int, impact: float) -> void:
	if target != null and car_id == target.car_id:
		shake(clampf(impact * 0.8, 0.0, 22.0))


func _on_car_damaged(car_id: int, _part: String, amount: float, _remaining: float) -> void:
	if target != null and car_id == target.car_id:
		shake(clampf(amount * 90.0, 0.0, 26.0))
