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
const BUSES := ["Engine", "Tyres", "Impacts", "Music", "Interface"]

## Default levels, in decibels relative to each bus's own full scale. Engines
## sit below the effects because they are continuous and everything else is
## occasional — a mix where the constant sound is loudest is exhausting.
const DEFAULT_LEVELS := {
	"Master": -3.0,
	"Engine": -6.0,
	"Tyres": -9.0,
	"Impacts": -4.0,
	# Music sits under everything: it is what you notice when you stop paying
	# attention, not what you are listening to. In a race it ducks further.
	"Music": -13.0,
	"Interface": -8.0,
}

## Every local player's car. The listener resolves against these.
var local_cars: Array[RallyCar] = []

var _last_listener := Vector2.ZERO

## The soundtrack, and the clicks the menus make. Both live here because both
## outlive any one screen and neither belongs to a car.
var music: MusicPlayer
var interface: InterfaceSounds


func _ready() -> void:
	_ensure_buses()
	for bus in DEFAULT_LEVELS:
		set_bus_volume(bus, float(DEFAULT_LEVELS[bus]))
	music = MusicPlayer.new()
	music.name = "Music"
	add_child(music)
	interface = InterfaceSounds.new()
	interface.name = "Interface"
	add_child(interface)


## How far the master is pulled down to make room for several listeners.
var listener_trim: float = 0.0
## Whether the music is currently under a race.
var music_ducked: bool = false


## Music down while a race is running. It is still there — a soundtrack that
## vanishes the moment the action starts is a soundtrack nobody hears — but
## twelve engines have to be able to get past it.
func duck_music(ducked: bool) -> void:
	music_ducked = ducked
	set_bus_volume("Music", level_for("Music"))


## Every seat's viewport is its own 2D listener, so a sound in the world is
## mixed once per player and four people on a couch get every engine four times.
## That is four times the power into one pair of speakers, so the master comes
## down by the usual ten-log-ten to put it back where one player had it.
##
## Not twenty-log-ten: the copies are only truly coherent for a source the same
## distance from every seat, which during a race is almost never true.
func set_listener_count(count: int) -> void:
	listener_trim = -10.0 * log(float(maxi(count, 1))) / log(10.0)
	refresh_levels()


## What a bus should be sitting at right now: the tuned default, the player's
## own slider, and whatever the game is doing to it at this moment.
##
## One function so the three cannot disagree. They used to: ducking the music
## wrote the default back over the player's setting, so turning the soundtrack
## down in the menus and then starting a race turned it back up again.
func level_for(bus: String) -> float:
	var level: float = float(DEFAULT_LEVELS.get(bus, 0.0))
	# Settings is a later autoload, so early calls fall back to the defaults.
	var settings := _settings()
	if settings != null:
		level = settings.volume_db(bus)
	if bus == "Music" and music_ducked:
		level -= 9.0
	if bus == "Master":
		level += listener_trim
	return level


func refresh_levels() -> void:
	for bus in DEFAULT_LEVELS:
		set_bus_volume(bus, level_for(bus))


func _settings() -> Node:
	return get_tree().root.get_node_or_null("Settings") if is_inside_tree() else null


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
