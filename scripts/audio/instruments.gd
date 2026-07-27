class_name Instruments
extends RefCounted
## The voices the music is played on, rendered a note at a time.
##
## Every one of these is an oscillator, an envelope and a filter, which between
## them are most of what a synthesiser is. They are written as "render this note
## into this buffer at this offset" rather than as live voices, because the
## music is baked into a loop up front: a four-bar loop rendered once costs a
## few hundred kilobytes and nothing per frame, where a live synth costs
## something every frame forever and would be competing with twelve cars'
## engines for the same budget.



## An ADSR envelope, evaluated at one moment. Attack and release in seconds,
## sustain as a level.
##
## The shape of this is most of what tells one instrument from another: a
## plucked string is all attack and decay, a pad is all attack and release, and
## the same oscillator does both.
static func envelope(t: float, duration: float, attack: float, decay: float,
		sustain: float, release: float) -> float:
	if t < 0.0:
		return 0.0
	var body := maxf(duration - release, 0.001)
	if t < attack:
		return t / maxf(attack, 0.0001)
	if t < attack + decay:
		var into := (t - attack) / maxf(decay, 0.0001)
		return lerpf(1.0, sustain, into)
	if t < body:
		return sustain
	if t < duration:
		return sustain * (1.0 - (t - body) / maxf(release, 0.0001))
	return 0.0


## A sawtooth, which is every harmonic at once and therefore the starting point
## for anything that has to sound big.
static func saw(phase: float) -> float:
	return 2.0 * (phase - floorf(phase + 0.5))


## A square with a variable pulse width. Narrowing the pulse thins the sound
## and is the classic way to make one oscillator sound like two.
static func pulse(phase: float, width: float) -> float:
	return 1.0 if fposmod(phase, 1.0) < width else -1.0


static func triangle(phase: float) -> float:
	var p := fposmod(phase, 1.0)
	return 4.0 * absf(p - 0.5) - 1.0


## The bass. A detuned pair of saws an octave apart through a low-pass, which
## is the sound of every driving track ever made and is not an accident: the
## octave gives it weight on a phone speaker and body on a subwoofer, and one
## of the two survives whatever the player is listening on.
static func bass(buffer: PackedFloat32Array, start: int, hz: float,
		duration: float, gain: float) -> void:
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phase := 0.0
	var sub_phase := 0.0
	var step := hz / AudioSynth.MIX_RATE
	# A slight detune between the two so they beat against each other rather
	# than sitting perfectly still, which is what makes it sound analogue.
	var sub_step := hz * 0.4995 / AudioSynth.MIX_RATE
	var low := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var env := envelope(t, duration, 0.004, 0.08, 0.72, 0.05)
		# The filter closes as the note decays, which is what makes a bass note
		# sound plucked rather than switched on.
		var cutoff := lerpf(0.42, 0.10, clampf(t / maxf(duration, 0.001), 0.0, 1.0))
		var raw := saw(phase) * 0.6 + saw(sub_phase) * 0.75
		low += (raw - low) * cutoff
		buffer[index] += low * env * gain
		phase += step
		sub_phase += sub_step


## The lead. A narrow pulse with vibrato, sitting two octaves above the bass so
## it never fights it for the same space in the mix.
static func lead(buffer: PackedFloat32Array, start: int, hz: float,
		duration: float, gain: float) -> void:
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phase := 0.0
	var low := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var env := envelope(t, duration, 0.012, 0.10, 0.55, 0.09)
		# Vibrato, delayed slightly so the note lands cleanly before it starts
		# to move. An immediate vibrato sounds like a wobble; a delayed one
		# sounds like somebody playing.
		var vibrato := sin(TAU * 5.4 * t) * 0.006 * clampf((t - 0.06) * 5.0, 0.0, 1.0)
		var step := hz * (1.0 + vibrato) / AudioSynth.MIX_RATE
		var raw := pulse(phase, 0.30) * 0.5 + triangle(phase * 2.0) * 0.2
		low += (raw - low) * 0.55
		buffer[index] += low * env * gain
		phase += step


