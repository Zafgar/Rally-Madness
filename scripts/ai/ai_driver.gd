class_name AIDriver
extends RefCounted
## Fills the field in career events.
##
## The driver follows a plan. Before the race starts, the road is read into a
## TrackModel, a RacingLine is solved through it, and a SpeedProfile is solved
## for this specific car with its specific parts — which gives a target speed at
## every point on the track and, as a consequence rather than a decision, the
## place where braking has to begin.
##
## It used to work the other way round: scan a few points ahead every frame and
## react to what turned up. That reads plausibly and drives badly, and the way
## it fails is instructive. Reacting to a corner is always too late, because the
## moment you can see you are carrying too much speed is the moment it is
## already too late to shed it. The only lever left was to make the driver
## slower everywhere, so skill and safety were the same number: turning the AI
## up made the field faster into corners without making it any better at them,
## and a probe at high skill returned six wrecks out of eight.
##
## With a plan, skill stops being that number. Everybody knows where the
## braking point is; what a good driver has is a later one, a tighter line and
## the nerve to use the road. A poor driver on the same plan is slower and still
## arrives.
##
## It produces a VehicleCommand exactly like a pad does, so it is subject to the
## same physics, damage and tuning as a player's car — a badly set-up AI car is
## genuinely slower rather than scripted to a lap time.
##
## How well any of it is done comes from a DriverProfile. A nervous club driver
## handed a Group B car does not become a works driver; they drive at the pace
## they always did in something far more frightening.

## How far ahead to aim, in metres, at a standstill and at full speed.
const LOOKAHEAD_MIN := 14.0
const LOOKAHEAD_MAX := 55.0
## How often an inconsistent driver re-rolls their commitment for the next
## corner, in seconds.
const MOOD_INTERVAL := 2.5
## How far off line a driver pulls to make a pass, in metres.
const OVERTAKE_OFFSET_M := 3.2
## Road needed beyond the gap itself to call a pass complete: both cars' length
## plus enough to pull back in front without touching.
const PASS_CLEARANCE_M := 12.0
## How close the next corner has to be before it decides which side to pass on.
## Beyond this the corner and the move are separate events and the corner has
## nothing useful to say about the move.
const INSIDE_LINE_RANGE_M := 90.0
## Below this the car in front is not a rival to be raced, it is a stationary
## object to be driven round, and the pass zones do not apply.
const STOPPED_RIVAL_MS := 3.0

## How far past the tyre's peak slip ratio counts as fully lit up. Beyond this
## much extra spin the driver is backing off as hard as they are going to.
const TRACTION_SPIN_SPAN := 0.55
## And how far they will back off. Never to nothing: lifting completely in the
## middle of a slide unloads the driven axle and makes it worse.
const TRACTION_FLOOR := 0.25

## How much of the plan's speed a driver at the bottom and the top of the range
## actually asks for.
##
## Deliberately narrow. The plan is already a speed the car can hold, so this is
## the difference between a driver who uses all of it and one who leaves a bit
## in hand — not, as the old scaling was, the only thing standing between the
## field and the scenery. A wide band here is how "harder AI" turns into "AI
## that crashes".
const PACE_FLOOR := 0.80
const PACE_CEILING := 1.01

## How far ahead a driver with no anticipation at all is already reacting to,
## and how far for one with perfect anticipation, in metres.
##
## Both are short, because the plan has already put the braking point in the
## right place — this is reaction time on top of it, not the braking itself. A
## poor braker looks further ahead and so starts easing off earlier than they
## need to, which costs time everywhere and costs nothing in safety.
const ANTICIPATION_POOR_M := 30.0
const ANTICIPATION_GOOD_M := 8.0

## How much of the calibrated braking a driver with no braking skill at all
## plans to use. Their braking points are genuinely earlier, rather than the
## same points taken more timidly.
const BRAKE_MARGIN_POOR := 0.70

var car: RallyCar
var track: TrackBuilder
var profile: DriverProfile
## This driver's habitual offset from the racing line, in metres. Small: with a
## line to follow, a personal quirk is a quirk rather than a private route.
var line_bias_m: float = 0.0

## The recce. Shared across the field — the road is the same for everybody.
var model: TrackModel
var line: RacingLine
## And this car's own answer to it, solved from its own resolved stats.
var plan: SpeedProfile

## What this driver can see of the cars around them.
var awareness: RivalAwareness

