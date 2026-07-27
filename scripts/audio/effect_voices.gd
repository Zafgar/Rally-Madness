class_name EffectVoices
extends RefCounted
## Everything a car makes a noise with that is not its engine.
##
## Same principle throughout: the sound comes from the number that causes it. A
## bigger turbo whistles lower and dumps harder because it moves more air; a
## tyre squeals at a pitch that comes from how fast the tread is scrubbing;
## a crash is loud in proportion to the energy that went into it. Fit a
## different turbo and it sounds different, because the sound was made from the
## turbo's own figures.
##
## These are baked once per car and then pitched and mixed at runtime, exactly
## like the engine loops.

# --- Turbo ------------------------------------------------------------------

## A steady whistle, looped. Pitch and volume are driven at runtime by how much
## boost is actually being made.
##
## `boost_ratio` is VehicleStats.turbo_boost — 1.0 for a naturally aspirated
## engine, higher for a turbo. `lag_seconds` stands in for the size of the
## thing: a big single is laggy and whistles low, a small journal bearing turbo
## spools instantly and screams.
static func bake_turbo_whistle(boost_ratio: float, lag_seconds: float,
		rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.5)
	var buffer := AudioSynth.noise(samples, rng)

	# Turbine speed, and therefore the note, falls as the turbo gets bigger.
	# Baked at the top of its range and pitched down at runtime.
	var whistle_hz := 5200.0 / (1.0 + clampf(lag_seconds, 0.0, 1.2) * 1.6)
	AudioSynth.high_pass(buffer, whistle_hz * 0.45)
	# Two closely spaced resonances rather than one: a compressor's whistle has
	# a beat to it, and a single pure tone sounds like a test signal.
	AudioSynth.resonate(buffer, whistle_hz, 34.0, 0.92)
	AudioSynth.resonate(buffer, whistle_hz * 1.49, 22.0, 0.45)
	# The rush of air underneath the whistle, which is most of what a big turbo
	# actually sounds like from outside the car.
	var rush := AudioSynth.noise(samples, rng)
	AudioSynth.low_pass(rush, 2400.0)
	AudioSynth.high_pass(rush, 700.0)
	AudioSynth.scale(rush, 0.30 + clampf(boost_ratio - 1.0, 0.0, 1.2) * 0.20)
	for i in buffer.size():
		buffer[i] += rush[i]

	_seamless(buffer)
	AudioSynth.normalise(buffer, 0.8)
	return AudioSynth.to_stream(buffer, true)


## The dump valve, on lifting off. A short chuff of released air, longer and
## deeper the more boost there was to release.
static func bake_blow_off(boost_ratio: float, lag_seconds: float,
		rng: RandomNumberGenerator) -> AudioStreamWAV:
	var over_boost := clampf(boost_ratio - 1.0, 0.0, 1.5)
	var length := 0.10 + over_boost * 0.14 + clampf(lag_seconds, 0.0, 1.0) * 0.10
	var samples := AudioSynth.seconds_to_samples(length)
	var buffer := AudioSynth.noise(samples, rng)

	# Falls in pitch as the pressure drops, which is the characteristic sound.
	var start_hz := 2600.0 / (1.0 + clampf(lag_seconds, 0.0, 1.2))
	AudioSynth.resonate(buffer, start_hz, 9.0, 0.7, false)
	AudioSynth.high_pass(buffer, 320.0, false)
	for i in samples:
		var t := float(i) / float(samples)
		# Sharp attack, long release: air escaping, not a click.
		buffer[i] *= (1.0 - exp(-t * 60.0)) * exp(-t * 5.5)
	AudioSynth.fade_edges(buffer, 0.004)
	AudioSynth.normalise(buffer, 0.85)
	return AudioSynth.to_stream(buffer, false)


