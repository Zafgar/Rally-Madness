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
## Below this speed the slip-angle model is meaningless, so we fade it out.
const LOW_SPEED_MS := 2.5
## The car has to be under this speed, with the brake held, before reverse will
## be considered at all. Walking pace.
const REVERSE_ENGAGE_SPEED := 1.4
## And it has to stay there this long. Braking into a hairpin routinely holds a
## car at a standstill for a couple of tenths before the driver gets back on the
## throttle, so anything shorter than this fires them backwards out of corners.
## Half a second is longer than that overlap and still short enough that asking
## to reverse feels like it answered.
const REVERSE_ENGAGE_DWELL := 0.50
## Air density * 0.5, folded into the drag term.
const DRAG_CONSTANT := 0.6125

@export var car_id: int = 0
@export var is_locally_controlled: bool = true
## Whether holding the brake at a standstill selects reverse. It is a
## convenience for somebody holding a pad, who has no other way to ask; an AI
## that wants reverse selects it. Left on for an AI it is actively harmful,
## because in reverse the brake pedal is what drives the car — a computer
## sitting on the brakes behind a stopped rival would select reverse and then
## drive itself backwards down the stage.
@export var auto_reverse: bool = true

var stats: VehicleStats
var spec: CarSpec
var transmission: Transmission
var engine: EngineModel
var nitro: NitroSystem
var axle_front: Axle
var axle_rear: Axle
var damage: DamageModel
## Wear, heat, fuel and everything that can let go. Nothing in the physics asks
## it questions directly: it hands out a small number of multipliers and the
## rest of the car simply applies them.
var mechanical: MechanicalModel
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
## Times this car has hit another car. Separated from scenery contacts because
## trading paint is a racing problem, not a driving one, and the AI's whole job
## is to keep this number down.
var contacts_with_cars: int = 0

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
## How long the brake has been held at a standstill, which is how reverse is
## asked for in an automatic.
var _reverse_dwell: float = 0.0

## Whether the headlights are on. Set by the race for night stages.
var lights_on: bool = false

var _visual: CarVisual
var _effects: CarEffects
var _audio: CarAudio
var _shadow: Polygon2D
## Where tyre marks are laid. Shared across the race so marks outlive the car
## that made them.
var mark_layer: TireMarks = null

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

	wheel_radius = stats.wheel_radius
	axle_front = Axle.new(true, wheel_radius)
	axle_rear = Axle.new(false, wheel_radius)
	axle_front.inertia = stats.wheel_inertia
	axle_rear.inertia = stats.wheel_inertia

	transmission = Transmission.new(stats)
	engine = EngineModel.new(stats)
	nitro = NitroSystem.new(stats)
	damage = DamageModel.new(stats)
	if not saved_damage.is_empty():
		damage.restore(saved_damage)
	mechanical = MechanicalModel.new(stats, damage)
	mechanical.boost_setting = float(loadout.setup.get("boost_pressure", 0.0))
	mechanical.rev_limit_setting = float(loadout.setup.get("rev_limit", 0.0))

	_build_appearance(loadout)
	_build_audio(loadout)
	transmission.gear_changed.connect(_on_gear_changed)
	nitro.overheating.connect(func(amount): damage.apply("engine", amount))
	nitro.state_changed.connect(func(c, a): EventBus.nitro_state_changed.emit(car_id, c, a))
	damage.damaged.connect(func(part, amt, rem): EventBus.car_damaged.emit(car_id, part, amt, rem))
	damage.caught_fire.connect(func(): EventBus.car_caught_fire.emit(car_id))
	damage.wrecked_out.connect(_on_wrecked)
	mechanical.failure.connect(_on_mechanical_failure)
	mechanical.oil_dropped.connect(_on_oil_dropped)

	if is_inside_tree():
		_apply_stats_to_body()


## Every voice this car has, baked from the same numbers that drive it.
##
## Baking takes a moment, so it happens here — once, when the car is built —
## rather than during the race. Headless runs skip it entirely: a smoke test has
## no speakers and baking twelve engines for nobody is a waste of several
## seconds on every run.
func _build_audio(loadout: TuningLoadout) -> void:
	if _audio != null:
		_audio.queue_free()
		_audio = null
	if not GameConfig.audio_enabled():
		return
	var layout := spec.engine_layout if spec != null else null
	if layout == null:
		layout = EngineLayout.new()
	_audio = CarAudio.new()
	_audio.name = "Audio"
	add_child(_audio)
	_audio.setup(self, layout, loadout)


