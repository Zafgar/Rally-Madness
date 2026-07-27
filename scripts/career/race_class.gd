class_name RaceClass
extends RefCounted
## A competition class: who may enter and in what.
##
## Events belong to a class rather than carrying their own limits, so a whole
## series can be re-balanced by editing one entry instead of a dozen.
##
## The three gates stop three different things, and all three are needed:
##
##   tier         which chassis are eligible at all
##   performance  a cap on resolved performance_index, which is what stops a
##                fully built starter car from walking a novice class — the
##                tier gate alone cannot see the parts bolted to it
##   rating       the driver's own band, so a veteran cannot farm beginner
##                events and a beginner is not fed to works drivers

const CLASSES_PATH := "res://data/classes.json"

var id: String = "open"
var display_name: String = "Open"
var short_name: String = "OPN"
var description: String = ""

var min_car_tier: int = 0
var max_car_tier: int = 99
var max_performance_index: float = 99999.0
var min_rating: int = 0
var max_rating: int = 9999
var purse_scale: float = 1.0
var colour: Color = Color(0.54, 0.56, 0.60)

static var _classes: Dictionary = {}
static var _ordered: Array[RaceClass] = []
static var _loaded: bool = false


static func load_all(path: String = CLASSES_PATH) -> Dictionary:
	if _loaded:
		return _classes
	_loaded = true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RaceClass: cannot open %s" % path)
		return _classes
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("RaceClass: %s is not a JSON object" % path)
		return _classes

	for entry in parsed.get("classes", []):
		var c := RaceClass.from_dict(entry)
		if c.id.is_empty():
			continue
		_classes[c.id] = c
		_ordered.append(c)
	return _classes


static func by_id(id: String) -> RaceClass:
	load_all()
	var found: RaceClass = _classes.get(id)
	if found == null:
		found = _classes.get("open")
	return found


static func all() -> Array[RaceClass]:
	load_all()
	return _ordered


static func clear_cache() -> void:
	_classes.clear()
	_ordered.clear()
	_loaded = false


static func from_dict(d: Dictionary) -> RaceClass:
	var c := RaceClass.new()
	c.id = String(d.get("id", ""))
	c.display_name = String(d.get("name", c.id))
	c.short_name = String(d.get("short", c.display_name.substr(0, 3)))
	c.description = String(d.get("description", ""))
	c.min_car_tier = int(d.get("min_car_tier", 0))
	c.max_car_tier = int(d.get("max_car_tier", 99))
	c.max_performance_index = float(d.get("max_performance_index", 99999.0))
	c.min_rating = int(d.get("min_rating", 0))
	c.max_rating = int(d.get("max_rating", 9999))
	c.purse_scale = float(d.get("purse_scale", 1.0))
	c.colour = Color.from_string(String(d.get("colour", "#8a8f99")), Color(0.54, 0.56, 0.60))
	return c


## Why a driver may not enter, or an empty string if they may.
##
## Only the lower bound is enforced. The upper bound is a matchmaking figure,
## not an entry rule: locking a rated driver out of the cheap classes strands
## anyone whose rating climbs faster than their bank balance, which is most
## people, and re-entering an event you have already won pays so little that
## farming the bottom of the ladder is not worth doing anyway.
func driver_rejection_reason(profile: PlayerProfile) -> String:
	if profile.rating < min_rating:
		return "Needs a driver rating of %d (you are %d)" % [min_rating, profile.rating]
	return ""


## Whether this driver is rated above the class. Online lobbies use it to keep
## a veteran out of a beginners' room; the career screen uses it to say an
## event has nothing left to teach you.
func outclasses(profile: PlayerProfile) -> bool:
	return profile.rating > max_rating


## Why a car may not enter, or an empty string if it may. The performance cap
## is checked against the car as it is actually built, not as it left the
## factory.
func car_rejection_reason(car: OwnedCar) -> String:
	var spec := car.spec()
	if spec == null:
		return "Unknown car"
	if spec.tier < min_car_tier:
		return "Needs a tier %d car or better" % min_car_tier
	if spec.tier > max_car_tier:
		return "Above the tier %d limit for this class" % max_car_tier
	var index := car.resolved_stats().performance_index()
	if index > max_performance_index:
		return "Too quick for this class (%d, limit %d)" % [
			int(index), int(max_performance_index)]
	return ""


## How much of the class's performance allowance a car is using, 0..1+. The
## garage shows this so a player can see how much they can still add before
## being pushed up a class.
func headroom_used(car: OwnedCar) -> float:
	if max_performance_index >= 99999.0:
		return 0.0
	return car.resolved_stats().performance_index() / max_performance_index


## The class a car most naturally belongs to: the lowest one that will still
## have it. Used by the showroom and the garage to say where a car can race.
static func best_fit(car: OwnedCar) -> RaceClass:
	for c in all():
		if c.id == "open":
			continue
		if c.car_rejection_reason(car).is_empty():
			return c
	return by_id("open")


## The same question for a car nobody owns yet, at a given performance index.
## The showroom asks it twice per car — once showroom-standard, once fully
## built — because those are often two different classes and that difference is
## the reason to buy.
static func best_fit_spec(spec: CarSpec, index: float = -1.0) -> RaceClass:
	if index < 0.0:
		index = spec.stock_index()
	for c in all():
		if c.id == "open":
			continue
		if spec.tier < c.min_car_tier or spec.tier > c.max_car_tier:
			continue
		if index <= c.max_performance_index:
			return c
	return by_id("open")
