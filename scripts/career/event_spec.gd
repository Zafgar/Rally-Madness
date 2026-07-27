class_name EventSpec
extends RefCounted
## One entry on the career calendar.
##
## Events carry their own entry requirements, their own prize money and their
## own unlock edges, so the whole progression graph is data. Adding a
## championship means editing events.json, not writing code.

## What an AI field is worth on the rating scale. `ai_skill` 0 is a driver who
## should not be on the road; 1 is a works driver. Mapping it onto Elo linearly
## gives every event a rating opponent without authoring a second number that
## could drift out of step with the first.
const AI_RATING_FLOOR := 700
const AI_RATING_SPAN := 1500

## How much of a full Elo swing a career race against AI is worth. Racing the
## calendar moves your rating, but slowly; the classes gated on rating are meant
## to take a season, not an afternoon.
const CAREER_RATING_WEIGHT := 0.5

## Repeat-entry purse decay, and the floor it settles at. The floor is low on
## purpose: re-running an event you have already won should cover a repair bill,
## not fund a career. Moving up the calendar is what pays.
const REPEAT_DECAY := 0.55
const REPEAT_FLOOR := 0.15

## However far the purse has decayed, winning still pays this multiple of the
## entry fee. An event you can win must never cost more than it returns.
const WIN_TO_FEE_FLOOR := 2.5

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
## The championship this event belongs to. Presentational: it groups the
## calendar screen and gives each rung of the ladder a name.
var series: String = ""
## Which competition class this event runs under. The class carries the tier,
## performance and rating gates, so a whole series is balanced in one place.
var class_id: String = "open"
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
	e.series = String(d.get("series", ""))
	e.class_id = String(d.get("class", "open"))
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


func race_class() -> RaceClass:
	return RaceClass.by_id(class_id)


## The rating this event's AI field represents, used as the Elo reference when
## a career result is scored. Deliberately derived from ai_skill rather than
## from the class band: the band is wide on purpose — a class holds drivers of
## very different ability — and its midpoint is nobody in particular.
func field_rating() -> int:
	return AI_RATING_FLOOR + int(round(clampf(ai_skill, 0.0, 1.0) * AI_RATING_SPAN))


## Prize money for a finishing position. `repeats` is how many times the driver
## has already finished this event; the purse falls off so the calendar, not one
## favourite event, is the way to make money.
func payout_for(position: int, repeats: int = 0) -> int:
	if payouts.is_empty():
		return 0
	var idx := clampi(position - 1, 0, payouts.size() - 1)
	# Anyone finishing outside the paid places still gets the last listed
	# amount, so a bad race is not a total loss.
	return int(payouts[idx] * race_class().purse_scale * _effective_repeat_scale(repeats))


## The repeat discount, held back from ever making an event a trap.
##
## Winning always pays at least WIN_TO_FEE_FLOOR times what it cost to enter.
## Without that, a paid-entry event decays into something you lose money on even
## when you beat everyone, which is not a discount — it is a punishment for
## liking a race.
func _effective_repeat_scale(repeats: int) -> float:
	var scale := repeat_scale(repeats)
	if entry_fee <= 0 or payouts.is_empty() or payouts[0] <= 0:
		return scale
	var needed := float(entry_fee) * WIN_TO_FEE_FLOOR / float(payouts[0])
	return maxf(scale, minf(needed, 1.0))


## How much of the advertised purse a repeat entry pays.
##
## It decays but never reaches zero: an event you have already won stays worth
## running when you are broke — that is the safety net that stops a career
## dead-ending — but it stops being the best thing on the calendar after the
## first couple of visits.
static func repeat_scale(repeats: int) -> float:
	if repeats <= 0:
		return 1.0
	return maxf(REPEAT_FLOOR, pow(REPEAT_DECAY, float(repeats)))


## Whether a profile is allowed to enter at all, ignoring the car.
func profile_can_enter(profile: PlayerProfile) -> bool:
	return profile_rejection_reason(profile).is_empty()


## Why a driver cannot enter, or an empty string if they can. Phrased for the
## player, because "this event is greyed out" without a reason is the most
## annoying thing a career screen can do.
func profile_rejection_reason(profile: PlayerProfile) -> String:
	if profile.level < min_level:
		return "Reach level %d (you are %d)" % [min_level, profile.level]
	for required in requires_events:
		if not profile.completed_events.has(required):
			var prerequisite := EventDatabase.get_event(required)
			var name := prerequisite.display_name if prerequisite != null else required
			return "Finish %s first" % name
	return race_class().driver_rejection_reason(profile)


## Whether a specific car is eligible. Returns an empty string if it is, or a
## reason to show the player if it is not.
func car_ineligible_reason(car: OwnedCar) -> String:
	var spec := car.spec()
	if spec == null:
		return "Unknown car"
	if not car.is_driveable():
		return "Car is wrecked"
	# Class gates first: they are the ones a player is meant to plan around.
	var class_reason := race_class().car_rejection_reason(car)
	if not class_reason.is_empty():
		return class_reason
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


## Effective car tier band, folding the class limits into the event's own.
func effective_tier_range() -> Vector2i:
	var c := race_class()
	return Vector2i(maxi(min_car_tier, c.min_car_tier), mini(max_car_tier, c.max_car_tier))


func format_name() -> String:
	return ["Sprint", "Stage", "Circuit", "Elimination", "Derby"][format]
