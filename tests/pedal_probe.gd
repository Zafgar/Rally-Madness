extends Node
## How much of the brake pedal actually does anything.
##
## Written for a specific complaint: the trigger feels like a switch — a small
## press already brakes hard. The input path is linear (deadzone, rescale, and
## the pedal multiplies brake torque directly), so if that is what it feels
## like, the non-linearity is in the car rather than in the pad.
##
## A brake can always out-torque a tyre. Past the point where the wheel locks,
## more pedal buys nothing — the wheel is already sliding and the friction is
## whatever a sliding tyre gives, which is *less* than a rolling one. So the
## useful travel runs from zero to the lock point, and if that point is a third
## of the way down, two thirds of the trigger is scenery.
##
##   godot --headless --path . res://tests/pedal_probe.tscn -- [car_id ...]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
## Speed each stop starts from, m/s. About eighty km/h — high enough to be a
## real stop, low enough that a Lada reaches it on gravel without a long run-up.
const FROM_MS := 22.0
## Pedal positions tried, as a fraction of full travel.
##
## Six, not twenty. Headless Godot still runs its physics at sixty ticks of
## wall-clock a second, so every stop costs its own run-up in real time and a
## finer sweep simply does not finish inside any sensible timeout. Six points
## are enough to see where the curve stops rising, which is the whole question.
const STEPS := 6
const SURFACES := [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL]

var _car: RallyCar
var _queue: Array = []
var _phase := "accelerate"
var _spin_up := 0.0
var _brake_time := 0.0
var _brake_from := 0.0
var _locked := false
## car id -> surface -> [{pedal, decel, locked}]
var _rows: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var ids: Array = args if not args.is_empty() else [
		"lada_2101", "impreza_gc8"]
	for id in ids:
		for surface in SURFACES:
			for step in range(1, STEPS + 1):
				_queue.append({
					"car": String(id),
					"surface": surface,
					"pedal": float(step) / float(STEPS),
				})
	print("=== how much of the brake pedal is usable ===")
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
	if spec == null:
		_queue.pop_front()
		_next()
		return
	_car = CAR_SCENE.instantiate()
	_car.car_id = 1
	_car.is_locally_controlled = false
	_car.configure(spec, spec.default_loadout(), {})
	add_child(_car)
	_car.surface = job["surface"] as TireModel.Surface
	_phase = "accelerate"
	_spin_up = 0.0
	_brake_time = 0.0
	_locked = false


func _physics_process(delta: float) -> void:
	if _car == null or _queue.is_empty():
		return
	var job: Dictionary = _queue[0]
	# Re-asserted every step: nothing is driving over a surface zone here, so
	# whatever the car last decided it was standing on would otherwise win.
	_car.surface = job["surface"] as TireModel.Surface

	if _phase == "accelerate":
		_car.command.clear()
		_car.command.throttle = 1.0
		_spin_up += delta
		if _car.speed_ms >= FROM_MS or _spin_up > 12.0:
			_phase = "brake"
			_brake_from = _car.speed_ms
			_brake_time = 0.0
		return

	_car.command.clear()
	_car.command.brake = float(job["pedal"])
	_brake_time += delta
	if _car.wheels_locked():
		_locked = true
	# One second of braking, or until it has stopped. Either way the average
	# deceleration over that window is the number that matters.
	if _brake_time >= 1.0 or _car.speed_ms < 1.0:
		_rows.append({
			"car": job["car"],
			"surface": job["surface"],
			"pedal": job["pedal"],
			"decel": (_brake_from - _car.speed_ms) / maxf(_brake_time, 0.001),
			"locked": _locked,
		})
		_queue.pop_front()
		_next()


func _report() -> void:
	# Grouped per car and surface, because the answer is different for a Lada on
	# gravel and a Group B car on tarmac, and the complaint came from one of them.
	var groups: Dictionary = {}
	for row in _rows:
		var key: String = "%s|%d" % [row["car"], int(row["surface"])]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(row)

	print("%-18s %-8s %9s %10s %9s" % [
		"car", "surface", "locks at", "best decel", "at pedal"])
	for key in groups:
		var rows: Array = groups[key]
		var lock_at := -1.0
		var best := 0.0
		var best_pedal := 0.0
		for row in rows:
			if lock_at < 0.0 and bool(row["locked"]):
				lock_at = float(row["pedal"])
			if float(row["decel"]) > best:
				best = float(row["decel"])
				best_pedal = float(row["pedal"])
		var first: Dictionary = rows[0]
		print("%-18s %-8s %9s %7.1f m/s² %7.0f%%" % [
			first["car"], TireModel.surface_name(first["surface"]),
			("%.0f%%" % (lock_at * 100.0)) if lock_at > 0.0 else "never",
			best, best_pedal * 100.0])
		# And the shape of the curve, which is the thing being asked about.
		var line := "    "
		for row in rows:
			line += "%.0f%%:%.0f  " % [float(row["pedal"]) * 100.0, float(row["decel"])]
		print(line)
	get_tree().quit(0)
