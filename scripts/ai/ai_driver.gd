class_name AIDriver
extends RefCounted
## Fills the field in career events.
##
## The AI drives by aiming at a point down the road and deciding a target speed
## from how sharp the road is between here and there. It produces a
## VehicleCommand exactly like a pad does, so it is subject to the same physics,
## the same damage and the same tuning as a player's car — a badly set-up AI
## car is genuinely slower, rather than being scripted to a lap time.

## How far ahead to aim, in metres, at a standstill and at full speed.
const LOOKAHEAD_MIN := 14.0
const LOOKAHEAD_MAX := 55.0
## Lateral acceleration the AI is willing to ask for, as a fraction of the
## car's actual grip. Skill scales this.
const CORNERING_CONFIDENCE := 0.88
## Spacing between the points used to measure how sharp the road is. Long
## enough that a real corner produces a real triangle; short enough that two
## corners in a row are not averaged into one gentle bend.
const CURVATURE_CHORD_M := 18.0

var car: RallyCar
var track: TrackBuilder
## 0 = slow and cautious, 1 = quick and committed.
var skill: float = 0.5
## Small per-driver offset from the racing line so the field does not drive
## nose-to-tail in a single file.
var line_offset_m: float = 0.0

var _command := VehicleCommand.new()
var _progress: float = 0.0
var _stuck_timer: float = 0.0
var _last_position := Vector2.ZERO
var _prev_shift_up: bool = false


func _init(p_car: RallyCar, p_track: TrackBuilder, p_skill: float, p_offset: float) -> void:
	car = p_car
	track = p_track
	skill = clampf(p_skill, 0.0, 1.0)
	line_offset_m = p_offset
	if car != null:
		_last_position = car.global_position
		# AI cars shift for themselves; there is no reason to model a computer
		# driver fumbling a manual box.
		if car.transmission != null:
			car.transmission.mode = Transmission.Mode.AUTOMATIC


func update(delta: float) -> VehicleCommand:
	_command.clear()
	if car == null or track == null or car.damage == null or car.damage.wrecked:
		return _command

	var ppm := GameConfig.PIXELS_PER_METRE
	_progress = track.progress_at(car.global_position)

	var speed := car.speed_ms
	var lookahead_m := lerpf(LOOKAHEAD_MIN, LOOKAHEAD_MAX, clampf(speed / 40.0, 0.0, 1.0))

	# Already off the line? Aim nearer, so the correction is sharper, and back
	# off the speed. Looking a long way down the road while running out of it
	# is how the AI used to end up in the barriers.
	var lateral_error := _lateral_error()
	var edge_m := track.spec.width * 0.5
	var edge_pressure := clampf((absf(lateral_error) - edge_m * 0.45) / maxf(edge_m * 0.55, 0.5),
		0.0, 1.0)
	lookahead_m *= lerpf(1.0, 0.55, edge_pressure)
	var aim := _point_ahead(lookahead_m * ppm)
	var probe := _point_ahead(lookahead_m * ppm * 2.2)

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
	# A less skilled driver is coarser with the wheel and corrects later.
	_command.steer = steer * lerpf(0.82, 1.0, skill)

	# --- Target speed from every corner within braking distance -------------
	# Looking only at the next corner is not enough: at speed the car needs to
	# start braking long before that corner is the nearest thing ahead. So we
	# scan the road out to the full braking distance, work out the entry speed
	# each corner allows, and take the lowest speed that is still reachable.
	var mu_here := TireModel.surface_mu(car.stats, car.surface, true)
	# The AI follows the centreline, which is the tightest way through a
	# corner — a real racing line uses the road's full width and carries far
	# more speed. Until it does, its confidence has to sit well under the
	# theoretical grip limit or it simply runs out of road.
	var confidence := CORNERING_CONFIDENCE * lerpf(0.52, 0.74, skill)
	var brake_decel := maxf(mu_here * 9.81 * car.stats.brake_force * 0.85, 1.0)
	var scan_distance := speed * speed / (2.0 * brake_decel) + LOOKAHEAD_MIN

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
		# The fastest we may be going now and still scrub down to entry_speed
		# by the time we arrive.
		var allowed := sqrt(entry_speed * entry_speed + 2.0 * brake_decel * distance_m)
		if allowed < target_speed:
			target_speed = allowed
		if distance_m <= lookahead_m * 1.5:
			corner_radius = minf(corner_radius, radius)

	# Running wide costs speed too, not just steering angle.
	target_speed *= lerpf(1.0, 0.62, edge_pressure)

	# A point-to-point stage ends. Without this the AI keeps its foot in past
	# the last checkpoint and drives off into open ground at top speed.
	if not track.spec.closed:
		var remaining_m := (track.total_length_px - _progress) / ppm
		if remaining_m < 60.0:
			target_speed = minf(target_speed, maxf(remaining_m * 0.5, 0.0))

	# --- Pedals -------------------------------------------------------------
	if speed < target_speed * 0.95:
		_command.throttle = clampf((target_speed - speed) / 6.0, 0.0, 1.0)
	elif speed > target_speed * 1.06:
		_command.brake = clampf((speed - target_speed) / 8.0, 0.0, 1.0)
		_command.throttle = 0.0

	# Grip spent on turning is grip not available for driving. Holding full
	# throttle at full lock just pushes the car wide, so ease off as the
	# steering loads up — the same thing a driver does without thinking.
	var lock_load := absf(_command.steer)
	_command.throttle *= lerpf(1.0, 0.45, lock_load * lock_load)

	# A very tight corner taken too fast gets the handbrake, which is what a
	# player would do and keeps the AI from simply understeering into a wall.
	if corner_radius < 22.0 and speed > target_speed * 1.25 and absf(steer) > 0.55:
		_command.handbrake = true

	# --- Nitro --------------------------------------------------------------
	# Only when it is pointing where it wants to go and the road is open.
	if car.nitro != null and car.nitro.has_nitro():
		var straight := corner_radius > 90.0
		var committed := absf(steer) < 0.2 and speed > 15.0
		_command.nitro = straight and committed and skill > 0.35

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

	_last_position = car.global_position
	return _command


## A point further along the centreline, pushed sideways by this driver's
## personal line offset.
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
	var offset_px := line_offset_m * GameConfig.PIXELS_PER_METRE
	return sample["pos"] + sample["normal"] * offset_px


## How far the car has strayed from its intended line, in metres. Positive is
## to the right of the road's direction of travel.
func _lateral_error() -> float:
	var here := track._sample_at(_progress)
	var offset: Vector2 = car.global_position - here["pos"]
	var lateral: float = offset.dot(here["normal"]) / GameConfig.PIXELS_PER_METRE
	return lateral - line_offset_m


## Curvature of the road at a point some distance ahead.
##
## The three sample points are spaced a fixed chord apart rather than scaled to
## the scan distance. Three points a couple of metres apart on a real corner
## are so close to collinear that the circle through them is numerically
## meaningless — which showed up as the AI believing a hairpin was a straight
## and arriving at it flat out.
func _curvature_radius_at(distance_px: float) -> float:
	var chord := CURVATURE_CHORD_M * GameConfig.PIXELS_PER_METRE
	var a := _point_ahead(maxf(distance_px - chord, 0.0))
	var b := _point_ahead(distance_px)
	var c := _point_ahead(distance_px + chord)
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
