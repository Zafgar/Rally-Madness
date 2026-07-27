class_name RumbleBackend
extends HapticBackend
## Rumble through Godot's built-in joypad vibration.
##
## Works on any pad Godot recognises, including a DualSense over USB or
## Bluetooth. Godot exposes exactly two amplitudes — a low-frequency motor and
## a high-frequency one — and no trigger control, so this covers half of what
## the feel design asks for. DualSenseBackend adds the other half.

## Vibration set with an infinite duration can be dropped on some platforms
## after a while, so it is re-sent periodically even when unchanged.
const REFRESH_INTERVAL := 0.25
## Below this the motors are told to stop outright rather than being driven at
## a level that just makes them whine.
const SILENCE_THRESHOLD := 0.02
## Change needed before a new command is worth sending.
const CHANGE_TOLERANCE := 0.03

var _last_low: Dictionary = {}
var _last_high: Dictionary = {}
var _since_refresh: Dictionary = {}


func backend_name() -> String:
	return "godot-rumble"


func set_rumble(device_id: int, low: float, high: float) -> void:
	if device_id < 0:
		return  # keyboard
	low = clampf(low, 0.0, 1.0)
	high = clampf(high, 0.0, 1.0)

	var previous_low: float = _last_low.get(device_id, -1.0)
	var previous_high: float = _last_high.get(device_id, -1.0)
	var elapsed: float = _since_refresh.get(device_id, 999.0)

	var changed := absf(low - previous_low) > CHANGE_TOLERANCE \
		or absf(high - previous_high) > CHANGE_TOLERANCE
	if not changed and elapsed < REFRESH_INTERVAL:
		return

	_last_low[device_id] = low
	_last_high[device_id] = high
	_since_refresh[device_id] = 0.0

	if low < SILENCE_THRESHOLD and high < SILENCE_THRESHOLD:
		Input.stop_joy_vibration(device_id)
		return
	# Godot's "weak" motor is the high-frequency one and "strong" the
	# low-frequency one. Duration 0 means run until told otherwise.
	Input.start_joy_vibration(device_id, high, low, 0.0)


## Drives the refresh timer. Called by the director once per frame.
func tick(delta: float) -> void:
	for device_id in _since_refresh:
		_since_refresh[device_id] = float(_since_refresh[device_id]) + delta


func stop(device_id: int) -> void:
	if device_id < 0:
		return
	Input.stop_joy_vibration(device_id)
	_last_low.erase(device_id)
	_last_high.erase(device_id)
	_since_refresh.erase(device_id)
