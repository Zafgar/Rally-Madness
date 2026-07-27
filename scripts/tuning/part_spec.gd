class_name PartSpec
extends RefCounted
## A single fitted component. Parts are pure data: a slot, a price, and a set
## of modifiers against VehicleStats. No part has bespoke code, which is what
## makes it cheap to add hundreds of them.
##
## Trade-offs are expressed by giving a part both an upside and a downside — a
## big turbo raises boost and lag together, sticky tires raise grip and wear.

## Every slot accepts exactly one part. Order here is the order shown in the
## garage UI.
const SLOTS := [
	"engine", "intake", "exhaust", "turbo", "ecu", "cooling",
	"gearbox", "clutch", "differential",
	"suspension", "springs", "dampers", "antiroll", "brakes", "electronics",
	"tires", "wheels",
	"chassis", "weight", "aero", "armor", "nitro",
]

## Slots whose parts are consumed / worn and may need replacing after a race.
const CONSUMABLE_SLOTS := ["tires", "nitro"]

var id: String = ""
var display_name: String = ""
var slot: String = ""
var tier: int = 0
var price: int = 0
var description: String = ""
## Optional gate: only fits cars whose drivetrain is in this list. Empty = any.
var drivetrain_filter: Array[String] = []
## Optional gate: minimum car tier this part can be fitted to.
var min_car_tier: int = 0

## stat_key -> { "add": float, "mul": float }
var modifiers: Dictionary = {}


static func from_dict(d: Dictionary) -> PartSpec:
	var p := PartSpec.new()
	p.id = String(d.get("id", ""))
	p.display_name = String(d.get("name", p.id))
	p.slot = String(d.get("slot", ""))
	p.tier = int(d.get("tier", 0))
	p.price = int(d.get("price", 0))
	p.description = String(d.get("description", ""))
	p.min_car_tier = int(d.get("min_car_tier", 0))
	for dt in d.get("drivetrain_filter", []):
		p.drivetrain_filter.append(String(dt))

	for key in d.get("mods", {}):
		var stat := String(key)
		if not VehicleStats.STAT_KEYS.has(stat):
			push_error("PartSpec '%s' targets unknown stat '%s'" % [p.id, stat])
			continue
		var raw = d["mods"][key]
		# Bare numbers are the common case, so allow the shorthand:
		#   "grip_lat": 1.15      -> multiplier
		#   "mass_kg": {"add": -60} -> explicit
		if raw is Dictionary:
			p.modifiers[stat] = {
				"add": float(raw.get("add", 0.0)),
				"mul": float(raw.get("mul", 1.0)),
			}
		else:
			p.modifiers[stat] = {"add": 0.0, "mul": float(raw)}

	if not SLOTS.has(p.slot):
		push_error("PartSpec '%s' has unknown slot '%s'" % [p.id, p.slot])
	return p


func fits(stats: VehicleStats) -> bool:
	if stats.tier < min_car_tier:
		return false
	if drivetrain_filter.is_empty():
		return true
	var name_of: String = ["FWD", "RWD", "AWD"][stats.drivetrain]
	return drivetrain_filter.has(name_of)


## Human-readable effect list for the garage screen.
func summarize() -> Array[String]:
	var out: Array[String] = []
	for stat in modifiers:
		var m: Dictionary = modifiers[stat]
		var parts: Array[String] = []
		if not is_equal_approx(m["mul"], 1.0):
			parts.append("%+.0f%%" % ((m["mul"] - 1.0) * 100.0))
		if not is_zero_approx(m["add"]):
			parts.append("%+.2f" % m["add"])
		out.append("%s %s" % [stat, " ".join(parts)])
	return out
