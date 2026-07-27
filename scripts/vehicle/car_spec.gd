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
## Slots this chassis specifically cannot take, whatever else it accepts.
var blocked_slots: Array[String] = []

## Highest part tier this chassis will accept.
##
## A Lada can be usefully improved — better tyres, a rebuild, a cage — but no
## amount of money turns it into a Group B car, and being able to bolt a
## sequential race gearbox and WRC dampers to one would make the whole
## progression pointless. Defaults to one tier above the car, so every chassis
## has real headroom without ever catching the tier above it.
var upgrade_ceiling: int = 1

## Published real-world figures, used to calibrate the model rather than to
## drive it. Power and top speed both fall out of the torque curve, the gearing
## and the drag area, so holding them against reality is how those numbers get
## checked. 0 means "not recorded".
var reference_power_hp: float = 0.0
var reference_top_speed_kmh: float = 0.0

## Parts fitted from new — how a rally-homologated model arrives already
## sitting on the right suspension.
var stock_parts: Dictionary = {}

## Offered as a choice when starting a new career. Not every bottom-tier car is:
## the starter tier is also the free-to-repair safety net, and a new player
## choosing between sixteen near-identical shopping cars is choosing between
## nothing. The flagged five drive genuinely differently.
var starter_choice: bool = false

## Lazily resolved and then kept: working these out means resolving the whole
## parts catalogue against the chassis, and the showroom asks for them per frame.
var _stock_index: float = -1.0
var _potential_index: float = -1.0


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
	for s in d.get("blocked_slots", []):
		c.blocked_slots.append(String(s))
	for slot in d.get("stock_parts", {}):
		c.stock_parts[String(slot)] = String(d["stock_parts"][slot])

	c.upgrade_ceiling = int(d.get("upgrade_ceiling", c.tier + 1))
	c.starter_choice = bool(d.get("starter_choice", false))
	c.reference_power_hp = float(d.get("power_hp", 0.0))
	c.reference_top_speed_kmh = float(d.get("top_speed_kmh", 0.0))
	return c


func accepts_slot(slot: String) -> bool:
	if blocked_slots.has(slot):
		return false
	if supported_slots.is_empty():
		return true
	return supported_slots.has(slot)


## Whether this chassis will take a given part at all. Tier is the main gate in
## both directions: a part can demand a good chassis, and a chassis can refuse
## a part that is simply beyond it.
func accepts_part(part: PartSpec) -> bool:
	if part == null:
		return false
	if not accepts_slot(part.slot):
		return false
	if part.tier > upgrade_ceiling:
		return false
	if tier < part.min_car_tier:
		return false
	return true


## Why a part will not fit, for the garage to show the player. Empty when it
## will.
func part_rejection_reason(part: PartSpec) -> String:
	if part == null:
		return "Unknown part"
	if blocked_slots.has(part.slot):
		return "This chassis has no %s to modify" % part.slot
	if not supported_slots.is_empty() and not supported_slots.has(part.slot):
		return "This chassis has no %s to modify" % part.slot
	if part.tier > upgrade_ceiling:
		return "Beyond what this chassis can take (accepts up to tier %d)" % upgrade_ceiling
	if tier < part.min_car_tier:
		return "Needs a tier %d chassis or better" % part.min_car_tier
	return ""


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


## The best parts this chassis will accept, in every slot. What the car becomes
## when someone with money is finished with it.
func best_loadout() -> TuningLoadout:
	var l := default_loadout()
	for slot in PartSpec.SLOTS:
		var best: PartSpec = null
		for part in PartDatabase.for_slot(slot):
			if not accepts_part(part):
				continue
			if best == null or part.price > best.price:
				best = part
		if best != null:
			l.set_part(slot, best.id)
	return l


## What this car is worth showroom-standard, and what it is worth fully built.
##
## The second number is the one that decides whether a car is worth buying, and
## it is not obvious from the first: a built hot hatch outscores a
## showroom-standard four-wheel-drive car, but the four-wheel-drive car will
## take parts the hatch's chassis refuses and ends up in a class above it. The
## showroom shows both, because "it is slower than my current car and you should
## buy it anyway" needs an explanation.
func stock_index() -> float:
	if _stock_index < 0.0:
		_stock_index = TuningCalculator.resolve(self, default_loadout()).performance_index()
	return _stock_index


func potential_index() -> float:
	if _potential_index < 0.0:
		_potential_index = TuningCalculator.resolve(self, best_loadout()).performance_index()
	return _potential_index


## What it costs to take this car from the showroom to its ceiling — the second
## half of the price, and usually the larger half.
func full_build_cost() -> int:
	var total := 0
	var stock := default_loadout()
	var best := best_loadout()
	for slot in PartSpec.SLOTS:
		var fitted := best.get_part(slot)
		if fitted.is_empty() or fitted == stock.get_part(slot):
			continue
		var part := PartDatabase.get_part(fitted)
		if part != null:
			total += part.price
	return total
