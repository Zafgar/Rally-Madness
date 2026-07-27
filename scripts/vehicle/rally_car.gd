class_name RallyCar
extends RigidBody2D
## The car. A two-axle (bicycle) model with load transfer, per-axle tire
## forces, a real drivetrain split and a fake Z axis for jumps.
##
## All physics maths is done in SI units — metres, kilograms, newtons — and
## converted to Godot's pixel space only at the point where force is applied.
## That keeps the tuning numbers in the data files meaningful to anyone who has
## looked at a real spec sheet.
##
## The car is driven entirely by a VehicleCommand, so a local pad, a remote
## peer and an AI all feed the same code path.

const GRAVITY := 9.81
## Drivetrain losses between crank and road.
const DRIVELINE_EFFICIENCY := 0.88
## Newtons of braking at full pedal per kilogram of car, before brake_force.
const BRAKE_FORCE_PER_KG := 11.0
## Below this speed the slip-angle model is meaningless, so we fade it out.
const LOW_SPEED_MS := 2.5
## Air density * 0.5, folded into the drag term.
const DRAG_CONSTANT := 0.6125

@export var car_id: int = 0
@export var is_locally_controlled: bool = true

var stats: VehicleStats
var spec: CarSpec
var transmission: Transmission
var engine: EngineModel
var nitro: NitroSystem
var damage: DamageModel
var command := VehicleCommand.new()

## Fake third axis. Everything about jumps lives in these three.
var height: float = 0.0
var vertical_speed: float = 0.0
var airborne: bool = false

var steer_angle: float = 0.0
var wheel_radius: float = 0.32
var surface: TireModel.Surface = TireModel.Surface.TARMAC
## Set by surface zones that overlap; the last one entered wins.
var _surface_stack: Array[int] = []

## Read by the HUD and the drift scoring.
var speed_ms: float = 0.0
var slip_angle_rear: float = 0.0
var slip_angle_front: float = 0.0
var wheel_slip: float = 0.0
var is_drifting: bool = false

## Smoothed longitudinal acceleration, used for load transfer. Reading it a
## frame late is standard practice and far more stable than solving the
## transfer and the tire forces together.
var _last_accel_x: float = 0.0

## Colliders touched last physics step, and the velocity carried into it. Both
## exist so a fresh impact can be told apart from a continuing scrape.
var _contacting: Dictionary = {}
var _prev_velocity := Vector2.ZERO

var _rng := RandomNumberGenerator.new()
var _spawn_transform := Transform2D()
var _respawn_cooldown: float = 0.0

@onready var _visual: Node2D = $Visual if has_node("Visual") else null
@onready var _shadow: Node2D = $Shadow if has_node("Shadow") else null

signal wrecked(car_id: int, cause: String)
signal landed(car_id: int, impact: float)


func _ready() -> void:
	_rng.randomize()
	contact_monitor = true
	max_contacts_reported = 4
	can_sleep = false
	gravity_scale = 0.0
	linear_damp = 0.0
	angular_damp = 0.0
	_spawn_transform = global_transform
	if stats != null:
		_apply_stats_to_body()


## Called before the car enters the tree, or whenever parts change in the pits.
func configure(p_spec: CarSpec, loadout: TuningLoadout, saved_damage: Dictionary = {}) -> void:
	spec = p_spec
	stats = TuningCalculator.resolve(p_spec, loadout, saved_damage)

	transmission = Transmission.new(stats)
	engine = EngineModel.new(stats)
	nitro = NitroSystem.new(stats)
	damage = DamageModel.new(stats)
	if not saved_damage.is_empty():
		damage.restore(saved_damage)

	transmission.gear_changed.connect(_on_gear_changed)
	nitro.overheating.connect(func(amount): damage.apply("engine", amount))
	nitro.state_changed.connect(func(c, a): EventBus.nitro_state_changed.emit(car_id, c, a))
	damage.damaged.connect(func(part, amt, rem): EventBus.car_damaged.emit(car_id, part, amt, rem))
	damage.caught_fire.connect(func(): EventBus.car_caught_fire.emit(car_id))
	damage.wrecked_out.connect(_on_wrecked)

	if is_inside_tree():
		_apply_stats_to_body()


