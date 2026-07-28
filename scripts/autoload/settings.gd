extends Node
## What the player has decided about the window and the mix, remembered.
##
## Everything here has a sane answer before anybody opens the settings screen.
## The window mode defaults to the borderless full screen a game is normally
## launched into; the resolution defaults to whatever the monitor actually is,
## read from the display server rather than guessed, because a fixed 1920×1080
## is wrong on a laptop and wrong again on a 4K panel. The volumes default to
## the mix the audio director was tuned with.
##
## Saved next to the careers, in its own file, because settings belong to the
## machine and not to any one driver: three people sharing a couch should not
## each have to find the sound sliders again.

const SETTINGS_PATH := "user://settings.cfg"

enum WindowMode { WINDOWED, BORDERLESS, FULLSCREEN }

## Window sizes offered in the settings screen. The monitor's own resolution is
## added to this list at runtime and is the default, so the first entry a player
## sees is always the right one for their screen.
const COMMON_SIZES := [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3440, 1440), Vector2i(3840, 2160),
]

## The sliders, and the bus each one drives. Master is separate because it is
## the only one that is not a category.
const VOLUME_BUSES := ["Master", "Engine", "Tyres", "Impacts", "Music", "Interface"]

var window_mode: int = WindowMode.BORDERLESS
var resolution: Vector2i = Vector2i(1920, 1080)
var vsync: bool = true
## Bus name -> 0..1. Linear, because that is what a slider should be; converted
## to decibels on the way to the mixer.
var volumes: Dictionary = {}

var _loaded: bool = false


func _ready() -> void:
	resolution = native_resolution()
	for bus in VOLUME_BUSES:
		volumes[bus] = 1.0
	load_settings()
	# Applied a frame later so the audio director has built its buses.
	apply.call_deferred()


## What the monitor this window is on actually is. The honest default.
func native_resolution() -> Vector2i:
	if DisplayServer.get_name() == "headless":
		return Vector2i(1920, 1080)
	var screen := DisplayServer.window_get_current_screen()
	var size := DisplayServer.screen_get_size(screen)
	if size.x <= 0 or size.y <= 0:
		return Vector2i(1920, 1080)
	return size


## Every resolution worth offering: the monitor's own first, then the standard
## sizes that fit inside it. Offering a window larger than the screen is how a
## player loses the title bar and cannot get it back.
func resolution_choices() -> Array:
	var native := native_resolution()
	var out: Array = [native]
	for size in COMMON_SIZES:
		if size == native:
			continue
		if size.x <= native.x and size.y <= native.y:
			out.append(size)
	return out


func apply() -> void:
	_apply_window()
	_apply_volumes()


func _apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	match window_mode:
		WindowMode.FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		WindowMode.BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(resolution)
			# Centred, so a resize never puts the window half off the screen.
			var screen := DisplayServer.window_get_current_screen()
			var area := DisplayServer.screen_get_usable_rect(screen)
			DisplayServer.window_set_position(
				area.position + (area.size - resolution) / 2)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)


func _apply_volumes() -> void:
	AudioDirector.refresh_levels()


## A slider position turned into a bus level.
##
## Linear amplitude, not linear decibels: halfway along the slider should sound
## half as loud, and decibels are logarithmic, so a slider that moves the dB
## figure evenly spends most of its travel in the inaudible bottom end. Zero is
## silence proper rather than a very quiet -60.
func volume_db(bus: String) -> float:
	var base: float = float(AudioDirector.DEFAULT_LEVELS.get(bus, 0.0))
	var linear: float = clampf(float(volumes.get(bus, 1.0)), 0.0, 1.0)
	if linear <= 0.0001:
		return -80.0
	return base + linear_to_db(linear)


func set_volume(bus: String, linear: float) -> void:
	volumes[bus] = clampf(linear, 0.0, 1.0)
	AudioDirector.set_bus_volume(bus, AudioDirector.level_for(bus))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("window", "mode", window_mode)
	cfg.set_value("window", "width", resolution.x)
	cfg.set_value("window", "height", resolution.y)
	cfg.set_value("window", "vsync", vsync)
	for bus in VOLUME_BUSES:
		cfg.set_value("audio", bus, float(volumes.get(bus, 1.0)))
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	window_mode = int(cfg.get_value("window", "mode", window_mode))
	resolution = Vector2i(
		int(cfg.get_value("window", "width", resolution.x)),
		int(cfg.get_value("window", "height", resolution.y)))
	vsync = bool(cfg.get_value("window", "vsync", vsync))
	for bus in VOLUME_BUSES:
		volumes[bus] = clampf(float(cfg.get_value("audio", bus, 1.0)), 0.0, 1.0)
