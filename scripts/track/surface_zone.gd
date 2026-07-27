class_name SurfaceZone
extends Area2D
## Marks a stretch of ground as a particular surface. Cars push the surface
## when they enter and pop it when they leave, so overlapping zones behave
## sensibly and a car that leaves the road falls back to the default.

@export var surface: TireModel.Surface = TireModel.Surface.TARMAC


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	body_entered.connect(_on_entered)
	body_exited.connect(_on_exited)


func _on_entered(body: Node2D) -> void:
	var car := body as RallyCar
	if car != null:
		car.push_surface(surface)


func _on_exited(body: Node2D) -> void:
	var car := body as RallyCar
	if car != null:
		car.pop_surface(surface)
