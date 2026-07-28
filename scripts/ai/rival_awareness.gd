class_name RivalAwareness
extends RefCounted
## What an AI driver can see of the cars around it.
##
## Separated from the driving logic because "where is everyone" and "what do I
## do about it" are different problems, and because the interesting part is
## that different drivers see the same situation differently.
##
## The model is deliberately not omniscient. A driver's picture of the field is
## refreshed on their own reaction interval, so a poor one is acting on
## information that is up to half a second stale — which is exactly why they
## get caught out by a car braking hard in front of them, and why they leave
## bigger gaps to compensate. Nobody is given a perfect instantaneous view of
## the track and then told to pretend otherwise.

## How far ahead a driver bothers to look, in metres, at the extremes of
## awareness.
const SCAN_RANGE_MIN := 35.0
const SCAN_RANGE_MAX := 90.0
## Half-width of the corridor counted as "in my path", in metres. A car outside
## this is beside you, not in front of you.
const PATH_HALF_WIDTH := 2.6
## Lateral band within which a rival counts as alongside.
const ALONGSIDE_HALF_WIDTH := 4.5
## Longitudinal band within which a rival counts as alongside rather than ahead.
const ALONGSIDE_REACH := 5.5
## How far forward rivals are projected when judging a threat. Watching where a
## car is going rather than where it is now is most of what "seeing" means.
const PROJECTION_SECONDS := 0.6

## The room a driver leaves when nothing is moving — roughly a car length.
##
## A following distance is a time, not a distance. Two cars queueing sit a
## metre apart; two at 200 km/h need sixty. Written as a fixed number of metres,
## every driver on the start grid wanted more room than a grid gives them,
## braked for the stationary car in front, and since that car was doing the same
## thing the entire field deadlocked before it had moved. Which is exactly what
## it looked like: cars sitting on the line going nowhere.
const STANDING_GAP_M := 4.0
## Seconds of headway on top of that, from the most cautious driver to the
## boldest. Two seconds is the road-safety number; racing drivers use far less.
const HEADWAY_MAX := 1.25
const HEADWAY_MIN := 0.55
## Closer than this and the gap matters whatever the closing speed, because at
## this range a twitch is a contact.
const CONTACT_GAP_M := 3.0
## Below this the car in front has stopped being traffic and started being
## scenery. Walking pace.
const CRAWLING_MS := 2.0
## How close you have to be to a stopped car before going around it is a plan
## rather than an intention.
const OBSTACLE_PASS_RANGE_M := 45.0
## How much slower than this driver's own plan the car ahead has to be before it
## is worth going around whatever the closing speed says, as a fraction.
##
## Closing speed cannot answer this question, and that is the whole difficulty.
## A follower slows to match the car in front, and the moment it has, the two
## are travelling at the same speed and the closing speed is zero — so a rule
## that asks "am I catching them?" answers no, permanently, *because* the driver
## did the sensible thing. The queue is self-stabilising: everyone behind a slow
## car has an excellent reason not to pass it, which is that they have already
## slowed down to its speed.
##
## What the driver should be asking is "should I be behind this car at all",
## and the speed profile already knows the answer: it says what this car, with
## these parts, could be doing at this point on this road.
const CLEARLY_SLOWER := 0.22
## Below this the pass has to justify itself on closing speed alone, as before.
const WORTH_A_LOOK := 0.08

# --- Refreshed picture of the field ---
## Nearest rival directly ahead, or null.
var car_ahead: RallyCar = null
## Gap to it along our heading, in metres.
var gap_ahead: float = INF
## Its speed along our heading, m/s. Used to work out a safe following speed.
var speed_ahead: float = 0.0
## How fast we are closing on it, m/s. Negative means it is pulling away.
var closing_speed: float = 0.0
## True when the car ahead is braking hard enough to matter.
var ahead_braking: bool = false
## Seconds until contact at the current closing rate, INF if not closing.
var time_to_contact: float = INF

## Rivals level with us on either side. Steering into one is how a race ends.
var alongside_left: bool = false
var alongside_right: bool = false
var nearest_side_gap: float = INF

var _car: RallyCar
var _profile: DriverProfile
var _rivals: Array[RallyCar] = []
var _since_scan: float = 999.0


func _init(p_car: RallyCar, p_profile: DriverProfile) -> void:
	_car = p_car
	_profile = p_profile


func set_field(cars: Array) -> void:
	_rivals.clear()
	for other in cars:
		if other != _car and other is RallyCar:
			_rivals.append(other)


## How often this driver refreshes their picture of the field. An attentive
## driver is looking constantly; a nervous novice glances up now and then and
## acts on what they saw last time.
func scan_interval() -> float:
	return lerpf(0.45, 0.08, _profile.awareness)


## The gap this driver wants to keep to the car ahead, in metres. Caution is
## the inverse of commitment and aggression: a driver who does not dare push
## also does not dare sit on someone's bumper.
func desired_gap() -> float:
	var boldness := (_profile.commitment + _profile.aggression) * 0.5
	var headway := lerpf(HEADWAY_MAX, HEADWAY_MIN, clampf(boldness, 0.0, 1.0))
	var speed := _car.speed_ms if _car != null and is_instance_valid(_car) else 0.0
	return STANDING_GAP_M + speed * headway


func update(delta: float) -> void:
	_since_scan += delta
	if _since_scan < scan_interval():
		return
	_since_scan = 0.0
	_scan()


