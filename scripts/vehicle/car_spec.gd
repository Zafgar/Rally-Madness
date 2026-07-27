class_name CarSpec
extends RefCounted
## Factory-stock definition of one car, straight from the data table. Kept
## separate from VehicleStats so the showroom can describe a car without
## resolving anybody's tuning, and so a modified car can always be reverted.

var id: String = ""
var manufacturer: String = ""
var model: String = ""
var year: int = 1990
var tier: int = 0
var price: int = 5000
var drivetrain: VehicleStats.Drivetrain = VehicleStats.Drivetrain.RWD
var category: String = "road"   # road / rally / offroad / classic / hyper
var description: String = ""

## Raw stat values as delivered from the factory. Keys are VehicleStats.STAT_KEYS.
var base_stats: Dictionary = {}
var gear_ratios: PackedFloat32Array = PackedFloat32Array()
var reverse_ratio: float = 3.2

## Slots this chassis can accept. Empty means "all of them".
var supported_slots: Array[String] = []

## Parts fitted from new — how a rally-homologated model arrives already
## sitting on the right suspension.
var stock_parts: Dictionary = {}


func display_name() -> String:
	if manufacturer.is_empty():
		return model
	return "%s %s" % [manufacturer, model]


func full_name() -> String:
	return "%s (%d)" % [display_name(), year]


static func from_dict(d: Dictionary) -> CarSpec:
	var c := CarSpec.new()
	c.id = String(d.get("id", ""))
	c.manufacturer = String(d.get("manufacturer", ""))
	c.model = String(d.get("model", c.id))
	c.year = int(d.get("year", 1990))
	c.tier = int(d.get("tier", 0))
	c.price = int(d.get("price", 5000))
	c.category = String(d.get("category", "road"))
	c.description = String(d.get("description", ""))

	match String(d.get("drivetrain", "RWD")).to_upper():
		"FWD": c.drivetrain = VehicleStats.Drivetrain.FWD
		"AWD", "4WD": c.drivetrain = VehicleStats.Drivetrain.AWD
		_: c.drivetrain = VehicleStats.Drivetrain.RWD

	for key in d.get("stats", {}):
		var stat := String(key)
		if not VehicleStats.STAT_KEYS.has(stat):
			push_error("CarSpec '%s' sets unknown stat '%s'" % [c.id, stat])
			continue
		c.base_stats[stat] = float(d["stats"][key])

	var ratios: Array = d.get("gears", [])
	if ratios.is_empty():
		c.gear_ratios = PackedFloat32Array([3.45, 2.05, 1.42, 1.08, 0.86, 0.72])
	else:
		var packed := PackedFloat32Array()
		for r in ratios:
			packed.append(float(r))
		c.gear_ratios = packed
	c.reverse_ratio = float(d.get("reverse", 3.2))

	for s in d.get("slots", []):
		c.supported_slots.append(String(s))
	for slot in d.get("stock_parts", {}):
		c.stock_parts[String(slot)] = String(d["stock_parts"][slot])
	return c


func accepts_slot(slot: String) -> bool:
	if supported_slots.is_empty():
		return true
	return supported_slots.has(slot)


## Fresh, untuned stats for this car.
func to_base_stats() -> VehicleStats:
	var s := VehicleStats.new()
	s.spec_id = id
	s.display_name = display_name()
	s.tier = tier
	s.drivetrain = drivetrain
	for key in base_stats:
		s.set(key, base_stats[key])
	if gear_ratios.size() > 0:
		s.gear_ratios = gear_ratios.duplicate()
	s.reverse_ratio = reverse_ratio
	return s


## A loadout containing whatever this model ships with.
func default_loadout() -> TuningLoadout:
	var l := TuningLoadout.new()
	for slot in stock_parts:
		l.set_part(slot, stock_parts[slot])
	return l