## Chords, held. Three or four detuned saws, filtered hard, quiet — the thing
## that fills the space between the bass and the lead and that nobody notices
## until it is missing.
static func pad(buffer: PackedFloat32Array, start: int, notes: Array,
		duration: float, gain: float) -> void:
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phases := PackedFloat32Array()
	var detunes := PackedFloat32Array()
	for n in notes.size():
		phases.append(0.0)
		# Each voice a few cents off, spread either side of true.
		detunes.append(1.0 + (float(n) - float(notes.size()) * 0.5) * 0.0016)
	var low := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var env := envelope(t, duration, 0.18, 0.25, 0.80, 0.30)
		var raw := 0.0
		for n in notes.size():
			raw += saw(phases[n])
			phases[n] += float(notes[n]) * detunes[n] / AudioSynth.MIX_RATE
		raw /= maxf(float(notes.size()), 1.0)
		low += (raw - low) * 0.13
		buffer[index] += low * env * gain


## A plucked arpeggio voice — short, bright, and the part that carries the
## movement while the pad holds still.
static func pluck(buffer: PackedFloat32Array, start: int, hz: float,
		duration: float, gain: float) -> void:
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phase := 0.0
	var step := hz / AudioSynth.MIX_RATE
	var low := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var env := envelope(t, duration, 0.002, duration * 0.7, 0.05, 0.02)
		var raw := saw(phase) * 0.5 + pulse(phase, 0.5) * 0.3
		# The filter opens with velocity and shuts fast, which is what a pluck
		# is: a bright transient and then almost nothing.
		var cutoff := lerpf(0.75, 0.14, clampf(t / maxf(duration, 0.001), 0.0, 1.0))
		low += (raw - low) * cutoff
		buffer[index] += low * env * gain


# --- Drums ------------------------------------------------------------------
#
# All three are noise or a sine with an envelope on it. A kick is a sine whose
# pitch falls; a snare is noise plus a tuned body; a hat is filtered noise. That
# really is all they are, and it is why a drum machine could be built out of
# almost nothing decades before anyone could afford to store a recording.

static func kick(buffer: PackedFloat32Array, start: int, gain: float,
		rng: RandomNumberGenerator) -> void:
	var duration := 0.34
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phase := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		# The pitch drop is the kick. From a click down to a note in 60 ms.
		var hz := lerpf(150.0, 44.0, clampf(t / 0.06, 0.0, 1.0))
		var env: float = exp(-t * 13.0)
		var click: float = exp(-t * 320.0) * rng.randf_range(-1.0, 1.0) * 0.25
		buffer[index] += (sin(TAU * phase) + click) * env * gain
		phase += hz / AudioSynth.MIX_RATE


static func snare(buffer: PackedFloat32Array, start: int, gain: float,
		rng: RandomNumberGenerator) -> void:
	var duration := 0.22
	var samples := int(duration * AudioSynth.MIX_RATE)
	var phase := 0.0
	var high := 0.0
	var previous := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var noise := rng.randf_range(-1.0, 1.0)
		# High-passed noise is the snare wires; the sine underneath is the drum
		# itself, and without it a snare is just a hiss.
		high = 0.72 * (high + noise - previous)
		previous = noise
		var env: float = exp(-t * 22.0)
		var body: float = sin(TAU * phase) * exp(-t * 34.0) * 0.5
		buffer[index] += (high * 0.8 + body) * env * gain
		phase += 185.0 / AudioSynth.MIX_RATE


static func hat(buffer: PackedFloat32Array, start: int, gain: float,
		open: bool, rng: RandomNumberGenerator) -> void:
	var duration := 0.16 if open else 0.045
	var samples := int(duration * AudioSynth.MIX_RATE)
	var high := 0.0
	var previous := 0.0
	for i in samples:
		var index := start + i
		if index >= buffer.size():
			return
		var t := float(i) / AudioSynth.MIX_RATE
		var noise := rng.randf_range(-1.0, 1.0)
		# Steeper high-pass than the snare: a hat is almost all top end.
		high = 0.92 * (high + noise - previous)
		previous = noise
		var env: float = exp(-t * (11.0 if open else 62.0))
		buffer[index] += high * env * gain
