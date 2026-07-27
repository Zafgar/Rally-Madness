class_name AIDriver
extends RefCounted
## Fills the field in career events.
##
## The driver aims at a point down the road and decides a target speed from how
## sharp the road is between here and there. It produces a VehicleCommand
## exactly like a pad does, so it is subject to the same physics, the same
## damage and the same tuning as a player's car — a badly set-up AI car is
## genuinely slower rather than being scripted to a lap time.
##
## How well any of that is done comes from a DriverProfile. That is the whole
## point: a nervous club driver handed a Group B car does not become a works
## driver, they drive at the same pace they always did in something far more
## frightening. Traits pull in different directions, so the field contains
## people rather than difficulty settings.

## How far ahead to aim, in metres, at a standstill and at full speed.
const LOOKAHEAD_MIN := 14.0
const LOOKAHEAD_MAX := 55.0
## Lateral acceleration a fully committed driver is willing to ask for, as a
## fraction of the car's actual grip.
const CORNERING_CONFIDENCE := 0.88
## Spacing between the points used to measure how sharp the road is. Long
## enough that a real corner produces a real triangle; short enough that two
## corners in a row are not averaged into one gentle bend.
const CURVATURE_CHORD_M := 18.0
## How often an inconsistent driver re-rolls their commitment for the next
## corner, in seconds.
const MOOD_INTERVAL := 2.5
## How far off line a driver pulls to make a pass, in metres.
const OVERTAKE_OFFSET_M := 3.2

## How far past the tyre's peak slip ratio counts as fully lit up. Beyond this
## much extra spin the driver is backing off as hard as they are going to.
const TRACTION_SPIN_SPAN := 0.55
## And how far they will back off. Never to nothing: lifting completely in the
## middle of a slide unloads the driven axle and makes it worse.
const TRACTION_FLOOR := 0.25

var car: RallyCar
var track: TrackBuilder
var profile: DriverProfile
## This driver's habitual offset from the centreline, in metres. Poor drivers
## simply sit on it; good ones use it as a starting point and apex properly.
var line_bias_m: float = 0.0

## What this driver can see of the cars around them.
var awareness: RivalAwareness

var _command := VehicleCommand.new()
var _progress: float = 0.0
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
	p_seed: int = 0
) -> void:
	car = p_car
	track = p_track
	profile = p_profile
	line_bias_m = p_line_bias
	awareness = RivalAwareness.new(p_car, p_profile)
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
	_progress = track.progress_at(car.global_position)
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

	# --- Target speed from every corner within braking distance -------------
	# Looking only at the next corner is not enough: at speed the car needs to
	# start braking long before that corner is the nearest thing ahead. So we
	# scan the road out to the full braking distance, work out the entry speed
	# each corner allows, and take the lowest speed that is still reachable.
	var mu_here := TireModel.surface_mu(car.stats, car.surface, true)
	var confidence := CORNERING_CONFIDENCE * lerpf(0.40, 0.78, profile.commitment) * _mood
	var brake_decel := maxf(mu_here * 9.81 * car.stats.brake_force * 0.85, 1.0)
	# A poor braker leaves a large margin and coasts in far too early.
	var braking_margin := lerpf(1.9, 1.05, profile.braking_skill)
	var scan_distance := speed * speed / (2.0 * brake_decel) * braking_margin + LOOKAHEAD_MIN

	var target_speed := 120.0
	var corner_radius := 100000.0
	var steps := 8
	for i in range(1, steps + 1):
		var distance_m := scan_distance * float(i) / float(steps)
		var radius := _curvature_radius_at(distance_m * ppm)
		# Grip is read where the corner actually is. Planning an entry speed
		# from the tarmac under the car is how a driver arrives at an ice patch
		# already carrying far too much speed.
		var surface_there := track.surface_at_offset(_progress + distance_m * ppm)
		var mu := TireModel.surface_mu(car.stats, surface_there, true)
		var entry_speed := sqrt(maxf(radius, 1.0) * mu * 9.81 * confidence)
		var allowed := sqrt(entry_speed * entry_speed + 2.0 * brake_decel * distance_m)
		if allowed < target_speed:
			target_speed = allowed
		if distance_m <= lookahead_m * 1.5:
			corner_radius = minf(corner_radius, radius)

	# Running wide costs speed too, not just steering angle.
	target_speed *= lerpf(1.0, 0.62, edge_pressure)

	# The hard ceiling on pace. Without this, handing a timid driver a fast car
	# turns them into a fast driver, which is exactly backwards.
	target_speed *= profile.pace_ceiling

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

	_overtake_side = 0.0
	if not awareness.wants_to_overtake():
		return

	# Somewhere to go: enough road on that side, and nobody in it.
	var usable := track.spec.width * 0.5 - 2.5
	var here := _lateral_error() + line_bias_m
	for side in [-1.0, 1.0]:
		if awareness.side_blocked(side):
			continue
		if absf(here + side * OVERTAKE_OFFSET_M) > usable:
			continue
		_overtake_side = side
		_overtake_hold = lerpf(1.2, 3.0, profile.aggression)
		return


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


