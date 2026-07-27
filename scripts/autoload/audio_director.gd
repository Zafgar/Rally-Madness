extends Node
## Where the listener is, what the buses are, and how loud everything is.
##
## Split screen makes this less obvious than it sounds. With four people on one
## couch there are four cameras and one pair of speakers, so "the listener" has
## to be a compromise: sounds are mixed relative to whichever local car is
## nearest to them, which is the only arrangement where every player can hear
## their own car properly and nobody hears somebody else's crash in the wrong
## ear.

## Bus names. Separating them means a player can turn the engines down without
## losing the tyres, and it gives the mix somewhere to compress.
const BUSES := ["Engine", "Tyres", "Impacts"]

## Default levels, in decibels relative to each bus's own full scale. Engines
## sit below the effects because they are continuous and everything else is
## occasional — a mix where the constant sound is loudest is exhausting.
const DEFAULT_LEVELS := {
	"Master": -3.0,
	"Engine": -6.0,
	"Tyres": -9.0,
	"Impacts": -4.0,
}

## Every local player's car. The listener resolves against these.
var local_cars: Array[RallyCar] = []

var _last_listener := Vector2.ZERO


func _ready() -> void:
	_ensure_buses()
	for bus in DEFAULT_LEVELS:
		set_bus_volume(bus, float(DEFAULT_LEVELS[bus]))


## Creates the buses if the project does not already have them, so the audio
## works in a fresh checkout without anyone having to open the editor.
func _ensure_buses() -> void:
	for name in BUSES:
		if AudioServer.get_bus_index(name) >= 0:
			continue
		var index := AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, name)
		AudioServer.set_bus_send(index, "Master")


func set_bus_volume(bus: String, volume_db: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index >= 0:
		AudioServer.set_bus_volume_db(index, volume_db)


func bus_volume(bus: String) -> float:
	var index := AudioServer.get_bus_index(bus)
	return AudioServer.get_bus_volume_db(index) if index >= 0 else 0.0


## Registers a car as belonging to somebody sitting in front of this screen.
func add_local_car(car: RallyCar) -> void:
	if car != null and not local_cars.has(car):
		local_cars.append(car)


func clear_local_cars() -> void:
	local_cars.clear()


## Where sound is being heard from.
##
## With one player this is simply their car. With several it is the average of
## them, which keeps everyone roughly equidistant from the action; each car's
## own voices are still loudest to its own driver because they are closest to
## the average when the field is spread out, and when two players are together
## they are hearing the same thing anyway.
func listener_position() -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for car in local_cars:
		if car != null and is_instance_valid(car):
			sum += car.global_position
			count += 1
	if count == 0:
		return _last_listener
	_last_listener = sum / float(count)
	return _last_listener


## How loud a source at `world_position` should be, 0..1, from the listener's
## point of view. Used for anything that is not an AudioStreamPlayer2D and so
## does not get attenuation for free.
##
## Godot pans and attenuates AudioStreamPlayer2D relative to each viewport's own
## camera, which is exactly right for split screen: every player hears the world
## from where they are sitting. This is only for the culling decision, which has
## to be one answer for the whole machine.
func audibility_at(world_position: Vector2, range_m: float) -> float:
	var distance := world_position.distance_to(listener_position()) \
		/ GameConfig.PIXELS_PER_METRE
	return clampf(1.0 - distance / maxf(range_m, 1.0), 0.0, 1.0)