var _command := VehicleCommand.new()
## -1 rather than 0: zero is a *plausible* hint — the start line — and a car
## sitting on a grid slot behind it would have its first lookup quietly answered
## with the wrong end of the track.
var _progress: float = -1.0
var _stuck_timer: float = 0.0
var _mood_timer: float = 0.0
## Current commitment after consistency wander, re-rolled every MOOD_INTERVAL.
var _mood: float = 1.0
## Which side we have committed to for a pass, and for how much longer.
var _overtake_side: float = 0.0
var _overtake_hold: float = 0.0
var _rng := RandomNumberGenerator.new()


func _init(
	p_car: RallyCar,
	p_track: TrackBuilder,
	p_profile: DriverProfile,
	p_line_bias: float,
	p_seed: int = 0,
	p_model: TrackModel = null,
	p_line: RacingLine = null
) -> void:
	car = p_car
	track = p_track
	profile = p_profile
	line_bias_m = p_line_bias
	awareness = RivalAwareness.new(p_car, p_profile)

	# The recce is handed in when there is a field to share it with, and read
	# here when there is not — a probe or a test driving one car should not have
	# to know that the AI needs a plan before it can drive.
	model = p_model if p_model != null else TrackModel.analyse(p_track)
	line = p_line if p_line != null else RacingLine.solve(model)
	if car != null and car.stats != null:
		# The plan is this driver's, not just this car's. A poor braker's plan
		# has genuinely earlier braking points in it — which is a different
		# thing from approaching the same points more slowly, and looks
		# different from outside the car.
		plan = SpeedProfile.solve(model, line, car.stats,
			lerpf(BRAKE_MARGIN_POOR, 1.0, profile.braking_skill))
	_rng.seed = p_seed if p_seed != 0 else hash(p_profile.display_name)
	if car != null and car.transmission != null:
		# Weaker drivers leave it in automatic and never use the rev range
		# properly; that is part of not getting everything out of the car.
		car.transmission.mode = Transmission.Mode.MANUAL if profile.uses_manual_gearbox \
			else Transmission.Mode.AUTOMATIC


