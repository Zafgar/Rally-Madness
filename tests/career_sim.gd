extends Node
## Plays a whole career on fast-forward and reports the money curve.
##
## Balancing an economy by reading the numbers and hoping is how you end up
## with a game that is either trivially rich by race five or permanently broke.
## This drives a profile through the calendar the way a player would — enter
## what you can, finish where your car deserves, pay for the damage, buy
## something better when you can afford it — and prints what happens.
##
##   godot --headless --path . res://tests/career_sim.tscn -- [races] [skill]
##
## `skill` is the simulated player's driving ability, 0..1. Running it at 0.25
## and at 0.85 answers two different questions: can a poor player still
## progress, and can a good one break the economy.

## How much of the payout gap between positions a driver's skill is worth.
const SKILL_WEIGHT := 0.55
## Typical damage taken per race, as a fraction of condition. Scaled by how
## hard the driver is pushing and how far above their class the event is.
const BASE_DAMAGE := 0.12

var _races := 40
var _skill := 0.55
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_races = int(args[0])
	if args.size() > 1:
		_skill = float(args[1])
	_rng.seed = 20240727

	var profile := PlayerProfile.create_new("career_sim", "Sim Driver",
		CarDatabase.default_starter(), 0)
	print("=== career simulation: %d races at skill %.2f ===" % [_races, _skill])
	print("%-4s %-26s %-12s %5s %8s %10s %9s %7s %6s" % [
		"race", "event", "class", "pos", "purse", "repairs", "balance", "rating", "level"])

	var stuck_races := 0
	var lowest_balance := profile.money
	var bankrupt_races := 0

	var rescues := 0
	for race in range(1, _races + 1):
		if EventDatabase.ensure_entry_possible(profile):
			rescues += 1
			print("     -> broke with nothing to enter; issued a starter car")
		var choice := _pick_event(profile)
		if choice == null:
			stuck_races += 1
			print("%-4d %-26s  nothing enterable — %d cr, level %d" % [
				race, "-", profile.money, profile.level])
			# A player with nothing to enter is the failure this exists to
			# catch, but keep going so the report shows how long it lasts.
			continue

		var event: EventSpec = choice
		var car := _best_car_for(profile, event)
		profile.active_car_uid = car.uid
		var before := profile.money
		profile.spend(event.entry_fee)

		var repeats := profile.times_completed(event.id)
		var position := _simulate_position(profile, car, event)
		var purse := event.payout_for(position, repeats)
		profile.earn(purse)
		profile.award_xp(int(event.xp_reward
			* lerpf(1.3, 0.7, float(position - 1) / 6.0)
			* EventSpec.repeat_scale(repeats)))
		profile.stat_races += 1
		if position == 1:
			profile.stat_wins += 1
		profile.update_rating(_field_rating(event), position, event.ai_opponents + 1,
			EventSpec.CAREER_RATING_WEIGHT)
		profile.complete_event(event.id, 0.0)
		EventDatabase.apply_unlocks(profile, event.id)

		var repairs := _apply_damage_and_repair(profile, car, event, position)
		_apply_sponsors(profile, event, position)
		_consider_selling(profile)
		_consider_buying(profile)
		_consider_tuning(profile)

		lowest_balance = mini(lowest_balance, profile.money)
		if profile.money < 0:
			bankrupt_races += 1

		print("%-4d %-26s %-12s %5d %8d %10d %9d %7d %6d" % [
			race, event.display_name.substr(0, 26), event.race_class().display_name,
			position, purse, repairs, profile.money, profile.rating, profile.level])
		before = before  # keeps the pre-race balance available while debugging

	_dump_options(profile)
	_report(profile, stuck_races, lowest_balance, bankrupt_races, rescues)
	SaveSystem.delete_profile("career_sim")
	get_tree().quit(0)


## What a player would sensibly enter: the richest event they are allowed into
## and can afford the entry for, driving whichever car in the garage is both
## eligible and quickest for it.
##
## Considering the whole garage matters. A player who buys a faster car does not
## scrap the old one, and a class the new car is too quick for is still open to
## the old one — a simulation that only ever looks at the active car reports the
## player as stranded when they are not.
func _pick_event(profile: PlayerProfile) -> EventSpec:
	var best: EventSpec = null
	var best_value := -INF
	for event in EventDatabase.available_for(profile):
		if not event.profile_rejection_reason(profile).is_empty():
			continue
		if event.entry_fee > profile.money:
			continue
		var car := _best_car_for(profile, event)
		if car == null:
			continue
		# Judged on what the entry is likely to be worth, not on the winner's
		# cheque. A player who keeps entering the richest event they are
		# technically allowed into and finishing last is not playing well, and
		# balancing the economy around that mistake would make everything else
		# too generous.
		var value := _expected_value(car, event, profile.times_completed(event.id)) \
			- float(event.entry_fee)
		if value > best_value:
			best_value = value
			best = event
	return best


