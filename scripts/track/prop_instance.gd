class_name PropInstance
extends RigidBody2D
## One hazard sitting on the racing surface.
##
## A hay bale you can shove aside and a concrete block you cannot are the same
## code and different numbers, which is the point of the prop catalogue. Light
## props are ordinary rigid bodies that get knocked away; heavy ones are frozen
## so they behave as part of the scenery until something enormous hits them.
##
## The consequence of a hit is not left to the physics engine alone. A car that
## clouts a tyre stack should lose a specific amount of speed and take a
## specific amount of damage, because those are balance numbers and the
## simulation's own impulse is not.

## Below this speed a contact is a nudge, not a hit worth pricing.
const MIN_IMPACT_SPEED := 4.0
## Turns a prop's authored damage fraction into an impulse the damage model
## understands. Set so a hay bale at 25 m/s is a scrape and a concrete block at
## the same speed is a race-ending one.
const DAMAGE_TO_IMPULSE := 26.0

var prop: TrackProp
var radius_px: float = 20.0

var _rng_seed: int = 0
var _hit_cooldown: float = 0.0
## Cars currently touching, so one collision is priced once rather than every
## physics step it lasts.
var _touching: Dictionary = {}


static func create(p_prop: TrackProp, position_px: Vector2, angle: float,
		scale_factor: float, seed_value: int) -> PropInstance:
	var node := PropInstance.new()
	node.prop = p_prop
	node.position = position_px
	node.rotation = angle
	node.radius_px = p_prop.radius_m * scale_factor * GameConfig.PIXELS_PER_METRE
	node._rng_seed = seed_value
	return node


func _ready() -> void:
	mass = maxf(prop.mass_kg, 1.0)
	# Props sit on the world layer so cars hit them, but they do not collide
	# with each other: a row of cones nudging itself apart is noise.
	collision_layer = 1
	collision_mask = 2
	gravity_scale = 0.0
	linear_damp = 3.5
	angular_damp = 5.0
	contact_monitor = true
	max_contacts_reported = 4
	if not prop.movable:
		freeze = true
		freeze_mode = RigidBody2D.FREEZE_MODE_STATIC

	var shape := CircleShape2D.new()
	shape.radius = radius_px
	var collider := CollisionShape2D.new()
	collider.shape = shape
	add_child(collider)

	var art := PropArt.new()
	art.prop = prop
	art.radius_px = radius_px
	art.seed_value = _rng_seed
	add_child(art)


func _physics_process(delta: float) -> void:
	_hit_cooldown = maxf(_hit_cooldown - delta, 0.0)
	# Newly-formed contacts only. Reading the contact list every step prices a
	# car resting against a bale as a fresh collision sixty times a second.
	var still_touching := {}
	for body in get_colliding_bodies():
		if not body is RallyCar:
			continue
		var car: RallyCar = body
		still_touching[car.get_instance_id()] = true
		if _touching.has(car.get_instance_id()):
			continue
		_apply_hit(car)
	_touching = still_touching


func _apply_hit(car: RallyCar) -> void:
	var speed := car.linear_velocity.length() / GameConfig.PIXELS_PER_METRE
	if speed < MIN_IMPACT_SPEED or _hit_cooldown > 0.0:
		return
	_hit_cooldown = 0.25

	# How hard a hit lands depends on the car as well as the prop: a Group B
	# car swats a hay bale that would stop a Trabant.
	var car_mass := maxf(car.mass, 1.0)
	var authority := prop.mass_kg / (prop.mass_kg + car_mass)
	var direction := (global_position - car.global_position).rotated(-car.rotation)
	car.linear_velocity *= 1.0 - prop.speed_penalty * authority
	if prop.damage > 0.0 and car.damage != null:
		# Priced as an impulse so it goes through the same durability, armour
		# and component routing as any other collision — a hit on the nose has
		# to reach the engine the same way whatever it was against.
		var impulse := prop.damage * authority * car_mass * speed * DAMAGE_TO_IMPULSE
		car.damage.apply_impact(impulse, direction)
	EventBus.prop_struck.emit(car.car_id, prop.id, speed)


## The drawn half of a prop, kept separate so the body can move it without the
## drawing code knowing anything about physics.
class PropArt extends Node2D:
	var prop: TrackProp
	var radius_px: float = 20.0
	var seed_value: int = 0

	func _draw() -> void:
		if prop != null:
			prop.draw_at(self, Vector2.ZERO, 0.0, radius_px, seed_value)
