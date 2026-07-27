class_name OwnedCar
extends RefCounted
## One car in a player's garage: which model it is, what is bolted to it, and
## how beaten up it currently is.
##
## Damage persists between events. That is the point of the repair economy —
## finishing a stage with a bent car and no money is a situation the player has
## to drive their way out of.

var uid: String = ""
var spec_id: String = ""
var loadout: TuningLoadout
var damage: Dictionary = {"body": 1.0, "engine": 1.0, "suspension": 1.0, "tires": 1.0}
var nickname: String = ""
var odometer_km: float = 0.0
var races_entered: int = 0
var wins: int = 0
## Set when the car burned out or was written off. Still repairable, but the
## bill is the full one.
var write_off: bool = false


static func create(spec: CarSpec, p_uid: String) -> OwnedCar:
	var c := OwnedCar.new()
	c.uid = p_uid
	c.spec_id = spec.id
	c.loadout = spec.default_loadout()
	return c


func spec() -> CarSpec:
	return CarDatabase.get_car(spec_id)


func display_name() -> String:
	if not nickname.is_empty():
		return nickname
	var s := spec()
	return s.display_name() if s != null else spec_id


func condition() -> float:
	return (damage["body"] * 0.35 + damage["engine"] * 0.30
		+ damage["suspension"] * 0.25 + damage["tires"] * 0.10)


func is_driveable() -> bool:
	return damage["body"] > 0.0 and not write_off


## Free for starter-tier cars, which is the safety net that keeps a broke
## player in the game.
func repair_cost() -> int:
	var s := spec()
	if s == null:
		return 0
	return TuningCalculator.repair_cost(s, loadout, damage)


func repair() -> void:
	for key in damage:
		damage[key] = 1.0
	write_off = false


func resolved_stats() -> VehicleStats:
	var s := spec()
	if s == null:
		return VehicleStats.new()
	return TuningCalculator.resolve(s, loadout, damage)


## Market value: what the player gets back if they sell it. Damage and the
## usual depreciation both bite.
func sale_value() -> int:
	var s := spec()
	if s == null:
		return 0
	var base := float(s.price) * 0.65
	var parts := float(loadout.total_value()) * 0.40
	return int((base + parts) * lerpf(0.35, 1.0, condition()))


func to_dict() -> Dictionary:
	return {
		"uid": uid,
		"spec_id": spec_id,
		"loadout": loadout.to_dict() if loadout else {},
		"damage": damage.duplicate(),
		"nickname": nickname,
		"odometer_km": odometer_km,
		"races_entered": races_entered,
		"wins": wins,
		"write_off": write_off,
	}


static func from_dict(d: Dictionary) -> OwnedCar:
	var c := OwnedCar.new()
	c.uid = String(d.get("uid", ""))
	c.spec_id = String(d.get("spec_id", ""))
	c.loadout = TuningLoadout.from_dict(d.get("loadout", {}))
	var saved: Dictionary = d.get("damage", {})
	for key in c.damage:
		if saved.has(key):
			c.damage[key] = clampf(float(saved[key]), 0.0, 1.0)
	c.nickname = String(d.get("nickname", ""))
	c.odometer_km = float(d.get("odometer_km", 0.0))
	c.races_entered = int(d.get("races_entered", 0))
	c.wins = int(d.get("wins", 0))
	c.write_off = bool(d.get("write_off", false))
	return c
