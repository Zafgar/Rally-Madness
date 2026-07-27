class_name UsedCarMarket
extends RefCounted
## The second-hand forecourt: a short list of specific cars, each with a
## history, that changes over time.
##
## A new-car showroom is a catalogue — every model, always, at one price. That
## is the wrong shape for the bottom of the market, where the interesting
## question is never "which model" but "is *this one* worth it". A tidy
## eighty-thousand-kilometre hatchback and a thrashed one with a blown
## suspension are the same model at very different prices, and choosing between
## them is a real decision in a way that reading a catalogue is not.
##
## So the stock is a handful of individual cars, each with its own mileage,
## wear, damage and whatever the last owner bolted to it. Some are bargains.
## Some are traps. The price reflects the condition, but only roughly — a car
## can be underpriced for what it is, and spotting that is the point.
##
## The list rotates, on two clocks at once:
##
##   * the real calendar, so a forecourt looks different tomorrow, and coming
##     back to a save after a week finds new stock the way it would in life;
##   * races run, so a player in a long session is not staring at the same nine
##     cars all evening.
##
## Everything is generated from those two numbers, so nothing is stored: the
## same day and the same race count always produce the same forecourt, on any
## machine, and a save file never has to carry a car nobody bought.

## How many cars are on the forecourt at once. Enough to browse, few enough
## that each one is a specific car rather than a row in a table.
const STOCK_SIZE := 9
## Races between rotations, for a player who is not coming back tomorrow.
const RACES_PER_ROTATION := 4
## The most a used car can be asked for, against the same model new.
const MAX_OF_NEW := 0.88

## What the seller says. Sorted from best to worst, and deliberately vague in
## the way small ads are: they describe the seller, not the car.
const CONDITION_NOTES := [
	"One owner, garaged, folder of receipts.",
	"Well kept. Serviced on the button.",
	"Tidy for the mileage. Nothing needs doing.",
	"Honest car. A few marks, all of them earned.",
	"Drives fine. Needs a service and a set of tyres.",
	"Cheap because it needs work. You can see what.",
	"Sold as seen. It has had a hard life and it shows.",
]


class Listing extends RefCounted:
	var spec: CarSpec = null
	## The specific car, complete with its history. This is what the player
	## takes delivery of if they buy it — the mileage and the wear come with it.
	var car: OwnedCar = null
	var price: int = 0
	## What the same model costs new, for the comparison the player is making.
	var new_price: int = 0
	var note: String = ""
	## True when the asking price is below what the condition is worth. The
	## player is not told this; it is what they are looking for.
	var underpriced: bool = false


## Which forecourt is currently showing. Changes with the day and with races.
static func period(races_run: int) -> int:
	var now := Time.get_datetime_dict_from_system()
	# Days since an arbitrary epoch. Any monotonic day number does; this one
	# is cheap and does not care about leap years being exactly right, because
	# it is a shuffle key rather than a date.
	var day := int(now.get("year", 2025)) * 372 + int(now.get("month", 1)) * 31 \
		+ int(now.get("day", 1))
	return day * 1000 + int(races_run / RACES_PER_ROTATION)


## How many races the player has run, which is the second clock.
static func races_run(profile: PlayerProfile) -> int:
	if profile == null:
		return 0
	var total := 0
	for id in profile.event_runs:
		total += int(profile.event_runs[id])
	return total


## The current stock. Deterministic in the period, so two calls in the same
## moment give the same forecourt and the player can leave a screen and come
## back to it.
static func stock(profile: PlayerProfile) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = period(races_run(profile))

	# What the player can plausibly be shopping for. A forecourt full of
	# machinery ten times their budget is a catalogue again, and one that never
	# shows anything better than what they have is a dead end — so it spans
	# from well within reach to a stretch.
	var budget := maxf(float(profile.money if profile != null else 12000), 3000.0)
	var candidates: Array = []
	for spec in CarDatabase.all():
		# Used prices run around half of new, so this is the reach in new money.
		if float(spec.price) > budget * 3.2:
			continue
		if spec.price <= 0:
			continue   # the free starter is not for sale second hand
		candidates.append(spec)
	if candidates.is_empty():
		return []

	var listings: Array = []
	var used_models := {}
	var attempts := 0
	while listings.size() < STOCK_SIZE and attempts < STOCK_SIZE * 12:
		attempts += 1
		var spec: CarSpec = candidates[rng.randi_range(0, candidates.size() - 1)]
		# At most two of any one model, or a forecourt turns into a fleet sale.
		if int(used_models.get(spec.id, 0)) >= 2:
			continue
		used_models[spec.id] = int(used_models.get(spec.id, 0)) + 1
		listings.append(_make_listing(spec, rng))

	listings.sort_custom(func(a, b): return a.price < b.price)
	return listings


