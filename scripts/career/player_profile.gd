class_name PlayerProfile
extends RefCounted
## One player's career: money, level, garage, unlocked events and online
## rating. Each seat in a split-screen session loads its own profile from this
## machine, so four people on one couch keep four separate careers.

## XP needed to reach each level, cumulative index = level.
const XP_CURVE_BASE := 800.0
const XP_CURVE_EXPONENT := 1.35

## Starting rating for online matchmaking. Standard Elo-style scale.
const DEFAULT_RATING := 1200

var profile_id: String = ""
var display_name: String = "Driver"
## Index into DriverAvatar.PRESETS. Profile pictures are drawn rather than
## loaded, so this is all that needs saving.
var avatar_id: int = 0
var created_unix: int = 0
var last_played_unix: int = 0

var money: int = 12000
var level: int = 1
var xp: int = 0
var rating: int = DEFAULT_RATING
var rating_races: int = 0

## uid -> OwnedCar
var garage: Dictionary = {}
var active_car_uid: String = ""

var unlocked_events: Array[String] = []
var completed_events: Array[String] = []
## event_id -> best time in seconds
var best_times: Dictionary = {}

## sponsor_id -> { "races_remaining": int, "per_race": int, "bonus_win": int }
var sponsors: Dictionary = {}

var stat_races: int = 0
var stat_wins: int = 0
var stat_wrecks: int = 0
var stat_distance_km: float = 0.0

var _next_uid: int = 1


## A brand new career.
##
## The starter car is a choice, not an assignment: the five tier-0 cars drive
## very differently — rear-engined, front-drive, light and revvy — and picking
## one is the player's first real decision. Passing null falls back to the
## first starter, which keeps quick-start and headless paths simple.
static func create_new(
	id: String,
	name: String,
	starter: CarSpec = null,
	p_avatar_id: int = 0
) -> PlayerProfile:
	var p := PlayerProfile.new()
	p.profile_id = id
	p.display_name = name
	p.avatar_id = p_avatar_id
	p.created_unix = int(Time.get_unix_time_from_system())
	p.last_played_unix = p.created_unix
	# The first car is free, so the first race needs no purchase and there is
	# always something to fall back on later.
	if starter == null:
		starter = CarDatabase.default_starter()
	if starter != null:
		var car := p.add_car(starter)
		p.active_car_uid = car.uid
	return p


# --- Garage -----------------------------------------------------------------

func add_car(spec: CarSpec) -> OwnedCar:
	var uid := "%s_%d" % [spec.id, _next_uid]
	_next_uid += 1
	var car := OwnedCar.create(spec, uid)
	garage[uid] = car
	return car


func remove_car(uid: String) -> void:
	garage.erase(uid)
	if active_car_uid == uid:
		active_car_uid = ""
		var fallback := first_driveable_car()
		if fallback != null:
			active_car_uid = fallback.uid


func get_car(uid: String) -> OwnedCar:
	return garage.get(uid)


func active_car() -> OwnedCar:
	var car: OwnedCar = garage.get(active_car_uid)
	if car != null:
		return car
	return first_driveable_car()


func first_driveable_car() -> OwnedCar:
	for uid in garage:
		var car: OwnedCar = garage[uid]
		if car.is_driveable():
			return car
	return null


func owns_model(spec_id: String) -> bool:
	for uid in garage:
		if garage[uid].spec_id == spec_id:
			return true
	return false


## The safety net. If every car in the garage is broken and the player cannot
## pay to fix any of them, hand them a free starter so they can keep earning.
func ensure_driveable_car() -> OwnedCar:
	var car := first_driveable_car()
	if car != null:
		return car

	# Anything repairable for free gets repaired.
	for uid in garage:
		var owned: OwnedCar = garage[uid]
		if owned.repair_cost() <= 0:
			owned.repair()
			active_car_uid = uid
			return owned

	# Anything the player can actually afford to fix.
	for uid in garage:
		var owned: OwnedCar = garage[uid]
		var cost := owned.repair_cost()
		if cost <= money:
			money -= cost
			owned.repair()
			active_car_uid = uid
			return owned

	# Nothing left: issue a fresh starter car, free.
	var starter := CarDatabase.default_starter()
	if starter == null:
		return null
	var new_car := add_car(starter)
	active_car_uid = new_car.uid
	return new_car


# --- Economy ----------------------------------------------------------------

func can_afford(amount: int) -> bool:
	return money >= amount


func spend(amount: int) -> bool:
	if amount > money:
		return false
	money -= amount
	return true


func earn(amount: int) -> void:
	money += amount


func buy_car(spec: CarSpec) -> OwnedCar:
	if not spend(spec.price):
		return null
	return add_car(spec)


func sell_car(uid: String) -> int:
	var car: OwnedCar = garage.get(uid)
	if car == null:
		return 0
	# Never let a player sell their way into having nothing to drive.
	if garage.size() <= 1:
		return 0
	var value := car.sale_value()
	earn(value)
	remove_car(uid)
	return value


