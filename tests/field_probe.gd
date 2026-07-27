extends Node
## Several AI drivers on one track at once, to see how they behave in traffic.
##
## The single-car probe says nothing about racecraft. This one puts a mixed
## field out together and reports what each driver managed and, crucially, how
## often they hit each other — which is the number the awareness work exists to
## bring down.
##
##   godot --headless --fixed-fps 60 --path . res://tests/field_probe.tscn \
##       -- <track> [duration]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
const ARCHETYPES := ["nervous_novice", "sunday_driver", "steady_privateer",
	"old_hand", "reckless_local", "works_driver"]

var _builder: TrackBuilder
var _cars: Array[RallyCar] = []
var _drivers: Array[AIDriver] = []
var _names: Array[String] = []
var _distance: Array[float] = []
var _last_progress: Array[float] = []
var _elapsed: float = 0.0
var _duration: float = 90.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	if args.size() > 1:
		_duration = float(args[1])
	var seed_offset: int = int(args[3]) if args.size() > 3 else 0

	var blind_arg := args.size() > 2 and args[2] == "blind"
	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("field_probe: unknown track '%s'" % track_id)
		get_tree().quit(1)
		return
	_builder = TrackBuilder.new(track)
	add_child(_builder.build())

	# One car for everyone, so the only thing that differs is the driver.
	var spec := CarDatabase.get_car("impreza_gc8")
	var field: Array[RallyCar] = []
	for i in ARCHETYPES.size():
		var loadout := spec.default_loadout()
		loadout.set_part("tires", "tires_gravel")
		var car: RallyCar = CAR_SCENE.instantiate()
		car.car_id = i + 1
		car.is_locally_controlled = false
		car.configure(spec, loadout)
		add_child(car)
		car.set_spawn(_builder.start_grid[i])
		_cars.append(car)
		field.append(car)

		var profile := _archetype(ARCHETYPES[i])
		_names.append(profile.display_name)
		var lane := maxf(track.width * 0.5 - 3.0, 1.0)
		_drivers.append(AIDriver.new(car, _builder, profile,
			lerpf(-lane, lane, float(i) / float(ARCHETYPES.size() - 1)), 500 + i + seed_offset * 97))
		_distance.append(0.0)
		_last_progress.append(-1.0)

	# "blind" leaves every driver unaware of the others, for a baseline to
	# measure the awareness work against.
	var blind := blind_arg
	if not blind:
		for driver in _drivers:
			driver.awareness.set_field(field)

	print("=== field probe: %d drivers on %s for %.0fs%s ===" % [
		_cars.size(), track_id, _duration, "  (BLIND)" if blind else ""])


func _archetype(id: String) -> DriverProfile:
	for entry in DriverProfile.load_pool():
		var profile: DriverProfile = entry["profile"]
		if profile.archetype == id:
			return profile
	return DriverProfile.from_skill(0.5)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	for i in _cars.size():
		_cars[i].command = _drivers[i].update(delta)
		_track_progress(i)
	if _elapsed >= _duration:
		_report()
		get_tree().quit(0)


func _track_progress(i: int) -> void:
	var here := _builder.progress_at(_cars[i].global_position)
	var length := _builder.total_length_px
	if _last_progress[i] >= 0.0:
		var step := here - _last_progress[i]
		if step < -length * 0.5:
			step += length
		elif step > length * 0.5:
			step -= length
		if absf(step) < length * 0.2:
			_distance[i] += step
	_last_progress[i] = here


func _report() -> void:
	print("%-20s %10s %9s %9s %9s" % [
		"driver", "covered", "contacts", "crashes", "condition"])
	var total_contacts := 0
	for i in _cars.size():
		var car := _cars[i]
		total_contacts += car.contacts_with_cars
		print("%-20s %8.0f m %9d %9s %9.2f" % [
			_names[i],
			_distance[i] / GameConfig.PIXELS_PER_METRE,
			car.contacts_with_cars,
			"WRECKED" if car.damage.wrecked else "-",
			car.damage.overall()])
	# Halved because every contact is reported by both cars involved.
	var wrecks := 0
	var distance := 0.0
	for i in _cars.size():
		if _cars[i].damage.wrecked:
			wrecks += 1
		distance += _distance[i] / GameConfig.PIXELS_PER_METRE
	# Halved because every contact is reported by both cars involved.
	print("\nRESULT contacts=%d wrecks=%d distance=%.0f" % [
		total_contacts / 2, wrecks, distance])