## Wastegate flutter, for the big laggy turbos that do it. Only worth having on
## something with real boost.
static func bake_flutter(lag_seconds: float, rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.22)
	var buffer := AudioSynth.noise(samples, rng)
	AudioSynth.low_pass(buffer, 1300.0, false)
	# Chopped at fifty-odd hertz — the flutter is the valve chattering.
	var chops := 12
	for i in samples:
		var t := float(i) / float(samples)
		var chop := 0.5 + 0.5 * sin(TAU * float(chops) * t)
		buffer[i] *= chop * exp(-t * 7.0) * (1.0 + clampf(lag_seconds, 0.0, 1.0))
	AudioSynth.fade_edges(buffer, 0.004)
	AudioSynth.normalise(buffer, 0.7)
	return AudioSynth.to_stream(buffer, false)


# --- Tyres ------------------------------------------------------------------

## Rubber sliding on tarmac. A resonant scream whose pitch runs with how hard
## the tyre is working, pitched at runtime from the slip angle.
static func bake_tyre_squeal(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.6)
	var buffer := AudioSynth.noise(samples, rng)
	AudioSynth.high_pass(buffer, 500.0)
	# Squeal is stick-slip: the tread grabs and releases hundreds of times a
	# second, which is a strong narrow resonance with harmonics above it.
	AudioSynth.resonate(buffer, 1250.0, 26.0, 0.85)
	AudioSynth.resonate(buffer, 2500.0, 16.0, 0.40)
	AudioSynth.resonate(buffer, 3750.0, 12.0, 0.22)
	# A slow wobble, because a real squeal is never perfectly steady.
	var wobble := AudioSynth.looped_sine(samples, 5, 0.0, 0.22)
	for i in buffer.size():
		buffer[i] *= 1.0 - 0.22 + wobble[i]
	_seamless(buffer)
	AudioSynth.normalise(buffer, 0.75)
	return AudioSynth.to_stream(buffer, true)


## Loose surface under the tyres: gravel, dirt, snow. Broadband rather than
## tonal, because nothing is sticking and slipping — it is stones being thrown.
static func bake_surface_scrub(surface: TireModel.Surface,
		rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.7)
	var buffer := AudioSynth.noise(samples, rng)
	match surface:
		TireModel.Surface.GRAVEL:
			# Stones: hard, bright, rattly.
			AudioSynth.high_pass(buffer, 900.0)
			AudioSynth.low_pass(buffer, 7000.0)
			_sprinkle_grit(buffer, 260, rng)
		TireModel.Surface.DIRT, TireModel.Surface.MUD:
			AudioSynth.high_pass(buffer, 300.0)
			AudioSynth.low_pass(buffer, 2600.0)
			_sprinkle_grit(buffer, 90, rng)
		TireModel.Surface.SNOW, TireModel.Surface.ICE:
			# Snow is a hiss with nothing hard in it.
			AudioSynth.high_pass(buffer, 1600.0)
			AudioSynth.low_pass(buffer, 6000.0)
		TireModel.Surface.GRASS:
			AudioSynth.high_pass(buffer, 700.0)
			AudioSynth.low_pass(buffer, 4200.0)
		_:
			# Tarmac roar: the tread pattern, mostly low.
			AudioSynth.low_pass(buffer, 1500.0)
			AudioSynth.high_pass(buffer, 160.0)
	_seamless(buffer)
	AudioSynth.normalise(buffer, 0.62)
	return AudioSynth.to_stream(buffer, true)


## Individual stones pinging off the arches, which is what makes gravel sound
## like gravel rather than like static.
static func _sprinkle_grit(buffer: PackedFloat32Array, count: int,
		rng: RandomNumberGenerator) -> void:
	for i in count:
		var at := rng.randi_range(0, maxi(buffer.size() - 40, 1))
		var strength := rng.randf_range(0.3, 1.0)
		for j in 30:
			var index := (at + j) % buffer.size()
			buffer[index] += rng.randf_range(-1.0, 1.0) * strength * exp(-float(j) * 0.22)


# --- Impacts ----------------------------------------------------------------