func buy_part(car_uid: String, slot: String, part_id: String) -> bool:
	var car: OwnedCar = garage.get(car_uid)
	if car == null:
		return false
	var part := PartDatabase.get_part(part_id)
	if part == null:
		return false
	if not spend(part.price):
		return false
	car.loadout.set_part(slot, part_id)
	return true


# --- Progression ------------------------------------------------------------

func xp_for_level(target_level: int) -> int:
	if target_level <= 1:
		return 0
	return int(XP_CURVE_BASE * pow(float(target_level - 1), XP_CURVE_EXPONENT))


func xp_to_next_level() -> int:
	return xp_for_level(level + 1) - xp


## Returns how many levels were gained.
func award_xp(amount: int) -> int:
	xp += amount
	var gained := 0
	while xp >= xp_for_level(level + 1):
		level += 1
		gained += 1
	return gained


func unlock_event(event_id: String) -> bool:
	if unlocked_events.has(event_id):
		return false
	unlocked_events.append(event_id)
	return true


func complete_event(event_id: String, time_seconds: float) -> void:
	if not completed_events.has(event_id):
		completed_events.append(event_id)
	var previous: float = best_times.get(event_id, INF)
	if time_seconds < previous:
		best_times[event_id] = time_seconds


# --- Online rating ----------------------------------------------------------

## Elo update against the average rating of the field. K falls off as a player
## builds a record, so a veteran's rating is stable but a newcomer converges
## fast.
func update_rating(field_average: int, placing: int, field_size: int) -> int:
	if field_size <= 1:
		return 0
	var k := 40.0 if rating_races < 15 else (24.0 if rating_races < 60 else 16.0)
	var expected := 1.0 / (1.0 + pow(10.0, float(field_average - rating) / 400.0))
	# Placing mapped to a 0..1 score: first is 1, last is 0.
	var score := 1.0 - float(placing - 1) / float(field_size - 1)
	var delta := int(round(k * (score - expected)))
	rating += delta
	rating_races += 1
	return delta


func rating_tier_name() -> String:
	if rating < 1000: return "Rookie"
	if rating < 1250: return "Club"
	if rating < 1500: return "National"
	if rating < 1750: return "Pro"
	if rating < 2000: return "Factory"
	return "Legend"


# --- Serialisation ----------------------------------------------------------

func to_dict() -> Dictionary:
	var cars := {}
	for uid in garage:
		cars[uid] = garage[uid].to_dict()
	return {
		"version": 1,
		"profile_id": profile_id,
		"display_name": display_name,
		"avatar_id": avatar_id,
		"created_unix": created_unix,
		"last_played_unix": last_played_unix,
		"money": money,
		"level": level,
		"xp": xp,
		"rating": rating,
		"rating_races": rating_races,
		"garage": cars,
		"active_car_uid": active_car_uid,
		"unlocked_events": unlocked_events,
		"completed_events": completed_events,
		"best_times": best_times,
		"sponsors": sponsors,
		"stat_races": stat_races,
		"stat_wins": stat_wins,
		"stat_wrecks": stat_wrecks,
		"stat_distance_km": stat_distance_km,
		"next_uid": _next_uid,
	}


static func from_dict(d: Dictionary) -> PlayerProfile:
	var p := PlayerProfile.new()
	p.profile_id = String(d.get("profile_id", ""))
	p.display_name = String(d.get("display_name", "Driver"))
	p.avatar_id = int(d.get("avatar_id", 0))
	p.created_unix = int(d.get("created_unix", 0))
	p.last_played_unix = int(d.get("last_played_unix", 0))
	p.money = int(d.get("money", 12000))
	p.level = int(d.get("level", 1))
	p.xp = int(d.get("xp", 0))
	p.rating = int(d.get("rating", DEFAULT_RATING))
	p.rating_races = int(d.get("rating_races", 0))
	p.active_car_uid = String(d.get("active_car_uid", ""))
	p.sponsors = (d.get("sponsors", {}) as Dictionary).duplicate()
	p.stat_races = int(d.get("stat_races", 0))
	p.stat_wins = int(d.get("stat_wins", 0))
	p.stat_wrecks = int(d.get("stat_wrecks", 0))
	p.stat_distance_km = float(d.get("stat_distance_km", 0.0))
	p._next_uid = int(d.get("next_uid", 1))

	for uid in d.get("garage", {}):
		p.garage[uid] = OwnedCar.from_dict(d["garage"][uid])
	for e in d.get("unlocked_events", []):
		p.unlocked_events.append(String(e))
	for e in d.get("completed_events", []):
		p.completed_events.append(String(e))
	for key in d.get("best_times", {}):
		p.best_times[String(key)] = float(d["best_times"][key])
	return p
