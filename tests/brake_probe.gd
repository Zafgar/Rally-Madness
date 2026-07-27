extends Node2D
## What a car can actually stop and turn at, against what the plan assumes.
##
## The speed profile decides where braking begins and how fast a corner can be
## taken by asking how much grip is available. If either number is optimistic
## the plan is optimistic everywhere, and it goes wrong in the worst possible
## way: the error grows with the car's grip, so the fastest cars in the game are
## the ones that arrive in the scenery. That is exactly the shape of the failure
## seen at high AI skill — the wrecks scaled with the pace of the field rather
## than with anything the drivers did.
##
## The obvious formula is peak mu times gravity. Peak mu is what a tyre makes at
## exactly the right slip angle and slip ratio, held for an instant. A real stop
## and a real corner both average a good deal less, and how much less depends on
## the tyre — which is why a single fudge factor cannot be guessed and has to be
## measured.
##
## So this drives real cars with the real physics: full throttle, then
## everything the brakes have, then a sustained corner at full lock.
##
##   godot --headless --path . res://tests/brake_probe.tscn -- [speed_ms]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

## Cars spanning the range that matters: light and slow, mid, and the fast
## machinery that was crashing.
const CARS := ["trabant_601", "golf_gti_mk2", "impreza_gc8", "delta_s4",
	"porsche_gt2_rs"]
const SURFACES := [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL]

## Speed the cornering measurement is taken at. Low enough that every car in the
## list reaches it, high enough to be a corner rather than a manoeuvre.
const CORNER_SPEED_MS := 22.0

var _car: RallyCar
var _queue: Array = []
var _target_speed := 35.0
var _phase := "accelerate"
var _brake_from := 0.0
var _brake_time := 0.0
var _accelerating := 0.0
var _decel := 0.0
var _corner_time := 0.0
var _yaw_total := 0.0
var _results: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_target_speed = float(args[0])

	for id in CARS:
		for surface in SURFACES:
			_queue.append({"car": id, "surface": surface})

	print("=== grip, measured against what the plan assumes ===")
	print("%-24s %-8s %8s %8s %6s %9s %9s %6s" % [
		"car", "surface", "brake", "assumed", "err", "corner", "assumed", "err"])
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
	_corner_time = 0.0
	_yaw_total = 0.0


func _physics_process(delta: float) -> void:
	if _car == null or _queue.is_empty():
		return
	# The surface is re-asserted every step: nothing is driving over a zone to
	# set it, so whatever the car last decided it was standing on would win.
	var job: Dictionary = _queue[0]
	_car.surface = job["surface"] as TireModel.Surface

	match _phase:
		"accelerate": _do_accelerate(delta)
		"brake": _do_brake(delta)
		"corner": _do_corner(delta)


func _do_accelerate(delta: float) -> void:
	_car.command.throttle = 1.0
	_car.command.brake = 0.0
	_car.command.steer = 0.0
	_accelerating += delta
	# A Trabant on gravel will never see thirty-five metres per second, and
	# waiting for it is how this probe hung the first time it was run. Brake
	# from whatever the car has got once it has stopped gaining.
	if _car.speed_ms >= _target_speed or _accelerating > 25.0:
		_phase = "brake"
		_brake_from = _car.speed_ms
		_brake_time = 0.0


func _do_brake(delta: float) -> void:
	_car.command.throttle = 0.0
	_car.command.brake = 1.0
	_car.command.steer = 0.0
	_brake_time += delta
	# Stop measuring well before a standstill: the last few metres per second
	# are dominated by rolling resistance and are not what a braking zone is
	# made of.
	if _car.speed_ms > _brake_from * 0.35 and _brake_time < 20.0:
		return
	_decel = (_brake_from - _car.speed_ms) / maxf(_brake_time, 0.001)
	_phase = "corner"
	_corner_time = 0.0
	_yaw_total = 0.0


## A sustained corner at full lock, held at a steady speed.
##
## Lateral acceleration comes out as speed times yaw rate, which needs no
## assumption about where the centre of the circle is — the car simply tells you
## how fast it is turning while you watch how fast it is going.
func _do_corner(delta: float) -> void:
	_car.command.steer = 1.0
	# Throttle held to keep the speed roughly steady, so the tyres are spending
	# their grip on turning rather than on accelerating.
	var error := CORNER_SPEED_MS - _car.speed_ms
	_car.command.throttle = clampf(error * 0.3, 0.0, 0.45)
	_car.command.brake = clampf(-error * 0.15, 0.0, 0.5)

	_corner_time += delta
	# The first second is turn-in, not steady state, and includes a yaw
	# transient that would flatter the answer considerably.
	if _corner_time > 1.0:
		_yaw_total += absf(_car.angular_velocity) * _car.speed_ms * delta
	if _corner_time < 5.0:
		return

	var measured := _corner_time - 1.0
	var lateral := _yaw_total / maxf(measured, 0.001)
	_finish(lateral)


func _finish(lateral: float) -> void:
	var job: Dictionary = _queue[0]
	var spec := CarDatabase.get_car(String(job["car"]))
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var surface := job["surface"] as TireModel.Surface
	# The profile's own functions, not copies of them: a calibration that lives
	# in two places drifts apart, and the first thing to go wrong is the number
	# nobody is checking any more.
	var assumed_brake := SpeedProfile.straight_line_decel(stats, surface)
	var assumed_lateral := SpeedProfile.cornering_accel(stats, surface)

	print("%-24s %-8s %7.1f %8.1f %5.0f%% %8.1f %9.1f %5.0f%%" % [
		spec.display_name(), TireModel.surface_name(surface),
		_decel, assumed_brake, (assumed_brake / maxf(_decel, 0.01) - 1.0) * 100.0,
		lateral, assumed_lateral,
		(assumed_lateral / maxf(lateral, 0.01) - 1.0) * 100.0])
	_results.append({
		"brake": _decel, "assumed_brake": assumed_brake,
		"lateral": lateral, "assumed_lateral": assumed_lateral,
	})
	_queue.pop_front()
	_next()


func _report() -> void:
	print("")
	for axis in [["brake", "assumed_brake", "braking"],
			["lateral", "assumed_lateral", "cornering"]]:
		var worst := 0.0
		var total := 0.0
		for r in _results:
			var ratio: float = float(r[axis[1]]) / maxf(float(r[axis[0]]), 0.01)
			worst = maxf(worst, ratio)
			total += ratio
		print("%-10s the plan assumes %3.0f%% of what the cars deliver, %3.0f%% at worst"
			% [axis[2] + ":", total / float(maxi(_results.size(), 1)) * 100.0,
				worst * 100.0])
	print("\n(over 100% means the plan asks for more than the car has, which is how")
	print(" a braking point or an apex ends up in a hedge. Under is merely slow.)")
	get_tree().quit(0)
