class_name PerformanceModel
extends RefCounted
## Derives a car's headline figures from its physics numbers.
##
## Power is not a separate input — it is torque times crank speed, so a car
## defined by a torque curve, a redline and a set of ratios already has a
## power output whether anyone checked it or not. This works it out, along with
## the speed at which drive force finally loses to drag.
##
## The point is calibration. Real cars have published power and top speed
## figures, so the model can be held against them: if a car makes 240 hp on
## paper and 310 here, its curve is wrong and it will feel wrong. The smoke
## test uses these to check the whole catalogue.

## Air density * 0.5, folded into the drag term. Matches RallyCar.
const DRAG_CONSTANT := 0.6125
## Drivetrain losses between crank and road. Matches RallyCar.
const DRIVELINE_EFFICIENCY := 0.88
const GRAVITY := 9.81
const WATTS_PER_HP := 745.7

## Resolution of the speed sweep used to find the top speed, in m/s.
const SPEED_STEP := 0.25
const MAX_SEARCH_SPEED := 130.0   # 468 km/h, well past anything in the game


## Crank torque in Nm at a given rpm, at full throttle and full boost.
static func crank_torque(stats: VehicleStats, rpm: float) -> float:
	var motor := EngineModel.new(stats)
	# Full boost: engine_torque_nm is already the on-boost rated figure, so
	# nothing is multiplied on top of it.
	return stats.engine_torque_nm * motor.torque_fraction(rpm)


## Power in kilowatts at a given rpm.
static func power_kw(stats: VehicleStats, rpm: float) -> float:
	var omega := rpm * TAU / 60.0
	return crank_torque(stats, rpm) * omega / 1000.0


## Peak power and the rpm it arrives at. Swept rather than solved because the
## torque curve is a shaped cosine, not something with a tidy derivative.
static func peak_power(stats: VehicleStats) -> Dictionary:
	var best_kw := 0.0
	var best_rpm := stats.idle_rpm
	var rpm := stats.idle_rpm
	while rpm <= stats.redline_rpm:
		var kw := power_kw(stats, rpm)
		if kw > best_kw:
			best_kw = kw
			best_rpm = rpm
		rpm += 25.0
	return {"kw": best_kw, "hp": best_kw * 1000.0 / WATTS_PER_HP, "rpm": best_rpm}


static func peak_power_hp(stats: VehicleStats) -> float:
	return peak_power(stats)["hp"]


## Peak torque and the rpm it arrives at.
static func peak_torque(stats: VehicleStats) -> Dictionary:
	var best_nm := 0.0
	var best_rpm := stats.idle_rpm
	var rpm := stats.idle_rpm
	while rpm <= stats.redline_rpm:
		var nm := crank_torque(stats, rpm)
		if nm > best_nm:
			best_nm = nm
			best_rpm = rpm
		rpm += 25.0
	return {"nm": best_nm, "rpm": best_rpm}


## Engine speed at a road speed in a given gear, 1-based.
static func rpm_at_speed(stats: VehicleStats, speed_ms: float, gear: int) -> float:
	var ratio := absf(stats.effective_ratio(gear - 1))
	if ratio <= 0.0:
		return stats.idle_rpm
	var wheel_omega := speed_ms / maxf(stats.wheel_radius, 0.05)
	return wheel_omega * ratio * 60.0 / TAU


## Tractive force at the contact patch, in newtons, in a given gear.
## Returns 0 past the limiter — the engine cannot pull what it cannot rev to.
static func drive_force(stats: VehicleStats, speed_ms: float, gear: int) -> float:
	var ratio := absf(stats.effective_ratio(gear - 1))
	if ratio <= 0.0:
		return 0.0
	var rpm := rpm_at_speed(stats, speed_ms, gear)
	if rpm > stats.redline_rpm:
		return 0.0
	return crank_torque(stats, maxf(rpm, stats.idle_rpm)) * ratio \
		* DRIVELINE_EFFICIENCY / maxf(stats.wheel_radius, 0.05)


## Everything pushing back, in newtons: aerodynamic drag plus rolling
## resistance. Downforce presses the car onto the road, so it costs rolling
## resistance as well as buying grip.
static func resistance(stats: VehicleStats, speed_ms: float) -> float:
	var drag := DRAG_CONSTANT * stats.drag_area * speed_ms * speed_ms
	var normal_load := stats.mass_kg * GRAVITY + stats.downforce * speed_ms * speed_ms
	var rolling := stats.rolling_resistance * normal_load
	return drag + rolling


