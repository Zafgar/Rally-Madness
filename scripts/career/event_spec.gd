class_name EventSpec
extends RefCounted
## One entry on the career calendar.
##
## Events carry their own entry requirements, their own prize money and their
## own unlock edges, so the whole progression graph is data. Adding a
## championship means editing events.json, not writing code.

enum Format {
	SPRINT,       ## point to point, fastest wins
	STAGE,        ## rally stage against the clock, no rivals on track
	CIRCUIT,      ## laps, wheel to wheel
	ELIMINATION,  ## last place drops out each interval
	DERBY,        ## last car still running wins
}

var id: String = ""
var display_name: String = ""
var track_id: String = ""
var format: Format = Format.SPRINT
var laps: int = 1
var description: String = ""

## Some events cost money to enter. The high-payout ones usually do, which is
## the risk half of the risk/reward.
var entry_fee: int = 0
## Prize money by finishing position, index 0 = first.
var payouts: Array[int] = []
var xp_reward: int = 100

# --- Entry requirements ---
var min_level: int = 1
var min_car_tier: int = 0
var max_car_tier: int = 99
## Empty means any. Otherwise "FWD" / "RWD" / "AWD".
var drivetrain_required: Array[String] = []
## Empty means any. Otherwise matches CarSpec.category.
var category_required: Array[String] = []
## Events that must be completed first.
var requires_events: Array[String] = []

# --- Consequences ---
var unlocks_events: Array[String] = []
var sponsor_offers: Array[String] = []

# --- Field ---
var ai_opponents: int = 5
var ai_skill: float = 0.5


static func from_dict(d: Dictionary) -> EventSpec:
	var e := EventSpec.new()
	e.id = String(d.get("id", ""))
	e.display_name = String(d.get("name", e.id))
	e.track_id = String(d.get("track", ""))
	e.laps = int(d.get("laps", 1))
	e.description = String(d.get("description", ""))
	e.entry_fee = int(d.get("entry_fee", 0))
	e.xp_reward = int(d.get("xp", 100))
	e.min_level = int(d.get("min_level", 1))
	e.min_car_tier = int(d.get("min_car_tier", 0))
	e.max_car_tier = int(d.get("max_car_tier", 99))
	e.ai_opponents = int(d.get("ai_opponents", 5))
	e.ai_skill = float(d.get("ai_skill", 0.5))

	match String(d.get("format", "sprint")).to_lower():
		"stage": e.format = Format.STAGE
		"circuit": e.format = Format.CIRCUIT
		"elimination": e.format = Format.ELIMINATION
		"derby": e.format = Format.DERBY
		_: e.format = Format.SPRINT

	for p in d.get("payouts", []):
		e.payouts.append(int(p))
	for s in d.get("drivetrain_required", []):
		e.drivetrain_required.append(String(s).to_upper())
	for s in d.get("category_required", []):
		e.category_required.append(String(s))
	for s in d.get("requires_events", []):
		e.requires_events.append(String(s))
	for s in d.get("unlocks", []):
		e.unlocks_events.append(String(s))
	for s in d.get("sponsor_offers", []):
		e.sponsor_offers.append(String(s))
	return e


func payout_for(position: int) -> int:
	if payouts.is_empty():
		return 0
	var idx := clampi(position - 1, 0, payouts.size() - 1)
	# Anyone finishing outside the paid places still gets the last listed
	# amount, so a bad race is not a total loss.
	return payouts[idx]


## Whether a profile is allowed to enter at all, ignoring the car.
func profile_can_enter(profile: PlayerProfile) -> bool:
	if profile.level < min_level:
		return false
	for required in requires_events:
		if not profile.completed_events.has(required):
			return false
	return true


## Whether a specific car is eligible. Returns an empty string if it is, or a
## reason to show the player if it is not.
func car_ineligible_reason(car: OwnedCar) -> String:
	var spec := car.spec()
	if spec == null:
		return "Unknown car"
	if not car.is_driveable():
		return "Car is wrecked"
	if spec.tier < min_car_tier:
		return "Requires a tier %d car or better" % min_car_tier
	if spec.tier > max_car_tier:
		return "Car is above the tier %d limit" % max_car_tier
	if not drivetrain_required.is_empty():
		var dt: String = ["FWD", "RWD", "AWD"][spec.drivetrain]
		if not drivetrain_required.has(dt):
			return "%s only" % "/".join(drivetrain_required)
	if not category_required.is_empty() and not category_required.has(spec.category):
		return "%s cars only" % "/".join(category_required)
	return ""


func can_afford_entry(profile: PlayerProfile) -> bool:
	return profile.money >= entry_fee


func format_name() -> String:
	return ["Sprint", "Stage", "Circuit", "Elimination", "Derby"][format]
