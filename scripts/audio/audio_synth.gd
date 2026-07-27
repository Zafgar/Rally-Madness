class_name AudioSynth
extends RefCounted
## The bits every sound in this game is built from.
##
## There are no audio files anywhere in this project, for the same reason there
## are no car sprites: everything is generated from the numbers that describe
## the thing making the noise. A turbo whistles at a pitch that comes from its
## boost pressure, a tyre squeals at a frequency that comes from its slip angle,
## and an engine's note comes from how many cylinders it has and how fast they
## are firing. Sampling that would mean recording 57 cars.
##
## Everything here works on PackedFloat32Array in the range -1..1 and only
## converts to 16-bit PCM at the very end, so intermediate stages never clip.

## Sounds are baked at half CD rate. Engine notes, tyre squeal and turbo
## whistle all live below 8 kHz, so 22 050 samples per second is transparent
## for this material and halves both the baking time and the memory.
const MIX_RATE := 22050


# --- Buffers ----------------------------------------------------------------

static func silence(samples: int) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(maxi(samples, 1))
	buffer.fill(0.0)
	return buffer


static func seconds_to_samples(seconds: float) -> int:
	return maxi(int(round(seconds * float(MIX_RATE))), 1)


## Adds `source` into `target` starting at `offset`, wrapping past the end.
##
## Wrapping is what makes a loop seamless: an exhaust pulse near the end of the
## cycle has its tail land at the beginning, which is exactly where it belongs
## when the loop repeats.
static func add_wrapped(
	target: PackedFloat32Array,
	source: PackedFloat32Array,
	offset: int,
	gain: float = 1.0
) -> void:
	var length := target.size()
	if length == 0:
		return
	for i in source.size():
		var index := (offset + i) % length
		target[index] += source[i] * gain


static func scale(buffer: PackedFloat32Array, gain: float) -> void:
	for i in buffer.size():
		buffer[i] *= gain


## Scales the whole buffer so its loudest sample sits at `peak`. Every bake ends
## with this, so no sound can clip regardless of how many pulses overlapped.
static func normalise(buffer: PackedFloat32Array, peak: float = 0.92) -> void:
	var loudest := 0.0
	for value in buffer:
		loudest = maxf(loudest, absf(value))
	if loudest > 0.0001:
		scale(buffer, peak / loudest)


## Removes any constant offset. A buffer that does not average to zero makes a
## click every time it loops and wastes headroom on silence.
static func remove_dc(buffer: PackedFloat32Array) -> void:
	if buffer.is_empty():
		return
	var sum := 0.0
	for value in buffer:
		sum += value
	var mean := sum / float(buffer.size())
	for i in buffer.size():
		buffer[i] -= mean


# --- Sources ----------------------------------------------------------------

## White noise, which is the raw material for anything that hisses, roars or
## scrubs: induction, tyres on gravel, wind, the broadband half of an exhaust.
static func noise(samples: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(maxi(samples, 1))
	for i in buffer.size():
		buffer[i] = rng.randf_range(-1.0, 1.0)
	return buffer


## A sine that completes a whole number of cycles over the buffer, so it loops
## without a click. Used wherever a steady tone has to sit inside a loop.
static func looped_sine(samples: int, cycles: int, phase: float = 0.0,
		amplitude: float = 1.0) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(maxi(samples, 1))
	for i in buffer.size():
		buffer[i] = sin(TAU * float(cycles) * float(i) / float(buffer.size()) + phase) \
			* amplitude
	return buffer


## One exhaust pulse: a burst of resonating gas that decays away.
##
## This is the single most important waveform in the game. An engine note is
## nothing but a lot of these arriving in a particular rhythm, and how bright,
## how long and how rough each one is decides whether the engine sounds like a
## diesel, a hot hatch or a Group B car.
##
##   `resonance_hz`  the pipe's own note — a long exhaust rings lower
##   `decay_seconds` how quickly it dies; short is crisp, long is boomy
##   `roughness`     how much of the pulse is noise rather than tone
##   `bite`          adds a harder attack transient, which is what makes an
##                   engine sound aggressive rather than smooth
static func exhaust_pulse(
	resonance_hz: float,
	decay_seconds: float,
	roughness: float,
	bite: float,
	rng: RandomNumberGenerator
) -> PackedFloat32Array:
	var samples := seconds_to_samples(decay_seconds * 4.0)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)
	var inverse_rate := 1.0 / float(MIX_RATE)
	var omega := TAU * maxf(resonance_hz, 20.0)
	# A second resonance a fifth above gives the pulse a body rather than a
	# pure beep; real exhausts ring at several frequencies at once.
	var omega_2 := omega * 1.5
	var noise_state := 0.0
	for i in samples:
		var t := float(i) * inverse_rate
		var envelope := exp(-t / maxf(decay_seconds, 0.0005))
		var attack := 1.0 - exp(-t * 900.0)   # a few hundred microseconds
		var tone := sin(omega * t) * 0.7 + sin(omega_2 * t) * 0.3
		# Brown-ish noise: white noise through a one-pole low pass, which is
		# much closer to combustion roar than white noise on its own.
		noise_state = lerpf(noise_state, rng.randf_range(-1.0, 1.0), 0.34)
		var body := lerpf(tone, noise_state * 1.6, clampf(roughness, 0.0, 1.0))
		# The transient: a very short, very sharp crack on top.
		var crack := exp(-t * 2600.0) * rng.randf_range(-1.0, 1.0) * bite
		buffer[i] = (body * envelope * attack) + crack
	return buffer