func update(delta: float) -> VehicleCommand:
	_command.clear()
	if car == null or track == null or car.damage == null or car.damage.wrecked:
		return _command

	var ppm := GameConfig.PIXELS_PER_METRE
	# Handing the last answer back turns a scan of the whole track into a
	# search of the forty metres around where this car actually was.
	_progress = track.progress_at(car.global_position, _progress)
	_update_mood(delta)
	awareness.update(delta)

	var speed := car.speed_ms
	# A driver who does not look far ahead cannot plan, which is a large part
	# of why a poor one is slow everywhere rather than just in corners.
	var vision := lerpf(0.55, 1.0, profile.line_quality)
	var lookahead_m := lerpf(LOOKAHEAD_MIN, LOOKAHEAD_MAX,
		clampf(speed / 40.0, 0.0, 1.0)) * vision

	# Already off the line? Aim nearer, so the correction is sharper, and back
	# off the speed.
	var lateral_error := _lateral_error()
	var edge_m := track.spec.width * 0.5
	var edge_pressure := clampf(
		(absf(lateral_error) - edge_m * 0.45) / maxf(edge_m * 0.55, 0.5), 0.0, 1.0)
	lookahead_m *= lerpf(1.0, 0.55, edge_pressure)

	_update_overtake(delta)
	var aim := _point_ahead(lookahead_m * ppm)

	# --- Steering -----------------------------------------------------------
	# Pure pursuit: the steering angle that puts the car on an arc through the
	# aim point, given its wheelbase. Steering by the raw bearing to the aim
	# point instead — the obvious-looking shortcut — asks for far more lock
	# than the geometry needs and saturates the rack in every corner.
	var to_aim := (aim - car.global_position).rotated(-car.rotation)
	var lookahead_px := maxf(to_aim.length(), 1.0)
	var alpha := atan2(to_aim.y, to_aim.x)
	var wheelbase_px := car.stats.wheelbase_m * ppm
	var required := atan2(2.0 * wheelbase_px * sin(alpha), lookahead_px)
	var steer := clampf(required / deg_to_rad(car.stats.max_steer_deg), -1.0, 1.0)
	# A less precise driver is coarser with the wheel and corrects later.
	_command.steer = steer * lerpf(0.80, 1.0, profile.line_quality)

	# --- Target speed, read off the plan ------------------------------------
	# The whole braking problem is already solved: the profile's backward pass
	# guarantees that the speed at any point can be shed in time for the speed
	# at the next one, so simply driving the number here arrives at every corner
	# on the limit and no faster. What is left for the driver is how much of it
	# they use and how far ahead they are already thinking.
	var s_m := _progress / ppm
	# Anticipation. A good braker holds on until the plan says to lift; a poor
	# one is already reacting to something fifty metres away and eases off long
	# before they need to. Both arrive; one of them is slow.
	var anticipation := lerpf(ANTICIPATION_POOR_M, ANTICIPATION_GOOD_M,
		profile.braking_skill)
	var target_speed := plan.speed_ahead(s_m, anticipation) if plan != null else 25.0
	var corner_radius := line.radius_at(model.index_at(s_m + lookahead_m))

	# Running wide costs speed. Off the line the plan does not apply — its
	# curvature is the line's, not whatever arc the car is actually on.
	target_speed *= lerpf(1.0, 0.62, edge_pressure)

	# How much of the plan this driver asks for. A narrow band on purpose: the
	# plan is a speed the car can hold, so this is the difference between using
	# all of it and leaving a little in hand. It used to be a wide multiplier
	# applied to a target that was already optimistic, which is how turning the
	# AI up produced a faster, deader field rather than a harder one.
	target_speed *= _pace_factor()

	# Someone who does not look after the car backs off when it is hurt.
	if car.damage.overall() < 0.5:
		target_speed *= lerpf(1.0, 0.75, profile.mechanical_sympathy)

	# A point-to-point stage ends. Without this the AI keeps its foot in past
	# the last checkpoint and drives off into open ground at top speed.
	if not track.spec.closed:
		var remaining_m := (track.total_length_px - _progress) / ppm
		if remaining_m < 60.0:
			target_speed = minf(target_speed, maxf(remaining_m * 0.5, 0.0))

	# --- Traffic ------------------------------------------------------------
	target_speed = _apply_traffic(target_speed, speed)

	# --- Pedals -------------------------------------------------------------
	if speed < target_speed * 0.95:
		var demand := clampf((target_speed - speed) / 6.0, 0.0, 1.0)
		# Poor throttle discipline means clumsy application: either lazy or
		# all-or-nothing, and neither gets the most out of the car.
		if profile.throttle_discipline < 0.5:
			demand = 1.0 if demand > 0.35 else demand * 0.6
		_command.throttle = demand
	elif speed > target_speed * 1.06:
		_command.brake = clampf((speed - target_speed) / 8.0, 0.0, 1.0)
		_command.throttle = 0.0

	# --- Traction -----------------------------------------------------------
	# A driver feels the wheels light up and eases off. Without this the AI held
	# the pedal flat from rest, the tyres spun at three times road speed and a
	# 500 hp car left the line slower than a shopping hatchback — which is how
	# a start grid turned into a queue of cars going nowhere.
	var spin := car.driven_slip_ratio()
	if spin > TireModel.BASE_PEAK_SLIP_RATIO:
		var over := (spin - TireModel.BASE_PEAK_SLIP_RATIO) / TRACTION_SPIN_SPAN
		# How quickly they catch it is throttle discipline, which is what the
		# words mean: a clumsy driver sits in the wheelspin far longer.
		var catch_rate := lerpf(0.40, 1.00, profile.throttle_discipline)
		_command.throttle *= clampf(1.0 - over * catch_rate, TRACTION_FLOOR, 1.0)

	# Grip spent on turning is grip not available for driving. Holding full
	# throttle at full lock just pushes the car wide, so ease off as the
	# steering loads up — the same thing a good driver does without thinking,
	# and something a bad one does not do at all.
	var lock_load := absf(_command.steer)
	var lift := lerpf(0.85, 0.45, profile.throttle_discipline)
	_command.throttle *= lerpf(1.0, lift, lock_load * lock_load)

	# --- Avoiding contact ---------------------------------------------------
	if awareness.emergency():
		# How hard depends on the driver. A good one brakes decisively and
		# leaves themselves somewhere to go; a poor one stamps on it, locks up
		# and is a passenger.
		_command.throttle = 0.0
		_command.brake = maxf(_command.brake, lerpf(1.0, 0.75, profile.braking_skill))
		if profile.recovery > 0.5 and _overtake_side != 0.0:
			_command.steer = clampf(_command.steer + _overtake_side * 0.25, -1.0, 1.0)

	# Never steer into someone who is already beside us.
	if awareness.side_blocked(signf(_command.steer)) and absf(_command.steer) > 0.05:
		_command.steer *= lerpf(0.15, 0.45, profile.awareness)

	# --- Recovering a slide -------------------------------------------------
	# A driver who cannot catch the car keeps their foot in and spins.
	if car.is_drifting and absf(car.slip_angle_rear) > 0.35:
		if profile.recovery > 0.5:
			# Counter-steer and ease off, in proportion to how good they are.
			_command.steer = clampf(
				_command.steer - signf(car.slip_angle_rear) * profile.recovery * 0.5, -1.0, 1.0)
			_command.throttle *= lerpf(1.0, 0.55, profile.recovery)
		else:
			_command.throttle *= lerpf(1.0, 0.85, profile.aggression)

	# A very tight corner taken too fast gets the handbrake, which is what a
	# committed driver would do and keeps the AI from understeering into a wall.
	if corner_radius < 22.0 and speed > target_speed * 1.25 and absf(steer) > 0.55:
		_command.handbrake = profile.recovery > 0.4

	# --- Manual shifting ----------------------------------------------------
	if profile.uses_manual_gearbox:
		_shift(delta)

	# --- Nitro --------------------------------------------------------------
	if car.nitro != null and car.nitro.has_nitro():
		var straight := corner_radius > 90.0
		var committed := absf(steer) < 0.2 and speed > 15.0
		# An aggressive driver lights it up on any half-opportunity; a cautious
		# one saves it and often never uses it at all.
		var wants := straight and committed
		if profile.aggression < 0.3:
			wants = wants and car.nitro.charge_fraction() > 0.8
		_command.nitro = wants and profile.aggression > 0.2

	# --- Unsticking ---------------------------------------------------------
	# Without this, one AI nosed into a barrier blocks the whole field forever.
	if speed < 1.5:
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	if _stuck_timer > 2.0:
		# Backing out, which means asking for reverse rather than leaning on
		# the brake and hoping. Holding the brake used to select reverse for
		# everyone; it no longer does for an AI, because in reverse the brake
		# is the accelerator and a computer sitting on it would drive itself
		# backwards down the stage. So the request is explicit — and without
		# it this recovery quietly stopped working and cars sat in ditches
		# until the respawn timer bailed them out.
		_command.request_reverse = true
		_command.throttle = 0.0
		_command.brake = 1.0
		_command.steer = -signf(steer) if not is_zero_approx(steer) else 1.0
		if _stuck_timer > 4.5:
			_command.respawn = true
			_stuck_timer = 0.0

	return _command


