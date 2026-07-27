class_name Transmission
extends RefCounted
## Gearbox and engine speed. Owns the gear the car is in, whether the clutch is
## currently disengaged for a shift, and the automatic shift logic.
##
## Manual shifting has to be worth doing, so automatic mode is deliberately
## conservative: it upshifts a little early and will not catch a
## power-band drop the way a good driver can.

enum Mode { AUTOMATIC, MANUAL }
enum Gear { REVERSE = -1, NEUTRAL = 0 }

var stats: VehicleStats
var mode: Mode = Mode.AUTOMATIC

## -1 reverse, 0 neutral, 1..n forward gears.
var gear: int = 0
var rpm: float = 900.0
## 0 while shifting, ramping back to 1 as the clutch re-engages.
var clutch: float = 1.0
var shift_timer: float = 0.0
var is_shifting: bool = false

## Automatic mode shift points, as a fraction of redline.
var auto_upshift_frac: float = 0.92
var auto_downshift_frac: float = 0.42
## Blocks the automatic box from hunting up and down on a rolling hill.
var _shift_cooldown: float = 0.0

signal gear_changed(new_gear: int)


func _init(p_stats: VehicleStats) -> void:
	stats = p_stats
	rpm = stats.idle_rpm


func gear_ratio() -> float:
	if gear > 0:
		return stats.effective_ratio(gear - 1)
	if gear == Gear.REVERSE:
		return -stats.reverse_ratio * stats.gear_spread * stats.final_drive
	return 0.0


func top_gear() -> int:
	return stats.gear_count()


## Update engine speed from the *driven wheels*, then run the automatic box.
##
## Deriving revs from road speed instead looks equivalent and is not: a car
## sitting in a cloud of tyre smoke is doing no road speed and screaming its
## head off. Reading the driven axle is what makes wheelspin audible and
## visible on the tacho.
func update(delta: float, driven_omega: float, road_speed_ms: float, throttle: float) -> void:
	if _shift_cooldown > 0.0:
		_shift_cooldown -= delta

	if is_shifting:
		shift_timer -= delta
		# The clutch comes back progressively; clutch_grab decides how sharply.
		var progress := 1.0 - clampf(shift_timer / maxf(stats.shift_time, 0.001), 0.0, 1.0)
		clutch = clampf(pow(progress, 1.0 / maxf(stats.clutch_grab, 0.1)), 0.0, 1.0)
		if shift_timer <= 0.0:
			is_shifting = false
			clutch = 1.0
	else:
		clutch = 1.0

	var ratio := gear_ratio()
	if is_zero_approx(ratio) or is_shifting:
		# Free-revving: throttle spins the engine up, otherwise it falls to idle.
		var target := lerpf(stats.idle_rpm, stats.redline_rpm, throttle)
		rpm = lerpf(rpm, target, clampf(delta * 4.0, 0.0, 1.0))
	else:
		rpm = absf(driven_omega) * absf(ratio) * 60.0 / TAU
		rpm = maxf(rpm, stats.idle_rpm)

	rpm = minf(rpm, stats.redline_rpm)

	if mode == Mode.AUTOMATIC:
		_auto_shift(road_speed_ms, throttle)


func _auto_shift(road_speed_ms: float, throttle: float) -> void:
	if is_shifting or _shift_cooldown > 0.0:
		return
	# Pulling away from a stop, and reverse, are handled by the caller.
	if gear <= 0:
		return
	var frac := rpm / maxf(stats.redline_rpm, 1.0)
	if frac >= auto_upshift_frac and gear < top_gear():
		shift_to(gear + 1)
	elif frac <= auto_downshift_frac and gear > 1:
		shift_to(gear - 1)
	elif throttle > 0.85 and frac < 0.55 and gear > 1:
		# Kickdown: heavy throttle low in the rev range asks for a lower gear.
		shift_to(gear - 1)


func shift_up() -> void:
	if gear < top_gear():
		shift_to(maxi(gear + 1, 1))


func shift_down() -> void:
	if gear > 1:
		shift_to(gear - 1)
	elif gear == 1:
		shift_to(Gear.NEUTRAL)
	elif gear == Gear.NEUTRAL:
		shift_to(Gear.REVERSE)


func shift_to(new_gear: int) -> void:
	new_gear = clampi(new_gear, Gear.REVERSE, top_gear())
	if new_gear == gear:
		return
	gear = new_gear
	is_shifting = true
	shift_timer = stats.shift_time
	clutch = 0.0
	_shift_cooldown = stats.shift_time + 0.25
	gear_changed.emit(gear)


## Called by the car when the driver is stationary and asking to move, so an
## automatic box selects a sensible direction without the player shifting.
func engage_for(direction: int) -> void:
	if direction > 0 and gear <= 0:
		shift_to(1)
	elif direction < 0 and gear >= 0:
		shift_to(Gear.REVERSE)


func toggle_mode() -> void:
	mode = Mode.MANUAL if mode == Mode.AUTOMATIC else Mode.AUTOMATIC


func mode_name() -> String:
	return "AUTO" if mode == Mode.AUTOMATIC else "MANUAL"


func gear_label() -> String:
	if gear == Gear.REVERSE:
		return "R"
	if gear == Gear.NEUTRAL:
		return "N"
	return str(gear)
