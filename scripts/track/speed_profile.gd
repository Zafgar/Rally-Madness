class_name SpeedProfile
extends RefCounted
## How fast this car, with these parts, can be at every point on this track.
##
## This is the piece that was missing. The AI knew how to work out an entry
## speed for a corner it could see; what it could not do was work backwards
## from that speed to the point where braking has to start. So it braked when
## the corner was close enough to worry about, which at 40 m/s is far too late,
## and the difference between a driver who arrives at the apex on the line and
## one who arrives in the scenery is exactly that distance.
##
## The solve is the standard one and it is not complicated:
##
##   1. At every point, the fastest the tyres will hold the line's curvature.
##      That is the ceiling, and it is a purely local number.
##   2. Walk the track backwards. A point cannot be faster than what the brakes
##      can shed before the next point's ceiling. This is what puts the braking
##      point in the right place, and it puts it there without anybody deciding
##      where it should be.
##   3. Walk forwards. A point cannot be faster than what the engine can add
##      since the last one. This is what stops a car exiting a hairpin at the
##      speed of the following straight.
##
## Everything in it comes from the resolved VehicleStats, which means it comes
## from the fitted parts: better tyres raise step 1, bigger brakes raise step 2,
## more power raises step 3. A player who buys brakes gets later braking points
## from their rivals too, because the rivals' profiles are solved from their own
## built cars.
##
## Solved once when the car is configured, and then it is a lookup.

## How much of the tyres' grip the solve assumes is available for cornering.
## Not 1.0: a real car is not on a skidpad, the surface varies within a corner
## and the line is an approximation of itself. This is the margin that makes
## the profile drivable rather than theoretical.
const GRIP_USE := 0.92
## The same for braking. Lower, because braking happens while the car is still
## turning in and the two share the same tyres.
const BRAKE_USE := 0.85
## And for accelerating out, which on a rear-drive car on gravel is the least
## of the three.
const DRIVE_USE := 0.78

## Passes of the backward/forward solve. Two is enough on a closed circuit,
## where the second pass carries the first's result across the start line.
const SOLVE_PASSES := 3


var model: TrackModel
var line: RacingLine
var stats: VehicleStats
## Target speed in metres per second at every sample.
var speeds: PackedFloat32Array = PackedFloat32Array()
## The purely local grip ceiling, kept for the bench and for the AI's
## "how much of the limit am I using" readout.
var limits: PackedFloat32Array = PackedFloat32Array()


static func solve(p_model: TrackModel, p_line: RacingLine,
		p_stats: VehicleStats) -> SpeedProfile:
	var profile := SpeedProfile.new()
	profile.model = p_model
	profile.line = p_line
	profile.stats = p_stats
	profile._grip_ceiling()
	profile._solve()
	return profile


# --- Step 1: what the tyres will hold ---------------------------------------

func _grip_ceiling() -> void:
	var count := model.positions.size()
	speeds.resize(count)
	limits.resize(count)
	var top := PerformanceModel.top_speed_kmh(stats) / 3.6

	for i in count:
		var radius := line.radius_at(i)
		var mu := TireModel.surface_mu(stats, model.surface_at(i), true)
		# v = sqrt(mu * g * r). Downforce raises the effective mu with speed,
		# but solving that properly needs the speed we are solving for, so it
		# is applied once at the ceiling rather than iterated.
		var lateral := mu * 9.81 * GRIP_USE * (1.0 + stats.downforce * 0.25)
		var v := sqrt(maxf(radius, 1.0) * lateral)
		limits[i] = minf(v, top)
		speeds[i] = limits[i]


# --- Steps 2 and 3: what the car can actually do between points -------------

func _solve() -> void:
	var count := speeds.size()
	if count < 4:
		return
	var ds := TrackModel.SPACING_M

	for pass_index in SOLVE_PASSES:
		# Backwards: where braking has to start.
		for step in range(count):
			var i := count - 1 - step
			var next := model._wrap(i + 1)
			if not model.closed and i == count - 1:
				continue
			var decel := _braking_decel(i)
			var reachable := sqrt(maxf(
				speeds[next] * speeds[next] + 2.0 * decel * ds, 0.0))
			speeds[i] = minf(speeds[i], reachable)

		# Forwards: how quickly it can be got back.
		for i in count:
			var previous := model._wrap(i - 1)
			if not model.closed and i == 0:
				continue
			var accel := _drive_accel(i, speeds[previous])
			var reachable := sqrt(maxf(
				speeds[previous] * speeds[previous] + 2.0 * accel * ds, 0.0))
			speeds[i] = minf(speeds[i], reachable)