## What entering is worth on average: the payout at the position this car and
## driver are likely to take. Uses the same strength model as the race itself,
## which is what a player builds by feel after a few attempts.
func _expected_value(car: OwnedCar, event: EventSpec, repeats: int) -> float:
	var mine := _strength(car, event)
	var lo := event.ai_skill - 0.22
	var beat := clampf((mine - lo) / 0.44, 0.0, 1.0)
	var expected_position := 1.0 + float(event.ai_opponents) * (1.0 - beat)

	# Interpolate the payout table, so being half a place better is worth
	# something and the choice is not a step function.
	var low_pos := int(floor(expected_position))
	var frac := expected_position - float(low_pos)
	return lerpf(
		float(event.payout_for(low_pos, repeats)),
		float(event.payout_for(low_pos + 1, repeats)),
		frac)


## The strongest eligible car in the garage for an event, or null if none of
## them may enter.
func _best_car_for(profile: PlayerProfile, event: EventSpec) -> OwnedCar:
	var best: OwnedCar = null
	var best_index := -1.0
	for uid in profile.garage:
		var car: OwnedCar = profile.garage[uid]
		if not event.car_ineligible_reason(car).is_empty():
			continue
		var index := car.resolved_stats().performance_index()
		if index > best_index:
			best_index = index
			best = car
	return best


## Where the player finishes.
##
## Ranked against the field rather than read off a curve. Each rival gets its
## own strength drawn around the event's ai_skill, the player gets one built
## from their skill and how their car compares with the class cap, and the
## result is simply how many rivals came out ahead. Scoring by rank is what
## makes a win possible at all: a formula mapping one number onto a position
## has to reach its extreme to ever return first place, and it never does.
func _simulate_position(profile: PlayerProfile, car: OwnedCar, event: EventSpec) -> int:
	var mine := _strength(car, event) + _rng.randf_range(-0.10, 0.10)
	var ahead := 0
	for i in event.ai_opponents:
		# The field is not uniform: most rivals run near the event's stated
		# skill, a couple are notably better or worse, which is what the driver
		# archetypes do on track.
		var theirs := event.ai_skill + _rng.randf_range(-0.22, 0.22)
		if theirs > mine:
			ahead += 1
	return ahead + 1


## How competitive this car and driver are, on the same 0..1 scale as ai_skill,
## so the two can simply be compared.
func _strength(car: OwnedCar, event: EventSpec) -> float:
	var cap := event.race_class().max_performance_index
	var index := car.resolved_stats().performance_index()
	# Rivals sit around 75% of the class cap, so bringing a barely-legal car
	# should be a real advantage and bringing a stock one should not.
	var reference: float = cap * 0.75 if cap < 99999.0 else maxf(index, 1.0)
	var car_edge := clampf(index / maxf(reference, 1.0), 0.4, 1.6)
	return (car_edge - 0.4) / 1.2 * (1.0 - SKILL_WEIGHT) + _skill * SKILL_WEIGHT


func _field_rating(event: EventSpec) -> int:
	return event.field_rating()


## Takes damage proportional to how hard the race was, then repairs whatever
## the player can afford — which is the decision the economy hinges on.
func _apply_damage_and_repair(
	profile: PlayerProfile,
	car: OwnedCar,
	event: EventSpec,
	position: int
) -> int:
	var pressure := lerpf(1.4, 0.6, _skill)
	var harm := BASE_DAMAGE * pressure * _rng.randf_range(0.4, 1.8)
	if position > event.ai_opponents:
		harm *= 1.6   # a bad race usually means a bad moment
	for component in car.damage:
		car.damage[component] = clampf(car.damage[component] - harm, 0.05, 1.0)

	var bill := car.repair_cost()
	if bill <= 0:
		car.repair()
		return 0
	# Repair when it is affordable or when the car is getting dangerous.
	if bill <= profile.money * 0.6 or car.condition() < 0.45:
		var paid := mini(bill, profile.money)
		profile.spend(paid)
		if paid >= bill:
			car.repair()
		return paid
	return 0


