class_name DriverProfile
extends RefCounted
## What kind of driver an AI opponent is.
##
## A single "skill" number makes every rival the same driver turned up or down.
## Real fields are not like that: one is quick but wild, another is slow and
## utterly reliable, a third has the fastest car in the race and no idea what
## to do with it. Splitting skill into traits that pull in different directions
## is what makes a field feel like people rather than difficulty settings.
##
## The traits are deliberately independent. A driver can be committed and
## inconsistent (fast, crashes), or cautious and precise (slow, always
## finishes), and both are interesting to race against for different reasons.

## Fraction of the car's actual grip the driver is willing to use. This is the
## difference between a quick driver and a slow one in the same machinery.
var commitment: float = 0.6
## A hard ceiling on pace regardless of the car. A nervous driver handed a
## Group B car does not suddenly drive like a works driver — they drive the
## same speed they always did, in a more frightening car. This is what stops
## the field's pace being decided purely by what they turned up in.
var pace_ceiling: float = 1.0
## How repeatable they are. Low consistency means their commitment wanders
## corner to corner, so they are sometimes fast and sometimes not.
var consistency: float = 0.7
## How well they position the car. Low values hold a lazy, roughly fixed line
## instead of using the road, which costs time everywhere and occasionally
## costs the car.
var line_quality: float = 0.6
## How late and how accurately they brake. Low values brake far too early and
## coast into corners.
var braking_skill: float = 0.6
## How well they get back on power. Low values either bog down or light the
## tyres up and go nowhere.
var throttle_discipline: float = 0.6
## How well they catch the car when it steps out.
var recovery: float = 0.6
## Risk appetite: nitro use, corner entry speed, willingness to keep their foot
## in when it is going wrong.
var aggression: float = 0.5
## Whether they look after the car. Low values keep driving flat out on a bent
## car and cut kerbs that break it.
var mechanical_sympathy: float = 0.6
## How much attention they pay to the cars around them. Low values refresh
## their picture of the field only a few times a second, so they act on stale
## information and get caught out by a car braking hard in front of them —
## which is also why they compensate by leaving much bigger gaps.
var awareness: float = 0.6
## Whether they shift for themselves and use the rev range properly.
var uses_manual_gearbox: bool = false

var display_name: String = "Driver"
var archetype: String = "privateer"


## Overall pace, for seeding the grid and for reporting. Weighted towards the
## traits that actually decide lap time.
func pace_rating() -> float:
	return clampf(
		commitment * 0.35
		+ line_quality * 0.25
		+ braking_skill * 0.20
		+ throttle_discipline * 0.12
		+ consistency * 0.08,
		0.0, 1.0) * pace_ceiling


static func from_dict(d: Dictionary) -> DriverProfile:
	var p := DriverProfile.new()
	p.archetype = String(d.get("id", "privateer"))
	p.display_name = String(d.get("name", p.archetype))
	p.commitment = float(d.get("commitment", 0.6))
	p.pace_ceiling = float(d.get("pace_ceiling", 1.0))
	p.consistency = float(d.get("consistency", 0.7))
	p.line_quality = float(d.get("line_quality", 0.6))
	p.braking_skill = float(d.get("braking_skill", 0.6))
	p.throttle_discipline = float(d.get("throttle_discipline", 0.6))
	p.recovery = float(d.get("recovery", 0.6))
	p.aggression = float(d.get("aggression", 0.5))
	p.mechanical_sympathy = float(d.get("mechanical_sympathy", 0.6))
	p.awareness = float(d.get("awareness", 0.6))
	p.uses_manual_gearbox = bool(d.get("manual_gearbox", false))
	return p


