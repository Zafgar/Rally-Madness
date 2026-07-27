class_name MusicTrack
extends RefCounted
## Writes a piece of music and renders it to a loop.
##
## A track is a handful of decisions — key, scale, chord progression, tempo,
## which parts play — and then a deterministic arrangement of them. The
## randomness is seeded, so a given track is the same piece every time the game
## runs; it is generated rather than composed, but it is not different every
## time you open the menu, which would be exhausting.
##
## The whole thing renders to a single looping AudioStreamWAV. Four bars at 92
## beats per minute is about ten seconds, which at 22 kHz mono is a few hundred
## kilobytes and no per-frame cost at all.

const BEATS_PER_BAR := 4

var key_midi: int = 45          ## A2, low enough for the bass to sit under.
var scale: String = "phrygian_dominant"
var progression: String = "drive"
var bpm: float = 92.0
var bars: int = 8
var seed_value: int = 1

## Which parts are in. A menu wants everything; a garage wants the bass and the
## pad and none of the noise.
var use_drums: bool = true
var use_bass: bool = true
var use_pad: bool = true
var use_lead: bool = true
var use_arp: bool = true

## Overall level. Music sits well under the engines: it is the thing you notice
## when you stop paying attention, not the thing you are listening to.
var gain: float = 0.5


static func make(preset: String) -> MusicTrack:
	var t := MusicTrack.new()
	match preset:
		# The front end. Fast, dark and busy — the drift-film sound, which is a
		# minor-key hook over a heavy off-beat bass with the hats doing most of
		# the work.
		"menu":
			t.key_midi = 45
			t.scale = "phrygian_dominant"
			t.progression = "drive"
			t.bpm = 94.0
			t.bars = 8
			t.seed_value = 20125
		# The garage. Same world, half the energy: you are reading numbers and
		# spending money, and a hook over the top of that is an irritation.
		"garage":
			t.key_midi = 43
			t.scale = "minor_pentatonic"
			t.progression = "hover"
			t.bpm = 78.0
			t.bars = 8
			t.use_lead = false
			t.gain = 0.38
			t.seed_value = 7731
		# The showroom, where the player is being sold something.
		"showroom":
			t.key_midi = 46
			t.scale = "minor"
			t.progression = "hover"
			t.bpm = 88.0
			t.bars = 8
			t.use_drums = true
			t.use_lead = false
			t.gain = 0.40
			t.seed_value = 4402
		# Results. The one place the music is allowed to be pleased, so it is
		# the one place with a major third in it.
		"results":
			t.key_midi = 48
			t.scale = "mixolydian"
			t.progression = "lift"
			t.bpm = 100.0
			t.bars = 4
			t.gain = 0.46
			t.seed_value = 991
		# Behind the countdown, and nothing else. Tense and nearly empty.
		"grid":
			t.key_midi = 41
			t.scale = "locrian"
			t.progression = "hover"
			t.bpm = 120.0
			t.bars = 2
			t.use_lead = false
			t.use_arp = false
			t.gain = 0.42
			t.seed_value = 313
		_:
			pass
	return t


func seconds_per_beat() -> float:
	return 60.0 / maxf(bpm, 1.0)


func total_seconds() -> float:
	return float(bars) * float(BEATS_PER_BAR) * seconds_per_beat()


## Renders the whole piece and hands back a stream that loops seamlessly,
## because the loop length is a whole number of bars by construction.
func render() -> AudioStreamWAV:
	var samples := int(total_seconds() * AudioSynth.MIX_RATE)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)
	buffer.fill(0.0)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	if use_pad:
		_write_pad(buffer)
	if use_bass:
		_write_bass(buffer)
	if use_arp:
		_write_arp(buffer, rng)
	if use_lead:
		_write_lead(buffer, rng)
	if use_drums:
		_write_drums(buffer, rng)

	# Normalise to a known headroom rather than trusting the sum of the parts.
	# Five instruments adding up is entirely capable of clipping, and a clipped
	# loop clicks once per bar forever.
	var peak := AudioSynth.peak(buffer)
	if peak > 0.0001:
		var scale_to := gain / peak
		for i in buffer.size():
			buffer[i] *= scale_to
	return AudioSynth.to_stream(buffer, true)


func _sample_at(beat: float) -> int:
	return int(beat * seconds_per_beat() * AudioSynth.MIX_RATE)


# --- Parts ------------------------------------------------------------------

## The bass: the root of the chord on the downbeat, then an off-beat push. The
## push is what makes it drive rather than plod, and it is the single most
## recognisable thing about this kind of music.
func _write_bass(buffer: PackedFloat32Array) -> void:
	var beat_length := seconds_per_beat()
	for bar in bars:
		var root := MusicTheory.chord_root(key_midi, scale, progression, bar)
		var hz := MusicTheory.midi_to_hz(float(root))
		var base := float(bar * BEATS_PER_BAR)
		# Downbeat, held. Then three shorter notes off the beat.
		Instruments.bass(buffer, _sample_at(base), hz, beat_length * 0.9, 0.85)
		for offset in [1.5, 2.5, 3.0, 3.75]:
			# The octave jump on the last one is the fill that stops the bar
			# from being identical to the one before it.
			var note_hz := hz * (2.0 if is_equal_approx(offset, 3.75) else 1.0)
			Instruments.bass(buffer, _sample_at(base + offset), note_hz,
				beat_length * 0.42, 0.70)


