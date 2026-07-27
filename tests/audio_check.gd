extends Node2D
## Checks that the audio is actually running, with a real display server.
##
## The synthesis is verified numerically elsewhere. What that cannot see is
## whether anything is playing: a bus that does not exist, a stream that never
## started, a car whose voices were told to play before it was in the tree. All
## of those bake perfect waveforms and produce silence.
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/audio_check.tscn

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

var _car: RallyCar
var _frames := 0


func _ready() -> void:
	print("display server: %s" % DisplayServer.get_name())
	print("audio_enabled: %s" % GameConfig.audio_enabled())
	print("audio driver: %s" % AudioServer.get_driver_name())
	print("buses: %d" % AudioServer.bus_count)
	for i in AudioServer.bus_count:
		print("  %-10s %6.1f dB" % [AudioServer.get_bus_name(i),
			AudioServer.get_bus_volume_db(i)])

	# A camera, because an AudioStreamPlayer2D is mixed relative to one and
	# without it nothing is positioned at all.
	var camera := Camera2D.new()
	add_child(camera)
	camera.make_current()

	var spec := CarDatabase.get_car("impreza_gc8")
	_car = CAR_SCENE.instantiate()
	_car.car_id = 1
	# Exactly the order the race uses: configure, then add to the tree. That
	# order is the whole reason this test exists.
	_car.configure(spec, spec.default_loadout())
	add_child(_car)
	AudioDirector.clear_local_cars()
	AudioDirector.add_local_car(_car)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < 6:
		return

	# Give the car something to make a noise about.
	_car.command.throttle = 1.0
	if _frames < 12:
		return

	var audio := _car.get_node_or_null("Audio") as CarAudio
	if audio == null:
		print("\nFAIL: the car has no audio node at all")
		get_tree().quit(1)
		return

	print("\nvoices on %s:" % _car.spec.display_name())
	print("%-28s %-8s %8s %9s %s" % ["node", "bus", "playing", "volume", "stream"])
	var playing := 0
	var total := 0
	for child in audio.get_children():
		var player := child as AudioStreamPlayer2D
		if player == null:
			continue
		total += 1
		if player.playing:
			playing += 1
		var stream_desc := "none"
		if player.stream is AudioStreamWAV:
			var wav := player.stream as AudioStreamWAV
			stream_desc = "%d samples, loop=%s" % [
				wav.data.size() / 2,
				"forward" if wav.loop_mode == AudioStreamWAV.LOOP_FORWARD else "off"]
		print("%-28s %-8s %8s %8.1f  %s" % [
			player.name, player.bus, str(player.playing), player.volume_db,
			stream_desc])

	print("\n%d of %d voices playing" % [playing, total])
	# Every continuous voice — engine bands on and off load, turbo, tyre
	# squeal, surface scrub — has to be running for the mixer to have anything
	# to fade. Only the one-shot player is idle by design.
	var expected := total - 1
	if playing < expected:
		print("FAIL: %d voices are silent that should be looping" % [expected - playing])
		get_tree().quit(1)
		return
	# Pitch across the rev range. A loop baked at one speed and played back at
	# more than about double or less than about half is audibly a tape being
	# abused rather than an engine, so the bands have to cover the range
	# between them.
	print("\npitch across the rev range:")
	var worst := 1.0
	var rpm := _car.stats.idle_rpm
	while rpm <= _car.stats.redline_rpm + 1.0:
		var blend := audio.voice.band_blend(rpm)
		var band := int(blend[1]) if float(blend[2]) > 0.5 else int(blend[0])
		var pitch := audio.voice.pitch_for(band, rpm)
		print("  %5.0f rpm  band %d  pitch %.2f" % [rpm, band, pitch])
		worst = maxf(worst, maxf(pitch, 1.0 / maxf(pitch, 0.01)))
		rpm += (_car.stats.redline_rpm - _car.stats.idle_rpm) / 8.0
	print("worst pitch stretch: %.2fx" % worst)
	if worst > 2.2:
		print("FAIL: a loop is stretched %.2fx, which will not sound like an engine" % worst)
		get_tree().quit(1)
		return

	print("OK")
	get_tree().quit(0)
