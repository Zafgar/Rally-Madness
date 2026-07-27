class_name MechanicalModel
extends RefCounted
## What wears out, what gets hot, and what lets go.
##
## Separate from DamageModel, which is about being hit. This is about a car
## being a machine: an engine with mileage on it, oil that degrades, a turbo
## that has been leaned on, brakes that fade, a tank that empties. None of it is
## dramatic on its own — the drama is that all of it raises the chance of
## something failing at the worst moment, and the driver can see it coming.
##
## The design rule throughout is that a failure is earned, never random. Every
## hazard rate is the product of two things the player controls or can read:
##
##   wear    how tired the part is, which is visible in the garage and only
##           changes between races
##   stress  how hard it is being worked right now, which is visible on the
##           dashboard as a needle in the yellow
##
## A fresh car driven sensibly will essentially never break. A two-hundred
## thousand kilometre engine on maximum boost with the limiter raised will break
## often, and the dashboard will have been shouting about it for a minute first.
## That is the trade the tuning screen is selling.

# --- Systems ----------------------------------------------------------------

enum System { ENGINE, TURBO, OIL, COOLING, BRAKES, TYRES, FUEL }

## Reported to the dashboard for each system. Green is nothing to think about,
## amber means it will fail if you keep this up, red means it is failing.
enum Level { OK, WARNING, CRITICAL }

# --- Physical constants -----------------------------------------------------

## Brake specific fuel consumption, grams per kilowatt-hour, and the density of
## petrol. Together these turn engine power into litres per hour, which is what
## makes fuel use realistic rather than a made-up drain rate: a 60 kW average
## over a three-minute sprint is about a litre and a half, so short races never
## run dry and a forty-kilometre stage genuinely might.
const BSFC_G_PER_KWH := 300.0
const PETROL_KG_PER_L := 0.745

## Ambient, and the temperatures at which each fluid starts costing power.
const AMBIENT_C := 18.0
## The warning line is above anything a standard car reaches, on purpose. A
## light that is on during normal running is not a warning, it is decoration —
## and a power derate that applies to every car all the time is just a slower
## game. Only the settings a player deliberately turns up get near it.
const COOLANT_WARN_C := 110.0
const COOLANT_CRITICAL_C := 126.0
const OIL_WARN_C := 130.0
const OIL_CRITICAL_C := 150.0

## Kilometres of engine life before mileage alone starts to matter, and the
## figure at which an engine is thoroughly tired.
const ENGINE_FRESH_KM := 60000.0
const ENGINE_TIRED_KM := 220000.0

## Base hazard rates, in expected failures per hour of racing at full stress on
## a worn-out part. Deliberately low: the point is that pushing a tired car is a
## gamble, not that it is doomed.
## Calibrated against the smoke test rather than guessed: a thoroughly worn car
## on maximum boost with the limiter raised should usually not survive a
## ten-minute stage, and a healthy one should never fail at all. The wear factor
## is what gates these — at zero wear every rate below is multiplied by zero.
const BASE_RATE_ENGINE := 1.60
const BASE_RATE_TURBO := 2.20
const BASE_RATE_OIL := 1.40
const BASE_RATE_COOLING := 1.20
const BASE_RATE_PUNCTURE := 2.50

## Oil leaks put a slick on the road. One drop this often, in seconds.
const OIL_DROP_INTERVAL := 0.35

## Fraction of a set of pads used per unit of braking work, where the work is
## pedal pressure times metres travelled. Set so that a mid-size car driven
## hard through a four-minute stage — roughly a fifth of the time on the brakes
## at rally speeds — uses about a quarter of a set. Four or five hard events
## between pad changes: often enough that the service menu is a real decision,
## rare enough that it is not a chore after every race.
const BRAKE_WEAR_PER_JOULE := 0.00021

## Wear below this contributes nothing to any failure rate.
##
## Without a threshold, a perfectly maintained car has a small chance of failing
## simply because its oil is no longer brand new, and "I serviced everything and
## it broke anyway" is the exact feeling this system must never produce. Past
## the threshold the risk climbs quickly, so the message stays "look after it"
## rather than "cross your fingers".
const WEAR_THRESHOLD := 0.30