# --- Filters ----------------------------------------------------------------

## One-pole low pass. Cheap, and the only filter this needs: everything here is
## about how bright a sound is, not about surgical equalisation.
##
## `looped` runs a priming pass over the whole buffer first and throws the
## result away, so the filter's state when it reaches sample zero is the state
## it will have coming round again. Without it every filtered loop has a step
## at the seam — the first samples are filtered from silence and the last are
## not — and a step in a loop is a click at the loop rate. At 3000 rpm that is
## a hundred clicks a second, which is what this cost before it was found.
static func low_pass(buffer: PackedFloat32Array, cutoff_hz: float,
		looped: bool = true) -> void:
	var alpha := _one_pole_alpha(cutoff_hz)
	var state := 0.0
	if looped:
		for i in buffer.size():
			state += alpha * (buffer[i] - state)
	for i in buffer.size():
		state += alpha * (buffer[i] - state)
		buffer[i] = state


static func high_pass(buffer: PackedFloat32Array, cutoff_hz: float,
		looped: bool = true) -> void:
	var alpha := _one_pole_alpha(cutoff_hz)
	var state := 0.0
	if looped:
		for i in buffer.size():
			state += alpha * (buffer[i] - state)
	for i in buffer.size():
		state += alpha * (buffer[i] - state)
		buffer[i] -= state


## A resonant peak, for anything with a whistle in it: turbo, supercharger,
## transmission whine, tyre squeal. `q` decides how pure the tone is.
static func resonate(
	buffer: PackedFloat32Array,
	frequency_hz: float,
	q: float,
	mix: float,
	looped: bool = true
) -> void:
	# A two-pole band-pass, applied in parallel with the dry signal so the
	# result keeps its body instead of turning into a sine wave.
	var w := TAU * clampf(frequency_hz, 20.0, float(MIX_RATE) * 0.45) / float(MIX_RATE)
	var r := clampf(1.0 - 1.0 / maxf(q, 0.5) * 0.5, 0.80, 0.9995)
	var a1 := -2.0 * r * cos(w)
	var a2 := r * r
	var gain := (1.0 - r) * sqrt(1.0 - 2.0 * r * cos(2.0 * w) + r * r)
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	# Primed the same way as the one-pole filters, and for the same reason: a
	# resonator started from silence rings up over the first few milliseconds
	# and would leave a step where the loop joins.
	if looped:
		for i in buffer.size():
			var px := buffer[i]
			var py := gain * px - a1 * y1 - a2 * y2
			x2 = x1
			x1 = px
			y2 = y1
			y1 = py
	for i in buffer.size():
		var x := buffer[i]
		var y := gain * x - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		buffer[i] = lerpf(x, y, clampf(mix, 0.0, 1.0))


