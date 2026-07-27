class_name Axle
extends RefCounted
## One axle's wheels, with their own rotational state.
##
## The car used to apply brake force straight to the chassis, which meant a
## wheel could never lock: there was nothing to lock. Tracking wheel speed
## separately from road speed is what makes the interesting failures exist —
## lock-up under braking, wheelspin on power, and the electronics that stop
## both.
##
## Longitudinal force comes from *slip ratio* (how far the tread is sliding
## against the road) rather than from whatever the driver asked for. Ask for
## more than the tire can give and you do not get it; you get a locked wheel
## that stops less well and does not steer.

## Slip ratio ABS aims to hold. Peak braking force is around 10-15% slip; a
## fully locked wheel sits at -1.0 and stops noticeably worse.
const ABS_TARGET_SLIP := -0.11
## PI trim on top of the feed-forward, on slip error.
##
## A bang-bang controller looks right and stops worse than no ABS at all:
## dumping pressure the moment the wheel starts to lock lets it spin back up to
## zero slip, where a tyre makes no longitudinal force whatsoever. Proportional
## alone cannot hold a steady pressure either — its output is zero at the
## setpoint — and a large proportional gain simply drives the loop into
## oscillation, which costs stopping distance because the force curve is not
## symmetric about the peak. Feed-forward does the bulk, the integral holds the
## trim, and the proportional term is deliberately small.
const ABS_P_GAIN := 0.5
const ABS_I_GAIN := 25.0
## How quickly pressure follows the controller's demand.
const ABS_SLEW := 100.0
## Deliberate valve cycling, in Hz. Real ABS pulses because the hydraulics are
## bang-bang; keeping that here gives the trigger something honest to follow.
const ABS_PULSE_HZ := 14.0
const ABS_PULSE_DEPTH := 0.04
## Slip ratio past which a wheel counts as locked, for feedback purposes.
const LOCK_SLIP := -0.55
## Slip ratio past which it counts as spinning.
const SPIN_SLIP := 0.30
## Traction control targets a little wheelspin, not none — some slip is how a
## car actually puts power down, especially on gravel.
const TC_TARGET_SLIP := 0.18
const TC_CUT_RATE := 14.0
const TC_RESTORE_RATE := 5.0

## Below this road speed the slip-ratio model is numerically stiff, so it fades
## out and the axle just follows the road.
const LOW_SPEED_MS := 2.0

var is_front: bool = false
var radius: float = 0.32
## Wheel plus (for a driven axle) the driveline reflected through the gearing.
var inertia: float = 2.2

# --- State ---
var omega: float = 0.0          ## wheel angular speed, rad/s
var slip_ratio: float = 0.0
var slip_angle: float = 0.0
var force_long: float = 0.0     ## last longitudinal force produced, N
var force_lat: float = 0.0      ## last lateral force produced, N
## Magnitude of the combined slip vector, normalised so 1.0 is the grip peak.
var slip_magnitude: float = 0.0

# --- Feedback flags, read by the HUD and the haptics ---
var locked: bool = false
var spinning: bool = false
var abs_active: bool = false
var tc_active: bool = false
## 0 = full brake pressure, 1 = fully released. Oscillates while ABS works,
## which is exactly the signal the trigger effect wants.
var abs_release: float = 0.0
var tc_cut: float = 0.0

var _abs_phase: float = 0.0
var _abs_integral: float = 0.0


func _init(p_is_front: bool, p_radius: float) -> void:
	is_front = p_is_front
	radius = p_radius


## Match wheel speed to road speed. Used on spawn and respawn so the car does
## not start life with its wheels locked.
func sync_to_road(forward_speed: float) -> void:
	omega = forward_speed / maxf(radius, 0.05)
	slip_ratio = 0.0
	locked = false
	spinning = false
	abs_active = false
	tc_active = false
	abs_release = 0.0
	tc_cut = 0.0


