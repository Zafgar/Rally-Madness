extends Node
## Diagnostic harness: one AI car, alone on a track, reporting what it is
## actually doing. Used to tune the driver model without a whole race's worth
## of cars confusing the picture.
##
##   godot --headless --fixed-fps 60 --path . res://tests/ai_probe.tscn \
##       -- <track_id> <car_id> <archetype_or_skill> [tires_part]
##
## The third argument takes either a driver archetype id from drivers.json
## (e.g. sunday_driver, works_driver) or a bare number, which is spread across
## the traits as a plain skill level.

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
const DURATION := 90.0

var _car: RallyCar
var _driver: AIDriver
var _builder: TrackBuilder
var _elapsed: float = 0.0
var _report_timer: float = 0.0
var _impacts: int = 0
var _max_speed: float = 0.0
var _speed_sum: float = 0.0
var _samples: int = 0
var _distance_px: float = 0.0
var _last_progress: float = -1.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	var car_id: String = args[1] if args.size() > 1 else "golf_gti_mk2"
	var driver_arg: String = args[2] if args.size() > 2 else "0.3"

	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("ai_probe: unknown track '%s'" % track_id)
		get_tree().quit(1)
		return

	_builder = TrackBuilder.new(track)
	add_child(_builder.build())

	var spec := CarDatabase.get_car(car_id)
	var loadout := spec.default_loadout()
	# Optional fourth argument fits a tire compound, so the same track can be
	# probed with the right rubber and the wrong rubber.
	if args.size() > 3:
		loadout.set_part("tires", args[3])

	_car = CAR_SCENE.instantiate()
	_car.car_id = 1
	_car.is_locally_controlled = false
	_car.configure(spec, loadout)
	add_child(_car)
	_car.set_spawn(_builder.start_grid[0])

	var profile := _resolve_driver(driver_arg)
	_driver = AIDriver.new(_car, _builder, profile, 0.0, 12345)

	# One crash damages several components at once, so count body events only.
	# Counting every component made a handful of crashes look like dozens.
	EventBus.car_damaged.connect(func(_id, part, amount, remaining):
		if part != "body":
			return
		_impacts += 1
		var along := _builder.progress_at(_car.global_position) / GameConfig.PIXELS_PER_METRE
		print("  %6.1fs  CRASH at %5.0fm (wp %2d)  body -%.3f -> %.2f" % [
			_elapsed, along, _waypoint_near(along), amount, remaining]))

	print("=== AI probe: %s on %s ===" % [spec.display_name(), track_id])
	print("  driver: %s" % profile.describe())
	print("  track length %.0f m, %d checkpoints" % [
		_builder.total_length_px / GameConfig.PIXELS_PER_METRE,
		_builder.checkpoints.size()])


## Accepts either an archetype id from drivers.json or a bare skill number.
func _resolve_driver(arg: String) -> DriverProfile:
	for entry in DriverProfile.load_pool():
		var candidate: DriverProfile = entry["profile"]
		if candidate.archetype == arg:
			return candidate
	if arg.is_valid_float():
		return DriverProfile.from_skill(float(arg))
	push_error("ai_probe: unknown driver '%s'" % arg)
	return DriverProfile.from_skill(0.5)


## Distance covered *along the road*, which is the only metric that actually
## ranks drivers. Average speed is dominated by the straights, where everyone
## is flat out, so it rates a driver who cannot corner almost as highly as one
## who can.
func _track_progress(_delta: float) -> void:
	var here := _builder.progress_at(_car.global_position)
	var length := _builder.total_length_px
	if _last_progress >= 0.0:
		var step := here - _last_progress
		# Crossing the start line wraps the measure; ignore the jump.
		if step < -length * 0.5:
			step += length
		elif step > length * 0.5:
			step -= length
		if absf(step) < length * 0.2:
			_distance_px += step
	_last_progress = here


## Rough waypoint index for a distance along the road, so a crash report points
## at the bit of the track data that needs looking at.
func _waypoint_near(along_m: float) -> int:
	var total := _builder.total_length_px / GameConfig.PIXELS_PER_METRE
	var count := _builder.spec.waypoints.size()
	return clampi(int(along_m / maxf(total, 1.0) * count), 0, count - 1)


func _physics_process(delta: float) -> void:
	if _car == null:
		return
	_elapsed += delta
	_car.command = _driver.update(delta)

	_max_speed = maxf(_max_speed, _car.speed_kmh())
	_speed_sum += _car.speed_kmh()
	_samples += 1
	_track_progress(delta)

	# Dense reporting for the opening seconds, where a bad grid slot or a
	# mis-measured racing line shows up immediately, then sparse after that.
	var interval := 0.5 if _elapsed < 6.0 else 10.0
	_report_timer += delta
	if _report_timer >= interval:
		_report_timer = 0.0
		var here := _builder.progress_at(_car.global_position)
		var sample := _builder._sample_at(here)
		var lateral: float = (_car.global_position - sample["pos"]).dot(sample["normal"]) \
			/ GameConfig.PIXELS_PER_METRE
		print("  %6.1fs  %5.1f km/h  gear %s  thr %.2f brk %.2f steer %+.2f  along %6.0fm  lat %+5.1fm  cond %.2f" % [
			_elapsed, _car.speed_kmh(), _car.transmission.gear_label(),
			_car.command.throttle, _car.command.brake, _car.command.steer,
			here / GameConfig.PIXELS_PER_METRE, lateral, _car.damage.overall()])

	if _elapsed >= DURATION or _car.damage.wrecked:
		var laps := _builder.progress_at(_car.global_position)
		print("\n  ended at %.1fs — %s" % [
			_elapsed, "WRECKED (%s)" % _car.damage.wreck_cause if _car.damage.wrecked else "time up"])
		var covered := _distance_px / GameConfig.PIXELS_PER_METRE
		print("  covered %5.0f m in %.0fs   crashes: %d   avg %.1f km/h   condition %.2f" % [
			covered, _elapsed, _impacts,
			_speed_sum / maxf(_samples, 1), _car.damage.overall()])
		get_tree().quit(0)