## A collision. `severity` 0..1 decides how much of it is a deep structural
## thump and how much is a bright crack of panel and glass, which is the
## difference between brushing a barrier and hitting one.
static func bake_impact(severity: float, rng: RandomNumberGenerator) -> AudioStreamWAV:
	var hardness := clampf(severity, 0.0, 1.0)
	var length := 0.16 + hardness * 0.45
	var samples := AudioSynth.seconds_to_samples(length)
	var buffer := AudioSynth.silence(samples)

	# The body shell resonating: a low, short, tuned thump.
	var boom := AudioSynth.noise(samples, rng)
	AudioSynth.resonate(boom, lerpf(140.0, 78.0, hardness), 6.0, 0.75, false)
	AudioSynth.low_pass(boom, 500.0, false)
	# Panel and trim: a bright crack on top, and more of it the harder the hit.
	var crack := AudioSynth.noise(samples, rng)
	AudioSynth.high_pass(crack, 1800.0, false)

	for i in samples:
		var t := float(i) / float(AudioSynth.MIX_RATE)
		var body_env := exp(-t / (0.06 + hardness * 0.16))
		var crack_env := exp(-t / (0.012 + hardness * 0.05))
		buffer[i] = boom[i] * body_env * (0.6 + hardness * 0.5) \
			+ crack[i] * crack_env * (0.25 + hardness * 0.75)

	# Something torn off dragging along afterwards, on the big ones only.
	if hardness > 0.55:
		var debris := AudioSynth.noise(samples, rng)
		AudioSynth.high_pass(debris, 2600.0, false)
		for i in samples:
			var t := float(i) / float(AudioSynth.MIX_RATE)
			buffer[i] += debris[i] * exp(-t * 6.0) * (hardness - 0.55) * 0.6

	AudioSynth.fade_edges(buffer, 0.003)
	AudioSynth.normalise(buffer, 0.55 + hardness * 0.42)
	return AudioSynth.to_stream(buffer, false)


# --- Transmission -----------------------------------------------------------

## The horn.
##
## A real car horn is two horns, tuned a minor third or so apart and sounded
## together — the beating between them is what makes it carry, and a single
## tone sounds like a doorbell instead. The pitch comes from the car: a big
## saloon has a deep one and a small hatchback a shrill one, and mass is a
## perfectly good stand-in for how much horn a manufacturer fitted.
##
## Rendered as a loop, because a horn lasts exactly as long as somebody is
## leaning on it.
static func bake_horn(mass_kg: float, year: int,
		rng: RandomNumberGenerator) -> AudioStreamWAV:
	# 500 kg gets about 500 Hz, two and a half tonnes about 300. Modern cars
	# are a little higher and cleaner than period ones.
	var low_hz := clampf(620.0 - mass_kg * 0.13, 250.0, 560.0)
	if year >= 2000:
		low_hz *= 1.06
	# A minor third above, which is the interval most twin horns are tuned to.
	var high_hz := low_hz * 1.19

	# A whole number of cycles of the beat frequency, so the loop joins where
	# the two tones are back in the phase they started in.
	var beat_hz := high_hz - low_hz
	var duration := clampf(4.0 / maxf(beat_hz, 1.0), 0.08, 0.5)
	var samples := int(duration * AudioSynth.MIX_RATE)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)

	var low_phase := 0.0
	var high_phase := 0.0
	for i in samples:
		var value := 0.0
		# A horn is a diaphragm being driven hard: lots of harmonics, and the
		# odd ones dominate. Six of them is plenty to sound like brass rather
		# than a sine wave.
		for harmonic in range(1, 7):
			var weight := 1.0 / float(harmonic * harmonic)
			if harmonic % 2 == 1:
				weight *= 1.7
			value += sin(TAU * low_phase * float(harmonic)) * weight
			value += sin(TAU * high_phase * float(harmonic)) * weight * 0.85
		buffer[i] = value * 0.12
		low_phase += low_hz / AudioSynth.MIX_RATE
		high_phase += high_hz / AudioSynth.MIX_RATE

	# A touch of noise for the air being pushed, at a level you would never
	# pick out on its own.
	for i in samples:
		buffer[i] += rng.randf_range(-1.0, 1.0) * 0.012
	AudioSynth.normalise(buffer, 0.72)
	return AudioSynth.to_stream(buffer, true)


