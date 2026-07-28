class_name OwnedCar
extends RefCounted
## One car in a player's garage: which model it is, what is bolted to it, how
## beaten up it currently is, and how tired.
##
## Damage and wear are different things and both persist. Damage is what a crash
## did and is repaired in one go. Wear is what driving did — mileage on the
## engine, tread off the tyres, life out of the oil — and is serviced item by
## item. That distinction is the whole reason a cheap used car is cheap: it is
## undamaged and worn out, which looks fine in the garage and fails on the road.

## Service items, in the order the garage lists them. Each is 1.0 fresh and
## 0.0 due.
const SERVICE_ITEMS := ["tyres", "oil", "brakes"]

## What a fresh set of each costs, before the car's tier scales it. Deliberately
## small: routine servicing has to be something a broke player can afford, or
## the reliability system is just a tax on being poor.
const SERVICE_BASE_COST := {
	"tyres": 320,
	"oil": 110,
	"brakes": 240,
}

## Mileage at which a chassis has lost most of the value it is going to lose.
## Cars do not depreciate to nothing on distance alone.
const HIGH_MILEAGE_KM := 250000.0

var uid: String = ""
var spec_id: String = ""
var loadout: TuningLoadout
## Every part ever bought for this car, whether or not it is fitted right now.
##
## Without this the shop charged full price every time a part was fitted, so
## taking the gravel tyres off to try the tarmac ones and then putting the
## gravel tyres back cost two sets of gravel tyres. Worse, it made experimenting
## something you had to be rich to do — the one thing a tuning shop should
## encourage. A part bought for a car stays with that car; swapping between two
## you own costs nothing, because you own both.
var owned_parts: Array[String] = []
var damage: Dictionary = {"body": 1.0, "engine": 1.0, "suspension": 1.0, "tires": 1.0}
var nickname: String = ""
var races_entered: int = 0
var wins: int = 0
## Set when the car burned out or was written off. Still repairable, but the
## bill is the full one.
var write_off: bool = false

# --- Mileage and wear -------------------------------------------------------

## Distance the chassis has covered. Never resets — it is what a buyer asks.
var odometer_km: float = 0.0
## Distance on the engine currently fitted. An engine swap resets this and
## leaves the odometer alone, exactly as a real one does.
var engine_km: float = 0.0

var oil_life: float = 1.0
var brake_life: float = 1.0
## Turbo condition. Not directly serviceable — a turbo is replaced by fitting a
## different one in the tuning shop, which is how it works on a real car too.
var turbo_life: float = 1.0


static func create(spec: CarSpec, p_uid: String) -> OwnedCar:
	var c := OwnedCar.new()
	c.uid = p_uid
	c.spec_id = spec.id
	c.loadout = spec.default_loadout()
	# A showroom car in this game is a used car, and the price reflects it. The
	# cheap end of the market has genuinely tired engines in it.
	c.odometer_km = spec.showroom_km()
	c.engine_km = c.odometer_km
	# Whatever it came with is paid for, so taking it off and putting it back is
	# free from the first day.
	c.remember_fitted()
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
	var stats := TuningCalculator.resolve(s, loadout, damage)
	stats.engine_torque_nm *= engine_health_multiplier()
	return stats


# --- Wear ------------------------------------------------------------------

## How much of its factory output this engine still makes.
##
## An engine does not fall off a cliff, it just gets tired: a two hundred
## thousand kilometre unit is down a few per cent and a bit less willing. Small
## enough that it is never the reason a player loses, large enough that a fresh
## engine is a real upgrade.
func engine_health_multiplier() -> float:
	var worn := clampf((engine_km - MechanicalModel.ENGINE_FRESH_KM)
		/ (MechanicalModel.ENGINE_TIRED_KM - MechanicalModel.ENGINE_FRESH_KM), 0.0, 1.0)
	return lerpf(1.0, 0.92, worn)


func service_life(item: String) -> float:
	match item:
		"tyres": return clampf(float(damage.get("tires", 1.0)), 0.0, 1.0)
		"oil": return clampf(oil_life, 0.0, 1.0)
		"brakes": return clampf(brake_life, 0.0, 1.0)
	return 1.0


