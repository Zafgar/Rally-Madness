class_name EngineLayout
extends RefCounted
## What an engine is, mechanically, and therefore what it sounds like.
##
## An engine note is not a timbre somebody chose. It is a sequence of exhaust
## pulses, and everything distinctive about how an engine sounds comes from
## three facts: how many cylinders there are, how often each one fires, and
## whether they fire evenly.
##
##   A three-cylinder fires three times per two revolutions and sounds thin and
##   offbeat. A straight six fires six times and sounds smooth. A flat four has
##   unequal-length headers, so its pulses arrive slightly early and late, and
##   that timing error is the Subaru rumble — not a filter, an actual
##   irregularity. A crossplane V8 fires unevenly within each bank, which is
##   the burble. A five-cylinder is odd-numbered and therefore always slightly
##   lopsided, which is the Audi warble.
##
## So this class carries the mechanical facts, and the synthesiser turns them
## into pulses. Nothing here is a sound; it is a firing pattern.

## Where in one full engine cycle each cylinder fires, as a fraction 0..1, plus
## how loud that particular pulse is. Both come out of the layout.
enum Config {
	INLINE,   ## one bank, evenly spaced
	FLAT,     ## opposed banks, even on paper and not in practice
	VEE,      ## two banks at an angle, pulses arrive in pairs
	ROTARY,   ## no reciprocating cylinders at all
}

var cylinders: int = 4
var config: Config = Config.INLINE
## Two-strokes fire once per revolution rather than once every two, so they
## sound an octave up on a four-stroke of the same size and revs.
var two_stroke: bool = false
## Bank angle in degrees, for a vee. Decides how closely paired the pulses are.
var vee_angle: float = 90.0
## How far each pulse strays from its nominal position, as a fraction of the
## cycle. This one number is the difference between a flat four and an inline
## four, so it is worth having.
var timing_jitter: float = 0.0
## Crossplane cranks fire unevenly within a bank. Zero for a flatplane V8,
## which is why a Ferrari does not burble.
var crossplane: bool = false


static func from_dict(d: Dictionary) -> EngineLayout:
	var e := EngineLayout.new()
	e.cylinders = maxi(int(d.get("cylinders", 4)), 1)
	e.two_stroke = bool(d.get("two_stroke", false))
	e.vee_angle = float(d.get("vee_angle", 90.0))
	e.crossplane = bool(d.get("crossplane", false))
	match String(d.get("config", "inline")).to_lower():
		"flat", "boxer": e.config = Config.FLAT
		"vee", "v": e.config = Config.VEE
		"rotary", "wankel": e.config = Config.ROTARY
		_: e.config = Config.INLINE
	# A boxer's headers are unequal lengths on the cars people think of as
	# sounding like boxers, so the jitter is the default rather than an option.
	e.timing_jitter = float(d.get("timing_jitter",
		0.035 if e.config == Config.FLAT else 0.0))
	return e


## Firings per crankshaft revolution. A four-stroke fires each cylinder once
## every two revolutions; a two-stroke, every one.
func firings_per_rev() -> float:
	if config == Config.ROTARY:
		# A two-rotor Wankel gives two power pulses per eccentric shaft
		# revolution, which is why it sounds like a much smaller four-stroke.
		return float(cylinders)
	return float(cylinders) * (1.0 if two_stroke else 0.5)


## The frequency the exhaust actually pulses at, in hertz. This is the note.
func firing_hz(rpm: float) -> float:
	return maxf(rpm, 1.0) / 60.0 * firings_per_rev()


## Length of one complete engine cycle in crankshaft revolutions. Two for a
## four-stroke, because that is when the pattern repeats — and the pattern is
## what has to repeat for a loop to be seamless.
func cycle_revolutions() -> float:
	return 1.0 if (two_stroke or config == Config.ROTARY) else 2.0


func cycle_seconds(rpm: float) -> float:
	return cycle_revolutions() * 60.0 / maxf(rpm, 1.0)


## Where every cylinder fires within one cycle, and how strong each pulse is.
##
## Returned as [{"at": 0..1, "gain": float, "bank": int}]. `at` is the position
## in the cycle, which is what makes the rhythm; `bank` lets the synthesiser
## give the two sides of a vee slightly different exhaust resonances, which is
## most of why a V-engine sounds wider than an inline one.
func firing_events() -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var count := cylinders
	var rng := RandomNumberGenerator.new()
	# Seeded from the layout itself, so the same engine always has the same
	# character rather than a new one each time it is baked.
	rng.seed = hash([cylinders, int(config), two_stroke, vee_angle, crossplane])

	match config:
		Config.VEE:
			# Each bank fires evenly among its own cylinders; the second bank
			# is offset by the bank angle. That offset is what makes a 90-degree
			# V8 sound different from a 60-degree V6.
			var per_bank := maxi(count / 2, 1)
			var bank_offset := (vee_angle / 720.0) if not two_stroke else (vee_angle / 360.0)
			for bank in 2:
				for i in per_bank:
					var at := float(i) / float(per_bank)
					if bank == 1:
						at += bank_offset
					# A crossplane crank staggers alternate firings within the
					# bank. This is the burble, and it is a timing fact.
					if crossplane and i % 2 == 1:
						at += 0.5 / float(per_bank) * 0.5
					events.append({
						"at": fposmod(at, 1.0),
						"gain": 1.0,
						"bank": bank,
					})
		Config.ROTARY:
			for i in count:
				events.append({"at": float(i) / float(count), "gain": 1.0, "bank": 0})
		_:
			# Inline and flat: nominally even. What separates them is the
			# jitter, applied below.
			for i in count:
				events.append({"at": float(i) / float(count), "gain": 1.0,
					"bank": i % 2 if config == Config.FLAT else 0})

	if timing_jitter > 0.0:
		for e in events:
			e["at"] = fposmod(e["at"] + rng.randf_range(-timing_jitter, timing_jitter), 1.0)
			# Unequal headers change how much of each pulse arrives as well as
			# when, which is why the rumble has a beat to it.
			e["gain"] = 1.0 + rng.randf_range(-0.18, 0.18)

	events.sort_custom(func(a, b): return float(a["at"]) < float(b["at"]))
	return events


## A short human-readable name — "flat 4", "V10", "inline 3 two-stroke".
func display_name() -> String:
	var prefix := ""
	match config:
		Config.FLAT: prefix = "flat "
		Config.VEE: return "V%d%s" % [cylinders, " two-stroke" if two_stroke else ""]
		Config.ROTARY: return "%d-rotor" % cylinders
		_: prefix = "inline "
	return "%s%d%s" % [prefix, cylinders, " two-stroke" if two_stroke else ""]
