class_name EngineModel
extends RefCounted
## Torque delivery: the curve, the turbo, and the rev limiter.
##
## The curve shape is what makes two cars with identical peak torque feel
## different. A torquey lump pulls from anywhere; a peaky turbo motor is fast
## only if the driver keeps it on song, which is what makes manual shifting and
## gear-ratio tuning worth caring about.

## Torque as a fraction of peak at the very bottom and very top of the range.
const OFF_PEAK_FRACTION := 0.45
## Half-width of the usable power band, in normalised rev fraction.
const BAND_WIDTH := 0.78
## Revs (as a fraction of redline) below which the turbo cannot make boost.
const BOOST_THRESHOLD := 0.35

var stats: VehicleStats
## How much of the engine's rated torque is currently available, 0..1.
##
## `engine_torque_nm` is the peak torque a spec sheet quotes, which for a
## turbocharged car is already the on-boost figure. Treating boost as a
## multiplier on top of that double-counts it — it was making the Group B cars
## produce 800 hp instead of 480. Instead, full boost means the rated torque
## and off boost means `1 / turbo_boost` of it, so the quoted number stays
## honest and the hole below the turbo is what boost actually models.
var boost: float = 1.0
## True while the limiter is cutting fuel, so the car can pop and bang.
var rev_limiting: bool = false


func _init(p_stats: VehicleStats) -> void:
	stats = p_stats


## Where peak torque sits in the rev range, 0 at idle and 1 at redline.
func peak_position() -> float:
	return clampf(0.60 + stats.torque_curve_bias * 0.28, 0.20, 0.92)


## Fraction of peak torque available at these revs.
func torque_fraction(rpm: float) -> float:
	var span := maxf(stats.redline_rpm - stats.idle_rpm, 1.0)
	var n := clampf((rpm - stats.idle_rpm) / span, 0.0, 1.0)
	var offset := clampf((n - peak_position()) / BAND_WIDTH, -1.0, 1.0)
	var shape := 0.5 * (1.0 + cos(offset * PI))
	return lerpf(OFF_PEAK_FRACTION, 1.0, shape)


## Torque available off boost, as a fraction of the rated figure.
func off_boost_fraction() -> float:
	return 1.0 / maxf(stats.turbo_boost, 1.0)


func update_boost(delta: float, rpm: float, throttle: float) -> void:
	if stats.turbo_boost <= 1.0:
		boost = 1.0
		return
	var rev_frac := rpm / maxf(stats.redline_rpm, 1.0)
	var spooled := throttle > 0.25 and rev_frac > BOOST_THRESHOLD
	var target := 1.0 if spooled else off_boost_fraction()
	# Lag only applies to building boost; lifting off dumps it quickly.
	var tau := maxf(stats.turbo_lag, 0.01) if target > boost else 0.18
	boost = lerpf(boost, target, clampf(delta / tau, 0.0, 1.0))


## Crankshaft torque in Nm for the current throttle and revs.
func output_torque(rpm: float, throttle: float, nitro_multiplier: float = 1.0) -> float:
	rev_limiting = rpm >= stats.redline_rpm - 40.0
	if rev_limiting:
		# Hard cut, so bouncing off the limiter costs real time.
		throttle *= 0.15
	var base := stats.engine_torque_nm * torque_fraction(rpm)
	return base * throttle * boost * nitro_multiplier


## Engine braking when off throttle, which is a big part of how a car settles
## into a corner and how much a RWD car rotates on a lift.
func braking_torque(rpm: float, throttle: float) -> float:
	if throttle > 0.05:
		return 0.0
	var rev_frac := clampf(rpm / maxf(stats.redline_rpm, 1.0), 0.0, 1.0)
	return stats.engine_torque_nm * 0.12 * rev_frac
