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

## How much of the tyres' peak grip a car actually holds in a sustained corner.
##
## Measured, not chosen. Peak mu is what a tyre makes at exactly the right slip
## angle, held for an instant; a corner is several seconds long and averages
## well under it. The grip probe put three cars with no aerodynamics — a
## Trabant, a Golf and an Impreza — at 0.66 of peak mu each, on both tarmac and
## gravel, which is a consistent enough number to build on.
##
## It was 0.92, and that single wrong constant is where the remaining wrecks
## came from. The plan told every car it could corner half again as fast as it
## could, so every apex was approached too quickly, and the cars that went off
## went off on their own rather than into each other — which is exactly what the
## race probe showed: five wrecked with only ten car-to-car contacts in the
## whole race.
const GRIP_USE := 0.58
## The same for braking, and far lower — which is not caution, it is
## calibration.
##
## The obvious formula for available deceleration is grip times gravity times
## the car's brake force, and it is wrong in the one direction that matters. The
## brake probe measured it: a Trabant achieved slightly more than that formula
## predicted, a Golf a little less, a Delta S4 four fifths of it, and a GT2 RS
## barely half. The error grows with grip, because peak mu is what the tyre
## makes at exactly the right slip ratio and a real stop averages a good deal
## less than that. So the plan was most optimistic about precisely the fastest
## cars in the game, every one of their braking points was late, and the
## overshoot grew with speed — which is why turning the AI up filled the field
## with wrecks rather than making it quick.
##
## The car's own brake force is gone from the sum for the same reason. It scales
## the brake torque, and brake torque is not the limit: every car in the game
## can lock its wheels. The tyres are the limit, and they are already in mu.
##
## This value is what makes the worst case in the probe land under a hundred
## per cent — the plan asking for less than the car can give, everywhere.
const BRAKE_USE := 0.58
## And for accelerating out.
##
## Nearly all of it, and higher than the other two on purpose. A margin on the
## cornering ceiling and on braking is real caution — arriving too fast is a
## crash. A margin on acceleration is not caution at all: if the target on the
## exit is optimistic the car simply holds full throttle and the physics sorts
## out what it can actually deliver. Set at 0.78 this quietly capped every
## corner exit in the game, and on a twisty stage, where a car is accelerating
## out of something almost all the time, it cost about ten seconds a lap.
const DRIVE_USE := 0.95

## Passes of the backward/forward solve. Two is enough on a closed circuit,
## where the second pass carries the first's result across the start line.
const SOLVE_PASSES := 3


var model: TrackModel
var line: RacingLine
var stats: VehicleStats
## How much of the calibrated braking this driver's plan uses. One is the
## measured limit; less is a driver who brakes earlier than they need to.
var brake_margin: float = 1.0
## Target speed in metres per second at every sample.
var speeds: PackedFloat32Array = PackedFloat32Array()
## The purely local grip ceiling, kept for the bench and for the AI's
## "how much of the limit am I using" readout.
var limits: PackedFloat32Array = PackedFloat32Array()

# Worked out once by _precompute and then read by the solve's inner loops.
var _radius: PackedFloat32Array = PackedFloat32Array()
var _mu: PackedFloat32Array = PackedFloat32Array()
var _peak_power_w: float = 0.0
var _drag_coefficient: float = 0.0
var _driven: float = 1.0


## `brake_margin` scales how much of the calibrated braking the plan assumes,
## so a nervous driver's plan genuinely has earlier braking points in it rather
## than the same points approached more slowly. Those are different things and
## they look different from the outside: one driver rolls into the corner off
## the throttle early, the other stands on the brakes late. One is what a novice
## does.
static func solve(p_model: TrackModel, p_line: RacingLine,
		p_stats: VehicleStats, brake_margin: float = 1.0) -> SpeedProfile:
	var profile := SpeedProfile.new()
	profile.model = p_model
	profile.line = p_line
	profile.stats = p_stats
	profile.brake_margin = clampf(brake_margin, 0.3, 1.0)
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
		# v = sqrt(mu * g * r).
		var lateral := cornering_accel(stats, model.surface_at(i))
		var v := sqrt(maxf(radius, 1.0) * lateral)
		limits[i] = minf(v, top)
		speeds[i] = limits[i]