func _apply_stats_to_body() -> void:
	mass = stats.mass_kg
	# Godot would derive inertia from the collision shape, but the shape is a
	# rough box and we want it to follow the tuned wheelbase and track instead.
	var l := stats.wheelbase_m
	var w := stats.track_width_m
	var inertia_si := stats.mass_kg * (l * l + w * w) / 12.0
	inertia = inertia_si * GameConfig.PIXELS_PER_METRE * GameConfig.PIXELS_PER_METRE
	center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector2.ZERO


func _physics_process(delta: float) -> void:
	if _respawn_cooldown > 0.0:
		_respawn_cooldown -= delta
	if command.respawn and _respawn_cooldown <= 0.0:
		respawn()
	_update_height(delta)
	_update_visual()
	if damage != null:
		damage.update(delta, _rng)


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if stats == null:
		return
	var delta := state.step

	var v_world_px := state.linear_velocity
	var v_local := (v_world_px / GameConfig.PIXELS_PER_METRE).rotated(-rotation)
	var omega := state.angular_velocity
	speed_ms = v_local.length()

	_read_collisions(state)

	if damage.wrecked:
		_apply_wrecked_drag(state, v_local)
		return

	_update_steering(delta, v_local.x)

	if airborne:
		_integrate_airborne(state, delta, v_local, omega)
		return

	_integrate_grounded(state, delta, v_local, omega)


# --- Steering ---------------------------------------------------------------

## The wheels do not snap to the stick. They move toward it at a rate the car's
## steering rack allows, and the available lock shrinks with speed so that a
## flick of the stick at 180 km/h does not simply spin the car.
func _update_steering(delta: float, forward_speed: float) -> void:
	var speed_factor := clampf(absf(forward_speed) / 45.0, 0.0, 1.0)
	var available_lock := deg_to_rad(stats.max_steer_deg) \
		* lerpf(1.0, 1.0 - stats.steering_speed_falloff, speed_factor)
	var target := command.steer * available_lock
	# Returning to centre is quicker than adding lock, which is what the
	# self-centring of a real rack feels like on a pad.
	var rate := stats.steering_rate
	if absf(target) < absf(steer_angle):
		rate *= 1.7
	steer_angle = move_toward(steer_angle, target, rate * available_lock * delta)


# --- Grounded physics -------------------------------------------------------