## Holds back for the car in front.
##
## The gap a driver wants is the whole difference between a nervous novice and a
## works driver in traffic: one of them sits twenty metres back and never gets
## past, the other runs close enough to use the tow and is ready when a gap
## appears. Both are following the same rule with a different number in it.
func _apply_traffic(target_speed: float, speed: float) -> float:
	if awareness.car_ahead == null:
		return target_speed

	var gap := awareness.gap_ahead
	var wanted := awareness.desired_gap()
	# Passing? Then the car ahead is not the thing setting our speed.
	if _overtake_side != 0.0 and gap > wanted * 0.6:
		return target_speed

	if gap > wanted * 2.0:
		return target_speed

	# Match their speed at the desired gap, and scrub off proportionally when
	# closer than that. Reaction lag lives in how often the picture refreshes,
	# not here, so a slow driver is late to this rather than gentle about it.
	var follow_speed: float = awareness.speed_ahead + (gap - wanted) * 0.9
	if awareness.ahead_braking:
		follow_speed = minf(follow_speed, awareness.speed_ahead)
	# Matching the car ahead holds the gap exactly where it is, so a driver who
	# merely wants more room than they have should ease off rather than stop.
	# Without this floor, wanting a bigger gap than the road is currently
	# giving you is enough to brake to a standstill — and the car behind then
	# does the same, and so on down the field.
	if gap > RivalAwareness.STANDING_GAP_M:
		follow_speed = maxf(follow_speed, awareness.speed_ahead * 0.85)
	return minf(target_speed, maxf(follow_speed, 0.0))