# --- Steps 2 and 3: what the car can actually do between points -------------

## Everything the solve needs that does not change while it runs, worked out
## once.
##
## This is not tidiness, it is the difference between a race starting and a race
## hanging. The inner loop called PerformanceModel.peak_power_hp, which walks
## the whole rev range in twenty-five rpm steps — about two hundred and fifty
## torque evaluations. Three passes over a few hundred samples turned that into
## a quarter of a million evaluations per car, and one speed profile took 780
## milliseconds. Six cars on the grid meant five seconds of nothing happening
## before a race would start.
func _precompute() -> void:
	var count := model.positions.size()
	_radius.resize(count)
	_mu.resize(count)
	for i in count:
		_radius[i] = line.radius_at(i)
		_mu[i] = TireModel.surface_mu(stats, model.surface_at(i), true)
	_peak_power_w = PerformanceModel.peak_power_hp(stats) * 745.7 * 0.82
	_drag_coefficient = PerformanceModel.DRAG_CONSTANT * stats.drag_area
	_driven = _driven_share()


func _solve() -> void:
	var count := speeds.size()
	if count < 4:
		return
	_precompute()
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


## What this car can shed in a straight line on this surface, in m/s².
##
## Public and static because the brake probe measures against exactly this
## expression. A calibration that lives in two places drifts apart, and the
## first thing to go wrong is the number nobody is checking any more.
static func straight_line_decel(p_stats: VehicleStats,
		surface: TireModel.Surface) -> float:
	return TireModel.surface_mu(p_stats, surface, true) * 9.81 * BRAKE_USE


## And what it will hold in a sustained corner, in m/s². Same reasoning, same
## bench: peak mu is an instant, a corner is not.
##
## Downforce is deliberately absent. It was in here as a flat multiplier, and
## the probe showed why that is wrong: downforce grows with the square of speed,
## so a flat bonus credits a car with grip it only has flat out and none of the
## grip it needs in the slow corner it is about to arrive at. The two cars that
## carried it — a Delta S4 and a GT2 RS — were the two the plan overestimated
## most. Leaving it out means the plan is conservative about a fast car in a
## fast corner, which is the safe direction to be wrong in.
static func cornering_accel(p_stats: VehicleStats,
		surface: TireModel.Surface) -> float:
	return TireModel.surface_mu(p_stats, surface, true) * 9.81 * GRIP_USE


## Deceleration available at a sample, in m/s². Limited by the tyres, and
## reduced by whatever grip the corner is already using — a car at the limit
## laterally has nothing left for stopping, which is the whole reason trail
## braking is a skill rather than a default.
func _braking_decel(i: int) -> float:
	var mu := _mu[i]
	var available := mu * 9.81 * BRAKE_USE * brake_margin
	var lateral_use := clampf(speeds[i] * speeds[i]
		/ maxf(_radius[i] * mu * 9.81, 0.001), 0.0, 1.0)
	# The friction circle: what is left for the long axis when the lateral axis
	# is already using this much.
	var remaining := sqrt(maxf(1.0 - lateral_use * lateral_use, 0.02))
	return maxf(available * remaining, 0.5)


## Acceleration available, in m/s². The lesser of what the engine can push and
## what the driven tyres can take, sharing the same friction circle.
func _drive_accel(i: int, speed: float) -> float:
	var mu := _mu[i]
	var traction := mu * 9.81 * DRIVE_USE * _driven
	var lateral_use := clampf(speed * speed
		/ maxf(_radius[i] * mu * 9.81, 0.001), 0.0, 1.0)
	var remaining := sqrt(maxf(1.0 - lateral_use * lateral_use, 0.02))

	# What the engine can manage at this speed, from the power it makes and the
	# drag it is pushing through. Using peak power rather than the torque at
	# the revs it happens to be pulling is a simplification, and the right one:
	# the profile is a target, and a driver aiming at it will use the gearbox
	# to get near the power peak.
	var drag := _drag_coefficient * speed * speed
	var engine := (_peak_power_w / maxf(speed, 4.0) - drag) / maxf(stats.mass_kg, 1.0)
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