## Rescales a wear figure so anything below the threshold is zero and the
## remainder still spans the full range.
static func _past_threshold(wear: float, threshold: float = WEAR_THRESHOLD) -> float:
	return clampf((wear - threshold) / maxf(1.0 - threshold, 0.01), 0.0, 1.0)

var stats: VehicleStats
var damage: DamageModel

# --- Persistent condition, carried between races ----------------------------

## Total distance the chassis has covered. Cosmetic and economic: it is what a
## buyer asks about.
var odometer_km: float = 0.0
## Distance on this engine. An engine swap resets it while the odometer keeps
## counting, which is exactly how a used car works.
var engine_km: float = 0.0
## 1.0 is fresh, 0.0 is due. Serviced in the garage.
var oil_life: float = 1.0
var brake_life: float = 1.0
var turbo_life: float = 1.0

# --- Race state -------------------------------------------------------------

var fuel_l: float = 0.0
var tank_l: float = 50.0
var coolant_c: float = AMBIENT_C
var oil_c: float = AMBIENT_C

## Active failures, keyed by System. Once a thing has failed it stays failed for
## the rest of the stage.
var failed: Dictionary = {}
## -1 for none, otherwise Axle index: 0 front, 1 rear.
var punctured_axle: int = -1

## Set from the tuning setup each time the car is configured. Both raise power
## and both raise the chance of an expensive noise.
var boost_setting: float = 0.0
var rev_limit_setting: float = 0.0

var _oil_drop_timer: float = 0.0
var _distance_m: float = 0.0
## Seconds at high stress, which is what actually kills things — a single
## over-rev is survivable, a lap of them is not.
var _engine_strain: float = 0.0

signal failure(system: System, description: String)
signal oil_dropped(position: Vector2)
signal warning_changed(system: System, level: Level)

var _last_levels: Dictionary = {}


func _init(p_stats: VehicleStats, p_damage: DamageModel) -> void:
	stats = p_stats
	damage = p_damage
	tank_l = _tank_size()
	fuel_l = tank_l


## Tank size scaled off the car's mass, because that is the only proxy the data
## has for how big the thing is, and it is a decent one. A fitted cell adds to
## or takes away from that, which is the trade a rally team actually makes:
## less fuel is less weight and a bet on the stage being short.
func _tank_size() -> float:
	return maxf(clampf(stats.mass_kg * 0.045, 28.0, 110.0)
		+ stats.fuel_capacity_bonus_l, 12.0)


## Loads the wear a car is carrying into the race.
func load_condition(car: OwnedCar) -> void:
	odometer_km = car.odometer_km
	engine_km = car.engine_km
	oil_life = car.oil_life
	brake_life = car.brake_life
	turbo_life = car.turbo_life
	fuel_l = tank_l


## Writes back what the race did to it.
func store_condition(car: OwnedCar) -> void:
	car.odometer_km = odometer_km
	car.engine_km = engine_km
	car.oil_life = oil_life
	car.brake_life = brake_life
	car.turbo_life = turbo_life


# --- Wear factors -----------------------------------------------------------

## 0 when a part is as good as new, 1 when it is worn out. Everything that
## raises a hazard rate goes through one of these.

func engine_wear() -> float:
	var by_km := clampf(
		(engine_km - ENGINE_FRESH_KM) / (ENGINE_TIRED_KM - ENGINE_FRESH_KM), 0.0, 1.0)
	# Crash damage to the engine counts as wear too — a bent one is a tired one.
	var by_damage := 1.0 - float(damage.integrity.get("engine", 1.0))
	return clampf(maxf(by_km, by_damage * 0.9), 0.0, 1.0)


func oil_wear() -> float:
	return clampf(1.0 - oil_life, 0.0, 1.0)


func turbo_wear() -> float:
	if stats.turbo_boost <= 1.001:
		return 0.0   # nothing to fail
	return clampf(1.0 - turbo_life, 0.0, 1.0)


func brake_wear() -> float:
	return clampf(1.0 - brake_life, 0.0, 1.0)