## Highest speed the car can hold, in m/s.
##
## Every gear is checked, not just the tallest: a car geared too long for its
## power runs out of engine before it runs out of gear, and is genuinely faster
## one gear down. Top speed is where drive force finally loses to resistance.
static func top_speed_ms(stats: VehicleStats) -> float:
	var best := 0.0
	for gear in range(1, stats.gear_count() + 1):
		var speed := 1.0
		while speed < MAX_SEARCH_SPEED:
			var next := speed + SPEED_STEP
			if drive_force(stats, next, gear) <= resistance(stats, next):
				break
			speed = next
		best = maxf(best, speed)
	if stats.speed_limiter_kmh > 0.0:
		best = minf(best, stats.speed_limiter_kmh / 3.6)
	return best


static func top_speed_kmh(stats: VehicleStats) -> float:
	return top_speed_ms(stats) * 3.6


## Which gear the car tops out in, for reporting gearing problems.
static func top_speed_gear(stats: VehicleStats) -> int:
	var best := 0.0
	var best_gear := 1
	for gear in range(1, stats.gear_count() + 1):
		var speed := 1.0
		while speed < MAX_SEARCH_SPEED:
			var next := speed + SPEED_STEP
			if drive_force(stats, next, gear) <= resistance(stats, next):
				break
			speed = next
		if speed > best:
			best = speed
			best_gear = gear
	return best_gear


## Standing-start acceleration to a target speed, in seconds.
##
## Traction-limited at the bottom and power-limited at the top, which is why a
## 700 hp rear-drive car is not twice as quick to 100 as a 350 hp one. Returns
## INF if the car cannot reach the target at all.
static func time_to_speed(stats: VehicleStats, target_kmh: float = 100.0) -> float:
	var target := target_kmh / 3.6
	var dt := 0.005
	var speed := 0.0
	var elapsed := 0.0
	var gear := 1

	# Grip available to the driven axle. This is the ceiling a standing start
	# runs into before the engine is anywhere near its limit.
	var driven_share := stats.front_torque_share()
	if stats.drivetrain == VehicleStats.Drivetrain.RWD:
		driven_share = 1.0 - stats.weight_bias_front
	elif stats.drivetrain == VehicleStats.Drivetrain.FWD:
		driven_share = stats.weight_bias_front
	else:
		driven_share = 1.0   # all four wheels drive, so all the weight counts
	var mu := TireModel.surface_mu(stats, TireModel.Surface.TARMAC, false)

	while speed < target and elapsed < 60.0:
		# Shift up when the current gear runs past the limiter.
		while gear < stats.gear_count() \
				and rpm_at_speed(stats, speed, gear) > stats.redline_rpm:
			gear += 1
			elapsed += stats.shift_time

		var force := drive_force(stats, speed, gear)
		var traction_limit := mu * driven_share * stats.mass_kg * GRAVITY
		force = minf(force, traction_limit)
		var net := force - resistance(stats, speed)
		if net <= 0.0:
			return INF
		speed += net / stats.mass_kg * dt
		elapsed += dt
	return elapsed if speed >= target else INF


## Power per tonne, the number that actually predicts how a car feels.
static func power_to_weight_hp_per_tonne(stats: VehicleStats) -> float:
	return peak_power_hp(stats) / (stats.mass_kg / 1000.0)


## Everything at once, for the showroom and for the calibration bench.
static func summary(stats: VehicleStats) -> Dictionary:
	var power := peak_power(stats)
	var torque := peak_torque(stats)
	return {
		"power_hp": power["hp"],
		"power_kw": power["kw"],
		"power_rpm": power["rpm"],
		"torque_nm": torque["nm"],
		"torque_rpm": torque["rpm"],
		"top_speed_kmh": top_speed_kmh(stats),
		"top_gear_used": top_speed_gear(stats),
		"zero_to_100": time_to_speed(stats, 100.0),
		"mass_kg": stats.mass_kg,
		"hp_per_tonne": power_to_weight_hp_per_tonne(stats),
	}