## Decides whether to pull out, and which way.
##
## Committing to a side and holding it matters more than picking the perfect
## one: a driver who changes their mind halfway across is worse than one who
## never tried. The commitment decays once the move is done or the gap is gone.
func _update_overtake(delta: float) -> void:
	if _overtake_hold > 0.0:
		_overtake_hold -= delta
		if awareness.car_ahead == null or awareness.side_blocked(_overtake_side):
			_overtake_hold = 0.0
			_overtake_side = 0.0
			return
		# Room ran out before the move did. Tucking back in behind is not a
		# failure — arriving at the corner alongside somebody is, and that is
		# what used to happen because there was nothing here to change its mind.
		var s_m := _progress / GameConfig.PIXELS_PER_METRE
		if model != null and awareness.speed_ahead >= STOPPED_RIVAL_MS \
				and not model.pass_is_on(s_m):
			_overtake_hold = 0.0
			_overtake_side = 0.0
		return

	_overtake_side = 0.0
	if not awareness.wants_to_overtake(_plan_speed_here()):
		return
	if not _pass_can_be_finished():
		return

	# Somewhere to go: enough road on that side, and nobody in it.
	var usable := track.spec.width * 0.5 - 2.5
	var here := _lateral_error() + line_bias_m
	for side in _sides_worth_trying(here):
		if awareness.side_blocked(side):
			continue
		if absf(here + side * OVERTAKE_OFFSET_M) > usable:
			continue
		_overtake_side = side
		_overtake_hold = lerpf(1.2, 3.0, profile.aggression)
		return


## Which way to go round, best first.
##
## This used to be a fixed list — left, then right — so every driver in the game
## tried the left first regardless of what the road was doing, and a move that
## the corner ahead made impossible was attempted anyway. The recce knows which
## way the next corner goes, and the inside of it is both the shorter way round
## and the side the other car has to leave open on the way in. Failing a corner
## worth caring about, the answer is simply whichever side has more road.
func _sides_worth_trying(here: float) -> Array:
	var prefer := 0.0
	if model != null:
		var s_m := _progress / GameConfig.PIXELS_PER_METRE
		var corner := model.next_corner(s_m)
		# Only when the corner is close enough that the move and the corner are
		# the same event. A hairpin four hundred metres away says nothing about
		# which side to use on this straight.
		if corner != null and model.distance_to_next_corner(s_m) < INSIDE_LINE_RANGE_M:
			prefer = signf(corner.direction)
	if prefer == 0.0:
		# No corner in play: take the side with more road left on it.
		prefer = -1.0 if here > 0.0 else 1.0
	return [prefer, -prefer]


## What the plan says this car could be doing right here, in m/s. The number the
## decision to overtake is measured against.
func _plan_speed_here() -> float:
	if plan == null:
		return 0.0
	return plan.speed_at(_progress / GameConfig.PIXELS_PER_METRE)


## Whether there is enough road left to get past before somebody has to brake.
##
## This is the question the AI could never answer. It knew there was a car in
## front and that it was quicker; it had no idea whether two hundred metres of
## straight lay ahead or forty, so it committed to the same move in both cases
## and in one of them arrived at the corner side by side. That is where the
## contacts came from, and the contacts are where the wrecks came from.
##
## Now the recce answers it. The pass zones say where a move is realistic at
## all, and the closing speed says how long this particular one would take.
## Neither number is a guess.
func _pass_can_be_finished() -> bool:
	if model == null or awareness.car_ahead == null:
		return false
	var s_m := _progress / GameConfig.PIXELS_PER_METRE

	# A car that has come to a stop is an obstacle rather than a rival, and you
	# get past an obstacle wherever you find it.
	if awareness.speed_ahead < STOPPED_RIVAL_MS:
		return true

	# Anywhere else, the move has to be somewhere the road allows one.
	if not model.pass_is_on(s_m):
		return false

	# And it has to fit. How long a pass takes is how long it takes to cover
	# the gap plus both cars' lengths at the speed difference between them —
	# which for a small difference is a very long time, and is exactly why
	# following a slightly slower car for half a lap is the correct answer
	# rather than a failure of nerve.
	#
	# The difference that matters is the one the move would be made at, not the
	# one showing on the clock now. A driver who has already slowed to match the
	# car in front is closing at zero, and dividing by that says every pass takes
	# forever — so the rule that is meant to stop optimistic moves ends up
	# forbidding every move instead, exactly when a queue has formed.
	#
	# The speed to use is not the plan's either. Taking the full difference
	# between the plan and the rival assumes the car is already doing plan speed
	# the instant it pulls out, which greenlit moves that did not fit: it took
	# contacts from two to nine in a probe and finishers from six to four. The
	# car accelerates from where it is to where the plan allows, so the average
	# over the move is the average of the two — which is both more honest and
	# what actually happens.
	var reachable := (car.speed_ms + _plan_speed_here()) * 0.5 - awareness.speed_ahead
	var closing := maxf(maxf(awareness.closing_speed, reachable), 0.01)
	var to_cover := awareness.gap_ahead + PASS_CLEARANCE_M
	var seconds := to_cover / closing
	var room_needed := seconds * maxf(car.speed_ms, 1.0)
	var room := model.pass_room(s_m)

	# A bold driver will start a move they are not certain of finishing; a
	# cautious one wants it comfortably in hand. Neither will try one that
	# plainly does not fit.
	var confidence := lerpf(1.35, 0.85, profile.aggression)
	return room > room_needed * confidence


