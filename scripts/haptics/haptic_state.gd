class_name HapticState
extends RefCounted
## Turns what the car is doing into what the pad should do.
##
## Pure logic with no hardware in it, so the feel design can be reasoned about
## and tested directly: given a car in a given state, these are the numbers the
## pad gets. The backends only translate.
##
## The guiding rule is that every effect must correspond to something real. A
## driver should be able to tell, blindfolded, whether the wheels have locked,
## whether ABS is working, whether the rears are spinning and what the road
## surface is — because each of those is a distinct physical event, not a
## decorative buzz.

# --- Rumble tuning ---
## Godot exposes two motors: a low-frequency one and a high-frequency one. The
## engine is spread between them by revs, which is the standard approximation
## for "frequency" on hardware that only takes two amplitudes.
const ENGINE_IDLE_RUMBLE := 0.06
const ENGINE_MAX_RUMBLE := 0.34
## Extra rumble when the engine is actually pulling rather than coasting.
const ENGINE_LOAD_BONUS := 0.22
## How hard the limiter buzzes.
const REV_LIMIT_RUMBLE := 0.45

const SURFACE_RUMBLE := {
	TireModel.Surface.TARMAC: 0.03,
	TireModel.Surface.DIRT: 0.16,
	TireModel.Surface.GRAVEL: 0.24,
	TireModel.Surface.GRASS: 0.20,
	TireModel.Surface.SNOW: 0.10,
	TireModel.Surface.ICE: 0.04,
	TireModel.Surface.MUD: 0.18,
}
## Speed at which surface texture reaches full strength, m/s.
const SURFACE_REFERENCE_SPEED := 30.0

const WHEELSPIN_RUMBLE := 0.40
const LOCKUP_RUMBLE := 0.35
const SLIDE_RUMBLE := 0.28

## Impacts and landings are transients: they spike and decay rather than
## holding, so a crash reads as a hit and not as a new engine note.
const IMPACT_DECAY := 4.5
const IMPACT_SCALE := 1.6
const LANDING_SCALE := 0.06

# --- Trigger tuning ---
## Baseline pedal firmness. A brake pedal that offers nothing tells the driver
## nothing, so there is always some resistance to push against.
const BRAKE_BASE_RESISTANCE := 0.35
const BRAKE_FIRM_RESISTANCE := 0.85
## When a wheel locks with no ABS, the pedal goes light — there is nothing left
## to push against, because the tyre has stopped resisting. This is the single
## most useful thing the trigger can tell a driver.
const BRAKE_LOCKED_RESISTANCE := 0.10
const ABS_TRIGGER_FREQUENCY := 14.0
const ABS_TRIGGER_STRENGTH := 0.55

const THROTTLE_BASE_RESISTANCE := 0.18
## Resistance rises with how hard the engine is working, so boost coming in is
## something the finger feels.
const THROTTLE_LOAD_RESISTANCE := 0.45
const WHEELSPIN_TRIGGER_STRENGTH := 0.50
const WHEELSPIN_TRIGGER_FREQUENCY := 24.0

# --- Output ---
## Low-frequency motor, 0..1.
var rumble_low: float = 0.0
## High-frequency motor, 0..1.
var rumble_high: float = 0.0
var throttle_effect: TriggerEffect = TriggerEffect.off()
var brake_effect: TriggerEffect = TriggerEffect.off()

# --- Internal transient state ---
var _impact: float = 0.0


## Queue a one-off jolt. Severity is roughly 0..1 for a scrape through to a
## serious crash.
func add_impact(severity: float) -> void:
	_impact = clampf(maxf(_impact, severity * IMPACT_SCALE), 0.0, 1.6)


func add_landing(vertical_speed: float) -> void:
	add_impact(vertical_speed * LANDING_SCALE)


## Recompute everything for this frame.
func update(car: RallyCar, delta: float) -> void:
	_impact = maxf(_impact - IMPACT_DECAY * delta * maxf(_impact, 0.2), 0.0)

	if car == null or car.stats == null or car.damage == null:
		rumble_low = 0.0
		rumble_high = 0.0
		throttle_effect = TriggerEffect.off()
		brake_effect = TriggerEffect.off()
		return

	if car.damage.wrecked:
		_update_wrecked(car)
		return

	_update_rumble(car)
	_update_throttle_trigger(car)
	_update_brake_trigger(car)


func _update_wrecked(car: RallyCar) -> void:
	# A dead car has nothing to say through the pedals. A burning one still
	# shakes.
	rumble_low = clampf(_impact + (0.25 if car.damage.on_fire else 0.0), 0.0, 1.0)
	rumble_high = clampf(_impact * 0.6, 0.0, 1.0)
	throttle_effect = TriggerEffect.off()
	brake_effect = TriggerEffect.off()