## One specific car, with a life behind it.
static func _make_listing(spec: CarSpec, rng: RandomNumberGenerator) -> Listing:
	var listing := Listing.new()
	listing.spec = spec
	listing.new_price = spec.price

	var car := OwnedCar.create(spec, "used_%s_%d" % [spec.id, rng.randi()])
	# How well this one was treated, 0 for abused and 1 for cherished. Every
	# other number about the car follows from it, so the listing is internally
	# consistent: a car with a full service history does not also have four
	# bald tyres.
	var care := rng.randf()

	# Mileage. The model's own typical mileage is the middle of the range, and
	# a careless owner has done far more of it.
	var typical := spec.showroom_km()
	car.odometer_km = snappedf(typical * lerpf(1.45, 0.55, care)
		* rng.randf_range(0.85, 1.15), 500.0)
	# The engine is usually the original, but a well-kept car sometimes has a
	# replacement in it and that is worth real money.
	if care > 0.72 and rng.randf() < 0.35:
		car.engine_km = car.odometer_km * rng.randf_range(0.05, 0.30)
	else:
		car.engine_km = car.odometer_km

	car.oil_life = clampf(lerpf(0.15, 0.95, care) + rng.randf_range(-0.12, 0.12), 0.05, 1.0)
	car.brake_life = clampf(lerpf(0.20, 0.95, care) + rng.randf_range(-0.12, 0.12), 0.05, 1.0)
	car.turbo_life = clampf(lerpf(0.25, 0.95, care) + rng.randf_range(-0.10, 0.10),
		0.10, 1.0)

	# Cosmetic and structural damage, which is what the photographs never show.
	for part in ["body", "engine", "suspension", "tires"]:
		car.damage[part] = clampf(lerpf(0.58, 1.0, care)
			+ rng.randf_range(-0.10, 0.10), 0.32, 1.0)

	# What the last owner did to it. A cared-for car has sensible parts on it;
	# a thrashed one has whatever was cheapest, or a big turbo and nothing else
	# to cope with it, which is exactly the car that will let go.
	var standard := lerpf(0.15, 0.80, care) * rng.randf_range(0.6, 1.2)
	car.loadout = spec.prepared_loadout(clampf(standard, 0.0, 1.0), rng)

	listing.car = car
	listing.note = CONDITION_NOTES[
		clampi(int((1.0 - care) * float(CONDITION_NOTES.size())), 0,
			CONDITION_NOTES.size() - 1)]

	# The asking price. Roughly what the car is worth, moved either way by how
	# keen the seller is — which is where a bargain comes from.
	var worth := float(car.sale_value())
	var keenness := rng.randf_range(0.82, 1.24)
	var asking := worth * keenness
	# Never more than a dealer wants for the same car with no miles on it.
	#
	# The valuation counts the parts bolted to the car, which is right when the
	# player is selling — a built car is worth more than a bare one. But on a
	# forecourt it produced an Austin Allegro with two thousand credits of
	# suspension on it listed at more than a brand new Allegro, and a
	# second-hand lot whose cars cost more than new ones is not a second-hand
	# lot. Nobody pays a private seller a premium over a dealer for a shopping
	# car, however good the dampers are.
	asking = minf(asking, float(spec.price) * MAX_OF_NEW)
	listing.price = maxi(int(snappedf(asking, 50.0)), 200)
	listing.underpriced = listing.price < int(worth * 0.95)
	return listing


## When this forecourt changes, in words. A player deciding whether to wait for
## something better deserves to know how long waiting takes.
static func rotation_hint(profile: PlayerProfile) -> String:
	var run := races_run(profile)
	var until := RACES_PER_ROTATION - (run % RACES_PER_ROTATION)
	if until == 1:
		return "New stock arrives after your next race, or tomorrow."
	return "New stock arrives in %d races, or tomorrow." % until