## How much of the plan's speed this driver asks for, right now.
##
## Built from the two traits that describe pace — the ceiling they drive to and
## how much of the grip they will commit — and then moved by mood, so a corner
## comes at nine tenths and the next at full commitment.
func _pace_factor() -> float:
	var ability := profile.pace_ceiling * 0.6 + profile.commitment * 0.4
	return lerpf(PACE_FLOOR, PACE_CEILING, clampf(ability, 0.0, 1.0)) * _mood


## Consistency as a wandering commitment rather than per-frame noise. Jitter on
## the controls looks like a broken driver; a corner taken at nine tenths and
## the next at full commitment looks like a human one.
func _update_mood(delta: float) -> void:
	_mood_timer -= delta
	if _mood_timer > 0.0:
		return
	_mood_timer = MOOD_INTERVAL
	var spread := (1.0 - profile.consistency) * 0.35
	_mood = clampf(1.0 - _rng.randf_range(0.0, spread * 2.0) + spread * 0.5, 0.45, 1.15)


## Manual gear selection. A driver using the box properly holds gears to the
## power peak; the automatic box the weaker drivers leave it in shifts early
## and never does.
func _shift(_delta: float) -> void:
	if car.transmission.is_shifting:
		return
	var rev_fraction := car.transmission.rpm / maxf(car.stats.redline_rpm, 1.0)
	var upshift_point := lerpf(0.82, 0.97, profile.throttle_discipline)
	if rev_fraction > upshift_point and car.transmission.gear < car.transmission.top_gear():
		_command.shift_up = true
	elif rev_fraction < 0.45 and car.transmission.gear > 1:
		_command.shift_down = true
	elif car.transmission.gear <= 0 and _command.throttle > 0.1:
		car.transmission.shift_to(1)


## A point further down the road, on the line this driver is capable of taking.
##
## The line itself is solved once for the track and shared by the whole field.
## What varies between drivers is how much of it they use: the offsets are
## scaled by line quality, so a weak driver ends up somewhere near the middle of
## the road taking every corner at its tightest radius — which is exactly what a
## weak driver does — while a good one is on the apex.
func _point_ahead(distance_px: float) -> Vector2:
	var ppm := GameConfig.PIXELS_PER_METRE
	var s_m := _progress / ppm + distance_px / ppm
	var i := model.index_at(s_m)

	# Habitual quirk, the racing line as far as this driver can use it, and any
	# overtaking move — together clamped to the road. Without the clamp a
	# committed pass stacks on top of an apex offset and aims the car at the
	# barrier, which is how the quickest drivers used to damage themselves while
	# overtaking.
	var usable := maxf(track.spec.width * 0.5 - 2.2, 0.5)
	var offset_m := clampf(
		line_bias_m
			+ line.offsets[i] * lerpf(0.15, 1.0, profile.line_quality)
			+ _overtake_side * OVERTAKE_OFFSET_M,
		-usable, usable)
	return model.positions[i] + model.normals[i] * offset_m * ppm


## How far the car has strayed from its intended line, in metres. Positive is
## to the right of the road's direction of travel.
func _lateral_error() -> float:
	var ppm := GameConfig.PIXELS_PER_METRE
	var i := model.index_at(_progress / ppm)
	var offset: Vector2 = car.global_position - model.positions[i]
	var lateral: float = offset.dot(model.normals[i]) / ppm
	# Measured against where this driver is trying to be, not against the middle
	# of the road. A car sitting perfectly on the apex is not off line, and
	# treating it as though it were made every driver back off in exactly the
	# place the line was earning its keep.
	var wanted := line_bias_m + line.offsets[i] * lerpf(0.15, 1.0, profile.line_quality)
	return lateral - wanted

