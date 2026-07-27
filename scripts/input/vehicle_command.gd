class_name VehicleCommand
extends RefCounted
## One frame of driver intent, decoupled from where it came from. Local pads,
## the network layer and the AI all produce these, so the car physics never
## needs to know which is driving it.

var steer: float = 0.0        # -1 full left .. 1 full right
var throttle: float = 0.0     # 0..1
var brake: float = 0.0        # 0..1
var handbrake: bool = false
var nitro: bool = false
var shift_up: bool = false    # edge-triggered
var shift_down: bool = false  # edge-triggered
var toggle_gearbox: bool = false
var respawn: bool = false
## Edge-triggered: the lights come on and stay on until asked again.
var toggle_lights: bool = false
## Held, not edge-triggered — a horn sounds for as long as you lean on it.
var horn: bool = false
## An explicit "I want reverse". The pad convenience of selecting it by holding
## the brake is not available to an AI, and an AI stuck nose-first in a ditch
## has to be able to back out of it — so it asks in words instead.
var request_reverse: bool = false


func clear() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	nitro = false
	shift_up = false
	shift_down = false
	toggle_gearbox = false
	respawn = false
	toggle_lights = false
	horn = false
	request_reverse = false


## Compact form for network replication. Analogue axes are quantised to a byte
## each because 12 cars * 60 Hz of full floats is a lot of bandwidth for
## precision nobody can feel.
func encode() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(4)
	buf[0] = int(clampf(steer, -1.0, 1.0) * 127.0) + 127
	buf[1] = int(clampf(throttle, 0.0, 1.0) * 255.0)
	buf[2] = int(clampf(brake, 0.0, 1.0) * 255.0)
	var flags := 0
	flags |= 1 if handbrake else 0
	flags |= 2 if nitro else 0
	flags |= 4 if shift_up else 0
	flags |= 8 if shift_down else 0
	flags |= 16 if toggle_gearbox else 0
	flags |= 32 if respawn else 0
	flags |= 64 if toggle_lights else 0
	flags |= 128 if horn else 0
	buf[3] = flags
	return buf


func decode(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		clear()
		return
	steer = (float(buf[0]) - 127.0) / 127.0
	throttle = float(buf[1]) / 255.0
	brake = float(buf[2]) / 255.0
	var flags := buf[3]
	handbrake = (flags & 1) != 0
	nitro = (flags & 2) != 0
	shift_up = (flags & 4) != 0
	shift_down = (flags & 8) != 0
	toggle_gearbox = (flags & 16) != 0
	respawn = (flags & 32) != 0
	toggle_lights = (flags & 64) != 0
	horn = (flags & 128) != 0


func duplicate_command() -> VehicleCommand:
	var c := VehicleCommand.new()
	c.steer = steer
	c.throttle = throttle
	c.brake = brake
	c.handbrake = handbrake
	c.nitro = nitro
	c.shift_up = shift_up
	c.shift_down = shift_down
	c.toggle_gearbox = toggle_gearbox
	c.respawn = respawn
	c.toggle_lights = toggle_lights
	c.horn = horn
	c.request_reverse = request_reverse
	return c