## Body, wheels, particles and lights, all sized from the car's own numbers.
func _build_appearance(loadout: TuningLoadout) -> void:
	for old in [_visual, _effects, _shadow, _audio]:
		if old != null:
			old.queue_free()

	_shadow = Polygon2D.new()
	_shadow.color = Color(0, 0, 0, 0.32)
	_shadow.z_index = -2
	add_child(_shadow)

	_visual = CarVisual.new()
	_visual.name = "Visual"
	add_child(_visual)
	_visual.setup(spec, stats, loadout.paint_color if loadout else Color(0.85, 0.2, 0.15))

	_effects = CarEffects.new()
	_effects.name = "Effects"
	add_child(_effects)
	_effects.setup(stats)

	# The shadow and the collision box are the bodywork, so they come from the
	# thing that draws the bodywork. They used to be their own guesses at the
	# same numbers, which is a guarantee that one day they will disagree with
	# what is on screen — and they did.
	var body := _visual.body_size() * 0.5
	var half_l := body.x
	var half_w := body.y
	_shadow.polygon = PackedVector2Array([
		Vector2(-half_l, -half_w), Vector2(half_l, -half_w),
		Vector2(half_l, half_w), Vector2(-half_l, half_w)])

	# The collision box has to match what the player can see, or cars will
	# bounce off each other before they touch.
	var shape := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape != null and shape.shape is RectangleShape2D:
		var box := RectangleShape2D.new()
		box.size = Vector2(half_l * 2.0, half_w * 2.0)
		shape.shape = box


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
	if command.toggle_lights:
		lights_on = not lights_on
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
	# Gear selection reads the raw pedals, before they are swapped below.
	_auto_engage_gear(delta, v_local.x, throttle, brake)

	# In an automatic, once reverse is selected the brake pedal is what drives
	# the car. Without this, holding the brake at a standstill engaged reverse
	# and then held the car still with the brakes — the gear was right and
	# nothing moved, which is exactly what it looked like.
	if transmission.mode == Transmission.Mode.AUTOMATIC and transmission.gear < 0:
		var reverse_drive := brake
		brake = throttle   # and the accelerator becomes the brake, as it must
		throttle = reverse_drive

	engine.update_boost(delta, transmission.rpm, throttle)
	var nitro_mult := nitro.update(delta, command.nitro, throttle)

	# Revs come off the driven wheels, not the road, so wheelspin actually
	# revs the engine.
	var front_share := stats.front_torque_share()
	var driven_omega := axle_front.omega * front_share + axle_rear.omega * (1.0 - front_share)
	transmission.update(delta, driven_omega, v_local.x, throttle)

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

	# Grip per axle rather than per car, because a puncture happens at one end
	# and a car with a flat front and a car with a flat rear are two completely
	# different problems to drive.
	var tire_health: float = damage.integrity["tires"]
	var grip_front := tire_health * mechanical.axle_grip_multiplier(0)
	var grip_rear := tire_health * mechanical.axle_grip_multiplier(1)
	mu_lat_f *= grip_front
	mu_lat_r *= grip_rear
	mu_long_f *= grip_front
	mu_long_r *= grip_rear

	# --- Driveline torque ---------------------------------------------------
	# An electronic limiter simply stops fuelling. Nothing else changes, which
	# is why a limited car still pulls hard right up to the wall.
	if stats.speed_limiter_kmh > 0.0 and speed_ms * 3.6 > stats.speed_limiter_kmh:
		throttle = 0.0
	# The rev limiter is a setting, not a constant: raising it is one of the two
	# ways a player buys power with reliability.
	if transmission.rpm > mechanical.effective_redline():
		throttle = 0.0
	var crank_torque := engine.output_torque(transmission.rpm, throttle, nitro_mult)
	# Everything the machine has to say about how much power there is right now
	# arrives as two multipliers: what the boost setting adds, and what is
	# currently broken or too hot.
	crank_torque *= mechanical.boost_gain() * mechanical.power_multiplier()
	var ratio := transmission.gear_ratio()
	var wheel_torque := crank_torque * ratio * transmission.clutch * DRIVELINE_EFFICIENCY

	# Engine braking only reaches the ground through the driven wheels.
	var engine_brake := engine.braking_torque(transmission.rpm, throttle)
	if not is_zero_approx(ratio):
		wheel_torque -= signf(driven_omega) * engine_brake * absf(ratio)

	# --- Brake torque -------------------------------------------------------
	var max_brake_torque := stats.max_brake_torque() * tire_health \
		* mechanical.brake_multiplier()
	var brake_front := brake * max_brake_torque * stats.brake_bias_front
	var brake_rear := brake * max_brake_torque * (1.0 - stats.brake_bias_front)

	# The handbrake is a cable straight to the rear calipers. It bypasses ABS,
	# which is exactly why yanking it still steps the tail out on a car whose
	# ABS would never let the brake pedal do the same.
	var handbrake_rear := 0.0
	if command.handbrake:
		handbrake_rear = max_brake_torque * 0.85 * stats.handbrake_lock

	# --- Axles --------------------------------------------------------------
	# Each axle solves its own combined slip and hands back both force
	# components at once. The force is whatever the tyre actually produces at
	# its current slip, not what the driver asked for — ask for more than it
	# can give and you get a locked wheel that stops worse and steers not at
	# all, because its grip has all gone into the slide.
	var force_front := axle_front.update(
		delta, v_local.x, slip_angle_front,
		wheel_torque * front_share, brake_front, 0.0,
		mu_long_f, mu_lat_f, load_front,
		stats, ratio, transmission.clutch, front_share)
	var force_rear := axle_rear.update(
		delta, v_local.x, slip_angle_rear,
		wheel_torque * (1.0 - front_share), brake_rear, handbrake_rear,
		mu_long_r, mu_lat_r, load_rear,
		stats, ratio, transmission.clutch, 1.0 - front_share)

	# The low-speed fade applies to cornering force only. Fading the
	# longitudinal component too would mean the car could never pull away from
	# a standstill — there would be no force left to move it.
	var fx_front := force_front.x
	var fy_front := force_front.y * model_blend
	var fx_rear := force_rear.x
	var fy_rear := force_rear.y * model_blend

	# --- Resistances --------------------------------------------------------
	var surface_drag: float = TireModel.SURFACE_DRAG.get(surface, 1.0)
	var rolling := stats.rolling_resistance * surface_drag * total_load * signf(v_local.x)
	var drag := DRAG_CONSTANT * stats.drag_area * speed_ms * speed_ms * signf(v_local.x)
	var flat := mechanical.puncture_drag() * signf(v_local.x)
	var resistance := -(rolling + drag + flat)

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
	# Sliding tread wears whether it is sliding sideways, spinning up or locked
	# solid — a flat-spotted tyre from one big lock-up is a real outcome.
	var longitudinal_scrub := absf(axle_front.slip_ratio) + absf(axle_rear.slip_ratio)
	damage.apply_tire_wear(delta, wheel_slip + longitudinal_scrub, surface_drag)

	# Sliding sideways at speed on gravel rewards nitro on bottles that regen.
	if is_drifting:
		nitro.award(delta * 3.0 * minf(absf(slip_angle_rear), 0.8))

	# The machine's own housekeeping: fuel, heat, wear, and the dice that decide
	# whether any of it has finally had enough.
	var load_fraction := clampf(throttle * engine.torque_fraction(transmission.rpm), 0.0, 1.0)
	var power_w := absf(crank_torque) * transmission.rpm * TAU / 60.0
	mechanical.update(delta, absf(v_local.x), transmission.rpm, load_fraction,
		power_w, _rng, global_position)


