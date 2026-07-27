extends Node2D
## Full throttle in a straight line, printing what the mechanical model does to
## the car. Exists to answer "why is this car not moving" with numbers.
##
##   godot --headless --path . res://tests/mech_probe.tscn -- [car_id] [seconds]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

var _car: RallyCar
var _t: float = 0.0
var _limit: float = 30.0
var _next_report: float = 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var car_id: String = args[0] if args.size() > 0 else "golf_gti_mk2"
	if args.size() > 1:
		_limit = float(args[1])
	var spec := CarDatabase.get_car(car_id)
	_car = CAR_SCENE.instantiate()
	_car.car_id = 1
	_car.is_locally_controlled = false
	_car.configure(spec, spec.default_loadout(), {})
	add_child(_car)
	print("=== %s ===" % spec.display_name())
	print("%6s %8s %8s %8s %8s %8s %8s %8s" % [
		"t", "km/h", "rpm", "power", "fuel", "coolant", "oil", "failed"])


func _physics_process(delta: float) -> void:
	_t += delta
	_car.command.throttle = 1.0
	_car.command.brake = 0.0
	_car.command.steer = 0.0
	if _t >= _next_report:
		_next_report += 3.0
		var m := _car.mechanical
		print("%6.1f %8.1f %8.0f %8.2f %8.1f %8.1f %8.1f %8s" % [
			_t, _car.speed_kmh(), _car.transmission.rpm, m.power_multiplier(),
			m.fuel_l, m.coolant_c, m.oil_c, m.failure_text()])
	if _t >= _limit:
		get_tree().quit(0)
