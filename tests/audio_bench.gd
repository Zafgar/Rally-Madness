extends Node
## What every car in the game sounds like, in numbers.
##
## Audio cannot be checked by reading the code and there is nobody here to
## listen, so it is checked the only other way: by measuring the waveform. The
## claims worth measuring are the ones that would ruin the game if they were
## wrong.
##
##   The fundamental has to be the firing frequency. If it is not, every engine
##   in the game is the wrong note and no amount of mixing will save it.
##
##   Loops have to be seamless. A step between the last sample and the first
##   clicks once per repetition, which at 3000 rpm is a hundred clicks a second.
##
##   Engines have to differ from each other. Fifty-seven cars that all sound
##   the same at different pitches is the failure this whole system exists to
##   avoid, and it is visible as a spectral centroid.
##
##   godot --headless --path . res://tests/audio_bench.tscn

func _ready() -> void:
	print("=== Rally Madness audio bench ===")
	print("%-30s %-16s %7s %7s %8s %8s %7s" % [
		"car", "engine", "idle Hz", "max Hz", "loop ms", "centroid", "peak"])

	var worst_discontinuity := 0.0
	var centroids: Array[float] = []

	for spec in CarDatabase.all():
		var layout: EngineLayout = spec.engine_layout
		if layout == null:
			continue
		var stats := TuningCalculator.resolve(spec, spec.default_loadout())
		var voice := EngineVoice.bake(stats, layout, 0, 0)

		# Measure the top band, which is the one a player hears most.
		var band := voice.on_load.size() - 1
		var samples := _samples_of(voice.on_load[band])
		var rpm := voice.band_rpm[band]
		var firing := layout.firing_hz(rpm)

		var discontinuity := AudioSynth.loop_discontinuity(samples)
		worst_discontinuity = maxf(worst_discontinuity, discontinuity)
		var centroid := AudioSynth.spectral_centroid(samples)
		centroids.append(centroid)

		print("%-30s %-16s %7.0f %7.0f %8.1f %8.0f %7.2f" % [
			spec.display_name(), layout.display_name(),
			layout.firing_hz(stats.idle_rpm), firing,
			float(samples.size()) / float(AudioSynth.MIX_RATE) * 1000.0,
			centroid, AudioSynth.peak(samples)])

	centroids.sort()
	print("\nloop discontinuity, worst: %.4f" % worst_discontinuity)
	print("spectral centroid across the field: %.0f Hz to %.0f Hz" % [
		centroids[0], centroids[centroids.size() - 1]])
	get_tree().quit(0)


static func _samples_of(stream: AudioStreamWAV) -> PackedFloat32Array:
	var data := stream.data
	var out := PackedFloat32Array()
	out.resize(data.size() / 2)
	for i in out.size():
		out[i] = float(data.decode_s16(i * 2)) / 32768.0
	return out