## Money kept back for repairs at all times. Being fast and unable to start is
## not progress.
const REPAIR_RESERVE := 5000


## Runs the sponsor contracts and signs any new offer going. Sponsor income is
## a real part of the economy — per-race retainers are what smooth out a season
## where the purses are lumpy — so a balance pass that ignores it reads the
## mid-career as far tighter than it is.
func _apply_sponsors(profile: PlayerProfile, event: EventSpec, position: int) -> void:
	var expired: Array[String] = []
	for sponsor_id in profile.sponsors:
		var state: Dictionary = profile.sponsors[sponsor_id]
		profile.earn(SponsorSpec.apply_result(state, position, false))
		if int(state.get("races_remaining", 0)) <= 0:
			expired.append(sponsor_id)
	for sponsor_id in expired:
		var sponsor := EventDatabase.get_sponsor(sponsor_id)
		if sponsor != null:
			if SponsorSpec.objective_met(profile.sponsors[sponsor_id]):
				profile.earn(sponsor.completion_bonus)
			else:
				profile.spend(sponsor.failure_penalty)
		profile.sponsors.erase(sponsor_id)

	for offer in EventDatabase.sponsor_offers_for(profile, event.sponsor_offers):
		profile.sponsors[offer.id] = offer.new_contract_state()


## Sells cars the player has finished with: anything they can no longer race
## competitively and are not keeping as a class entry. Old cars are money, and a
## player saving for the next chassis clears the garage first.
func _consider_selling(profile: PlayerProfile) -> void:
	var target := _next_car_target(profile)
	if target == null or profile.money >= target.price + REPAIR_RESERVE:
		return
	# Keep the car being developed, one below it for the class it still fits,
	# and — always — the cheapest thing in the garage. The bottom-tier car is
	# the ticket into the free events, which is what a broke player lives on.
	var by_potential: Array = []
	for uid in profile.garage:
		var spec := (profile.garage[uid] as OwnedCar).spec()
		by_potential.append({"uid": uid, "potential": spec.potential_index() if spec else 0.0})
	by_potential.sort_custom(func(a, b): return a["potential"] > b["potential"])

	for i in range(2, by_potential.size() - 1):
		var value := profile.sell_car(by_potential[i]["uid"])
		if value > 0:
			print("     -> sold a car for %d cr" % value)


## The car the player is saving up for: the cheapest chassis that is a real step
## up on what they already have and that they are rated to race. Returns null
## once there is nothing left to want.
func _next_car_target(profile: PlayerProfile) -> CarSpec:
	# Compared on what each chassis can become, not on what it leaves the
	# showroom as. A built hot hatch outscores a standard four-wheel-drive car,
	# so comparing stock figures says every upgrade is a downgrade and the
	# player never buys anything.
	var owned_best := 0.0
	for uid in profile.garage:
		var spec := (profile.garage[uid] as OwnedCar).spec()
		if spec != null:
			owned_best = maxf(owned_best, spec.potential_index())

	var target: CarSpec = null
	for spec in CarDatabase.all():
		if profile.owns_model(spec.id):
			continue
		if spec.potential_index() < owned_best * 1.25:
			continue
		if not _class_allows(profile, spec, spec.stock_index()):
			continue
		if target == null or spec.price < target.price:
			target = spec
	return target


## Buys the car being saved for, once it is affordable without eating the
## repair fund.
func _consider_buying(profile: PlayerProfile) -> void:
	var target := _next_car_target(profile)
	if target == null or target.price > profile.money - REPAIR_RESERVE:
		return
	var bought := profile.buy_car(target)
	if bought != null:
		profile.active_car_uid = bought.uid
		print("     -> bought a %s for %d cr" % [target.display_name(), target.price])


## Every event on the calendar as the finished career sees it, with the reason
## it is closed or what entering it would be worth. When the simulation settles
## into re-running one event, this says whether that is a sensible choice or a
## gap in the calendar.
func _dump_options(profile: PlayerProfile) -> void:
	print("\n--- calendar as the player now sees it ---")
	for event in EventDatabase.all_events():
		var reason := event.profile_rejection_reason(profile)
		if not reason.is_empty():
			print("  %-28s locked: %s" % [event.display_name, reason])
			continue
		var car := _best_car_for(profile, event)
		if car == null:
			var why := "no eligible car"
			var active := profile.active_car()
			if active != null:
				why = event.car_ineligible_reason(active)
			print("  %-28s no car: %s" % [event.display_name, why])
			continue
		var repeats := profile.times_completed(event.id)
		var value := _expected_value(car, event, repeats) - float(event.entry_fee)
		print("  %-28s %-22s runs %d, expect %d cr" % [
			event.display_name, car.display_name().substr(0, 22), repeats, int(value)])


