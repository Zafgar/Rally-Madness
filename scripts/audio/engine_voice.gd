class_name EngineVoice
extends RefCounted
## Bakes one car's engine into a handful of loops.
##
## The alternative — synthesising every car's audio sample by sample every
## frame — is correct and far too slow: twelve cars at 22 kHz is a quarter of a
## million samples a second through GDScript. So each engine is baked once when
## the car is built, into short seamless loops, and played back pitch-scaled.
## The timbre is still that car's own, because the loops were made from that
## car's own numbers; only the note moves.
##
## Six loops per engine: three rev bands, each on and off the throttle.
##
##   Rev bands, because pitch-shifting a loop shifts its resonances too. Over a
##   7:1 rev range that turns an idle into a wasp; over the 2:1 each band
##   actually covers, it is what a real engine does anyway.
##
##   On and off throttle, because an engine under load and an engine trailing
##   are different sounds, not the same sound quieter. Crossfading between them
##   is what makes the car respond audibly to the pedal.

## One cycle is too short to loop convincingly at low revs — the ear hears the
## repeat. Bake this many consecutive cycles so the pulse-to-pulse variation has
## room to breathe.
const CYCLES_PER_LOOP := 4

## Where the three bands sit, as a fraction of the way from idle to the redline.
const BAND_POSITIONS := [0.06, 0.42, 0.88]

## What each band was baked at, in rpm. Playback divides by these.
var band_rpm: Array[float] = []
## band index -> AudioStreamWAV, on the throttle and off it.
var on_load: Array[AudioStreamWAV] = []
var off_load: Array[AudioStreamWAV] = []

var layout: EngineLayout
var idle_rpm: float = 900.0
var redline_rpm: float = 7000.0


## Bakes every loop for one car. Called once, when the car is configured.
##
## `exhaust_tier` and `intake_tier` are the fitted parts' tiers: a straight
## through system is louder, harder and brighter than the standard one, which
## is the whole reason a player fits it.
static func bake(
	stats: VehicleStats,
	p_layout: EngineLayout,
	exhaust_tier: int = 0,
	intake_tier: int = 0
) -> EngineVoice:
	var voice := EngineVoice.new()
	voice.layout = p_layout
	voice.idle_rpm = maxf(stats.idle_rpm, 400.0)
	voice.redline_rpm = maxf(stats.redline_rpm, voice.idle_rpm * 2.0)

	var rng := RandomNumberGenerator.new()
	# Seeded from the car, so a Golf always sounds like that Golf.
	rng.seed = hash(stats.spec_id) if not stats.spec_id.is_empty() else 12345

	for position in BAND_POSITIONS:
		var rpm := lerpf(voice.idle_rpm, voice.redline_rpm, float(position))
		voice.band_rpm.append(rpm)
		voice.on_load.append(AudioSynth.to_stream(
			voice._bake_band(stats, rpm, true, exhaust_tier, intake_tier, rng), true))
		voice.off_load.append(AudioSynth.to_stream(
			voice._bake_band(stats, rpm, false, exhaust_tier, intake_tier, rng), true))
	return voice