func _update_rumble(car: RallyCar) -> void:
	var stats := car.stats
	var rev_fraction := clampf(car.transmission.rpm / maxf(stats.redline_rpm, 1.0), 0.0, 1.0)
	var load := car.command.throttle

	# Engine: amplitude with revs and load, split between the motors so low
	# revs feel like a lumpy idle and high revs feel like a hard buzz.
	var engine := lerpf(ENGINE_IDLE_RUMBLE, ENGINE_MAX_RUMBLE, rev_fraction)
	engine += ENGINE_LOAD_BONUS * load * rev_fraction
	var low := engine * (1.0 - rev_fraction * 0.65)
	var high := engine * rev_fraction * 0.8

	if car.engine.rev_limiting:
		high += REV_LIMIT_RUMBLE
		low += REV_LIMIT_RUMBLE * 0.4

	# Surface texture, only while the wheels are actually on it.
	if not car.airborne:
		var texture: float = SURFACE_RUMBLE.get(car.surface, 0.05)
		var speed_factor := clampf(car.speed_ms / SURFACE_REFERENCE_SPEED, 0.0, 1.0)
		high += texture * speed_factor
		low += texture * speed_factor * 0.45
	else:
		# Airborne is conspicuously smooth, which is what sells the jump.
		low *= 0.3
		high *= 0.3

	# The three failure modes, each with its own character so they are
	# distinguishable without looking.
	if car.wheels_spinning():
		high += WHEELSPIN_RUMBLE * clampf(car.worst_slip_ratio(), 0.0, 1.0)
	if car.wheels_locked():
		low += LOCKUP_RUMBLE
	if car.is_drifting:
		var slide := clampf(absf(car.slip_angle_rear) / 0.8, 0.0, 1.0)
		low += SLIDE_RUMBLE * slide * 0.6
		high += SLIDE_RUMBLE * slide * 0.4

	rumble_low = clampf(low + _impact, 0.0, 1.0)
	rumble_high = clampf(high + _impact * 0.7, 0.0, 1.0)


func _update_throttle_trigger(car: RallyCar) -> void:
	# Spinning the driven wheels buzzes the throttle. It is the clearest way to
	# tell a driver they are wasting the power they are asking for.
	if car.wheels_spinning():
		var severity := clampf(car.worst_slip_ratio(), 0.0, 1.2)
		throttle_effect = TriggerEffect.vibration(
			0.2, WHEELSPIN_TRIGGER_STRENGTH * severity, WHEELSPIN_TRIGGER_FREQUENCY)
		return

	# Traction control cutting in is a softer, slower flutter — the car is
	# handling it, the driver just needs to know.
	if car.traction_control_engaged():
		throttle_effect = TriggerEffect.vibration(0.35, 0.30, 10.0)
		return

	# Otherwise resistance tracks how hard the engine is working, so boost
	# arriving is something the finger feels before the speedo shows it.
	var rev_fraction := clampf(car.transmission.rpm / maxf(car.stats.redline_rpm, 1.0), 0.0, 1.0)
	var boost_fraction := 0.0
	if car.stats.turbo_boost > 1.0:
		boost_fraction = clampf(
			(car.engine.boost - 1.0) / (car.stats.turbo_boost - 1.0), 0.0, 1.0)
	var load := THROTTLE_BASE_RESISTANCE \
		+ THROTTLE_LOAD_RESISTANCE * maxf(rev_fraction, boost_fraction)

	if car.engine.rev_limiting:
		# A wall at the top of the travel: there is nothing more to be had.
		throttle_effect = TriggerEffect.weapon(0.75, 0.95, 0.9)
		return
	throttle_effect = TriggerEffect.feedback(0.1, load)


func _update_brake_trigger(car: RallyCar) -> void:
	# Worn tyres and a damaged car give a longer, softer pedal.
	var condition: float = car.damage.integrity["tires"]
	var firmness := lerpf(BRAKE_BASE_RESISTANCE, BRAKE_FIRM_RESISTANCE,
		clampf(car.stats.brake_force, 0.0, 1.4) / 1.4) * lerpf(0.55, 1.0, condition)

	# ABS working: the pedal pulses under the foot, exactly as it does in a
	# real car, because the hydraulics really are cycling.
	if car.abs_engaged():
		var intensity := lerpf(0.6, 1.0, car.abs_pulse())
		brake_effect = TriggerEffect.vibration(
			0.25, ABS_TRIGGER_STRENGTH * intensity, ABS_TRIGGER_FREQUENCY)
		return

	# Locked with no ABS: the pedal goes light. There is no more braking to be
	# had no matter how hard it is pushed, and the resistance disappearing is
	# the cue to release and try again.
	if car.wheels_locked():
		brake_effect = TriggerEffect.feedback(0.15, BRAKE_LOCKED_RESISTANCE)
		return

	# Normal: progressive, building through the travel like a real pedal.
	brake_effect = TriggerEffect.feedback(0.12, firmness)


## Compact summary for debugging and for the test suite.
func describe() -> String:
	return "rumble %.2f/%.2f  throttle[%s]  brake[%s]" % [
		rumble_low, rumble_high, throttle_effect.describe(), brake_effect.describe()]