func _integrate_grounded(
	state: PhysicsDirectBodyState2D,
	delta: float,
	v_local: Vector2,
	omega: float
) -> void:
	var a_front := stats.cg_to_front_axle()
	var b_rear := stats.cg_to_rear_axle()
	var wheelbase := stats.wheelbase_m

	var throttle := command.throttle
	var brake := command.brake
	# Reverse needs no special case downstream: the gear ratio itself is
	# negative, so drive force comes out pointing backwards on its own.
	_auto_engage_gear(v_local.x, throttle, brake)

	engine.update_boost(delta, transmission.rpm, throttle)
	var nitro_mult := nitro.update(delta, command.nitro, throttle)
	transmission.update(delta, v_local.x, wheel_radius, throttle)

	# --- Vertical loads -----------------------------------------------------
	var weight := stats.mass_kg * GRAVITY
	var aero_load := stats.downforce * speed_ms * speed_ms
	var total_load := weight + aero_load

	# Longitudinal acceleration from the previous frame drives load transfer.
	var accel_x := _last_accel_x
	var transfer := stats.mass_kg * accel_x * stats.cg_height_m / wheelbase
	var load_front := maxf(total_load * stats.weight_bias_front - transfer, total_load * 0.05)
	var load_rear := maxf(total_load * (1.0 - stats.weight_bias_front) + transfer, total_load * 0.05)

	# --- Slip angles --------------------------------------------------------
	# Guarded denominator: at a standstill the slip angle is undefined, and an
	# unguarded atan2 makes the car twitch on the grid.
	var vx_ref := maxf(absf(v_local.x), LOW_SPEED_MS)
	var lat_front := v_local.y + omega * a_front
	var lat_rear := v_local.y - omega * b_rear

	var steer_sign := signf(v_local.x) if absf(v_local.x) > 0.5 else 1.0
	slip_angle_front = atan2(lat_front, vx_ref) - steer_angle * steer_sign
	slip_angle_rear = atan2(lat_rear, vx_ref)

	# Fade the whole tire model in from a standstill so the car does not fight
	# itself while creeping.
	var model_blend := clampf(speed_ms / LOW_SPEED_MS, 0.0, 1.0)

	# --- Grip budget per axle ----------------------------------------------
	var balance_f := stats.grip_balance_front * 2.0
	var balance_r := (1.0 - stats.grip_balance_front) * 2.0
	var mu_lat_f := TireModel.surface_mu(stats, surface, true) * balance_f
	var mu_lat_r := TireModel.surface_mu(stats, surface, true) * balance_r
	var mu_long_f := TireModel.surface_mu(stats, surface, false) * balance_f
	var mu_long_r := TireModel.surface_mu(stats, surface, false) * balance_r

	var tire_health: float = damage.integrity["tires"]
	mu_lat_f *= tire_health
	mu_lat_r *= tire_health
	mu_long_f *= tire_health
	mu_long_r *= tire_health

	# --- Lateral forces -----------------------------------------------------
	var fy_front := TireModel.lateral(slip_angle_front, stats) * mu_lat_f * load_front * model_blend
	var fy_rear := TireModel.lateral(slip_angle_rear, stats) * mu_lat_r * load_rear * model_blend

	# --- Drive force --------------------------------------------------------
	var crank_torque := engine.output_torque(transmission.rpm, throttle, nitro_mult)
	var ratio := transmission.gear_ratio()
	var wheel_torque := crank_torque * ratio * transmission.clutch * DRIVELINE_EFFICIENCY
	var drive_force := wheel_torque / maxf(wheel_radius, 0.05)

	# Engine braking only reaches the ground through the driven wheels.
	var engine_brake := engine.braking_torque(transmission.rpm, throttle)
	if not is_zero_approx(ratio):
		drive_force -= signf(v_local.x) * engine_brake * absf(ratio) / maxf(wheel_radius, 0.05)

	var front_share := stats.front_torque_share()
	var fx_front := drive_force * front_share
	var fx_rear := drive_force * (1.0 - front_share)

	# --- Braking ------------------------------------------------------------
	var max_brake := stats.mass_kg * BRAKE_FORCE_PER_KG * stats.brake_force
	var brake_total := brake * max_brake * tire_health
	var brake_dir := -signf(v_local.x) if absf(v_local.x) > 0.2 else 0.0
	fx_front += brake_dir * brake_total * stats.brake_bias_front
	fx_rear += brake_dir * brake_total * (1.0 - stats.brake_bias_front)

	# --- Handbrake ----------------------------------------------------------
	# A locked rear axle can make no lateral force worth the name. That is the
	# whole trick: yank it, the tail steps out, and the car rotates.
	if command.handbrake:
		var lock := stats.handbrake_lock
		fx_rear += brake_dir * max_brake * 0.75 * lock
		fy_rear *= 1.0 - lock * 0.82

	# --- Combined slip ------------------------------------------------------
	var limit_f := TireModel.combined_limit(
		fx_front, fy_front, mu_long_f * load_front, mu_lat_f * load_front)
	var limit_r := TireModel.combined_limit(
		fx_rear, fy_rear, mu_long_r * load_rear, mu_lat_r * load_rear)
	fx_front *= limit_f
	fy_front *= limit_f
	fx_rear *= limit_r
	fy_rear *= limit_r

	# --- Resistances --------------------------------------------------------
	var surface_drag: float = TireModel.SURFACE_DRAG.get(surface, 1.0)
	var rolling := stats.rolling_resistance * surface_drag * total_load * signf(v_local.x)
	var drag := DRAG_CONSTANT * stats.drag_area * speed_ms * speed_ms * signf(v_local.x)
	var resistance := -(rolling + drag)

	# --- Assemble and apply -------------------------------------------------
	# The front force acts along the steered wheel, so it rotates with it.
	var front_force := Vector2(fx_front, fy_front).rotated(steer_angle)
	var rear_force := Vector2(fx_rear, fy_rear)

	var ppm := GameConfig.PIXELS_PER_METRE
	var front_offset := Vector2(a_front, 0.0).rotated(rotation) * ppm
	var rear_offset := Vector2(-b_rear, 0.0).rotated(rotation) * ppm

	state.apply_force(front_force.rotated(rotation) * ppm, front_offset)
	state.apply_force(rear_force.rotated(rotation) * ppm, rear_offset)
	state.apply_central_force(Vector2(resistance, 0.0).rotated(rotation) * ppm)

	# Yaw damping. Without it the model is technically correct and practically
	# unplayable — small oscillations never settle on a pad.
	var yaw_damp := -omega * stats.mass_kg * 0.9 * ppm
	state.apply_torque(yaw_damp)

	# --- Bookkeeping --------------------------------------------------------
	var net_x := (fx_front + fx_rear + resistance) / stats.mass_kg
	_last_accel_x = lerpf(_last_accel_x, net_x, clampf(delta * 12.0, 0.0, 1.0))

	wheel_slip = absf(slip_angle_rear) + absf(slip_angle_front)
	is_drifting = absf(slip_angle_rear) > 0.22 and speed_ms > 6.0
	damage.apply_tire_wear(delta, wheel_slip, surface_drag)

	# Sliding sideways at speed on gravel rewards nitro on bottles that regen.
	if is_drifting:
		nitro.award(delta * 3.0 * minf(absf(slip_angle_rear), 0.8))