func tyre_wear() -> float:
	return clampf(1.0 - float(damage.integrity.get("tires", 1.0)), 0.0, 1.0)


## How hard the driver is asking the engine to work, 0..1, before wear. Boost
## and a raised limiter are the two settings a player buys risk with.
func engine_stress() -> float:
	var boost := maxf(boost_setting, 0.0)
	var limiter := maxf(rev_limit_setting, 0.0)
	var heat := clampf((coolant_c - COOLANT_WARN_C) / 30.0, 0.0, 1.0)
	var starved := clampf(oil_wear() - 0.5, 0.0, 0.5) * 2.0
	return clampf(0.15 + boost * 0.45 + limiter * 0.40 + heat * 0.6 + starved * 0.5,
		0.0, 1.6)


# --- Per-step update --------------------------------------------------------

## `load_fraction` is throttle times how much of peak torque the engine is
## actually making, 0..1. `power_w` is what it is producing right now.
## `brake_fraction` is how hard the brake pedal is being pressed, 0..1.
func update(
	delta: float,
	speed_ms: float,
	rpm: float,
	load_fraction: float,
	power_w: float,
	rng: RandomNumberGenerator,
	position: Vector2,
	brake_fraction: float = 0.0
) -> void:
	_accumulate_distance(delta, speed_ms)
	_burn_fuel(delta, power_w)
	_update_temperatures(delta, speed_ms, load_fraction)
	_wear_parts(delta, speed_ms, load_fraction, rpm, brake_fraction)
	_roll_for_failures(delta, rng, rpm)
	_leak_oil(delta, position)
	_publish_levels()


func _accumulate_distance(delta: float, speed_ms: float) -> void:
	var metres := speed_ms * delta
	_distance_m += metres
	var km := metres / 1000.0
	odometer_km += km
	engine_km += km


func _burn_fuel(delta: float, power_w: float) -> void:
	if failed.has(System.FUEL):
		return
	var litres_per_second := maxf(power_w, 0.0) / 1000.0 \
		* BSFC_G_PER_KWH / 1000.0 / PETROL_KG_PER_L / 3600.0 \
		* maxf(stats.fuel_burn_rate, 0.1)
	# Idle and overrun still use a trickle, or a car coasting a long stage
	# arrives with a full tank.
	litres_per_second += 0.00035
	fuel_l = maxf(fuel_l - litres_per_second * delta, 0.0)
	if fuel_l <= 0.0 and not failed.has(System.FUEL):
		_fail(System.FUEL, "Out of fuel")


## Heat in from load, heat out with airflow. Losing coolant removes most of the
## heat rejection, which is what makes that failure matter rather than being a
## message on the dash.
func _update_temperatures(delta: float, speed_ms: float, load_fraction: float) -> void:
	var cooling_capacity := maxf(stats.cooling_capacity, 0.2)
	if failed.has(System.COOLING):
		cooling_capacity = 0.12
	var airflow := 0.35 + clampf(speed_ms / 45.0, 0.0, 1.0) * 0.65

	# A working cooling system holds a car at its thermostat temperature almost
	# regardless of how hard it is driven — that is what it is for. Normal
	# running therefore has to sit comfortably *below* the warning threshold,
	# or every car is derated for the crime of being switched on. Heat only
	# becomes a problem when the driver has asked for more than the standard
	# system was built for, or when the system itself has failed.
	# Standard settings, worked hard: 86-94 C, which is where a car lives.
	# Everything above that is bought with the boost and limiter sliders, and
	# maximum on both lands right on the warning line.
	var coolant_target := 86.0 + load_fraction * 8.0
	# A bigger radiator does not make a car run below its thermostat — it makes
	# the *extra* heat the driver has asked for go away. So capacity divides the
	# terms the boost and limiter sliders add, and leaves the base alone.
	var shed := 1.0 / maxf(stats.cooling_capacity, 0.2)
	coolant_target += maxf(boost_setting, 0.0) * 14.0 * shed
	coolant_target += maxf(rev_limit_setting, 0.0) * 8.0 * shed
	# Airflow is what actually rejects the heat, so a car sitting still in a
	# gravel trap cooks and a car at speed does not.
	coolant_target -= (airflow - 0.7) * 12.0
	if cooling_capacity < 0.5:
		# Nothing carrying the heat away: it climbs until something gives.
		coolant_target = AMBIENT_C + 190.0
	var coolant_rate := 0.8 + load_fraction * 1.4
	if coolant_c > coolant_target:
		coolant_rate = 2.4 * airflow * cooling_capacity
	coolant_c = move_toward(coolant_c, coolant_target, coolant_rate * delta)

	# Oil runs hotter than water and lags it, which is why oil temperature is
	# the gauge that tells you about the engine and water is the one that tells
	# you about the radiator.
	var oil_target := coolant_c + 12.0 + load_fraction * 16.0
	if failed.has(System.OIL):
		oil_target += 70.0
	oil_c = move_toward(oil_c, oil_target, (1.4 * airflow + 0.6) * delta)