## Effective rotational inertia, including the engine and gearbox when this
## axle is driven and the clutch is engaged. Reflected inertia scales with the
## square of the gear ratio, which is why first gear feels so much heavier and
## why a car does not simply light its tyres up in top.
func effective_inertia(gear_ratio: float, clutch: float, torque_share: float) -> float:
	const ENGINE_INERTIA := 0.22
	var reflected := ENGINE_INERTIA * gear_ratio * gear_ratio * clutch * torque_share
	return inertia + absf(reflected)


## Integrate one step and return the longitudinal force at the contact patch.
##
## drive_torque and brake_torque are at the wheel, in Nm. mu is the available
## longitudinal friction coefficient, load the vertical force in N.
## Integrate one step and return the contact-patch force in the wheel's own
## frame: x forward, y lateral.
##
## Longitudinal and lateral are solved *together* from one combined slip
## vector, not separately. That matters: a tyre opposes the direction it is
## actually sliding, so a locked wheel — sliding almost purely backwards
## relative to the road — puts essentially all of its friction into the
## longitudinal axis and has nothing left to steer with. Solving the two axes
## independently and capping them afterwards leaves a locked wheel with most of
## its cornering force intact, which is both wrong and much less interesting.
##
## handbrake_torque is deliberately separate: the handbrake is a cable to the
## rear calipers with no electronics on it, which is exactly why yanking it
## still breaks the tail loose on a car whose ABS would never allow it.
func update(
	delta: float,
	forward_speed: float,
	p_slip_angle: float,
	drive_torque: float,
	brake_torque: float,
	handbrake_torque: float,
	mu_long: float,
	mu_lat: float,
	load: float,
	stats: VehicleStats,
	gear_ratio: float,
	clutch: float,
	torque_share: float
) -> Vector2:
	var i_eff := effective_inertia(gear_ratio, clutch, torque_share)
	slip_angle = p_slip_angle

	# --- Slip ratio ---------------------------------------------------------
	# Guarded denominator: at a standstill slip ratio is undefined and an
	# unguarded division makes the model explode on the grid.
	var v_ref := maxf(absf(forward_speed), LOW_SPEED_MS)
	var wheel_speed := omega * radius
	slip_ratio = clampf((wheel_speed - forward_speed) / v_ref, -2.0, 2.0)

	# --- Electronics --------------------------------------------------------
	# Roughly the most torque this tyre can take before it starts sliding.
	# Feeding it to the ABS lets the controller release the surplus pressure
	# immediately instead of discovering it through feedback.
	var grip_torque := mu_long * load * radius
	brake_torque = _apply_abs(delta, brake_torque, grip_torque, stats) + handbrake_torque
	drive_torque = _apply_traction_control(delta, drive_torque, stats)

	# --- Combined slip ------------------------------------------------------
	# Both axes normalised by their own peak, so the pair can be treated as one
	# vector even though they are measured in different units.
	var peak_ratio := TireModel.BASE_PEAK_SLIP_RATIO * stats.slip_forgiveness
	var peak_angle := TireModel.BASE_PEAK_SLIP_ANGLE * stats.slip_forgiveness
	# The lateral term is negated because the two standard slip conventions
	# point opposite ways: positive slip ratio drives the car forwards, while
	# positive slip angle must be opposed.
	var s := Vector2(
		slip_ratio / peak_ratio,
		-tan(clampf(slip_angle, -1.4, 1.4)) / peak_angle)
	slip_magnitude = s.length()

	var forces := Vector2.ZERO
	if slip_magnitude > 0.0001:
		# One force magnitude for the whole contact patch, split between the
		# axes by the direction the tread is actually sliding.
		var magnitude := TireModel.curve(slip_magnitude, stats.drift_release) * load
		var direction := s / slip_magnitude
		forces = Vector2(direction.x * magnitude * mu_long, direction.y * magnitude * mu_lat)
	force_long = forces.x
	force_lat = forces.y

	# --- Wheel torque balance ----------------------------------------------
	# The tyre's reaction resists whatever the driveline is doing to the wheel.
	var tire_torque := force_long * radius
	var omega_free := omega + (drive_torque - tire_torque) / maxf(i_eff, 0.05) * delta

	# Brakes oppose rotation but must never reverse it — a brake cannot drive a
	# wheel backwards, it can only stop it.
	if brake_torque > 0.0:
		var decel := brake_torque / maxf(i_eff, 0.05) * delta
		if absf(omega_free) <= decel:
			omega_free = 0.0
		else:
			omega_free -= signf(omega_free) * decel

	omega = omega_free

	locked = slip_ratio < LOCK_SLIP and absf(forward_speed) > LOW_SPEED_MS
	spinning = slip_ratio > SPIN_SLIP and absf(forward_speed) > 0.5
	return forces