## A gearchange. A synchromesh box thunks; a dog box cracks. `shift_seconds` is
## how quick the change is, which is exactly what separates the two.
static func bake_gear_change(shift_seconds: float,
		rng: RandomNumberGenerator) -> AudioStreamWAV:
	var quickness := clampf(1.0 - shift_seconds / 0.5, 0.0, 1.0)
	var samples := AudioSynth.seconds_to_samples(0.10)
	var buffer := AudioSynth.noise(samples, rng)
	AudioSynth.resonate(buffer, lerpf(320.0, 900.0, quickness), 8.0, 0.7, false)
	AudioSynth.high_pass(buffer, 180.0, false)
	for i in samples:
		var t := float(i) / float(AudioSynth.MIX_RATE)
		buffer[i] *= exp(-t / lerpf(0.030, 0.008, quickness))
	AudioSynth.fade_edges(buffer, 0.002)
	AudioSynth.normalise(buffer, 0.30 + quickness * 0.35)
	return AudioSynth.to_stream(buffer, false)


# --- Mechanical failures ----------------------------------------------------

## A turbo letting go: a bang, then the whistle stops for good.
static func bake_turbo_failure(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.9)
	var buffer := AudioSynth.noise(samples, rng)
	AudioSynth.low_pass(buffer, 1800.0, false)
	for i in samples:
		var t := float(i) / float(AudioSynth.MIX_RATE)
		# A crack, then the sound of a compressor wheel destroying itself.
		var bang := exp(-t / 0.05)
		var grind := exp(-t / 0.5) * (0.4 + 0.6 * absf(sin(t * 190.0)))
		buffer[i] *= bang + grind * 0.5
	AudioSynth.fade_edges(buffer, 0.003)
	AudioSynth.normalise(buffer, 0.95)
	return AudioSynth.to_stream(buffer, false)


## An engine expiring. Not an explosion — a knock that turns into a bang and
## then nothing at all, which is far more alarming.
static func bake_engine_failure(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(1.4)
	var buffer := AudioSynth.silence(samples)
	var knock := AudioSynth.noise(samples, rng)
	AudioSynth.resonate(knock, 160.0, 7.0, 0.8, false)
	for i in samples:
		var t := float(i) / float(AudioSynth.MIX_RATE)
		# Knocking that accelerates, then one final bang, then silence.
		var rate := 18.0 + t * 40.0
		var knocking := maxf(sin(TAU * rate * t), 0.0)
		var envelope := exp(-t / 0.55)
		var final_bang := exp(-maxf(t - 0.5, 0.0) / 0.09) if t > 0.5 else 0.0
		buffer[i] = knock[i] * (knocking * envelope * 0.7 + final_bang * 0.9)
	AudioSynth.fade_edges(buffer, 0.004)
	AudioSynth.normalise(buffer, 0.9)
	return AudioSynth.to_stream(buffer, false)


## A tyre going down: a bang, then the flap of a carcass going round.
static func bake_puncture(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var samples := AudioSynth.seconds_to_samples(0.7)
	var buffer := AudioSynth.noise(samples, rng)
	AudioSynth.high_pass(buffer, 400.0, false)
	for i in samples:
		var t := float(i) / float(AudioSynth.MIX_RATE)
		buffer[i] *= exp(-t / 0.045) + exp(-t / 0.4) * 0.35
	AudioSynth.fade_edges(buffer, 0.003)
	AudioSynth.normalise(buffer, 0.85)
	return AudioSynth.to_stream(buffer, false)


# --- Shared -----------------------------------------------------------------

## Crossfades a buffer's tail into its head so it loops without a seam. Applied
## to everything that repeats, which is everything continuous.
static func _seamless(buffer: PackedFloat32Array) -> void:
	var blend := mini(AudioSynth.seconds_to_samples(0.02), buffer.size() / 4)
	if blend <= 1:
		return
	for i in blend:
		var t := float(i) / float(blend)
		var head := buffer[i]
		var tail := buffer[buffer.size() - blend + i]
		buffer[i] = lerpf(tail, head, t)
	# The tail is now redundant: it has been mixed into the head.
	for i in blend:
		var index := buffer.size() - blend + i
		buffer[index] = lerpf(buffer[index], buffer[i], float(i) / float(blend))