static func _one_pole_alpha(cutoff_hz: float) -> float:
	var cutoff := clampf(cutoff_hz, 10.0, float(MIX_RATE) * 0.48)
	var rc := 1.0 / (TAU * cutoff)
	var dt := 1.0 / float(MIX_RATE)
	return clampf(dt / (rc + dt), 0.0, 1.0)


## Fades the ends of a buffer into each other so a one-shot can be looped, or a
## one-shot can start and stop without a click.
static func fade_edges(buffer: PackedFloat32Array, seconds: float) -> void:
	var fade := mini(seconds_to_samples(seconds), buffer.size() / 2)
	for i in fade:
		var t := float(i) / float(maxi(fade, 1))
		buffer[i] *= t
		buffer[buffer.size() - 1 - i] *= t


# --- Output -----------------------------------------------------------------

## Turns a float buffer into something Godot will play.
##
## Mono 16-bit, because these are point sources in a 2D world: the position and
## the distance come from the AudioStreamPlayer2D, and a stereo source would
## fight it.
static func to_stream(buffer: PackedFloat32Array, looping: bool) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false

	var data := PackedByteArray()
	data.resize(buffer.size() * 2)
	for i in buffer.size():
		var value := int(clampf(buffer[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, value)
	stream.data = data

	if looping:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = buffer.size()
	return stream


# --- Analysis, for the tests ------------------------------------------------

## How much energy a buffer has at one exact frequency, by the Goertzel
## algorithm — a single-bin discrete Fourier transform.
##
## This exists so the audio can be verified without listening to it. "The
## fundamental of this loop is where the firing frequency says it should be" is
## a checkable claim, and it is the one that matters: if it is wrong, every
## engine in the game is the wrong note.
static func energy_at(buffer: PackedFloat32Array, frequency_hz: float) -> float:
	if buffer.is_empty():
		return 0.0
	var k := TAU * frequency_hz / float(MIX_RATE)
	var coefficient := 2.0 * cos(k)
	var s1 := 0.0
	var s2 := 0.0
	for sample in buffer:
		var s0 := sample + coefficient * s1 - s2
		s2 = s1
		s1 = s0
	var power := s1 * s1 + s2 * s2 - coefficient * s1 * s2
	return sqrt(maxf(power, 0.0)) / float(buffer.size())


## Roughly where the energy sits in the spectrum, in hertz. A bright, hard
## sound has a high centroid and a boomy one a low centroid, so this is how two
## engines are shown to be genuinely different rather than the same sound at
## two pitches.
static func spectral_centroid(buffer: PackedFloat32Array, bins: int = 48,
		top_hz: float = 6000.0) -> float:
	var weighted := 0.0
	var total := 0.0
	for i in range(1, bins + 1):
		var frequency := top_hz * float(i) / float(bins)
		var magnitude := energy_at(buffer, frequency)
		weighted += frequency * magnitude
		total += magnitude
	return weighted / maxf(total, 0.000001)


## How badly a loop clicks where it joins, as a multiple of how much the signal
## normally moves between one sample and the next.
##
## The absolute step at the seam is not the measure. A bright sound at 22 kHz
## legitimately swings half its amplitude between adjacent samples, so a raw
## step of 0.4 can be either a loud click or completely normal — the number
## alone cannot tell you, and reading it as a fault sends you off fixing audio
## that was never broken.
##
## What matters is whether the seam looks like the rest of the waveform. Near 1
## is seamless; a large multiple is a click at the loop rate.
static func loop_discontinuity(buffer: PackedFloat32Array) -> float:
	if buffer.size() < 4:
		return 0.0
	var sum_squares := 0.0
	for i in range(1, buffer.size()):
		var step := buffer[i] - buffer[i - 1]
		sum_squares += step * step
	var typical := sqrt(sum_squares / float(buffer.size() - 1))
	if typical < 0.000001:
		return 0.0
	var seam := absf(buffer[0] - buffer[buffer.size() - 1])
	return seam / typical


static func peak(buffer: PackedFloat32Array) -> float:
	var loudest := 0.0
	for value in buffer:
		loudest = maxf(loudest, absf(value))
	return loudest


static func rms(buffer: PackedFloat32Array) -> float:
	if buffer.is_empty():
		return 0.0
	var sum := 0.0
	for value in buffer:
		sum += value * value
	return sqrt(sum / float(buffer.size()))