func _scan() -> void:
	car_ahead = null
	gap_ahead = INF
	speed_ahead = 0.0
	closing_speed = 0.0
	ahead_braking = false
	time_to_contact = INF
	alongside_left = false
	alongside_right = false
	nearest_side_gap = INF

	if _car == null or not is_instance_valid(_car):
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var range_m := lerpf(SCAN_RANGE_MIN, SCAN_RANGE_MAX, _profile.awareness)
	var forward := Vector2.RIGHT.rotated(_car.rotation)
	var our_velocity := _car.linear_velocity / ppm

	for rival in _rivals:
		if rival == null or not is_instance_valid(rival):
			continue
		var offset := (rival.global_position - _car.global_position) / ppm
		var local := offset.rotated(-_car.rotation)
		if local.length() > range_m:
			continue

		var rival_velocity := rival.linear_velocity / ppm
		var relative := our_velocity - rival_velocity

		# --- Alongside ------------------------------------------------------
		if absf(local.x) < ALONGSIDE_REACH and absf(local.y) < ALONGSIDE_HALF_WIDTH:
			if local.y < 0.0:
				alongside_left = true
			else:
				alongside_right = true
			nearest_side_gap = minf(nearest_side_gap, absf(local.y))
			continue

		if local.x <= 0.0:
			continue  # behind us; their problem, not ours

		# --- Ahead ----------------------------------------------------------
		# Judged on where the rival will be shortly, not where it is. A car
		# drifting across our nose is a threat before it is in front of us.
		var projected := local + (rival_velocity - our_velocity).rotated(-_car.rotation) \
			* PROJECTION_SECONDS
		var in_path := absf(local.y) < PATH_HALF_WIDTH or absf(projected.y) < PATH_HALF_WIDTH
		if not in_path:
			continue
		if local.x >= gap_ahead:
			continue

		car_ahead = rival
		gap_ahead = local.x
		speed_ahead = rival_velocity.dot(forward)
		closing_speed = relative.dot(forward)
		# A wreck sitting on the racing line is the most dangerous thing there
		# is, and it is not going to move.
		if rival.damage != null and rival.damage.wrecked:
			ahead_braking = true
		else:
			ahead_braking = rival.command.brake > 0.4 or rival.wheels_locked()
		if closing_speed > 0.1:
			time_to_contact = gap_ahead / closing_speed


## Is there a rival on the side we would like to move toward?
func side_blocked(side: float) -> bool:
	if side < 0.0:
		return alongside_left
	if side > 0.0:
		return alongside_right
	return false


## Whether this driver would attempt a pass at all.
##
## Overtaking needs three things: being faster, having somewhere to go, and the
## nerve to use it. A cautious driver has the first two often enough and simply
## never takes them, which is what makes a slow driver slow in traffic rather
## than only in corners.
##
## `own_plan_ms` is what this driver's speed profile says they could be doing
## here. Pass it and the judgement is made on pace; leave it out and it falls
## back to closing speed, which is only ever right for a car that is genuinely
## getting away.
func wants_to_overtake(own_plan_ms: float = 0.0) -> bool:
	if car_ahead == null:
		return false
	# A car that is not moving is an obstacle, not a rival. Once you have
	# slowed to match it you are both stationary, closing speed is zero and it
	# can never become anything else — so a rule that needs closing speed to
	# justify a pass will queue the entire field behind one crashed car and
	# leave it there. Anyone with any nerve at all goes around a parked car.
	if speed_ahead < CRAWLING_MS:
		# Near enough that the move is now. Committing to a line around
		# something forty metres up the road is not a decision yet.
		return gap_ahead < OBSTACLE_PASS_RANGE_M and _profile.aggression > 0.2
	if gap_ahead > desired_gap() * 2.0:
		return false

	# The same reasoning as the parked car, one step short of stopped: how far
	# below this driver's own pace the car in front is running.
	var deficit := 0.0
	if own_plan_ms > 1.0:
		deficit = (own_plan_ms - speed_ahead) / own_plan_ms
	if deficit >= CLEARLY_SLOWER:
		# Sitting behind somebody doing three quarters of your pace is not
		# racing, and it is not something a driver needs much nerve to fix —
		# but it still takes some. Dropping the bar to nothing turns every
		# timid driver into one who will have a go at anything, which shows up
		# as contacts rather than as passes.
		return _profile.aggression > 0.28
	if closing_speed <= 0.5 and deficit < WORTH_A_LOOK:
		return false
	# Nerve, and enough presence of mind to place the car.
	return _profile.aggression > 0.35 and _profile.line_quality > 0.45


## True when the situation calls for lifting or braking regardless of the
## racing line. Reaction is not instant — the picture this is judged on is only
## as fresh as the driver's own scan interval.
func emergency() -> bool:
	if car_ahead == null:
		return false
	# Only a gap that is actually shrinking is an emergency. A car sitting a
	# few metres behind a stationary one is not about to hit it, and calling
	# that a panic stop is half of what pinned the field to the start line.
	# A car in front that is slowing while still moving is a gap about to
	# shrink, so it counts even before the closing speed shows it. A car that
	# has stopped and is sitting on its brakes is not.
	var slowing_ahead := ahead_braking and speed_ahead > CRAWLING_MS
	if closing_speed <= 0.0 and gap_ahead > CONTACT_GAP_M and not slowing_ahead:
		return false
	var margin := lerpf(2.2, 0.9, _profile.recovery)
	return time_to_contact < margin or (slowing_ahead and gap_ahead < desired_gap())