## Spends spare money on parts, the way a player does between rounds.
##
## Without this the simulation buys cars and never builds them, which reports
## the calendar as far harder than it is: every class is won by a car built
## towards its cap, and a showroom-standard car is meant to lose to one.
##
## The rule is the one a player follows: best index gain per credit, never
## enough spend to leave nothing for repairs, and never a part that pushes the
## car into a class the driver is not rated for.
func _consider_tuning(profile: PlayerProfile) -> void:
	# Develops the car with the highest ceiling, not the one that is quickest
	# today. A freshly bought chassis is slower than the built one it replaces,
	# and developing by current speed means the new car never gets touched.
	var car: OwnedCar = null
	var best_potential := -1.0
	for uid in profile.garage:
		var owned: OwnedCar = profile.garage[uid]
		var owned_spec := owned.spec()
		if owned_spec == null:
			continue
		if owned_spec.potential_index() > best_potential:
			best_potential = owned_spec.potential_index()
			car = owned
	if car == null:
		return
	var spec := car.spec()
	if spec == null:
		return

	# Parts come out of whatever is left once the repair fund and the deposit on
	# the next car are set aside. A player saving for a better chassis does not
	# spend the fund on brake pads for the one they are replacing.
	var reserve := REPAIR_RESERVE
	var target := _next_car_target(profile)
	if target != null:
		# At most half the balance goes into the savings pot. Locking away the
		# full deposit means a player saving for a car they cannot afford yet
		# never develops the one they are driving, and so never earns it.
		reserve += mini(int(target.price * 0.5), int(profile.money * 0.5))

	for pass_index in 12:
		var budget := profile.money - reserve
		if budget <= 0:
			return
		var current := car.resolved_stats().performance_index()
		var best_slot := ""
		var best_part: PartSpec = null
		var best_value := 0.0

		for slot in PartDatabase.slots():
			var fitted := car.loadout.get_part(slot)
			for part in PartDatabase.for_slot(slot):
				if part.id == fitted or part.price > budget:
					continue
				if not spec.accepts_part(part):
					continue
				var trial := car.loadout.clone()
				trial.set_part(slot, part.id)
				var index := TuningCalculator.resolve(spec, trial).performance_index()
				if index <= current:
					continue
				if not _class_allows(profile, spec, index):
					continue
				var value := (index - current) / maxf(float(part.price), 1.0)
				if value > best_value:
					best_value = value
					best_slot = slot
					best_part = part

		if best_part == null:
			return
		profile.spend(best_part.price)
		car.loadout.set_part(best_slot, best_part.id)


## Whether a car at this index still has a class to race in that the driver's
## rating allows. Stops the simulation from building itself out of competition,
## which is a mistake a real player can make but not one worth balancing around.
func _class_allows(profile: PlayerProfile, spec: CarSpec, index: float) -> bool:
	for c in RaceClass.all():
		if c.id == "open":
			continue
		if spec.tier < c.min_car_tier or spec.tier > c.max_car_tier:
			continue
		if index > c.max_performance_index:
			continue
		if profile.rating < c.min_rating or profile.rating > c.max_rating:
			continue
		return true
	return false


func _report(
	profile: PlayerProfile,
	stuck_races: int,
	lowest_balance: int,
	bankrupt_races: int,
	rescues: int
) -> void:
	print("\n--- after %d races ---" % _races)
	print("  balance      %d cr (lowest point %d)" % [profile.money, lowest_balance])
	print("  level        %d" % profile.level)
	print("  rating       %d (%s)" % [profile.rating, profile.rating_tier_name()])
	print("  wins         %d of %d" % [profile.stat_wins, profile.stat_races])
	print("  garage       %d cars" % profile.garage.size())
	var active := profile.active_car()
	if active != null:
		print("  driving      %s, class %s" % [
			active.display_name(), RaceClass.best_fit(active).display_name])
	print("  races with nothing to enter: %d" % stuck_races)
	print("  times the safety net fired:  %d" % rescues)
	print("  races ending in the red:     %d" % bankrupt_races)
	print("RESULT balance=%d level=%d rating=%d stuck=%d bankrupt=%d cars=%d rescues=%d" % [
		profile.money, profile.level, profile.rating, stuck_races, bankrupt_races,
		profile.garage.size(), rescues])