func _wear_parts(delta: float, speed_ms: float, load_fraction: float, rpm: float,
		brake_fraction: float) -> void:
	var hours := delta / 3600.0
	# Oil degrades with heat and revs. A gentle stage barely touches it; a long
	# hot one uses most of a service interval.
	var rev_fraction := clampf(rpm / maxf(stats.redline_rpm, 1000.0), 0.0, 1.2)
	var oil_load := 0.4 + load_fraction * 0.8 + maxf(rev_fraction - 0.8, 0.0) * 2.0
	oil_load *= 1.0 + clampf((oil_c - OIL_WARN_C) / 40.0, 0.0, 1.5)
	oil_life = maxf(oil_life - oil_load * hours * 0.9 * maxf(stats.oil_wear_rate, 0.0), 0.0)

	if stats.turbo_boost > 1.001:
		var turbo_load := load_fraction * (1.0 + maxf(boost_setting, 0.0) * 1.4)
		turbo_load *= 1.0 + clampf((oil_c - OIL_WARN_C) / 30.0, 0.0, 2.0)
		turbo_life = maxf(
			turbo_life - turbo_load * hours * 0.55 * maxf(stats.turbo_wear_rate, 0.0), 0.0)

	_wear_brakes(delta, speed_ms, brake_fraction)


## Pads and discs, worn by the work they do.
##
## Brake life was read everywhere — the fade model, the failure roll, the
## garage bill, the used-car listing — and written nowhere, so a set of pads
## lasted forever and the "new brakes" line in the service menu bought nothing.
## The fix is the physical quantity: braking work is force times distance, so
## pedal pressure times road speed times time is exactly the energy going into
## the discs, and a heavy car late-braking from 200 km/h eats a set in a way
## that a hatchback trickling round a village stage never will.
func _wear_brakes(delta: float, speed_ms: float, brake_fraction: float) -> void:
	if brake_fraction <= 0.01 or speed_ms < 1.0:
		return
	var work := clampf(brake_fraction, 0.0, 1.0) * speed_ms * delta
	# Mass relative to a mid-size car, because stopping two tonnes costs twice
	# as much pad as stopping one.
	var heft := clampf(stats.mass_kg / 1200.0, 0.5, 2.2)
	# Fade is not just a symptom: hot brakes wear far faster than cool ones,
	# which is why the second half of a long descent is where a set dies.
	var heat := 1.0 + clampf((oil_c - OIL_WARN_C) / 60.0, 0.0, 0.8)
	brake_life = maxf(
		brake_life - work * heft * heat * BRAKE_WEAR_PER_JOULE
			* maxf(stats.brake_wear_rate, 0.0), 0.0)