## What replacing one service item costs. Scales with the car, because a set of
## tyres for a Group B car is not a set of tyres for a Lada, and with how far
## gone the item is, so topping up early is cheap.
func service_cost(item: String) -> int:
	var s := spec()
	if s == null:
		return 0
	var base: int = SERVICE_BASE_COST.get(item, 200)
	var tier_scale := 1.0 + float(s.tier) * 0.55
	var needed := 1.0 - service_life(item)
	if needed <= 0.01:
		return 0
	return int(base * tier_scale * maxf(needed, 0.25))


func service(item: String) -> void:
	match item:
		"tyres": damage["tires"] = 1.0
		"oil": oil_life = 1.0
		"brakes": brake_life = 1.0


## Whether anything is worn enough to be worth mentioning before a race.
func needs_service() -> bool:
	for item in SERVICE_ITEMS:
		if service_life(item) < 0.45:
			return true
	return false


## What a replacement engine costs. A rebuilt unit is cheaper and arrives with
## some mileage already on it; a new one is expensive and starts at zero.
func engine_swap_cost(rebuilt: bool) -> int:
	var s := spec()
	if s == null:
		return 0
	var base := maxf(float(s.price) * 0.22, 900.0)
	return int(base * (0.45 if rebuilt else 1.0))


## Fits a different engine. The odometer is untouched — the car has still done
## the distance, it just is not this engine that did it.
func swap_engine(rebuilt: bool) -> void:
	engine_km = 70000.0 if rebuilt else 0.0
	damage["engine"] = 1.0
	oil_life = 1.0
	turbo_life = maxf(turbo_life, 0.85 if rebuilt else 1.0)


# --- Value ------------------------------------------------------------------

## Market value: what the player gets back if they sell it.
##
## Three things move it, and all three are things the player did: damage,
## mileage, and the parts bolted to it. Parts come back at less than they cost,
## because they always do.
func sale_value() -> int:
	var s := spec()
	if s == null:
		return 0
	var base := float(s.price) * 0.65 * mileage_value_multiplier()
	var parts := float(loadout.total_value()) * 0.40
	return int((base + parts) * lerpf(0.35, 1.0, condition()))


## How much of its value the chassis has left on distance alone. Bottoms out at
## 45%: a very high mileage car is worth much less, not nothing.
func mileage_value_multiplier() -> float:
	var worn := clampf(odometer_km / HIGH_MILEAGE_KM, 0.0, 1.0)
	return lerpf(1.0, 0.45, worn)


## Whether this car already has one of these on the shelf.
func owns_part(part_id: String) -> bool:
	return part_id.is_empty() or owned_parts.has(part_id)


## What fitting this part would actually cost, which is nothing if it is already
## on the shelf.
func price_to_fit(part: PartSpec) -> int:
	if part == null:
		return 0
	return 0 if owns_part(part.id) else part.price


func buy_part(part_id: String) -> void:
	if not part_id.is_empty() and not owned_parts.has(part_id):
		owned_parts.append(part_id)


## Adds whatever is currently bolted on to the shelf.
func remember_fitted() -> void:
	if loadout == null:
		return
	for slot in loadout.parts:
		buy_part(String(loadout.parts[slot]))


func to_dict() -> Dictionary:
	return {
		"uid": uid,
		"spec_id": spec_id,
		"loadout": loadout.to_dict() if loadout else {},
		"damage": damage.duplicate(),
		"nickname": nickname,
		"odometer_km": odometer_km,
		"engine_km": engine_km,
		"oil_life": oil_life,
		"brake_life": brake_life,
		"turbo_life": turbo_life,
		"races_entered": races_entered,
		"wins": wins,
		"write_off": write_off,
		"owned_parts": owned_parts,
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
	# Saves written before engines had their own mileage: assume the engine has
	# done the distance the car has, which is true unless it was swapped.
	c.engine_km = float(d.get("engine_km", c.odometer_km))
	c.oil_life = clampf(float(d.get("oil_life", 1.0)), 0.0, 1.0)
	c.brake_life = clampf(float(d.get("brake_life", 1.0)), 0.0, 1.0)
	c.turbo_life = clampf(float(d.get("turbo_life", 1.0)), 0.0, 1.0)
	c.races_entered = int(d.get("races_entered", 0))
	c.wins = int(d.get("wins", 0))
	c.write_off = bool(d.get("write_off", false))
	for id in d.get("owned_parts", []):
		c.owned_parts.append(String(id))
	# A save written before the shelf existed still owns whatever is bolted to
	# the car, and the player has certainly paid for it. Charging them again to
	# put back a part they are currently running would be the same bug wearing
	# a different hat.
	c.remember_fitted()
	return c
