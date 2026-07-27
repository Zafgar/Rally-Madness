class_name FieldPreview
extends RefCounted
## Who is entered in an event, worked out without running it.
##
## The race director builds its field from a generator seeded on the event id,
## so the entry list is already the same every time that event is run. This
## reproduces it — the same pool, the same seeds, the same order — so the
## player can see who they are up against before paying the entry fee.
##
## It has to stay in step with RaceDirector's own selection. That is the price
## of showing an entry list at all, and the smoke test holds the two together.
##
## Two ratings, deliberately separate. A driver rating says how good the person
## is; a car rating says what they are sitting in. A quick driver in a tired
## car and a poor one in a fast car are completely different problems, and a
## single number for "how hard is this rival" hides exactly the thing a player
## needs to know when deciding where to spend their money.

## The rating a driver archetype represents at the top and bottom of its own
## ability. Scaled the same way the career's own Elo is, so a rival's number
## means the same thing as the player's.
const DRIVER_RATING_FLOOR := 700.0
const DRIVER_RATING_SPAN := 1500.0


class Entry extends RefCounted:
	var driver_name: String = ""
	var archetype: String = ""
	var archetype_name: String = ""
	var car: CarSpec = null
	var driver_rating: int = 0
	var car_rating: int = 0
	## What has been done to the car, in words, for the ones that had money
	## spent on them.
	var prepared: String = ""


## The whole entry list for an event, in grid order.
static func build(event: EventSpec, director_pool: Array = []) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(event.id)
	var pool: Array = director_pool
	if pool.is_empty():
		pool = eligible_cars(event)
	if pool.is_empty():
		return []

	var entries: Array = []
	for i in event.ai_opponents:
		var spec: CarSpec = pool[rng.randi_range(0, pool.size() - 1)]
		var standard := clampf(event.ai_skill * 0.85 + rng.randf_range(-0.18, 0.22),
			0.0, 1.0)
		var loadout := spec.prepared_loadout(standard, rng)
		var profile := DriverProfile.pick_for(event.ai_skill, rng)

		var entry := Entry.new()
		entry.archetype = profile.archetype
		entry.archetype_name = profile.display_name
		entry.car = spec
		entry.driver_rating = rating_for(profile)
		entry.car_rating = int(round(
			TuningCalculator.resolve(spec, loadout).performance_index()))
		entry.prepared = preparation_text(spec, loadout)
		entries.append(entry)
	return entries


## How good this driver is, as a number on the same scale as the player's own.
##
## Built from the traits that actually decide lap time — how much of the grip
## they will use, the ceiling they drive to, and how well they place the car —
## rather than from the archetype's name, so a varied copy of an archetype
## rates slightly differently from its template exactly as it drives.
static func rating_for(profile: DriverProfile) -> int:
	var ability := (profile.pace_ceiling * 0.40
		+ profile.commitment * 0.25
		+ profile.line_quality * 0.20
		+ profile.braking_skill * 0.15)
	return int(round(DRIVER_RATING_FLOOR + DRIVER_RATING_SPAN
		* clampf(ability, 0.0, 1.0)))


## The same pool the race director draws from, including the performance floor
## that keeps a field matched.
static func eligible_cars(event: EventSpec) -> Array:
	var pool := []
	var band := event.effective_tier_range()
	var cap := event.race_class().max_performance_index
	if cap >= 99999.0:
		cap = 0.0
		for spec in CarDatabase.all():
			if spec.tier >= band.x and spec.tier <= band.y:
				cap = maxf(cap, spec.to_base_stats().performance_index())
	var floor_index := cap * lerpf(RaceDirector.FIELD_FLOOR_LOW,
		RaceDirector.FIELD_FLOOR_HIGH, clampf(event.ai_skill, 0.0, 1.0))

	for spec in CarDatabase.all():
		if spec.tier < band.x or spec.tier > band.y:
			continue
		var index := spec.to_base_stats().performance_index()
		if index > cap or index < floor_index:
			continue
		if not event.drivetrain_required.is_empty():
			var dt: String = ["FWD", "RWD", "AWD"][spec.drivetrain]
			if not event.drivetrain_required.has(dt):
				continue
		if not event.category_required.is_empty() \
				and not event.category_required.has(spec.category):
			continue
		pool.append(spec)
	return pool


## The headline modifications, for the entry list. Naming every part would be a
## spreadsheet; naming the two or three that change how a car goes is a
## description of the car.
static func preparation_text(spec: CarSpec, loadout: TuningLoadout) -> String:
	var notable: Array[String] = []
	for slot in ["engine", "turbo", "suspension", "tires", "weight", "gearbox"]:
		var fitted := loadout.get_part(slot)
		var stock: String = String(spec.stock_parts.get(slot, ""))
		if fitted.is_empty() or fitted == stock:
			continue
		var part := PartDatabase.get_part(fitted)
		if part != null and part.tier > 0:
			notable.append(part.display_name)
	if notable.is_empty():
		return "As standard"
	if notable.size() > 3:
		notable.resize(3)
	return ", ".join(notable)


## What the player has to be rated before the entry list is shown to them.
##
## Not a gate for its own sake: knowing the field before you enter is what a
## driver with a reputation gets — somebody rings them up and tells them. Early
## on, you turn up and find out.
const ENTRY_LIST_RATING := 1050


static func visible_to(driver_rating: int) -> bool:
	return driver_rating >= ENTRY_LIST_RATING