## Deceleration available at a sample, in m/s². Limited by the tyres and by how
## much brake the car actually has, and reduced by whatever grip the corner is
## already using — a car at the limit laterally has nothing left for stopping,
## which is the whole reason trail braking is a skill rather than a default.
func _braking_decel(i: int) -> float:
	var mu := TireModel.surface_mu(stats, model.surface_at(i), true)
	var available := mu * 9.81 * BRAKE_USE * stats.brake_force
	var lateral_use := clampf(speeds[i] * speeds[i]
		/ maxf(line.radius_at(i) * mu * 9.81, 0.001), 0.0, 1.0)
	# The friction circle: what is left for the long axis when the lateral axis
	# is already using this much.
	var remaining := sqrt(maxf(1.0 - lateral_use * lateral_use, 0.02))
	return maxf(available * remaining, 0.5)


## Acceleration available, in m/s². The lesser of what the engine can push and
## what the driven tyres can take, sharing the same friction circle.
func _drive_accel(i: int, speed: float) -> float:
	var mu := TireModel.surface_mu(stats, model.surface_at(i), true)
	var traction := mu * 9.81 * DRIVE_USE * _driven_share()
	var lateral_use := clampf(speed * speed
		/ maxf(line.radius_at(i) * mu * 9.81, 0.001), 0.0, 1.0)
	var remaining := sqrt(maxf(1.0 - lateral_use * lateral_use, 0.02))

	# What the engine can manage at this speed, from the power it makes and the
	# drag it is pushing through. Using peak power rather than the torque at
	# the revs it happens to be pulling is a simplification, and the right one:
	# the profile is a target, and a driver aiming at it will use the gearbox
	# to get near the power peak.
	var power_w := PerformanceModel.peak_power_hp(stats) * 745.7 * 0.82
	var drag := PerformanceModel.DRAG_CONSTANT * stats.drag_area * speed * speed
	var engine := (power_w / maxf(speed, 4.0) - drag) / maxf(stats.mass_kg, 1.0)
	return maxf(minf(engine, traction * remaining), 0.2)


## Fraction of the car's weight over the driven wheels, which is what decides
## how much of the tyres' grip can actually be used to accelerate.
func _driven_share() -> float:
	match stats.drivetrain:
		VehicleStats.Drivetrain.AWD:
			return 1.0
		VehicleStats.Drivetrain.FWD:
			return stats.weight_bias_front
		_:
			return 1.0 - stats.weight_bias_front


# --- Lookups ----------------------------------------------------------------

## The speed the car should be doing at this distance along the track.
func speed_at(s_m: float) -> float:
	if speeds.is_empty():
		return 30.0
	return speeds[model.index_at(s_m)]


## The lowest target speed anywhere in the next `distance_m` metres, which is
## what a driver is actually aiming at — you brake for the slowest thing you
## can see, not for the next metre.
func speed_ahead(s_m: float, distance_m: float) -> float:
	if speeds.is_empty():
		return 30.0
	var start := model.index_at(s_m)
	var steps := maxi(int(distance_m / TrackModel.SPACING_M), 1)
	var lowest := speeds[start]
	for step in range(1, steps + 1):
		lowest = minf(lowest, speeds[model._wrap(start + step)])
	return lowest


## How far ahead the next point slower than the car's current speed is, in
## metres, or INF if there is nothing slower within `horizon_m`.
##
## This is the number the AI never had: the distance to the braking, as opposed
## to the distance to the corner. They are not the same, and on a fast entry
## the difference is most of a straight.
func distance_to_slower(s_m: float, speed: float, horizon_m: float) -> float:
	if speeds.is_empty():
		return INF
	var start := model.index_at(s_m)
	var steps := maxi(int(horizon_m / TrackModel.SPACING_M), 1)
	for step in range(1, steps + 1):
		if speeds[model._wrap(start + step)] < speed:
			return float(step) * TrackModel.SPACING_M
	return INF


## An estimate of the lap this profile implies, in seconds. The bench's headline
## number: if fitting better tyres does not lower it, the parts are not reaching
## the driving.
func lap_estimate() -> float:
	if speeds.is_empty():
		return 0.0
	var total := 0.0
	for v in speeds:
		total += TrackModel.SPACING_M / maxf(v, 1.0)
	return total
