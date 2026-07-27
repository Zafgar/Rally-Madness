extends Node2D
## Renders a scene to a PNG so the visuals can actually be looked at.
##
## Graphics work done blind is guesswork. This puts cars on a track, runs the
## simulation for a moment so tyre marks and particles have something to show,
## and writes a frame to disk.
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/screenshot.tscn -- <track> <car> <mode> <out.png>
##
## Modes: static (grid), driving (AI laps first), night (headlights).

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

var _builder: TrackBuilder
var _cars: Array[RallyCar] = []
var _drivers: Array[AIDriver] = []
var _camera: Camera2D
var _out_path := "user://shot.png"
var _warmup := 0.0
var _target_warmup := 3.0
var _mode := "static"
var _shot_taken := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	var car_id: String = args[1] if args.size() > 1 else "lada_2101"
	_mode = args[2] if args.size() > 2 else "static"
	_out_path = args[3] if args.size() > 3 else "user://shot.png"
	var zoom: float = float(args[4]) if args.size() > 4 else 0.55

	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("screenshot: unknown track '%s'" % track_id)
		get_tree().quit(1)
		return

	_builder = TrackBuilder.new(track)
	add_child(_builder.build())

	# A short field so there is something to look at, drawn from cars around
	# the requested one so tiers and categories are visible together.
	var catalogue := CarDatabase.all()
	var start := 0
	for i in catalogue.size():
		if catalogue[i].id == car_id:
			start = i
			break

	var count: int = 4 if _mode != "static" else 5
	for i in count:
		var spec: CarSpec = catalogue[(start + i) % catalogue.size()]
		var car: RallyCar = CAR_SCENE.instantiate()
		car.car_id = i + 1
		car.is_locally_controlled = false
		var loadout := spec.default_loadout()
		loadout.paint_color = Color.from_hsv(fmod(0.08 + i * 0.19, 1.0), 0.72, 0.85)
		car.configure(spec, loadout)
		add_child(car)
		car.set_spawn(_builder.start_grid[i])
		_cars.append(car)
		if _mode != "static" and _mode != "drift":
			var profile := DriverProfile.from_skill(0.5 + i * 0.12)
			_drivers.append(AIDriver.new(car, _builder, profile, (i - 1.5) * 2.0, 100 + i))

	_camera = Camera2D.new()
	_camera.zoom = Vector2(zoom, zoom)
	_camera.position = _cars[0].global_position
	add_child(_camera)
	_camera.make_current()

	if _mode == "night":
		var dark := CanvasModulate.new()
		# The same value the race uses, or this harness is testing a night
		# nobody will ever play.
		dark.color = RaceScene.NIGHT_LIGHT
		add_child(dark)

	_target_warmup = 0.2 if _mode == "static" else (7.0 if _mode == "drift" else 8.0)
	# Marks and particles live on shared layers, exactly as they do in a race.
	if _mode != "static":
		var marks := TireMarks.new()
		add_child(marks)
		for car in _cars:
			car.mark_layer = marks
		if _mode == "night":
			for car in _cars:
				car.lights_on = true
	print("screenshot: %s / %s / %s -> %s" % [track_id, car_id, _mode, _out_path])


func _physics_process(delta: float) -> void:
	if _shot_taken:
		return
	_warmup += delta
	if _mode == "drift":
		# Build speed in a straight line first, then throw it sideways. Simply
		# holding full lock from a standstill spins the cars on the spot, which
		# produces no speed and therefore no spray.
		var sliding := _warmup > 4.0
		for car in _cars:
			car.command.throttle = 1.0
			car.command.steer = 0.9 if sliding else 0.0
			car.command.handbrake = sliding and fmod(_warmup, 1.6) < 0.5
			car.command.brake = 0.0
			if car.transmission != null and car.transmission.gear <= 0:
				car.transmission.shift_to(1)
	for i in _drivers.size():
		_cars[i].command = _drivers[i].update(delta)
	if not _cars.is_empty():
		_camera.position = _cars[0].global_position
	if _warmup >= _target_warmup:
		_shot_taken = true
		_capture.call_deferred()


func _capture() -> void:
	# Two frames of slack so the viewport has definitely drawn everything that
	# was only just spawned.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	for car in _cars:
		var fx := car.get_node_or_null("Effects")
		var spray := fx.get_child(0) if fx != null and fx.get_child_count() > 0 else null
		print("  car %d speed=%.1f slipF=%.2f slipR=%.2f effects=%s spray_emitting=%s" % [
			car.car_id, car.speed_ms,
			car.axle_front.slip_magnitude, car.axle_rear.slip_magnitude,
			"yes" if fx != null else "NO",
			str(spray.emitting) if spray is CPUParticles2D else "n/a"])
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_out_path)
	if err != OK:
		push_error("screenshot: could not write %s (%d)" % [_out_path, err])
	else:
		print("screenshot: wrote %s (%dx%d)" % [_out_path, image.get_width(), image.get_height()])
	get_tree().quit(0 if err == OK else 1)