## Standing still: decide direction from the pedals rather than making the
## player select reverse manually in an automatic.
##
## Reverse needs a moment of held brake before it engages, and that dwell is
## not a nicety. Braking hard into a hairpin takes the car through walking pace
## with the brake buried, and without the dwell it would select reverse there
## and — since the brake pedal drives the car in reverse — fire it backwards out
## of the corner. Forward has no such wait: pulling away should be instant.
func _auto_engage_gear(delta: float, forward_speed: float, throttle: float,
		brake: float) -> void:
	if transmission.mode != Transmission.Mode.AUTOMATIC:
		return
	# Asked for outright. No dwell and no speed condition beyond the one below,
	# because a driver who has said "reverse" has already made the decision the
	# dwell exists to confirm.
	if command.request_reverse:
		if absf(forward_speed) < REVERSE_ENGAGE_SPEED:
			transmission.engage_for(-1)
		return
	if not auto_reverse:
		_reverse_dwell = 0.0
	elif absf(forward_speed) > REVERSE_ENGAGE_SPEED or throttle > 0.1:
		_reverse_dwell = 0.0
	elif brake > 0.5:
		_reverse_dwell += delta

	if absf(forward_speed) > 1.0:
		return
	if throttle > 0.1:
		transmission.engage_for(1)
	elif auto_reverse and brake > 0.5 and _reverse_dwell >= REVERSE_ENGAGE_DWELL:
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

	# Wheels are still turning up here, just with nothing to push against. That
	# is why a car lands with its wheels already spun up if the driver kept
	# their foot in — and why it snaps sideways if they did.
	var ratio := transmission.gear_ratio()
	var front_share := stats.front_torque_share()
	var crank := engine.output_torque(transmission.rpm, command.throttle)
	var free_torque := crank * ratio * transmission.clutch * DRIVELINE_EFFICIENCY
	# Zero load means zero force: the wheels turn but nothing pushes back.
	axle_front.update(delta, v_local.x, 0.0, free_torque * front_share, 0.0, 0.0,
		0.0, 0.0, 0.0, stats, ratio, transmission.clutch, front_share)
	axle_rear.update(delta, v_local.x, 0.0, free_torque * (1.0 - front_share), 0.0, 0.0,
		0.0, 0.0, 0.0, stats, ratio, transmission.clutch, 1.0 - front_share)

	var driven_omega := axle_front.omega * front_share + axle_rear.omega * (1.0 - front_share)
	engine.update_boost(delta, transmission.rpm, command.throttle)
	transmission.update(delta, driven_omega, v_local.x, command.throttle)
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
	if _visual == null:
		return
	# Scaling with height is the classic top-down trick for reading altitude
	# without leaving 2D.
	var lift := 1.0 + height * 0.09
	_visual.scale = Vector2(lift, lift)
	_visual.steer_angle = steer_angle
	_visual.braking = command.brake > 0.15 or wheels_locked()
	_visual.reversing = transmission != null \
		and transmission.gear == Transmission.Gear.REVERSE
	_visual.lights_on = lights_on
	_visual.damage_body = damage.integrity["body"] if damage != null else 1.0
	_visual.queue_redraw()

	if _shadow != null:
		# The shadow separates from the car as it climbs, which is what sells
		# the jump — and it does not grow with the car, it stays on the ground.
		var ppm := GameConfig.PIXELS_PER_METRE
		var drop := height * 0.16 * ppm
		_shadow.position = (Vector2(0.35, 0.62).normalized() * drop).rotated(-rotation)
		_shadow.modulate.a = clampf(1.0 - height * 0.045, 0.25, 1.0)

	if _effects != null:
		_effects.update(self)
	_lay_tire_marks()


