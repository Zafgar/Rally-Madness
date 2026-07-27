extends Node
## Loads the car catalogue from JSON.
##
## Cars are plain data rather than .tres resources deliberately: the design
## calls for hundreds of them, and a JSON table stays diffable, mergeable and
## editable without opening the editor.

const CARS_PATH := "res://data/cars.json"

var _cars: Dictionary = {}          # id -> CarSpec
var _by_tier: Dictionary = {}       # tier -> Array[CarSpec]
var _ordered: Array[CarSpec] = []


func _ready() -> void:
	load_catalogue()


func load_catalogue(path: String = CARS_PATH) -> void:
	_cars.clear()
	_by_tier.clear()
	_ordered.clear()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CarDatabase: cannot open %s" % path)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("CarDatabase: %s is not a JSON object" % path)
		return

	for entry in parsed.get("cars", []):
		var spec := CarSpec.from_dict(entry)
		if spec.id.is_empty():
			push_error("CarDatabase: entry with no id, skipped")
			continue
		if _cars.has(spec.id):
			push_error("CarDatabase: duplicate car id '%s'" % spec.id)
			continue
		_cars[spec.id] = spec
		_ordered.append(spec)
		if not _by_tier.has(spec.tier):
			_by_tier[spec.tier] = []
		_by_tier[spec.tier].append(spec)

	_ordered.sort_custom(func(a, b):
		if a.tier != b.tier:
			return a.tier < b.tier
		return a.price < b.price)
	print("CarDatabase: loaded %d cars" % _cars.size())


func get_car(id: String) -> CarSpec:
	return _cars.get(id)


func has_car(id: String) -> bool:
	return _cars.has(id)


func all() -> Array[CarSpec]:
	return _ordered


func by_tier(tier: int) -> Array:
	return _by_tier.get(tier, [])


## Everything a player can afford right now, for the showroom's default filter.
func affordable(money: int, max_tier: int = 99) -> Array[CarSpec]:
	var out: Array[CarSpec] = []
	for spec in _ordered:
		if spec.price <= money and spec.tier <= max_tier:
			out.append(spec)
	return out


func by_category(category: String) -> Array[CarSpec]:
	var out: Array[CarSpec] = []
	for spec in _ordered:
		if spec.category == category:
			out.append(spec)
	return out


func by_drivetrain(dt: VehicleStats.Drivetrain) -> Array[CarSpec]:
	var out: Array[CarSpec] = []
	for spec in _ordered:
		if spec.drivetrain == dt:
			out.append(spec)
	return out


## The free-to-repair fallback fleet. A player who has crashed their way to
## zero always has one of these to fall back on.
func starter_cars() -> Array:
	return by_tier(GameConfig.STARTER_TIER)


## The cars offered when starting a new career: a short, deliberately varied
## subset of the fallback fleet. Falls back to the whole tier if the data has
## flagged none, so a new career is never left with nothing to choose from.
func starter_choices() -> Array:
	var out: Array = []
	for spec in starter_cars():
		if spec.starter_choice:
			out.append(spec)
	return out if not out.is_empty() else starter_cars()


func default_starter() -> CarSpec:
	var starters := starter_choices()
	if starters.is_empty():
		push_error("CarDatabase: no starter-tier cars defined")
		return null
	return starters[0]
