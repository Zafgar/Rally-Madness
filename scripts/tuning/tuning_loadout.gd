class_name TuningLoadout
extends RefCounted
## What is actually bolted to one owned car: a part id per slot, plus the
## continuous adjustments that need no purchase (ride height, diff preload,
## gearing). Serialises straight into the player's save file.

## slot -> part id
var parts: Dictionary = {}

## Free adjustments, all normalised -1..1 around the car's stock setting. These
## are the "setup sheet" a player fiddles with between stages, distinct from
## parts they have to buy.
var setup: Dictionary = {
	"brake_bias": 0.0,       # front <-> rear
	"diff_preload": 0.0,     # open <-> locked
	"ride_height": 0.0,      # low/grip <-> high/travel
	"antiroll_balance": 0.0, # oversteer <-> understeer
	"gear_length": 0.0,      # short/accel <-> long/top speed
	"awd_split": 0.0,        # front-biased <-> rear-biased (AWD only)
	"boost_pressure": 0.0,   # safe <-> power (raises engine wear)
	"rev_limit": 0.0,        # standard <-> raised (more power, more risk)
}

## Cosmetic only, but saved alongside so a car keeps its identity.
var livery_id: String = "default"
var paint_color: Color = Color(0.85, 0.2, 0.15)


func set_part(slot: String, part_id: String) -> void:
	if part_id.is_empty():
		parts.erase(slot)
	else:
		parts[slot] = part_id


func get_part(slot: String) -> String:
	return String(parts.get(slot, ""))


func clear_slot(slot: String) -> void:
	parts.erase(slot)


func total_value() -> int:
	var sum := 0
	for slot in parts:
		var p := PartDatabase.get_part(parts[slot])
		if p != null:
			sum += p.price
	return sum


func to_dict() -> Dictionary:
	return {
		"parts": parts.duplicate(),
		"setup": setup.duplicate(),
		"livery_id": livery_id,
		"paint_color": paint_color.to_html(false),
	}


static func from_dict(d: Dictionary) -> TuningLoadout:
	var l := TuningLoadout.new()
	l.parts = (d.get("parts", {}) as Dictionary).duplicate()
	var saved_setup: Dictionary = d.get("setup", {})
	for key in l.setup:
		if saved_setup.has(key):
			l.setup[key] = float(saved_setup[key])
	l.livery_id = String(d.get("livery_id", "default"))
	if d.has("paint_color"):
		l.paint_color = Color.from_string(String(d["paint_color"]), Color(0.85, 0.2, 0.15))
	return l


func clone() -> TuningLoadout:
	return TuningLoadout.from_dict(to_dict())
