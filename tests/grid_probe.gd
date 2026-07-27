extends Node
## Watches the first seconds of a race, car by car.
##
## Written because cars were reported sitting on the start grid going nowhere,
## and "a few cars did not move" is not something you can debug by reading the
## AI. This prints, for every entrant, where it is, how fast it is going, what
## its pedals say and how much wheelspin it has, so a car that is stuck can be
## told apart from one that is spinning its wheels, one that is jammed against
## a neighbour and one whose AI is not asking it to go anywhere at all.
##
##   godot --headless --path . res://tests/grid_probe.tscn [-- <track_id>]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
## How long to watch. Long enough to be past the countdown and clear of the
## grid, short enough to run on every change.
const WATCH_SECONDS := 14.0
## A car that has covered less than this many metres by the end is stuck.
const ESCAPED_METRES := 25.0

var _director: RaceDirector
var _elapsed: float = 0.0
var _next_report: float = 0.0
var _start_positions: Array[Vector2] = []
var _peak_slip: Array[float] = []
var _reported := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"

	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("grid_probe: no track '%s'" % track_id)
		get_tree().quit(1)
		return

	# A full grid, because the fault was reported with a field on it and two
	# cars cannot jam each other.
	var event := EventSpec.from_dict({
		"id": "grid_probe",
		"name": "Grid Probe",
		"track": track_id,
		"format": "sprint",
		"laps": 1,
		"payouts": [0],
		"xp": 0,
		"max_car_tier": 3,
		"ai_opponents": 11,
		"ai_skill": 0.5,
	})

	# A human seat is optional: with one, the probe also covers what the field
	# does when somebody is sitting still in front of it, which is what a
	# crashed player looks like from the AI's point of view.
	if args.size() > 1 and String(args[1]) == "with_player":
		PlayerManager.join(DeviceInput.DEVICE_KEYBOARD)
	PlayerManager.ensure_profiles()

	_director = RaceDirector.new()
	add_child(_director)
	_director.setup(event, track, CAR_SCENE)

	print("track: %s (%s, %.0f m)" % [track.display_name, track_id,
		_director.builder.total_length_px / GameConfig.PIXELS_PER_METRE])
	print("entrants: %d" % _director.entrants.size())
	for e in _director.entrants:
		_start_positions.append(e.car.global_position)
		_peak_slip.append(0.0)


func _physics_process(delta: float) -> void:
	if _director == null or _reported:
		return
	_elapsed += delta

	for i in _director.entrants.size():
		var car := _director.entrants[i].car
		if car != null:
			_peak_slip[i] = maxf(_peak_slip[i], absf(car.worst_slip_ratio()))

	if _elapsed >= _next_report:
		_snapshot()
		_next_report += 2.0
	if _elapsed >= WATCH_SECONDS:
		_verdict()


func _snapshot() -> void:
	print("\n--- t = %.1f s (%s) ---" % [_elapsed,
		"countdown" if _director.state == RaceDirector.State.COUNTDOWN else "racing"])
	print("%-22s %7s %6s %5s %5s %5s %4s %5s %5s %6s %6s  %s" % [
		"driver", "moved_m", "km/h", "thr", "brk", "spin", "gear",
		"touch", "off_m", "gap", "wants", "following"])
	for i in _director.entrants.size():
		var e: RaceEntrant = _director.entrants[i]
		var car := e.car
		if car == null:
			continue
		var moved := car.global_position.distance_to(_start_positions[i]) \
			/ GameConfig.PIXELS_PER_METRE
		var off_line := _lateral_offset(car)
		# What the driver believes, next to what is actually happening. A car
		# that is crawling because it thinks something is in front of it looks
		# identical to one that is stuck, until you print this.
		var ahead := "-"
		var gap := 0.0
		var wanted := 0.0
		if e.ai != null and e.ai.awareness != null:
			var aw = e.ai.awareness
			gap = aw.gap_ahead if aw.gap_ahead < 1000.0 else -1.0
			wanted = aw.desired_gap()
			if aw.car_ahead != null:
				ahead = _name_of(aw.car_ahead)
		print("%-22s %7.1f %6.1f %5.2f %5.2f %5.2f %4d %5d %5.1f %6.1f %6.1f  %s" % [
			e.display_name, moved, car.speed_ms * 3.6,
			car.command.throttle, car.command.brake,
			car.driven_slip_ratio(),
			car.transmission.gear if car.transmission != null else 0,
			car._contacting.size(), off_line, gap, wanted, ahead])


func _name_of(car: RallyCar) -> String:
	for e in _director.entrants:
		if e.car == car:
			return e.display_name
	return "?"


## How far the car is from the centre of the road, in metres. A car pinned
## against a wall or wedged in the verge shows up here and nowhere else.
func _lateral_offset(car: RallyCar) -> float:
	var along := _director.builder.progress_at(car.global_position)
	var centre := _director.builder.curve.sample_baked(
		clampf(along, 0.0, _director.builder.total_length_px))
	return car.global_position.distance_to(centre) / GameConfig.PIXELS_PER_METRE


## The answer the probe exists to give: which cars never got off the line, and
## what was happening to them when they did not.
func _verdict() -> void:
	_reported = true
	print("\n=== after %.0f s ===" % WATCH_SECONDS)
	var stuck := 0
	for i in _director.entrants.size():
		var e: RaceEntrant = _director.entrants[i]
		var car := e.car
		if car == null:
			continue
		var moved := car.global_position.distance_to(_start_positions[i]) \
			/ GameConfig.PIXELS_PER_METRE
		if moved >= ESCAPED_METRES:
			continue
		stuck += 1
		# Naming the likely cause rather than the symptom: wheelspin, being
		# held by something, or an AI that never asked for throttle.
		var why := "AI never applied throttle"
		var off_line := _lateral_offset(car)
		var half_road: float = _director.builder.spec.width * 0.5
		if car._contacting.size() > 0:
			why = "held by %d contact(s), %.1f m off line (road half-width %.1f)" % [
				car._contacting.size(), off_line, half_road]
		elif off_line > half_road:
			why = "off the road, %.1f m from centre (half-width %.1f)" % [
				off_line, half_road]
		elif _peak_slip[i] > 0.35:
			why = "wheelspin (peak slip %.2f)" % _peak_slip[i]
		elif car.command.throttle > 0.3:
			why = "throttle applied but held in place"
		print("STUCK  %-26s moved %.1f m — %s" % [e.display_name, moved, why])
	print("stuck: %d of %d" % [stuck, _director.entrants.size()])
	get_tree().quit(0)
