class_name DeviceInput
extends RefCounted
## Reads one physical controller (or the keyboard) and turns it into a
## VehicleCommand.
##
## Split-screen deliberately bypasses the InputMap: actions there are global,
## so four pads mapped to the same action all fire for every player. Polling
## the device id directly is the only way to keep the seats independent.

const DEVICE_KEYBOARD := -1

## DualSense / SDL standard layout. Godot normalises PS5 pads to this, so the
## same constants also cover Xbox and generic pads.
const BTN_CROSS := JOY_BUTTON_A
const BTN_CIRCLE := JOY_BUTTON_B
const BTN_SQUARE := JOY_BUTTON_X
const BTN_TRIANGLE := JOY_BUTTON_Y
const BTN_L1 := JOY_BUTTON_LEFT_SHOULDER
const BTN_R1 := JOY_BUTTON_RIGHT_SHOULDER
const BTN_OPTIONS := JOY_BUTTON_START
const BTN_DPAD_DOWN := JOY_BUTTON_DPAD_DOWN
## How long respawn has to be held before it fires.
const RESPAWN_HOLD_SECONDS := 0.8
## The sticks, clicked. Nothing else uses them and a horn wants a button you
## can lean on without letting go of the wheel — which is exactly where a real
## horn is.
const BTN_L3 := JOY_BUTTON_LEFT_STICK
const BTN_R3 := JOY_BUTTON_RIGHT_STICK

const STICK_DEADZONE := 0.15
const TRIGGER_DEADZONE := 0.06

var device_id: int = DEVICE_KEYBOARD
## PS5 triggers are analogue; some third-party pads report them as buttons.
## Detected on first use so we do not need a per-pad database.
var _digital_triggers: bool = false

var _prev_shift_up: bool = false
var _prev_shift_down: bool = false
var _prev_toggle: bool = false
var _prev_lights: bool = false
var _prev_respawn: bool = false
## How long the respawn button has been held, in seconds.
var _respawn_held: float = 0.0
## Filled in by the poll so the hold can be timed without threading a delta
## through every call site.
var _delta_hint: float = 1.0 / 60.0

var _command := VehicleCommand.new()


func _init(p_device_id: int = DEVICE_KEYBOARD) -> void:
	device_id = p_device_id


func is_keyboard() -> bool:
	return device_id == DEVICE_KEYBOARD


func device_name() -> String:
	if is_keyboard():
		return "Keyboard"
	return Input.get_joy_name(device_id)


## `delta` is only used to time held buttons; callers that do not have one get
## a single frame's worth, which is what they were effectively assuming anyway.
func poll(delta: float = 1.0 / 60.0) -> VehicleCommand:
	_delta_hint = delta
	if is_keyboard():
		_poll_keyboard()
	else:
		_poll_pad()
	return _command


func _poll_pad() -> void:
	var c := _command
	var steer_raw := Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X)
	c.steer = _apply_deadzone(steer_raw, STICK_DEADZONE)

	var r2 := Input.get_joy_axis(device_id, JOY_AXIS_TRIGGER_RIGHT)
	var l2 := Input.get_joy_axis(device_id, JOY_AXIS_TRIGGER_LEFT)
	if _digital_triggers or (absf(r2) < 0.001 and absf(l2) < 0.001):
		# Fall back to the shoulder-as-trigger reading; if the analogue axes
		# ever move we switch back, so a pad that idles at 0 is not misjudged.
		if absf(r2) > 0.001 or absf(l2) > 0.001:
			_digital_triggers = false
	c.throttle = _apply_deadzone(r2, TRIGGER_DEADZONE)
	c.brake = _apply_deadzone(l2, TRIGGER_DEADZONE)

	c.handbrake = Input.is_joy_button_pressed(device_id, BTN_CROSS)
	c.nitro = Input.is_joy_button_pressed(device_id, BTN_CIRCLE)

	var up := Input.is_joy_button_pressed(device_id, BTN_R1)
	var down := Input.is_joy_button_pressed(device_id, BTN_L1)
	var toggle := Input.is_joy_button_pressed(device_id, BTN_TRIANGLE)
	# Respawn is held, not tapped, and it is not on Options.
	#
	# It used to be a tap on Options — the menu button — so reaching for the
	# pause screen teleported the car back to the road instead. Nothing about
	# that is recoverable: by the time you see what happened you have lost the
	# position you were about to pause to think about. It is now the d-pad down
	# held for most of a second, which nobody presses by accident and which
	# leaves Options free to do what a menu button should do.
	if Input.is_joy_button_pressed(device_id, BTN_DPAD_DOWN):
		_respawn_held += _delta_hint
	else:
		_respawn_held = 0.0
	var respawn := _respawn_held >= RESPAWN_HOLD_SECONDS
	var lights := Input.is_joy_button_pressed(device_id, BTN_SQUARE)
	# The horn is held, not tapped: leaning on it is the point of a horn.
	c.horn = Input.is_joy_button_pressed(device_id, BTN_L3) \
		or Input.is_joy_button_pressed(device_id, BTN_R3)

	c.shift_up = up and not _prev_shift_up
	c.shift_down = down and not _prev_shift_down
	c.toggle_gearbox = toggle and not _prev_toggle
	c.respawn = respawn and not _prev_respawn
	if respawn:
		# One respawn per hold, not one per frame for as long as it is down.
		_respawn_held = 0.0
	c.toggle_lights = lights and not _prev_lights

	_prev_shift_up = up
	_prev_shift_down = down
	_prev_toggle = toggle
	_prev_respawn = respawn
	_prev_lights = lights


func _poll_keyboard() -> void:
	var c := _command
	var left := Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)
	var right := Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)
	c.steer = (1.0 if right else 0.0) - (1.0 if left else 0.0)
	c.throttle = 1.0 if (Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)) else 0.0
	c.brake = 1.0 if (Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) else 0.0
	c.handbrake = Input.is_key_pressed(KEY_SPACE)
	c.nitro = Input.is_key_pressed(KEY_SHIFT)

	var up := Input.is_key_pressed(KEY_E)
	var down := Input.is_key_pressed(KEY_Q)
	var toggle := Input.is_key_pressed(KEY_T)
	if Input.is_key_pressed(KEY_R):
		_respawn_held += _delta_hint
	else:
		_respawn_held = 0.0
	var respawn := _respawn_held >= RESPAWN_HOLD_SECONDS
	var lights := Input.is_key_pressed(KEY_L)
	c.horn = Input.is_key_pressed(KEY_H)

	c.shift_up = up and not _prev_shift_up
	c.shift_down = down and not _prev_shift_down
	c.toggle_gearbox = toggle and not _prev_toggle
	c.respawn = respawn and not _prev_respawn
	if respawn:
		# One respawn per hold, not one per frame for as long as it is down.
		_respawn_held = 0.0
	c.toggle_lights = lights and not _prev_lights

	_prev_shift_up = up
	_prev_shift_down = down
	_prev_toggle = toggle
	_prev_respawn = respawn
	_prev_lights = lights


static func _apply_deadzone(value: float, dead: float) -> float:
	var a := absf(value)
	if a <= dead:
		return 0.0
	# Rescale so the usable range still reaches full deflection.
	return signf(value) * ((a - dead) / (1.0 - dead))