## ABS regulates brake pressure to hold the wheel just past its grip peak,
## rather than simply letting go whenever it starts to lock.
func _apply_abs(
	delta: float,
	brake_torque: float,
	grip_torque: float,
	stats: VehicleStats
) -> float:
	if stats.abs_strength <= 0.0 or brake_torque <= 0.0:
		abs_active = false
		abs_release = move_toward(abs_release, 0.0, delta * ABS_SLEW)
		_abs_phase = 0.0
		_abs_integral = 0.0
		return brake_torque

	# Feed-forward: dump the pressure that provably exceeds what the tyre can
	# hold. Without this the integrator has to discover the same number by
	# trial, and it spends the first half-second of every stop with the wheel
	# sliding far past its peak — long enough to lose most of the advantage
	# ABS is supposed to give.
	var surplus := clampf((brake_torque - grip_torque) / maxf(brake_torque, 1.0), 0.0, 1.0)

	# Positive error means the wheel is sliding more than we want.
	var error := ABS_TARGET_SLIP - slip_ratio
	_abs_integral = clampf(_abs_integral + error * ABS_I_GAIN * delta, -0.4, 0.4)
	var demand := clampf(surplus + _abs_integral + error * ABS_P_GAIN, 0.0, 1.0)

	abs_active = demand > 0.02 or abs_release > 0.02
	if abs_active:
		_abs_phase = fmod(_abs_phase + delta * ABS_PULSE_HZ * TAU, TAU)
		demand = clampf(demand * (1.0 + ABS_PULSE_DEPTH * sin(_abs_phase)), 0.0, 1.0)
	else:
		_abs_phase = 0.0

	abs_release = move_toward(abs_release, demand, delta * ABS_SLEW)
	return brake_torque * (1.0 - abs_release * clampf(stats.abs_strength, 0.0, 1.0))


## Traction control trims engine torque when the driven wheels light up. Like
## ABS it aims for a little slip rather than none, because some wheelspin is
## how a car actually puts power down on a loose surface.
func _apply_traction_control(delta: float, drive_torque: float, stats: VehicleStats) -> float:
	if stats.traction_control <= 0.0 or absf(drive_torque) < 1.0:
		tc_active = false
		tc_cut = move_toward(tc_cut, 0.0, delta * TC_RESTORE_RATE)
		return drive_torque

	if slip_ratio > TC_TARGET_SLIP:
		tc_active = true
		tc_cut = move_toward(tc_cut, 1.0, delta * TC_CUT_RATE)
	else:
		tc_cut = move_toward(tc_cut, 0.0, delta * TC_RESTORE_RATE)
		if tc_cut <= 0.01:
			tc_active = false

	return drive_torque * (1.0 - tc_cut * clampf(stats.traction_control, 0.0, 1.0))


## Share of this axle's force that is doing cornering work, 0..1. Falls towards
## zero as a wheel locks or spins, because a sliding tyre's friction points
## along its slide rather than across it.
func lateral_share() -> float:
	var total := absf(force_long) + absf(force_lat)
	if total < 1.0:
		return 0.0
	return absf(force_lat) / total