## The pad: one chord per bar, held across the whole bar.
func _write_pad(buffer: PackedFloat32Array) -> void:
	var bar_length := seconds_per_beat() * float(BEATS_PER_BAR)
	for bar in bars:
		var notes := MusicTheory.chord_notes(key_midi, scale, progression, bar, true)
		var hz: Array = []
		for note in notes:
			# Two octaves up from the bass, where a pad does not muddy anything.
			hz.append(MusicTheory.midi_to_hz(float(note + 24)))
		Instruments.pad(buffer, _sample_at(float(bar * BEATS_PER_BAR)), hz,
			bar_length * 0.98, 0.38)


## The arpeggio: sixteenths climbing and falling through the chord. This is the
## part that carries the movement, and the reason a four-chord loop does not
## sound like four chords.
func _write_arp(buffer: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var beat_length := seconds_per_beat()
	var step := 0.25
	for bar in bars:
		var notes := MusicTheory.chord_notes(key_midi, scale, progression, bar, true)
		var count := int(float(BEATS_PER_BAR) / step)
		for i in count:
			# Up and back down rather than round and round: a pattern that only
			# ever climbs sounds like a scale exercise.
			var position := i % (notes.size() * 2 - 2) if notes.size() > 1 else 0
			var index: int = position if position < notes.size() \
				else notes.size() * 2 - 2 - position
			var octave := 24 if (i / notes.size()) % 2 == 0 else 36
			var hz := MusicTheory.midi_to_hz(float(int(notes[index]) + octave))
			# A few notes dropped, in a fixed pattern from the seed, so the
			# sixteenths breathe instead of machine-gunning.
			if rng.randf() < 0.16:
				continue
			Instruments.pluck(buffer, _sample_at(float(bar * BEATS_PER_BAR) + float(i) * step),
				hz, beat_length * step * 1.6, 0.30)


## The lead: a short hook, repeated with variation. Written once and then
## transposed to whatever chord the bar is on, so it always fits.
func _write_lead(buffer: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var beat_length := seconds_per_beat()
	# Degrees relative to the chord root, and how long each is held in beats.
	# A hook is short and has a shape; this one climbs, hangs, and falls back.
	var hook := [
		{"degree": 0, "at": 0.0, "length": 0.75},
		{"degree": 2, "at": 0.75, "length": 0.5},
		{"degree": 4, "at": 1.25, "length": 1.0},
		{"degree": 3, "at": 2.5, "length": 0.5},
		{"degree": 2, "at": 3.0, "length": 0.75},
	]
	for bar in bars:
		# The hook plays on alternate bars, so it is an answer to the rhythm
		# rather than a thing shouting over it continuously.
		if bar % 2 == 1:
			continue
		var roots: Array = MusicTheory.PROGRESSIONS.get(progression,
			MusicTheory.PROGRESSIONS["drive"])
		var chord_degree := int(roots[posmod(bar, roots.size())])
		for note in hook:
			var degree: int = chord_degree + int(note["degree"])
			# Two octaves above the bass, and one more every other repeat so
			# the second half of the loop lifts.
			var octave := 24 if bar < bars / 2 else 36
			var midi := MusicTheory.degree_to_midi(key_midi, scale, degree) + octave
			var length := float(note["length"]) * beat_length
			Instruments.lead(buffer,
				_sample_at(float(bar * BEATS_PER_BAR) + float(note["at"])),
				MusicTheory.midi_to_hz(float(midi)), length, 0.44)


## The drums. Kick on one and three with a push before four, snare on two and
## four, hats on every eighth with the off-beats accented — which is the beat
## that everything from a drum machine to a drift film soundtrack is built on.
func _write_drums(buffer: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	for bar in bars:
		var base := float(bar * BEATS_PER_BAR)
		for at in [0.0, 1.75, 2.0, 3.5]:
			Instruments.kick(buffer, _sample_at(base + at), 0.90, rng)
		for at in [1.0, 3.0]:
			Instruments.snare(buffer, _sample_at(base + at), 0.55, rng)
		var eighth := 0.0
		while eighth < float(BEATS_PER_BAR):
			var off_beat := not is_equal_approx(fposmod(eighth, 1.0), 0.0)
			# The open hat lands on the last off-beat of the bar and pulls it
			# into the next one. Without it the loop stops rather than turns.
			var open := is_equal_approx(eighth, float(BEATS_PER_BAR) - 0.5)
			Instruments.hat(buffer, _sample_at(base + eighth),
				0.26 if off_beat else 0.17, open, rng)
			eighth += 0.5
		# A fill at the end of the phrase, so eight bars is a phrase and not
		# just eight copies of one bar.
		if bar == bars - 1:
			for i in 4:
				Instruments.snare(buffer, _sample_at(base + 3.0 + float(i) * 0.25),
					0.30 + float(i) * 0.08, rng)