func _auto_engage_gear(forward_speed: float, throttle: float, brake: float) -> void:
	# Standing still: decide direction from the pedals rather than making the
	# player select reverse manually in an automatic.
	if absf(forward_speed) > 1.0:
		return
	if transmission.mode != Transmission.Mode.AUTOMATIC:
		return
	if throttle > 0.1:
		transmission.engage_for(1)
	elif brake > 0.5:
		transmission.engage_for(-1)


# --- Airborne physics -------------------------------------------------------

func _integrate_airborne(
	state: PhysicsDirectBodyState2D,
	delta: float,
	v_local: Vector2,
	omega: float
) -> void:
	# No tires on the ground, so no grip, no drive and no braking. All the
	# player keeps is a little yaw authority and whatever momentum they left
	# the ramp with.
	var ppm := GameConfig.PIXELS_PER_METRE
	var drag := DRAG_CONSTANT * stats.drag_area * speed_ms * speed_ms * signf(v_local.x)
	state.apply_central_force(Vector2(-drag, 0.0).rotated(rotation) * ppm)

	# Air control: enough to line up a landing, not enough to steer mid-flight.
	var air_yaw := command.steer * stats.mass_kg * 1.6 * ppm
	state.apply_torque(air_yaw)
	state.apply_torque(-omega * stats.mass_kg * 0.25 * ppm)

	engine.update_boost(delta, transmission.rpm, command.throttle)
	transmission.update(delta, v_local.x, wheel_radius, command.throttle)
	_last_accel_x = 0.0


func _update_height(delta: float) -> void:
	if not airborne and height <= 0.0:
		return
	vertical_speed -= GameConfig.JUMP_GRAVITY * delta
	height += vertical_speed * delta
	if height <= 0.0:
		var impact := absf(vertical_speed)
		height = 0.0
		vertical_speed = 0.0
		airborne = false
		if damage != null:
			damage.apply_landing(impact)
		landed.emit(car_id, impact)
		EventBus.car_landed.emit(car_id, impact)
		# A clean landing — nose straight, wheels pointed where you are going —
		# is worth something.
		if impact < GameConfig.SAFE_LANDING_SPEED and absf(slip_angle_rear) < 0.2:
			nitro.award(8.0)


## Called by ramps. `launch_speed` is vertical, in m/s.
func launch(launch_speed: float) -> void:
	vertical_speed = maxf(vertical_speed, launch_speed)
	airborne = true
	height = maxf(height, 0.01)