## Reports each axle's slip to the mark layer. Marks come out of the same slip
## numbers the tyre forces do, so a locked wheel really does leave the long
## straight line it should.
func _lay_tire_marks() -> void:
	if mark_layer == null or airborne or damage == null or damage.wrecked:
		return
	if speed_ms < 2.0:
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var surface_mark := TireMarks.surface_mark(surface)
	var half_track := stats.track_width_m * 0.5 * ppm

	for axle_data in [[axle_front, stats.cg_to_front_axle(), "f"],
			[axle_rear, -stats.cg_to_rear_axle(), "r"]]:
		var axle: Axle = axle_data[0]
		var along: float = axle_data[1] * ppm
		for side in [-1.0, 1.0]:
			var local := Vector2(along, half_track * side)
			var world: Vector2 = global_position + local.rotated(rotation)
			mark_layer.report(
				"%d:%s%s" % [car_id, axle_data[2], "l" if side < 0.0 else "r"],
				world, axle.slip_magnitude,
				surface_mark["darkness"], surface_mark["tint"])


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
		var hit_a_car := state.get_contact_collider_object(i) is RallyCar
		if hit_a_car:
			contacts_with_cars += 1
		# A car in the air is not scraping anything; the fake Z axis means 2D
		# still reports contacts it should be flying over.
		if not airborne:
			damage.apply_impact(impulse, normal.rotated(-rotation), hit_a_car)
			# Heard on the same scale it is felt: the reference impulse is the
			# one the damage model calls a serious hit.
			if _audio != null:
				_audio.play_impact(clampf(impulse / DamageModel.REFERENCE_IMPULSE,
					0.05, 1.0))

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
	_contacting.clear()
	_prev_velocity = Vector2.ZERO
	# Wheels have to match road speed or the car respawns with them locked.
	if axle_front != null:
		axle_front.sync_to_road(0.0)
		axle_rear.sync_to_road(0.0)
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


