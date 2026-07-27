class_name Ramp
extends Area2D
## A jump. Launch height scales with how fast the car crosses it, so the same
## ramp is a hop at 60 km/h and a genuine flight at 160.

## Vertical speed (m/s) imparted at the reference speed.
@export var launch_speed: float = 7.0
## Speed (m/s) at which the ramp gives exactly launch_speed.
@export var reference_speed: float = 25.0
## Above this multiple of launch_speed the ramp stops giving more, so a
## flat-out run does not send the car into orbit.
@export var max_multiplier: float = 1.8


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	var car := body as RallyCar
	if car == null or car.airborne:
		return
	# Only the component of speed heading along the ramp counts; clipping the
	# edge sideways should not launch you.
	var along := car.linear_velocity.normalized().dot(Vector2.RIGHT.rotated(global_rotation))
	if along < 0.35:
		return
	var speed_factor := car.speed_ms / maxf(reference_speed, 1.0)
	var multiplier := clampf(speed_factor, 0.25, max_multiplier)
	car.launch(launch_speed * multiplier)