func _update_visual() -> void:
	if _visual != null:
		# Scaling the sprite with height is the classic top-down trick for
		# reading altitude without leaving 2D.
		var s := 1.0 + height * 0.09
		_visual.scale = Vector2(s, s)
	if _shadow != null:
		_shadow.position = Vector2(height * 2.2, height * 2.2)
		_shadow.modulate.a = clampf(0.45 - height * 0.03, 0.08, 0.45)


# --- Collisions -------------------------------------------------------------

## Damage comes from *arriving* at a collision, not from resting against one.
##
## Reading the per-step contact impulse looks like the obvious approach and is
## wrong: a car leaning on a barrier reports an impulse every single tick, so
## scraping a wall would destroy it in seconds. Instead we notice the tick a
## contact first appears and price it from the speed the car carried into it.
## A sustained scrape then costs speed, as it should, but not integrity.
func _read_collisions(state: PhysicsDirectBodyState2D) -> void:
	if damage == null:
		_prev_velocity = state.linear_velocity
		return

	var current := {}
	for i in state.get_contact_count():
		var collider := state.get_contact_collider(i)
		current[collider] = true
		if _contacting.has(collider):
			continue  # already resting against this; not a new impact

		var normal: Vector2 = state.get_contact_local_normal(i)
		# Closing speed along the contact normal, in m/s, from the velocity the
		# car carried in rather than whatever the solver has left it with.
		var approach := -_prev_velocity.dot(normal) / GameConfig.PIXELS_PER_METRE
		if approach <= 0.0:
			continue
		var impulse := mass * approach
		if impulse < GameConfig.CRASH_IMPULSE_THRESHOLD:
			continue
		# A car in the air is not scraping anything; the fake Z axis means 2D
		# still reports contacts it should be flying over.
		if not airborne:
			damage.apply_impact(impulse, normal.rotated(-rotation))

	_contacting = current
	_prev_velocity = state.linear_velocity


func _apply_wrecked_drag(state: PhysicsDirectBodyState2D, v_local: Vector2) -> void:
	# A wreck still slides, it just does not drive. Heavy drag so it comes to
	# rest rather than coasting across the stage.
	var ppm := GameConfig.PIXELS_PER_METRE
	state.apply_central_force(-state.linear_velocity.normalized() * stats.mass_kg * 6.0 * ppm)
	state.apply_torque(-state.angular_velocity * stats.mass_kg * 3.0 * ppm)


# --- Surfaces ---------------------------------------------------------------

func push_surface(s: TireModel.Surface) -> void:
	_surface_stack.append(s)
	surface = s


func pop_surface(s: TireModel.Surface) -> void:
	var idx := _surface_stack.rfind(s)
	if idx >= 0:
		_surface_stack.remove_at(idx)
	surface = _surface_stack.back() if not _surface_stack.is_empty() else TireModel.Surface.TARMAC


# --- Lifecycle --------------------------------------------------------------

func set_spawn(t: Transform2D) -> void:
	_spawn_transform = t
	global_transform = t


func respawn() -> void:
	_respawn_cooldown = 2.0
	global_transform = _spawn_transform
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	height = 0.0
	vertical_speed = 0.0
	airborne = false
	_last_accel_x = 0.0
	if transmission != null:
		transmission.shift_to(0)


func repair_and_reset() -> void:
	if damage != null:
		damage.repair_all()
	if nitro != null:
		nitro.refill()
	respawn()


func speed_kmh() -> float:
	return speed_ms * 3.6


## Applied on clients from the host's snapshot. The body is moved outright
## rather than nudged: the host is authoritative, and a client that quietly
## disagrees about a car's position will disagree about collisions next.
func apply_network_state(
	p_position: Vector2,
	p_rotation: float,
	p_linear: Vector2,
	p_angular: float,
	p_height: float
) -> void:
	global_position = p_position
	rotation = p_rotation
	linear_velocity = p_linear
	angular_velocity = p_angular
	height = p_height
	airborne = height > 0.0


func _on_gear_changed(new_gear: int) -> void:
	EventBus.car_gear_changed.emit(car_id, new_gear)


func _on_wrecked(cause: String) -> void:
	wrecked.emit(car_id, cause)
	EventBus.car_wrecked.emit(car_id, cause)
