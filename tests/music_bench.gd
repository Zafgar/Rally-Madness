extends Node
## Renders every track and measures it.
##
## Music can be checked without listening to it, at least for the things that
## make it unlistenable. A loop that clips clicks once a bar; one with a DC
## offset eats headroom for nothing; one whose seam does not join clicks on
## every repeat; and one whose bass is not actually at the frequency the chord
## says it is, is in the wrong key. All of those are measurable.
##
##   godot --headless --path . res://tests/music_bench.tscn

const PRESETS := ["menu", "garage", "showroom", "results", "grid"]


func _ready() -> void:
	print("=== music ===")
	print("%-10s %6s %5s %5s %6s %7s %7s %7s" % [
		"track", "bpm", "bars", "sec", "peak", "rms", "dc", "seam"])

	var failures := 0
	for preset in PRESETS:
		var track := MusicTrack.make(preset)
		var stream := track.render()
		var buffer := _decode(stream)

		var peak := AudioSynth.peak(buffer)
		var rms := AudioSynth.rms(buffer)
		var dc := _mean(buffer)
		var seam := AudioSynth.loop_discontinuity(buffer)

		print("%-10s %6.0f %5d %5.1f %6.3f %7.4f %7.4f %7.2f" % [
			preset, track.bpm, track.bars, track.total_seconds(),
			peak, rms, dc, seam])

		if peak > 1.0:
			print("  FAIL clips at %.3f" % peak)
			failures += 1
		if peak < 0.2:
			print("  FAIL is nearly silent (%.3f)" % peak)
			failures += 1
		if absf(dc) > 0.02:
			print("  FAIL has a DC offset of %.4f" % dc)
			failures += 1
		if seam > 8.0:
			print("  FAIL loop seam is %.1fx the normal sample step" % seam)
			failures += 1
		if stream.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			print("  FAIL does not loop")
			failures += 1

		# The bass has to be where the key says it is, or the track is in the
		# wrong key and everything else built on it is too. Measured against
		# the root of the first chord.
		var root := MusicTheory.chord_root(track.key_midi, track.scale,
			track.progression, 0)
		var root_hz := MusicTheory.midi_to_hz(float(root))
		# Measured over the first bar only, where the chord is known and does
		# not change, and as a band rather than a single frequency.
		#
		# Both of those are necessary. Over the whole track the bass has moved
		# through three other chords, so the root of bar zero is not what most
		# of the buffer contains. And a note that repeats five times a bar has
		# a comb-shaped spectrum, so one exact bin can land between the teeth
		# and read as silence — the first version of this test measured the
		# kick drum and the second measured a gap in a comb.
		var bar_samples: int = mini(
			int(track.seconds_per_beat() * float(MusicTrack.BEATS_PER_BAR)
				* AudioSynth.MIX_RATE), buffer.size())
		var bar := buffer.slice(0, bar_samples)
		var semitone := pow(2.0, 1.0 / 12.0)
		var on_note := _band_energy(bar, root_hz)
		var off_note := maxf(_band_energy(bar, root_hz * semitone),
			_band_energy(bar, root_hz / semitone))
		var ratio := on_note / maxf(off_note, 0.000001)
		print("  root %.1f Hz over bar 1: %.2fx a semitone either side" % [
			root_hz, ratio])
		if ratio < 1.5:
			print("  FAIL the root note is not where the key says it is")
			failures += 1

	# The scales have to be scales: ascending, inside an octave, no repeats.
	for name in MusicTheory.SCALES:
		var steps: Array = MusicTheory.SCALES[name]
		var ok := steps.size() >= 5 and int(steps[0]) == 0 and int(steps[-1]) < 12
		for i in range(1, steps.size()):
			if int(steps[i]) <= int(steps[i - 1]):
				ok = false
		if not ok:
			print("FAIL scale '%s' is not a scale: %s" % [name, str(steps)])
			failures += 1

	# Two octaves of a scale have to be exactly twelve semitones apart, which
	# is the check that catches degree_to_midi wrapping wrongly on negatives.
	for name in MusicTheory.SCALES:
		var size: int = (MusicTheory.SCALES[name] as Array).size()
		var low := MusicTheory.degree_to_midi(60, name, -size)
		var mid := MusicTheory.degree_to_midi(60, name, 0)
		var high := MusicTheory.degree_to_midi(60, name, size)
		if mid - low != 12 or high - mid != 12:
			print("FAIL '%s' octaves are %d and %d semitones" % [
				name, mid - low, high - mid])
			failures += 1

	print("\n=== %d failures ===" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _decode(stream: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var data := stream.data
	out.resize(data.size() / 2)
	for i in out.size():
		out[i] = float(data.decode_s16(i * 2)) / 32767.0
	return out


## Energy in a narrow band around `hz`, summed over several bins. One bin is
## too sharp an instrument for a signal whose notes start and stop.
func _band_energy(buffer: PackedFloat32Array, hz: float) -> float:
	var total := 0.0
	# Plus and minus about a fifth of a semitone, which is far narrower than
	# the semitone the control sits at and wide enough to catch the note.
	for i in range(-2, 3):
		total += AudioSynth.energy_at(buffer, hz * (1.0 + float(i) * 0.005))
	return total


func _mean(buffer: PackedFloat32Array) -> float:
	if buffer.is_empty():
		return 0.0
	var total := 0.0
	for v in buffer:
		total += v
	return total / float(buffer.size())
