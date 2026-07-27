class_name Checkpoint
extends Area2D
## A gate across the road. Cars must pass them in order, which is what stops a
## player from cutting a corner or driving the course backwards.

@export var index: int = 0
@export var is_finish: bool = false

signal car_passed(car: RallyCar, index: int)


func _ready() -> void:
	collision_layer = 0
	# Layer 2 is cars; checkpoints only listen, they never collide.
	collision_mask = 2
	monitoring = true
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	var car := body as RallyCar
	if car == null:
		return
	car_passed.emit(car, index)