## A point further along the centreline, offset onto whatever line this driver
## is actually capable of taking.
func _point_ahead(distance_px: float) -> Vector2:
	var length := maxf(track.total_length_px, 1.0)
	var target := _progress + distance_px
	if track.spec.closed:
		target = fposmod(target, length)
	else:
		# A point-to-point stage has an end. Wrapping past it would aim the car
		# back at the start line, which is how a stage car ends up driving into
		# the scenery on the run to the finish.
		target = minf(target, length)
	var sample := track._sample_at(target)
	# Habitual line, apex and any overtaking move, together clamped to the road.
	# Without the clamp a committed pass stacks on top of an apex offset and
	# aims the car at the barrier — which is exactly how the quickest drivers
	# were damaging themselves while overtaking.
	var usable := maxf(track.spec.width * 0.5 - 2.2, 0.5)
	var offset_m := clampf(
		line_bias_m + _apex_offset(target, sample) + _overtake_side * OVERTAKE_OFFSET_M,
		-usable, usable)
	return sample["pos"] + sample["normal"] * offset_m * GameConfig.PIXELS_PER_METRE


## How far toward the inside of the upcoming bend this driver puts the car.
##
## Tightening the line at the apex is most of what separates a good line from a
## bad one, and it is the thing weak drivers simply do not do — they sit
## somewhere near the middle of the road and take every corner at its tightest
## possible radius.
func _apex_offset(offset_px: float, sample: Dictionary) -> float:
	if profile.line_quality <= 0.05:
		return 0.0
	var ppm := GameConfig.PIXELS_PER_METRE
	var chord := CURVATURE_CHORD_M * ppm
	var length := maxf(track.total_length_px, 1.0)

	var before := _raw_point(offset_px - chord, length)
	var after := _raw_point(offset_px + chord, length)
	var here: Vector2 = sample["pos"]
	var dir_in := (here - before).normalized()
	var dir_out := (after - here).normalized()
	var turn := dir_out - dir_in
	if turn.length() < 0.02:
		return 0.0

	# Which side the road is turning toward is the inside of the bend.
	var normal: Vector2 = sample["normal"]
	var inside := signf(turn.dot(normal))
	var sharpness := clampf(turn.length() * 2.0, 0.0, 1.0)
	# Never aim closer to the edge than a car's width leaves room for.
	var usable := maxf(track.spec.width * 0.5 - 2.5, 0.0)
	return inside * usable * sharpness * profile.line_quality


func _raw_point(offset_px: float, length: float) -> Vector2:
	var target := fposmod(offset_px, length) if track.spec.closed \
		else clampf(offset_px, 0.0, length)
	return track._sample_at(target)["pos"]


## How far the car has strayed from its intended line, in metres. Positive is
## to the right of the road's direction of travel.
func _lateral_error() -> float:
	var here := track._sample_at(_progress)
	var offset: Vector2 = car.global_position - here["pos"]
	var lateral: float = offset.dot(here["normal"]) / GameConfig.PIXELS_PER_METRE
	return lateral - line_bias_m


## Curvature of the road at a point some distance ahead.
##
## The three sample points are spaced a fixed chord apart rather than scaled to
## the scan distance. Three points a couple of metres apart on a real corner
## are so close to collinear that the circle through them is numerically
## meaningless — which showed up as the AI believing a hairpin was a straight
## and arriving at it flat out.
func _curvature_radius_at(distance_px: float) -> float:
	var chord := CURVATURE_CHORD_M * GameConfig.PIXELS_PER_METRE
	var length := maxf(track.total_length_px, 1.0)
	var a := _raw_point(_progress + distance_px - chord, length)
	var b := _raw_point(_progress + distance_px, length)
	var c := _raw_point(_progress + distance_px + chord, length)
	return _radius_through(a, b, c) / GameConfig.PIXELS_PER_METRE


## Radius of the circle through three points. Straight lines give a huge radius,
## which is exactly the "no need to slow down" signal we want.
static func _radius_through(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	var area := absf((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
	if area < 0.001:
		return 100000.0
	return (ab * bc * ca) / (4.0 * area)
