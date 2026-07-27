extends Node2D
## What a car can actually stop at, against what the plan assumes it can.
##
## The speed profile decides where braking begins by asking how much
## deceleration is available. If that number is optimistic the plan is
## optimistic everywhere, and it goes wrong in the worst possible way: every
## braking point is a little too late, the error grows with speed, and the
## fastest cars in the game are the ones that arrive in the scenery. That is
## exactly the shape of the failure seen at high AI skill — the wrecks scaled
## with the pace of the field rather than with anything the drivers did.
##
## So this drives a real car with the real physics: full throttle to a target
## speed, then everything the brakes have, and measures what comes out.
##
##   godot --headless --path . res://tests/brake_probe.tscn -- [speed_ms]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

## Cars spanning the range that matters: light and slow, mid, and the fast
## four-wheel-drive machinery that was crashing.
const CARS := ["trabant_601", "golf_gti_mk2", "impreza_gc8", "delta_s4",
	"porsche_gt2_rs"]
const SURFACES := [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL]

var _car: RallyCar
var _queue: Array = []
var _target_speed := 35.0
var _phase := "accelerate"
var _brake_from := 0.0
var _brake_time := 0.0
var _accelerating := 0.0
var _results: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_target_speed = float(args[0])

	for id in CARS:
		for surface in SURFACES:
			_queue.append({"car": id, "surface": surface})

	print("=== braking, measured against what the plan assumes ===")
	print("%-26s %-9s %8s %9s %9s %8s" % [
		"car", "surface", "from", "achieved", "assumed", "error"])
	_next()


func _next() -> void:
	if _car != null:
		_car.queue_free()
		_car = null
	if _queue.is_empty():
		_report()
		return
	var job: Dictionary = _queue[0]
	var spec := CarDatabase.get_car(String(job["car"]))
	_car = CAR_SCENE.instantiate()
	_car.car_id = 1
	_car.is_locally_controlled = false
	_car.configure(spec, spec.default_loadout(), {})
	add_child(_car)
	_car.surface = job["surface"] as TireModel.Surface
	_phase = "accelerate"
	_brake_time = 0.0
	_accelerating = 0.0


func _physics_process(delta: float) -> void:
	if _car == null or _queue.is_empty():
		return
	# The surface is re-asserted every step: nothing is driving over a zone to
	# set it, so whatever the car last decided it was standing on would win.
	var job: Dictionary = _queue[0]
	_car.surface = job["surface"] as TireModel.Surface

	if _phase == "accelerate":
		_car.command.throttle = 1.0
		_car.command.brake = 0.0
		_accelerating += delta
		# A Trabant on gravel will never see thirty-five metres per second, and
		# waiting for it is how this probe hung the first time it was run. Brake
		# from whatever the car has got once it has stopped gaining.
		if _car.speed_ms >= _target_speed or _accelerating > 25.0:
			_phase = "brake"
			_brake_from = _car.speed_ms
			_brake_time = 0.0
		return

	_car.command.throttle = 0.0
	_car.command.brake = 1.0
	_brake_time += delta
	# Stop measuring well before a standstill: the last few metres per second
	# are dominated by rolling resistance and are not what a braking zone is
	# made of.
	if _car.speed_ms > _brake_from * 0.35 and _brake_time < 20.0:
		return

	var achieved := (_brake_from - _car.speed_ms) / maxf(_brake_time, 0.001)
	var spec := CarDatabase.get_car(String(job["car"]))
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	# The profile's own function, not a copy of it: a calibration that lives in
	# two places drifts apart, and the first thing to go is the number nobody is
	# checking any more.
	var assumed := SpeedProfile.straight_line_decel(
		stats, job["surface"] as TireModel.Surface)

	print("%-26s %-9s %6.0f m/s %7.1f %9.1f %7.0f%%" % [
		spec.display_name(), TireModel.surface_name(job["surface"]),
		_brake_from, achieved, assumed,
		(assumed / maxf(achieved, 0.01) - 1.0) * 100.0])
	_results.append({"achieved": achieved, "assumed": assumed})
	_queue.pop_front()
	_next()


func _report() -> void:
	var worst := 0.0
	var total := 0.0
	for r in _results:
		var ratio: float = float(r["assumed"]) / maxf(float(r["achieved"]), 0.01)
		worst = maxf(worst, ratio)
		total += ratio
	var mean := total / float(maxi(_results.size(), 1))
	print("\nthe plan assumes %.0f%% of what the cars deliver on average, %.0f%% at worst"
		% [mean * 100.0, worst * 100.0])
	print("(over 100%% means the plan brakes later than the car can, which is how")
	print(" a braking point ends up in a hedge. Under 100%% is merely slow.)")
	get_tree().quit(0)