## One loop: a few complete engine cycles of exhaust pulses.
func _bake_band(
	stats: VehicleStats,
	rpm: float,
	loaded: bool,
	exhaust_tier: int,
	intake_tier: int,
	rng: RandomNumberGenerator
) -> PackedFloat32Array:
	var cycle_seconds := layout.cycle_seconds(rpm)
	var cycle_samples := AudioSynth.seconds_to_samples(cycle_seconds)
	var total_samples := cycle_samples * CYCLES_PER_LOOP
	var buffer := AudioSynth.silence(total_samples)

	# --- What this engine's pulses sound like -------------------------------
	# A big lazy engine rings low; a small one that revs to eight thousand rings
	# high. Displacement is not in the data, so it comes from torque per
	# cylinder, which is the same thing wearing a different hat.
	var torque_per_cylinder := stats.engine_torque_nm / float(maxi(layout.cylinders, 1))
	var resonance := 118.0 * pow(clampf(60.0 / maxf(torque_per_cylinder, 8.0), 0.35, 2.6), 0.55)
	# A free-flowing exhaust rings higher and rougher.
	resonance *= 1.0 + float(exhaust_tier) * 0.09

	# How long each pulse rings for. Scaled to the firing interval so a fast
	# engine's pulses do not smear into each other.
	var interval := cycle_seconds / float(maxi(layout.cylinders, 1))
	var decay := interval * (0.62 if loaded else 0.40)

	# On the throttle an engine is rough and hard; off it, most of what is left
	# is mechanical noise and the tail of the last pulse.
	var roughness := clampf(0.30 + float(exhaust_tier) * 0.06
		+ (0.16 if loaded else -0.10), 0.05, 0.85)
	var bite := (0.22 + float(exhaust_tier) * 0.07) if loaded else 0.05
	# Two-strokes are all top end and no bottom: that hard flat buzz.
	if layout.two_stroke:
		resonance *= 1.45
		roughness = clampf(roughness + 0.18, 0.0, 0.9)

	var events := layout.firing_events()
	# Each bank of a vee gets its own slightly different pipe, which is most of
	# why a V-engine sounds wider than an inline one.
	var bank_detune := [1.0, 1.0 + (layout.vee_angle / 90.0) * 0.045]

	for cycle in CYCLES_PER_LOOP:
		for event in events:
			var bank := int(event["bank"])
			var pulse := AudioSynth.exhaust_pulse(
				resonance * float(bank_detune[bank % 2]),
				decay,
				roughness,
				bite,
				rng)
			var at := cycle_samples * cycle + int(float(event["at"]) * float(cycle_samples))
			# A real engine's pulses are never exactly identical, and a loop
			# whose cycles are identical sounds like a loop.
			var variation := 1.0 + rng.randf_range(-0.06, 0.06)
			AudioSynth.add_wrapped(buffer, pulse, at, float(event["gain"]) * variation)

	# --- Induction ----------------------------------------------------------
	# The other half of an engine note, and the half a player buys when they
	# fit an intake. Broadband, gated by load, brightened by the part.
	if loaded:
		var induction := AudioSynth.noise(total_samples, rng)
		AudioSynth.low_pass(induction, 1400.0 + float(intake_tier) * 700.0)
		AudioSynth.high_pass(induction, 240.0)
		# Pulled in time with the firings, or it sounds like wind rather than
		# an engine breathing.
		var firing_cycles := maxi(int(layout.firings_per_rev()
			* layout.cycle_revolutions()) * CYCLES_PER_LOOP, 1)
		var gate := AudioSynth.looped_sine(total_samples, firing_cycles, 0.0, 0.5)
		for i in induction.size():
			induction[i] *= 0.5 + gate[i]
		AudioSynth.scale(induction, 0.30 + float(intake_tier) * 0.05)
		for i in buffer.size():
			buffer[i] += induction[i]

	# --- Mechanical noise ---------------------------------------------------
	# Valvetrain and timing gear. Quiet, constant, and its absence is why a
	# purely pulse-based engine sounds synthetic.
	var mechanical := AudioSynth.noise(total_samples, rng)
	AudioSynth.high_pass(mechanical, 1800.0)
	AudioSynth.low_pass(mechanical, 5200.0)
	AudioSynth.scale(mechanical, 0.05 if loaded else 0.07)
	for i in buffer.size():
		buffer[i] += mechanical[i]

	# --- Finish -------------------------------------------------------------
	# The whole loop through one low pass: an exhaust is a long pipe and a long
	# pipe is a low-pass filter. Off the throttle it is duller still.
	AudioSynth.low_pass(buffer, (3800.0 if loaded else 2200.0)
		+ float(exhaust_tier) * 900.0)
	AudioSynth.remove_dc(buffer)
	AudioSynth.normalise(buffer, 0.88 if loaded else 0.55)
	return buffer


## Which two bands to blend at a given rpm, and how much of the upper one.
##
## Returns [lower index, upper index, 0..1 weight of the upper].
func band_blend(rpm: float) -> Array:
	if band_rpm.size() < 2:
		return [0, 0, 0.0]
	if rpm <= band_rpm[0]:
		return [0, 0, 0.0]
	for i in range(band_rpm.size() - 1):
		if rpm <= band_rpm[i + 1]:
			var span := maxf(band_rpm[i + 1] - band_rpm[i], 1.0)
			return [i, i + 1, clampf((rpm - band_rpm[i]) / span, 0.0, 1.0)]
	var last := band_rpm.size() - 1
	return [last, last, 0.0]


## How much to speed a band up or slow it down to land on the wanted rpm.
##
## Clamped, because a loop played at four times its baked rate is a mosquito and
## at a quarter is a tractor. With three bands the blend never needs to stretch
## far, and the clamp only catches the extremes below idle and past the limiter.
func pitch_for(band: int, rpm: float) -> float:
	if band < 0 or band >= band_rpm.size():
		return 1.0
	return clampf(rpm / maxf(band_rpm[band], 1.0), 0.35, 2.6)


## The note the exhaust is actually pulsing at, which is what a listener hears
## as the pitch of the engine.
func firing_hz(rpm: float) -> float:
	return layout.firing_hz(rpm)