## One Poisson trial per system per step. Rates are per hour, so a step at
## 1/60 s is a very small probability — failures accumulate over a stage rather
## than being decided by one unlucky frame.
func _roll_for_failures(delta: float, rng: RandomNumberGenerator, rpm: float) -> void:
	var hours := delta / 3600.0
	var stress := engine_stress()
	# What a proper build buys. It is applied to the hours rather than to each
	# rate so that nothing can be made *more* fragile by a rounding accident in
	# one system while another is untouched.
	hours /= maxf(stats.reliability, 0.05)

	if not failed.has(System.TURBO) and stats.turbo_boost > 1.001:
		var rate := BASE_RATE_TURBO * _past_threshold(turbo_wear()) * stress
		if rng.randf() < rate * hours:
			_fail(System.TURBO, "Turbo let go")

	if not failed.has(System.OIL):
		var tiredness := _past_threshold(maxf(oil_wear(), engine_wear() * 0.6))
		var rate := BASE_RATE_OIL * tiredness * stress
		if rng.randf() < rate * hours:
			_fail(System.OIL, "Oil pressure lost")

	if not failed.has(System.COOLING):
		# Overheating can take a radiator out on its own, because that one is
		# the driver's doing rather than the car's age.
		var overheating := clampf((coolant_c - COOLANT_WARN_C) / 25.0, 0.0, 1.5)
		var rate := BASE_RATE_COOLING \
			* (_past_threshold(engine_wear()) * stress + overheating * 0.6)
		if rng.randf() < rate * hours:
			_fail(System.COOLING, "Coolant lost")

	if not failed.has(System.ENGINE):
		# The engine itself only lets go once something else has been wrong for
		# a while. A healthy engine does not spontaneously grenade.
		var strain := 0.0
		if failed.has(System.OIL):
			strain += 1.4
		if oil_c > OIL_CRITICAL_C:
			strain += 1.0
		if coolant_c > COOLANT_CRITICAL_C:
			strain += 1.0
		if rpm > stats.redline_rpm * 1.02:
			strain += 0.6
		_engine_strain = maxf(_engine_strain + (strain - 0.25) * delta, 0.0)
		var rate := BASE_RATE_ENGINE * (0.2 + _past_threshold(engine_wear())) * strain \
			* (1.0 + _engine_strain * 0.05)
		if strain > 0.0 and rng.randf() < rate * hours:
			_fail(System.ENGINE, "Engine failure")

	if punctured_axle < 0:
		# A worn tyre picks up a puncture; a fresh one almost never does.
		var wear := tyre_wear()
		var rate := BASE_RATE_PUNCTURE * maxf(wear - 0.45, 0.0) * 2.2
		if rng.randf() < rate * hours:
			punctured_axle = 0 if rng.randf() < 0.5 else 1
			_fail(System.TYRES, "%s puncture" % ("Front" if punctured_axle == 0 else "Rear"))


func _leak_oil(delta: float, position: Vector2) -> void:
	if not failed.has(System.OIL):
		return
	_oil_drop_timer -= delta
	if _oil_drop_timer <= 0.0:
		_oil_drop_timer = OIL_DROP_INTERVAL
		oil_dropped.emit(position)


func _fail(system: System, description: String) -> void:
	if failed.has(system):
		return
	failed[system] = description
	failure.emit(system, description)


# --- What the failures do ---------------------------------------------------

## Multiplier on engine output. Everything that hurts power lands here so the
## physics only has to ask one question.
func power_multiplier() -> float:
	if failed.has(System.ENGINE) or failed.has(System.FUEL):
		return 0.0
	var m := 1.0
	# A blown turbo is not a dead engine, it is a naturally aspirated one.
	if failed.has(System.TURBO) and stats.turbo_boost > 1.0:
		m /= stats.turbo_boost
	if failed.has(System.OIL):
		m *= 0.55
	# Heat derates progressively, which gives a driver the chance to lift and
	# save it rather than simply taking the car away from them.
	m *= 1.0 - clampf((coolant_c - COOLANT_WARN_C) / 60.0, 0.0, 0.50)
	m *= 1.0 - clampf((oil_c - OIL_WARN_C) / 70.0, 0.0, 0.35)
	return clampf(m, 0.0, 1.0)


## Extra power from the boost setting, applied before the failures above. This
## is the reward half of the risk the tuning screen sells.
func boost_gain() -> float:
	if failed.has(System.TURBO) or stats.turbo_boost <= 1.001:
		return 1.0
	return 1.0 + maxf(boost_setting, 0.0) * 0.14