# --- Feedback queries -------------------------------------------------------
# Read by the HUD and, more importantly, by the haptics: these are the events a
# driver is supposed to feel through the pad rather than read off a gauge.

func abs_engaged() -> bool:
	return axle_front != null and (axle_front.abs_active or axle_rear.abs_active)


## 0..1 pressure-release signal while ABS works. It oscillates naturally as the
## system bleeds pressure and puts it back, so the trigger effect can follow it
## directly rather than faking a pulse.
func abs_pulse() -> float:
	if axle_front == null:
		return 0.0
	return maxf(axle_front.abs_release, axle_rear.abs_release)


## True when a wheel has stopped turning while the car is still moving. On a
## car without ABS this is what standing on the brakes gets you: a longer stop
## and no steering at all.
func wheels_locked() -> bool:
	return axle_front != null and (axle_front.locked or axle_rear.locked)


func front_locked() -> bool:
	return axle_front != null and axle_front.locked


func wheels_spinning() -> bool:
	return axle_front != null and (axle_front.spinning or axle_rear.spinning)


func traction_control_engaged() -> bool:
	return axle_front != null and (axle_front.tc_active or axle_rear.tc_active)


## Worst longitudinal slip across the axles, signed: negative is locking up,
## positive is spinning up.
## How much the driven wheels are spinning up, 0 upwards. Positive slip only:
## a locked wheel under braking is a different problem with a different answer,
## and folding the two together would have a driver lift off mid-stop.
##
## Only axles that are actually driven count. A front-wheel-drive car sliding
## its rears is not wheelspinning; it is going sideways.
func driven_slip_ratio() -> float:
	if axle_front == null or stats == null:
		return 0.0
	var worst := 0.0
	if stats.front_torque_share() > 0.01:
		worst = maxf(worst, axle_front.slip_ratio)
	if stats.front_torque_share() < 0.99:
		worst = maxf(worst, axle_rear.slip_ratio)
	return maxf(worst, 0.0)


func worst_slip_ratio() -> float:
	if axle_front == null:
		return 0.0
	var f := axle_front.slip_ratio
	var r := axle_rear.slip_ratio
	return f if absf(f) > absf(r) else r


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


## Something let go. The physics has already picked up the consequence through
## the mechanical model's multipliers; this is the part the driver notices.
func _on_mechanical_failure(system: MechanicalModel.System, description: String) -> void:
	EventBus.car_failed.emit(car_id, MechanicalModel.system_name(system), description)
	match system:
		MechanicalModel.System.TURBO:
			# A turbo letting go is a bang and then a lot of smoke, and the
			# power simply is not there any more.
			if _effects != null:
				_effects.burst_smoke(2.5)
		MechanicalModel.System.COOLING:
			if _effects != null:
				_effects.burst_smoke(1.6)
		MechanicalModel.System.ENGINE:
			if _effects != null:
				_effects.burst_smoke(4.0)
		_:
			pass


## Oil on the road. Parented to the track rather than the car, or it would
## follow the car that dropped it.
func _on_oil_dropped(where: Vector2) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var slick := OilSlick.create(where, _rng.randi())
	parent.add_child(slick)


func _on_wrecked(cause: String) -> void:
	wrecked.emit(car_id, cause)
	EventBus.car_wrecked.emit(car_id, cause)
