class_name HapticsDirector
extends RefCounted
## Drives one seat's pad from one car.
##
## Each local player gets their own director, because each has their own pad
## and their own car — in a four-way split screen the four pads must be telling
## four different stories.

var device_id: int = -1
var car: RallyCar
var state := HapticState.new()
var backend: HapticBackend
var enabled: bool = true
## Global intensity, for players who want less of it. 0 disables output without
## tearing the system out.
var intensity: float = 1.0

var _connected_car_id: int = -1


func _init(p_device_id: int, p_backend: HapticBackend) -> void:
	device_id = p_device_id
	backend = p_backend


## Attach to a car and start listening for the transient events — impacts and
## landings — that have to be caught when they happen rather than sampled.
func bind(p_car: RallyCar) -> void:
	_disconnect_car()
	car = p_car
	if car == null:
		return
	_connected_car_id = car.car_id
	car.landed.connect(_on_landed)
	EventBus.car_damaged.connect(_on_damaged)


func _disconnect_car() -> void:
	if car != null and is_instance_valid(car):
		if car.landed.is_connected(_on_landed):
			car.landed.disconnect(_on_landed)
	if EventBus.car_damaged.is_connected(_on_damaged):
		EventBus.car_damaged.disconnect(_on_damaged)
	_connected_car_id = -1


func update(delta: float) -> void:
	if backend is RumbleBackend:
		(backend as RumbleBackend).tick(delta)
	if not enabled or car == null or not is_instance_valid(car):
		return

	state.update(car, delta)
	backend.set_rumble(device_id, state.rumble_low * intensity, state.rumble_high * intensity)

	if intensity <= 0.001:
		backend.set_triggers(device_id, TriggerEffect.off(), TriggerEffect.off())
		return
	backend.set_triggers(device_id, state.throttle_effect, state.brake_effect)


## Called when the race ends, the game is paused, or focus is lost. Leaving a
## pad buzzing after the player has put it down is the kind of bug that gets
## remembered.
func release() -> void:
	backend.stop(device_id)
	_disconnect_car()
	car = null


func _on_landed(landed_car_id: int, impact: float) -> void:
	if landed_car_id == _connected_car_id:
		state.add_landing(impact)


func _on_damaged(damaged_car_id: int, part: String, amount: float, _remaining: float) -> void:
	# One crash reports several components; the body event stands in for the
	# whole thing so a single impact is one jolt, not three.
	if damaged_car_id != _connected_car_id or part != "body":
		return
	state.add_impact(amount * 4.0)


## Picks the best backend available on this machine.
static func make_backend() -> HapticBackend:
	# DualSenseBackend degrades to plain rumble when no native extension is
	# present, so it is always the right choice — it simply does more when it
	# can.
	return DualSenseBackend.new()
