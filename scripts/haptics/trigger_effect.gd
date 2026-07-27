class_name TriggerEffect
extends RefCounted
## One adaptive-trigger setting, in the DualSense's own vocabulary.
##
## The hardware exposes a small number of effect modes rather than arbitrary
## force curves, so the game speaks in those modes and the backend translates
## them into HID output reports. Keeping the vocabulary honest here means the
## feel design does not quietly assume capabilities the pad does not have.

enum Mode {
	OFF,        ## free travel, no resistance
	FEEDBACK,   ## constant resistance from a start position onward
	WEAPON,     ## resistance across a band, then it gives way
	VIBRATION,  ## resistance that pulses at a set frequency
}

var mode: Mode = Mode.OFF
## Where in the travel the effect begins, 0 released .. 1 fully pressed.
var start: float = 0.0
## Where a WEAPON effect gives way.
var end: float = 1.0
## How hard it pushes back, 0..1.
var strength: float = 0.0
## VIBRATION only, in Hz. The hardware works in whole hertz up to ~40.
var frequency: float = 0.0


static func off() -> TriggerEffect:
	return TriggerEffect.new()


static func feedback(p_start: float, p_strength: float) -> TriggerEffect:
	var e := TriggerEffect.new()
	e.mode = Mode.FEEDBACK
	e.start = clampf(p_start, 0.0, 1.0)
	e.strength = clampf(p_strength, 0.0, 1.0)
	return e


static func weapon(p_start: float, p_end: float, p_strength: float) -> TriggerEffect:
	var e := TriggerEffect.new()
	e.mode = Mode.WEAPON
	e.start = clampf(p_start, 0.0, 1.0)
	e.end = clampf(p_end, e.start + 0.05, 1.0)
	e.strength = clampf(p_strength, 0.0, 1.0)
	return e


static func vibration(p_start: float, p_strength: float, p_frequency: float) -> TriggerEffect:
	var e := TriggerEffect.new()
	e.mode = Mode.VIBRATION
	e.start = clampf(p_start, 0.0, 1.0)
	e.strength = clampf(p_strength, 0.0, 1.0)
	e.frequency = clampf(p_frequency, 1.0, 40.0)
	return e


## Whether two effects differ enough to be worth re-sending. Adaptive triggers
## are set over HID, and pushing a report every frame floods the pad and adds
## latency to the very thing it is meant to make responsive.
func differs_from(other: TriggerEffect, tolerance: float = 0.06) -> bool:
	if other == null:
		return true
	if mode != other.mode:
		return true
	if absf(strength - other.strength) > tolerance:
		return true
	if absf(start - other.start) > tolerance:
		return true
	if mode == Mode.WEAPON and absf(end - other.end) > tolerance:
		return true
	if mode == Mode.VIBRATION and absf(frequency - other.frequency) > 1.5:
		return true
	return false


func duplicate_effect() -> TriggerEffect:
	var e := TriggerEffect.new()
	e.mode = mode
	e.start = start
	e.end = end
	e.strength = strength
	e.frequency = frequency
	return e


func describe() -> String:
	match mode:
		Mode.OFF: return "off"
		Mode.FEEDBACK: return "feedback from %.2f at %.2f" % [start, strength]
		Mode.WEAPON: return "weapon %.2f-%.2f at %.2f" % [start, end, strength]
		Mode.VIBRATION: return "vibration from %.2f at %.2f, %.0f Hz" % [start, strength, frequency]
	return "?"