## Where the rev limiter actually sits, after the setup slider has moved it.
func effective_redline() -> float:
	return stats.redline_rpm * (1.0 + maxf(rev_limit_setting, 0.0) * 0.09)


## Grip multiplier for one axle. A puncture takes most of the grip off that end
## and makes the car unmistakably wrong to drive.
func axle_grip_multiplier(axle_index: int) -> float:
	if punctured_axle == axle_index:
		return 0.42
	return 1.0 - tyre_wear() * 0.22


## Extra rolling drag from a flat tyre, in newtons.
func puncture_drag() -> float:
	return 900.0 if punctured_axle >= 0 else 0.0


## Brake torque multiplier. Worn pads fade, and fade further when hot.
func brake_multiplier() -> float:
	var fade := brake_wear() * 0.35
	fade += clampf((oil_c - OIL_WARN_C) / 90.0, 0.0, 0.15)
	return clampf(1.0 - fade, 0.35, 1.0)


## True when the car cannot continue under its own power.
func is_stranded() -> bool:
	return failed.has(System.ENGINE) or failed.has(System.FUEL)


func failure_text() -> String:
	if failed.is_empty():
		return ""
	var parts: Array[String] = []
	for system in failed:
		parts.append(String(failed[system]))
	return ", ".join(parts)


# --- Dashboard readouts -----------------------------------------------------

## The warning level for one system. This is what turns a dashboard light amber
## and then red, and it is deliberately the same number the failure roll uses:
## the light is not a hint, it is the actual state.
func level_of(system: System) -> Level:
	if failed.has(system):
		return Level.CRITICAL
	match system:
		System.ENGINE:
			if oil_c > OIL_CRITICAL_C or coolant_c > COOLANT_CRITICAL_C:
				return Level.CRITICAL
			if engine_wear() > 0.75 and engine_stress() > 0.7:
				return Level.WARNING
		System.TURBO:
			if stats.turbo_boost <= 1.001:
				return Level.OK
			if turbo_wear() > 0.85:
				return Level.CRITICAL
			if turbo_wear() > 0.6 and boost_setting > 0.2:
				return Level.WARNING
		System.OIL:
			if oil_c > OIL_CRITICAL_C or oil_wear() > 0.92:
				return Level.CRITICAL
			if oil_c > OIL_WARN_C or oil_wear() > 0.7:
				return Level.WARNING
		System.COOLING:
			if coolant_c > COOLANT_CRITICAL_C:
				return Level.CRITICAL
			if coolant_c > COOLANT_WARN_C:
				return Level.WARNING
		System.BRAKES:
			if brake_wear() > 0.85:
				return Level.CRITICAL
			if brake_wear() > 0.6:
				return Level.WARNING
		System.TYRES:
			if tyre_wear() > 0.85:
				return Level.CRITICAL
			if tyre_wear() > 0.6:
				return Level.WARNING
		System.FUEL:
			var fraction := fuel_fraction()
			if fraction < 0.04:
				return Level.CRITICAL
			if fraction < 0.12:
				return Level.WARNING
	return Level.OK


func fuel_fraction() -> float:
	return clampf(fuel_l / maxf(tank_l, 0.1), 0.0, 1.0)


## Emits only on change, so listeners can react to a light coming on rather than
## polling one every frame.
func _publish_levels() -> void:
	for system in [System.ENGINE, System.TURBO, System.OIL, System.COOLING,
			System.BRAKES, System.TYRES, System.FUEL]:
		var level := level_of(system)
		if _last_levels.get(system, Level.OK) != level:
			_last_levels[system] = level
			warning_changed.emit(system, level)


## The single worst thing currently wrong, for a HUD that has room for one line.
func worst_level() -> Level:
	var worst := Level.OK
	for system in _last_levels:
		worst = maxi(worst, int(_last_levels[system])) as Level
	return worst


static func system_name(system: System) -> String:
	return ["ENGINE", "TURBO", "OIL", "TEMP", "BRAKES", "TYRES", "FUEL"][int(system)]
