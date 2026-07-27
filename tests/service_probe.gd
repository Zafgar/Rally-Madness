extends Node
## What a stage costs to put right afterwards.
##
## The mechanical systems are meant to push a player towards tyres, a service
## and a tank of fuel — and to make them drive with some care. They are not
## meant to turn the game into an accounting exercise where every purse goes
## straight back into the car. The line between those two is a number, and this
## prints it: for a car from each tier, run a stage's worth of driving, then ask
## the garage what the bill is and compare it with what the event pays.
##
## The rule of thumb this is measured against: running costs should be a tithe,
## not a wage. Somewhere around a tenth of a decent finish, rising towards a
## quarter for a driver who leans on the car — noticeable, never crushing.
##
##   godot --headless --path . res://tests/service_probe.tscn -- [minutes]

## Cars that stand for the range: the first thing you own, a hot hatch, a
## proper rally car, a Group B monster, a modern supercar.
const SAMPLE := ["trabant_601", "golf_gti_mk2", "escort_cosworth", "delta_s4",
	"porsche_gt2_rs"]

## The two ways a stage gets driven, and the difference between them is the
## whole point: care is a strategy, not a personality.
const STYLES := {
	"careful": {"throttle": 0.62, "brake": 0.14, "speed": 22.0, "boost": 0.0, "rev": 0.0},
	"committed": {"throttle": 0.86, "brake": 0.22, "speed": 30.0, "boost": 0.5, "rev": 0.35},
	"reckless": {"throttle": 0.97, "brake": 0.30, "speed": 34.0, "boost": 1.0, "rev": 1.0},
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var minutes: float = float(args[0]) if args.size() > 0 else 4.0

	print("=== running costs over a %.0f-minute stage ===" % minutes)
	print("%-26s %-10s %7s %7s %7s %7s %9s %8s" % [
		"car", "style", "oil", "brakes", "tyres", "fuel", "bill", "of purse"])

	for car_id in SAMPLE:
		var spec := CarDatabase.get_car(car_id)
		if spec == null:
			push_error("service_probe: no car '%s'" % car_id)
			continue
		# What a mid-pack finish in this car's own class pays, which is the
		# income the bill has to be measured against.
		var purse := _typical_purse(spec)
		for style in STYLES:
			var row := _run(spec, STYLES[style], minutes * 60.0)
			print("%-26s %-10s %6.0f%% %6.0f%% %6.0f%% %6.0f%% %8d %7.0f%%" % [
				spec.display_name(), style,
				row["oil"] * 100.0, row["brakes"] * 100.0, row["tyres"] * 100.0,
				row["fuel"] * 100.0, row["bill"],
				100.0 * float(row["bill"]) / maxf(float(purse), 1.0)])

	print("\n(percentages are how much of each consumable the stage used up.")
	print(" the bill is what the garage charges to put all of it back.)")
	_report_reliability_parts(minutes * 60.0)
	get_tree().quit(0)


## What the reliability shelf actually buys.
##
## A part that says "reliability 2.1" on the tin is worth nothing if the number
## never reaches the wear model. This drives the same car, the same way, with
## and without each build, and prints the difference — so a claim in a
## description is a claim the bench has checked.
const BUILDS := {
	"stock": {},
	"gaskets": {"internals": "internals_gaskets"},
	"oil cooler": {"internals": "internals_oil_cooler", "cooling": "cooling_alloy"},
	"forged": {"internals": "internals_forged", "cooling": "cooling_race"},
	"dry sump": {"internals": "internals_dry_sump", "cooling": "cooling_wrc"},
	"big brakes": {"brakes": "brakes_4pot"},
	"anti-lag": {"exhaust": "exhaust_antilag", "turbo": "turbo_big"},
}


func _report_reliability_parts(seconds: float) -> void:
	var spec := CarDatabase.get_car("escort_cosworth")
	if spec == null:
		return
	print("\n=== what the reliability shelf buys — %s, driven hard ===" % spec.display_name())
	print("%-12s %7s %7s %7s %9s  %s" % [
		"build", "oil", "brakes", "turbo", "coolant", "fitted"])
	for name in BUILDS:
		var loadout := spec.default_loadout()
		var fitted: Array[String] = []
		for slot in BUILDS[name]:
			loadout.set_part(slot, BUILDS[name][slot])
			var part := PartDatabase.get_part(BUILDS[name][slot])
			if part != null:
				fitted.append(part.display_name)
		var row := _run_loadout(spec, loadout, STYLES["reckless"], seconds)
		print("%-12s %6.0f%% %6.0f%% %6.0f%% %8.0fC  %s" % [
			name, row["oil"] * 100.0, row["brakes"] * 100.0, row["turbo"] * 100.0,
			row["coolant"], ", ".join(fitted) if not fitted.is_empty() else "-"])


## One stage, driven in one style, on a fresh standard car.
func _run(spec: CarSpec, style: Dictionary, seconds: float) -> Dictionary:
	return _run_loadout(spec, spec.default_loadout(), style, seconds)


## The same, with a specific set of parts bolted on.
func _run_loadout(spec: CarSpec, loadout: TuningLoadout, style: Dictionary,
		seconds: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(spec.id)

	var car := OwnedCar.create(spec, "probe_%s" % spec.id)
	var stats := TuningCalculator.resolve(spec, loadout)
	var damage := DamageModel.new(stats)
	var mech := MechanicalModel.new(stats, damage)
	mech.load_condition(car)
	mech.boost_setting = float(style["boost"])
	mech.rev_limit_setting = float(style["rev"])

	var throttle := float(style["throttle"])
	var brake := float(style["brake"])
	var speed := float(style["speed"])
	var rpm := stats.redline_rpm * lerpf(0.62, 0.86, throttle)
	var power := stats.engine_torque_nm * rpm * 0.10472 * throttle

	# Throttle and brake are not both on at once, so the duty cycle alternates:
	# a burst of acceleration, then a corner. Averaging the two into one
	# permanently-half-pressed pedal would wear the brakes at a rate no real
	# stage produces.
	var step := 0.05
	var elapsed := 0.0
	var cycle := 0.0
	while elapsed < seconds:
		cycle = fmod(elapsed, 4.5)
		var braking := cycle > 3.2
		mech.update(step, speed, rpm, 0.0 if braking else throttle,
			0.0 if braking else power, rng, Vector2.ZERO,
			brake / 0.29 if braking else 0.0)
		# Tyres are worn by the tyre model, not the mechanical one, so the
		# scrub of the same corner has to be fed in alongside. A driver leaning
		# on the car slides it more, which is where the difference between the
		# styles comes from.
		var scrub := lerpf(0.5, 1.4, throttle) * (1.9 if braking else 1.0)
		damage.apply_tire_wear(step, scrub, 1.0)
		elapsed += step

	mech.store_condition(car)
	car.damage["tires"] = float(damage.integrity.get("tires", 1.0))

	var bill := 0
	for item in OwnedCar.SERVICE_ITEMS:
		bill += car.service_cost(item)

	return {
		"oil": 1.0 - car.oil_life,
		"brakes": 1.0 - car.brake_life,
		"tyres": 1.0 - float(car.damage.get("tires", 1.0)),
		"fuel": 1.0 - mech.fuel_l / maxf(mech.tank_l, 1.0),
		"turbo": 1.0 - mech.turbo_life,
		"coolant": mech.coolant_c,
		"bill": bill,
	}


## What a mid-pack finish in an event this car belongs in pays out.
##
## The median across the eligible events, not the best of them. Measuring the
## bill against the richest event a car could theoretically enter flatters
## every number — the honest comparison is the race the player is actually
## likely to be running this week.
func _typical_purse(spec: CarSpec) -> float:
	var purses: Array[float] = []
	for event in EventDatabase.all_events():
		var band: Vector2i = event.effective_tier_range()
		if spec.tier < band.x or spec.tier > band.y:
			continue
		var payouts: Array = event.payouts
		if payouts.is_empty():
			continue
		# Third place, or the last paying position if the field is shorter.
		purses.append(float(payouts[mini(2, payouts.size() - 1)]))
	if purses.is_empty():
		return 1000.0
	purses.sort()
	return purses[purses.size() / 2]