## Fallback when no archetype data is available: spreads a single skill number
## across the traits so the old behaviour still works.
static func from_skill(skill: float) -> DriverProfile:
	var p := DriverProfile.new()
	skill = clampf(skill, 0.0, 1.0)
	p.commitment = lerpf(0.35, 0.95, skill)
	p.consistency = lerpf(0.45, 0.95, skill)
	p.line_quality = lerpf(0.3, 0.95, skill)
	p.braking_skill = lerpf(0.3, 0.95, skill)
	p.throttle_discipline = lerpf(0.3, 0.95, skill)
	p.recovery = lerpf(0.25, 0.95, skill)
	p.aggression = lerpf(0.3, 0.8, skill)
	p.mechanical_sympathy = lerpf(0.4, 0.85, skill)
	p.awareness = lerpf(0.25, 0.95, skill)
	p.uses_manual_gearbox = skill > 0.6
	return p


## A copy with every trait nudged, so two drivers of the same archetype are not
## literally identical. Kept small: an archetype should still read as itself.
func varied(rng: RandomNumberGenerator, amount: float = 0.08) -> DriverProfile:
	var p := DriverProfile.new()
	p.archetype = archetype
	p.display_name = display_name
	p.uses_manual_gearbox = uses_manual_gearbox
	p.pace_ceiling = clampf(pace_ceiling + rng.randf_range(-amount, amount), 0.2, 1.2)
	for trait_name in ["commitment", "consistency", "line_quality", "braking_skill",
			"throttle_discipline", "recovery", "aggression", "mechanical_sympathy",
			"awareness"]:
		p.set(trait_name, clampf(
			float(get(trait_name)) + rng.randf_range(-amount, amount), 0.05, 1.0))
	return p


const DRIVERS_PATH := "res://data/drivers.json"

## Cached archetype pool: [{ profile, weight, skill_min, skill_max }]
static var _pool: Array[Dictionary] = []
static var _pool_loaded: bool = false


static func load_pool(path: String = DRIVERS_PATH) -> Array[Dictionary]:
	if _pool_loaded:
		return _pool
	_pool_loaded = true
	_pool.clear()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("DriverProfile: no archetypes at %s, falling back to plain skill" % path)
		return _pool
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("DriverProfile: %s is not a JSON object" % path)
		return _pool

	for entry in parsed.get("drivers", []):
		var range_values: Array = entry.get("skill_range", [0.0, 1.0])
		_pool.append({
			"profile": DriverProfile.from_dict(entry),
			"weight": float(entry.get("weight", 1.0)),
			"skill_min": float(range_values[0]) if range_values.size() > 0 else 0.0,
			"skill_max": float(range_values[1]) if range_values.size() > 1 else 1.0,
		})
	return _pool


## Picks an archetype suited to an event's difficulty.
##
## Selection is weighted toward the archetypes whose band contains the event's
## skill level, but never exclusively: a slow driver turning up to a fast event
## is part of what makes a field look real, and a quick one at a club meeting
## gives the player something to chase.
static func pick_for(event_skill: float, rng: RandomNumberGenerator) -> DriverProfile:
	var pool := load_pool()
	if pool.is_empty():
		return DriverProfile.from_skill(event_skill)

	var weights: Array[float] = []
	var total := 0.0
	for entry in pool:
		var band_min: float = entry["skill_min"]
		var band_max: float = entry["skill_max"]
		var in_band := event_skill >= band_min and event_skill <= band_max
		# Out-of-band archetypes stay possible but rare.
		var weight: float = float(entry["weight"]) * (1.0 if in_band else 0.12)
		weights.append(weight)
		total += weight

	var roll := rng.randf() * total
	for i in pool.size():
		roll -= weights[i]
		if roll <= 0.0:
			return (pool[i]["profile"] as DriverProfile).varied(rng)
	return (pool[pool.size() - 1]["profile"] as DriverProfile).varied(rng)


static func clear_cache() -> void:
	_pool.clear()
	_pool_loaded = false


func describe() -> String:
	return "%s (commit %.2f, line %.2f, brake %.2f, consistency %.2f, aggression %.2f)" % [
		display_name, commitment, line_quality, braking_skill, consistency, aggression]
