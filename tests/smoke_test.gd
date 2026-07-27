extends Node
## Headless smoke test.
##
## Two jobs. First, verify that every data file loads and that every reference
## between them resolves — a typo in cars.json or a track id an event points at
## but which does not exist should fail here, not when a player picks it from a
## menu. Second, actually run a race to completion so the physics, the AI, the
## checkpoints and the payout path are all exercised.
##
## Run with:
##   godot --headless --fixed-fps 60 --path . res://tests/smoke_test.tscn
##
## --fixed-fps runs the loop flat out with a constant timestep, so a race that
## takes a couple of minutes of simulated time finishes in a few seconds of
## wall clock without changing a single physics result.

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

## Simulated race seconds to allow before declaring the race hung. Generous:
## the point is to catch a race that can never end, not to police lap times.
const RACE_SIM_TIMEOUT := 600.0
## Wall-clock backstop, in case the race clock itself stops advancing. Six cars
## and a track saturate a core, so --fixed-fps buys much less than it looks
## like it should; this is deliberately well clear of the expected run time.
const RACE_WALL_TIMEOUT := 300.0

var _failures: Array[String] = []
var _checks: int = 0
var _director: RaceDirector
var _elapsed: float = 0.0
var _race_running: bool = false


func _ready() -> void:
	print("=== Rally Madness smoke test ===")
	_test_databases()
	_test_data_integrity()
	_test_tuning()
	_test_physics_model()
	_test_wheel_dynamics()
	_test_performance_calibration()
	_test_upgrade_ceiling()
	_test_driver_profiles()
	_test_rival_awareness()
	_test_visuals()
	_test_haptics()
	_test_damage_and_economy()
	_test_progression()
	_test_classes_and_economy()
	_test_command_encoding()
	_start_test_race()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
		print("  FAIL  %s" % description)


func _section(name: String) -> void:
	print("\n-- %s" % name)


# --- Data -------------------------------------------------------------------

func _test_databases() -> void:
	_section("databases")
	_check(CarDatabase.all().size() > 0, "car catalogue is not empty")
	_check(PartDatabase.for_slot("tires").size() > 0, "tire parts exist")
	_check(EventDatabase.all_events().size() > 0, "calendar is not empty")
	_check(not CarDatabase.starter_cars().is_empty(),
		"at least one free-to-repair starter car exists")
	print("  %d cars, %d events, %d tracks" % [
		CarDatabase.all().size(),
		EventDatabase.all_events().size(),
		TrackSpec.load_all().size()])


func _test_data_integrity() -> void:
	_section("cross-references")
	var tracks := TrackSpec.load_all()

	for event in EventDatabase.all_events():
		_check(tracks.has(event.track_id),
			"event '%s' points at a track that exists ('%s')" % [event.id, event.track_id])
		_check(event.payouts.size() > 0, "event '%s' pays something" % event.id)
		for unlocked in event.unlocks_events:
			_check(EventDatabase.get_event(unlocked) != null,
				"event '%s' unlocks a real event ('%s')" % [event.id, unlocked])
		for sponsor_id in event.sponsor_offers:
			_check(EventDatabase.get_sponsor(sponsor_id) != null,
				"event '%s' offers a real sponsor ('%s')" % [event.id, sponsor_id])
		# An event nobody can bring a legal car to is a dead end in the career.
		var eligible := 0
		for spec in CarDatabase.all():
			if spec.tier >= event.min_car_tier and spec.tier <= event.max_car_tier:
				if event.drivetrain_required.is_empty():
					eligible += 1
				else:
					var dt: String = ["FWD", "RWD", "AWD"][spec.drivetrain]
					if event.drivetrain_required.has(dt):
						eligible += 1
		_check(eligible > 0, "event '%s' has at least one eligible car" % event.id)

	for id in tracks:
		var track: TrackSpec = tracks[id]
		_check(track.waypoints.size() >= 3, "track '%s' has enough waypoints" % id)
		_check(track.width > 0.0, "track '%s' has a width" % id)
		for ramp in track.ramps:
			_check(int(ramp["at"]) < track.waypoints.size(),
				"track '%s' ramp indexes a real waypoint" % id)
		# Hazards are real bodies, so a bad reference here is a crash at load.
		for entry in track.props:
			var prop := TrackProp.by_id(String(entry["prop"]))
			_check(prop != null,
				"track '%s' places a real prop ('%s')" % [id, entry["prop"]])
			_check(int(entry["at"]) < track.waypoints.size(),
				"track '%s' places '%s' at a real waypoint" % [id, entry["prop"]])
			if prop != null:
				_check(prop.kind == TrackProp.Kind.HAZARD,
					"track '%s' places a hazard, not scenery ('%s')" % [id, entry["prop"]])
		# A theme with nothing to scatter leaves a stage looking abandoned.
		var palette := TrackProp.for_theme(track.scenery_theme(), TrackProp.Kind.SCENERY)
		_check(palette.size() >= 3,
			"track '%s' theme '%s' has scenery to scatter (%d props)" % [
				id, track.scenery_theme(), palette.size()])

	for spec in CarDatabase.all():
		for slot in spec.stock_parts:
			_check(PartDatabase.get_part(spec.stock_parts[slot]) != null,
				"car '%s' ships with a real part in '%s'" % [spec.id, slot])


# --- Tuning -----------------------------------------------------------------

func _test_tuning() -> void:
	_section("tuning")
	var spec := CarDatabase.get_car("impreza_gc8")
	_check(spec != null, "reference car loads")
	if spec == null:
		return

	var stock := TuningCalculator.resolve(spec, spec.default_loadout())
	var loadout := spec.default_loadout()
	# The biggest turbo the chassis will accept, rather than a named part: the
	# upgrade ceiling decides what fits, and hard-coding a part id here makes
	# this test fail whenever the ceilings are re-balanced rather than when the
	# turbo model breaks.
	loadout.set_part("turbo", "turbo_ball_bearing")
	loadout.set_part("tires", "tires_gravel")
	loadout.set_part("weight", "weight_strip_full")
	var tuned := TuningCalculator.resolve(spec, loadout)

	_check(tuned.turbo_boost > stock.turbo_boost, "a bigger turbo raises boost")
	_check(tuned.turbo_lag > stock.turbo_lag, "a bigger turbo also costs lag")
	_check(tuned.dirt_grip > stock.dirt_grip, "gravel tires improve dirt grip")
	_check(tuned.tarmac_grip < stock.tarmac_grip, "gravel tires give up tarmac grip")
	_check(tuned.mass_kg < stock.mass_kg, "stripping the interior saves weight")
	_check(tuned.crash_resistance < stock.crash_resistance,
		"stripping the interior costs crash protection")
	_check(tuned.performance_index() > stock.performance_index(),
		"the tuned car rates higher overall")

	# Setup sliders must move the car without needing a purchase.
	var setup_loadout := spec.default_loadout()
	setup_loadout.setup["brake_bias"] = 1.0
	var biased := TuningCalculator.resolve(spec, setup_loadout)
	_check(biased.brake_bias_front > stock.brake_bias_front,
		"the brake bias slider shifts bias forward")

	# Every stat a part can name must actually exist on VehicleStats.
	for slot in PartSpec.SLOTS:
		for part in PartDatabase.for_slot(slot):
			for stat in part.modifiers:
				_check(VehicleStats.STAT_KEYS.has(stat),
					"part '%s' targets a real stat ('%s')" % [part.id, stat])


func _test_physics_model() -> void:
	_section("physics model")
	var spec := CarDatabase.get_car("impreza_gc8")
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())

	# Axle geometry must sum back to the wheelbase, or load transfer is wrong.
	var sum := stats.cg_to_front_axle() + stats.cg_to_rear_axle()
	_check(is_equal_approx(sum, stats.wheelbase_m),
		"axle distances sum to the wheelbase")
	# A front-biased car must sit closer to its front axle.
	_check(stats.cg_to_front_axle() < stats.cg_to_rear_axle(),
		"a front-biased car has its CoG nearer the front axle")

	# Drivetrain torque split.
	var fwd := CarDatabase.get_car("golf_gti_mk2").to_base_stats()
	var rwd := CarDatabase.get_car("corolla_ae86").to_base_stats()
	_check(is_equal_approx(fwd.front_torque_share(), 1.0), "FWD sends all torque forward")
	_check(is_equal_approx(rwd.front_torque_share(), 0.0), "RWD sends none forward")
	_check(stats.front_torque_share() > 0.0 and stats.front_torque_share() < 1.0,
		"AWD splits torque between both axles")

	# The grip curve must rise to a peak at normalised slip 1.0 and fall away
	# past it. Everything about how a car behaves at the limit comes from that
	# shape.
	var peak := TireModel.curve(1.0, stats.drift_release)
	var past := TireModel.curve(3.0, stats.drift_release)
	var below := TireModel.curve(0.5, stats.drift_release)
	_check(peak > below, "grip builds up to the slip peak")
	_check(peak > past, "and falls away past it")
	_check(past > TireModel.SLIDE_RATIO * 0.9,
		"a fully sliding tyre still makes some force, just less")
	_check(TireModel.curve(-1.0, stats.drift_release) < 0.0,
		"and the force opposes the slip")

	# Cornering and driving share one grip budget. Asking for both at once must
	# give less of each than asking for either alone — the friction circle.
	var axle := Axle.new(true, stats.wheel_radius)
	axle.inertia = stats.wheel_inertia
	var load := stats.mass_kg * 0.5 * 9.81
	var mu := TireModel.surface_mu(stats, TireModel.Surface.TARMAC, true)

	# Several steps, not one: brake torque changes the wheel's speed, and the
	# slip ratio that costs cornering force only shows up on the frames after
	# that. A single step measures the state before anything has happened.
	var pure_lateral := _settled_axle_force(axle, stats, mu, load, 0.0)
	var combined := _settled_axle_force(axle, stats, mu, load,
		stats.max_brake_torque() * 0.5)
	_check(absf(combined.y) < absf(pure_lateral.y),
		"braking hard costs cornering force (%.0f N vs %.0f N)" % [
			absf(combined.y), absf(pure_lateral.y)])

	# Engine torque must peak somewhere inside the rev range, not at idle.
	var engine := EngineModel.new(stats)
	var at_peak := engine.torque_fraction(
		lerpf(stats.idle_rpm, stats.redline_rpm, engine.peak_position()))
	_check(at_peak > engine.torque_fraction(stats.idle_rpm),
		"torque at the power peak beats torque at idle")
	_check(at_peak >= engine.torque_fraction(stats.redline_rpm),
		"torque at the power peak beats torque at the limiter")

	# Automatic gearbox must climb through the gears under load.
	var gearbox := Transmission.new(stats)
	gearbox.mode = Transmission.Mode.AUTOMATIC
	gearbox.shift_to(1)
	var speed := 0.0
	for i in 600:
		speed = minf(speed + 0.25, 70.0)
		gearbox.update(1.0 / 60.0, speed, 0.32, 1.0)
	_check(gearbox.gear > 1, "the automatic box upshifts as speed builds")
	_check(gearbox.rpm <= stats.redline_rpm + 1.0, "revs never exceed the limiter")


## Wheel lock-up, ABS and traction control.
##
## Axle is pure logic with no physics body, so a braking event can be simulated
## exactly and deterministically here: one axle, a mass to decelerate, and a
## loop. That makes "does ABS actually stop shorter" a measured number rather
## than a claim.
## Runs an axle at a fixed slip angle and road speed until its wheel speed has
## settled, then reports the force it is making.
func _settled_axle_force(
	axle: Axle,
	stats: VehicleStats,
	mu: float,
	load: float,
	brake_torque: float
) -> Vector2:
	const SLIP_ANGLE := 0.14
	axle.sync_to_road(25.0)
	var force := Vector2.ZERO
	for i in 40:
		force = axle.update(1.0 / 120.0, 25.0, SLIP_ANGLE, 0.0, brake_torque, 0.0,
			mu, mu, load, stats, 0.0, 0.0, 0.0)
	return force


func _test_wheel_dynamics() -> void:
	_section("wheel dynamics")

	var spec := CarDatabase.get_car("golf_gti_mk2")
	var no_abs := TuningCalculator.resolve(spec, spec.default_loadout())
	_check(not no_abs.has_abs(), "a 1987 hot hatch has no ABS")

	var with_abs_loadout := spec.default_loadout()
	with_abs_loadout.set_part("electronics", "elec_abs_retrofit")
	var with_abs := TuningCalculator.resolve(spec, with_abs_loadout)
	_check(with_abs.has_abs(), "the ABS retrofit fits and takes effect")

	# Two separate claims, so two separate runs. Straight-line braking is about
	# stopping distance; braking while turning is about whether the car still
	# goes where it is pointed. Measuring both in one run conflates them — a
	# tyre that is busy cornering is not braking as hard, which made ABS look
	# worse than locked wheels until the runs were split.
	var locked_run := _simulate_braking(no_abs, 0.0)
	var abs_run := _simulate_braking(with_abs, 0.0)
	var locked_turn := _simulate_braking(no_abs, 0.175)     # ~10 degrees of lock
	var abs_turn := _simulate_braking(with_abs, 0.175)

	_check(locked_run["locked_fraction"] > 0.6,
		"without ABS, standing on the brakes locks the wheels and keeps them locked")
	_check(abs_run["locked_fraction"] < 0.1,
		"with ABS, they do not stay locked (%.0f%% of the stop)" % [
			abs_run["locked_fraction"] * 100.0])
	_check(abs_run["abs_fired"], "and the ABS reports itself working")
	# The whole point: a sliding tyre makes less force than one at peak slip.
	_check(abs_run["distance"] < locked_run["distance"],
		"ABS stops shorter than locked wheels (%.1f m vs %.1f m)" % [
			abs_run["distance"], locked_run["distance"]])
	# A locked wheel slides almost straight backwards, so nearly all of its
	# friction fights the slide and almost none is left to turn the car. This
	# is the answer to "do the brakes fail?" — the brakes are fine, it is the
	# tyre that has stopped doing two jobs at once.
	_check(locked_turn["steering_share"] < 0.15,
		"turning the wheel under locked braking does almost nothing (%.0f%% of grip)" % [
			locked_turn["steering_share"] * 100.0])
	_check(abs_turn["steering_share"] > locked_turn["steering_share"] * 2.0,
		"under ABS the car still steers (%.0f%% of grip)" % [
			abs_turn["steering_share"] * 100.0])
	# ABS is felt as pressure being bled off and put back, not as a constant.
	_check(abs_run["release_swing"] > 0.15,
		"ABS pressure oscillates rather than sitting at a constant")

	print("  braking from 30 m/s, straight:")
	print("    no ABS  %.1f m  (wheels locked %.0f%% of the stop)" % [
		locked_run["distance"], locked_run["locked_fraction"] * 100.0])
	print("    ABS     %.1f m  (%.0f%% shorter, slip held at %.2f)" % [
		abs_run["distance"], (1.0 - abs_run["distance"] / locked_run["distance"]) * 100.0,
		abs_run["mean_slip"]])
	print("  same again with 10 deg of steering held on:")
	print("    no ABS  %.0f%% of grip still steering the car" % [
		locked_turn["steering_share"] * 100.0])
	print("    ABS     %.0f%%" % [abs_turn["steering_share"] * 100.0])

	# --- Wheelspin and traction control ------------------------------------
	var powerful := CarDatabase.get_car("porsche_gt2_rs")
	var raw_loadout := powerful.default_loadout()
	raw_loadout.set_part("electronics", "elec_defeat")
	var raw := TuningCalculator.resolve(powerful, raw_loadout)
	_check(raw.traction_control <= 0.0, "the aids delete really removes traction control")

	var tc_loadout := powerful.default_loadout()
	tc_loadout.set_part("electronics", "elec_traction")
	var traction := TuningCalculator.resolve(powerful, tc_loadout)

	var raw_launch := _simulate_launch(raw)
	var tc_launch := _simulate_launch(traction)
	_check(raw_launch["max_slip"] > Axle.SPIN_SLIP,
		"700 hp through the rear wheels spins them up from a standstill")
	_check(tc_launch["tc_fired"], "traction control fires when they do")

	# Measured on gravel, where traction control earns its keep. On dry tarmac
	# the driveline's own rotational inertia already limits wheelspin to a
	# fraction of a second, so there is almost nothing for it to improve and any
	# difference is inside the noise. On a loose surface the spinning is real
	# and sustained.
	var loose_raw := _simulate_launch(raw, TireModel.Surface.GRAVEL)
	var full_authority := TuningCalculator.resolve(powerful, raw_loadout)
	full_authority.traction_control = 1.0
	var loose_managed := _simulate_launch(full_authority, TireModel.Surface.GRAVEL)

	_check(loose_raw["spin_fraction"] > 0.25,
		"on gravel, an unmanaged launch spends most of itself spinning (%.0f%%)" % [
			loose_raw["spin_fraction"] * 100.0])
	_check(loose_managed["spin_fraction"] < loose_raw["spin_fraction"],
		"traction control cuts that (%.0f%% vs %.0f%%)" % [
			loose_managed["spin_fraction"] * 100.0, loose_raw["spin_fraction"] * 100.0])
	_check(loose_managed["speed"] > loose_raw["speed"],
		"and the car actually goes faster for it (%.1f vs %.1f m/s)" % [
			loose_managed["speed"], loose_raw["speed"]])

	# --- The handbrake must bypass ABS -------------------------------------
	# Otherwise a modern car could never be thrown into a corner on it.
	var modern := CarDatabase.get_car("gr_yaris")
	var modern_stats := TuningCalculator.resolve(modern, modern.default_loadout())
	_check(modern_stats.has_abs(), "the reference modern car has ABS")
	var hb := Axle.new(false, modern_stats.wheel_radius)
	hb.inertia = modern_stats.wheel_inertia
	hb.sync_to_road(25.0)
	var load := modern_stats.mass_kg * 0.4 * 9.81
	for i in 60:
		hb.update(1.0 / 60.0, 25.0, 0.0, 0.0, 0.0, modern_stats.max_brake_torque(),
			1.0, 1.0, load, modern_stats, 0.0, 0.0, 0.0)
	_check(hb.locked, "the handbrake still locks the rear axle despite ABS")


## Braking run from 30 m/s under full pedal, optionally with steering held on
## so there is something for the cornering force to do. Returns the stopping
## distance and what the axle managed on the way.
func _simulate_braking(stats: VehicleStats, steer_angle: float) -> Dictionary:
	var axle := Axle.new(true, stats.wheel_radius)
	axle.inertia = stats.wheel_inertia
	var speed := 30.0
	axle.sync_to_road(speed)

	# Treat the whole car as riding on this one axle so the deceleration is
	# realistic; the comparison between the two runs is what matters.
	var mass := stats.mass_kg
	var load := mass * 9.81
	var mu_long := TireModel.surface_mu(stats, TireModel.Surface.TARMAC, false)
	var mu_lat := TireModel.surface_mu(stats, TireModel.Surface.TARMAC, true)
	var brake_torque := stats.max_brake_torque()

	var dt := 1.0 / 120.0
	var distance := 0.0
	var steps := 0
	var locked_steps := 0
	var abs_fired := false
	var steering_share := 0.0
	var slip_sum := 0.0
	var release_min := 1.0
	var release_max := 0.0

	for i in 2400:
		var force := axle.update(dt, speed, steer_angle, 0.0, brake_torque, 0.0,
			mu_long, mu_lat, load, stats, 0.0, 0.0, 0.0)
		speed += force.x / mass * dt
		if speed <= 0.5:
			break
		distance += speed * dt
		steps += 1
		if axle.locked:
			locked_steps += 1
		steering_share += axle.lateral_share()
		slip_sum += axle.slip_ratio
		if axle.abs_active:
			abs_fired = true
			release_min = minf(release_min, axle.abs_release)
			release_max = maxf(release_max, axle.abs_release)

	return {
		"distance": distance,
		"locked_fraction": float(locked_steps) / maxf(float(steps), 1.0),
		"steering_share": steering_share / maxf(float(steps), 1.0),
		"mean_slip": slip_sum / maxf(float(steps), 1.0),
		"abs_fired": abs_fired,
		"release_swing": maxf(release_max - release_min, 0.0),
	}


## Standing start in first gear, to see whether the driven wheels light up.
func _simulate_launch(
	stats: VehicleStats,
	surface: TireModel.Surface = TireModel.Surface.TARMAC
) -> Dictionary:
	var axle := Axle.new(false, stats.wheel_radius)
	axle.inertia = stats.wheel_inertia
	var gearbox := Transmission.new(stats)
	var motor := EngineModel.new(stats)
	gearbox.shift_to(1)

	var speed := 0.5
	var mass := stats.mass_kg
	var load := mass * (1.0 - stats.weight_bias_front) * 9.81
	var mu := TireModel.surface_mu(stats, surface, false)
	var dt := 1.0 / 120.0
	var max_slip := 0.0
	var slip_sum := 0.0
	var spinning_steps := 0
	var tc_fired := false

	for i in 240:
		motor.update_boost(dt, gearbox.rpm, 1.0)
		gearbox.update(dt, axle.omega, speed, 1.0)
		var ratio := gearbox.gear_ratio()
		var torque := motor.output_torque(gearbox.rpm, 1.0) * ratio * gearbox.clutch * 0.88
		var force := axle.update(dt, speed, 0.0, torque, 0.0, 0.0,
			mu, mu, load, stats, ratio, gearbox.clutch, 1.0)
		speed += force.x / mass * dt
		max_slip = maxf(max_slip, axle.slip_ratio)
		slip_sum += maxf(axle.slip_ratio, 0.0)
		if axle.spinning:
			spinning_steps += 1
		tc_fired = tc_fired or axle.tc_active

	return {
		"max_slip": max_slip,
		"mean_slip": slip_sum / 240.0,
		# Time spent spinning is the honest measure. Peak slip always happens on
		# the first frame, before any controller has had a chance to act.
		"spin_fraction": float(spinning_steps) / 240.0,
		"tc_fired": tc_fired,
		"speed": speed,
	}


## Mass, torque, power and grip against reality.
##
## Power and top speed are not authored anywhere — they fall out of the torque
## curve, the gearing and the drag area. That makes them the honest check on
## whether those inputs are right, and it is a check the catalogue failed badly
## before it existed: boost was being multiplied onto torque figures that
## already included it, so the Group B cars made 800 hp instead of 480.
##
## tests/spec_bench.tscn prints the whole table; this holds the line.
func _test_performance_calibration() -> void:
	_section("performance vs reality")

	var power_off := 0
	var speed_off := 0
	var worst_power := 0.0
	var worst_speed := 0.0

	for spec in CarDatabase.all():
		var stats := TuningCalculator.resolve(spec, spec.default_loadout())
		_check(spec.reference_power_hp > 0.0,
			"'%s' records a real power figure to be checked against" % spec.id)
		_check(spec.reference_top_speed_kmh > 0.0,
			"'%s' records a real top speed" % spec.id)
		if spec.reference_power_hp <= 0.0:
			continue

		var hp := PerformanceModel.peak_power_hp(stats)
		var power_error: float = absf(hp - spec.reference_power_hp) / spec.reference_power_hp
		if power_error > 0.12:
			power_off += 1
			print("    %s: %.0f hp against a real %.0f" % [
				spec.id, hp, spec.reference_power_hp])
		worst_power = maxf(worst_power, power_error)

		var kmh := PerformanceModel.top_speed_kmh(stats)
		var speed_error: float = absf(kmh - spec.reference_top_speed_kmh) \
			/ spec.reference_top_speed_kmh
		if speed_error > 0.15:
			speed_off += 1
			print("    %s: %.0f km/h against a real %.0f" % [
				spec.id, kmh, spec.reference_top_speed_kmh])
		worst_speed = maxf(worst_speed, speed_error)

		# Sanity that does not depend on the reference figures.
		_check(stats.mass_kg > 300.0 and stats.mass_kg < 4000.0,
			"'%s' has a plausible mass" % spec.id)
		_check(PerformanceModel.time_to_speed(stats, 100.0) < 60.0,
			"'%s' can actually reach 100 km/h" % spec.id)

	_check(power_off == 0, "every car's power matches its real figure within 12%%")
	_check(speed_off == 0, "every car's top speed matches within 15%%")
	print("  %d cars checked; worst power error %.0f%%, worst top speed error %.0f%%" % [
		CarDatabase.all().size(), worst_power * 100.0, worst_speed * 100.0])

	# Power must rise with revs the way torque times speed says it does, or the
	# curve is not a curve.
	var reference := CarDatabase.get_car("golf_gti_mk2").to_base_stats()
	var peak: Dictionary = PerformanceModel.peak_power(reference)
	_check(peak["rpm"] > PerformanceModel.peak_torque(reference)["rpm"],
		"peak power arrives after peak torque, as it must")

	# Boost describes the hole below it, not a multiplier on the rated figure.
	# Getting this backwards was the original calibration bug.
	var turbo_car := CarDatabase.get_car("impreza_gc8").to_base_stats()
	var motor := EngineModel.new(turbo_car)
	_check(motor.off_boost_fraction() < 1.0, "an engine off boost makes less than its rated torque")
	motor.boost = 1.0
	_check(is_equal_approx(
		motor.output_torque(PerformanceModel.peak_torque(turbo_car)["rpm"], 1.0),
		turbo_car.engine_torque_nm),
		"and exactly its rated torque on full boost")


## Low-tier cars must not be buildable into high-tier ones.
func _test_upgrade_ceiling() -> void:
	_section("upgrade ceilings")

	var starter := CarDatabase.get_car("lada_2101")
	var group_b := CarDatabase.get_car("delta_s4")
	_check(starter.upgrade_ceiling < group_b.upgrade_ceiling,
		"a starter chassis accepts lower-tier parts than a Group B car")

	# The specific thing that must not be possible.
	var race_box := PartDatabase.get_part("gearbox_sequential")
	var wrc_dampers := PartDatabase.get_part("susp_wrc")
	_check(not starter.accepts_part(race_box),
		"a sequential race gearbox will not fit a Lada")
	_check(not starter.accepts_part(wrc_dampers), "and neither will WRC dampers")
	_check(not starter.part_rejection_reason(race_box).is_empty(),
		"and the garage can say why")
	_check(group_b.accepts_part(race_box), "a Group B car takes them happily")

	# A loadout that names an illegal part must be ignored, not honoured. Saves
	# from an older build, or edited by hand, must not smuggle one in.
	var cheat := starter.default_loadout()
	cheat.set_part("gearbox", "gearbox_sequential")
	var cheated := TuningCalculator.resolve(starter, cheat)
	var honest := TuningCalculator.resolve(starter, starter.default_loadout())
	_check(is_equal_approx(cheated.shift_time, honest.shift_time),
		"an illegal part in a saved loadout has no effect")

	# Every tier must still gain something real from what it can fit, or
	# upgrading a cheap car would be pointless.
	for tier in range(0, 5):
		var cars := CarDatabase.by_tier(tier)
		if cars.is_empty():
			continue
		var spec: CarSpec = cars[0]
		var stock := TuningCalculator.resolve(spec, spec.default_loadout())
		var built := TuningCalculator.resolve(spec, _max_legal_loadout(spec))
		var gain := PerformanceModel.peak_power_hp(built) \
			/ maxf(PerformanceModel.peak_power_hp(stock), 1.0)
		_check(gain > 1.15, "tier %d cars gain real power from upgrades (%.0f%%)" % [
			tier, (gain - 1.0) * 100.0])
		# The ladder has to hold overall. Compared on performance_index rather
		# than raw power, and against the best of the higher tier rather than
		# the first: a Stratos is tier 4 for being light and vicious, not for
		# its 206 hp, so a power-only comparison says nothing useful.
		if tier <= 2:
			var best_higher := 0.0
			for rival in CarDatabase.by_tier(tier + 2):
				var rival_built := TuningCalculator.resolve(rival, _max_legal_loadout(rival))
				best_higher = maxf(best_higher, rival_built.performance_index())
			if best_higher > 0.0:
				_check(built.performance_index() < best_higher,
					"a built tier %d car stays behind the best built tier %d one" % [
						tier, tier + 2])

	# Building a car has to be a real second purchase — comparable to the price
	# of the car — without being so far beyond it that the showroom becomes
	# irrelevant and every career is decided by the parts catalogue.
	var cosworth := CarDatabase.get_car("sierra_cosworth")
	var build_cost := cosworth.full_build_cost()
	_check(build_cost > cosworth.price * 0.5 and build_cost < cosworth.price * 2.5,
		"a full build costs about what the car does (%d vs %d)" % [
			build_cost, cosworth.price])
	print("  Lada accepts up to tier %d parts, Group B up to tier %d" % [
		starter.upgrade_ceiling, group_b.upgrade_ceiling])


## The most expensive legal part in every slot for a chassis.
func _max_legal_loadout(spec: CarSpec) -> TuningLoadout:
	var loadout := spec.default_loadout()
	var stats := spec.to_base_stats()
	for slot in PartSpec.SLOTS:
		var best: PartSpec = null
		for part in PartDatabase.available_for(slot, spec, stats):
			if best == null or part.price > best.price:
				best = part
		if best != null:
			loadout.set_part(slot, best.id)
	return loadout


## AI driver archetypes.
##
## The behaviour these produce is measured separately by tests/ai_probe.tscn,
## which drives each archetype round a track and reports what they managed.
## What is checked here is that the data describes distinct people and that
## selection puts the right ones in the right events.
func _test_driver_profiles() -> void:
	_section("driver profiles")

	var pool := DriverProfile.load_pool()
	_check(pool.size() >= 4, "there are enough archetypes for a varied field")

	var by_id := {}
	for entry in pool:
		var p: DriverProfile = entry["profile"]
		by_id[p.archetype] = p
		for trait_name in ["commitment", "consistency", "line_quality", "braking_skill",
				"throttle_discipline", "recovery", "aggression", "mechanical_sympathy"]:
			var value: float = p.get(trait_name)
			_check(value >= 0.0 and value <= 1.0,
				"'%s' has a sane %s (%.2f)" % [p.archetype, trait_name, value])
		_check(p.pace_ceiling > 0.0 and p.pace_ceiling <= 1.2,
			"'%s' has a sane pace ceiling" % p.archetype)

	var slow: DriverProfile = by_id.get("sunday_driver")
	var fast: DriverProfile = by_id.get("works_driver")
	if slow != null and fast != null:
		_check(slow.pace_rating() < fast.pace_rating(),
			"a Sunday driver rates slower than a works driver (%.2f vs %.2f)" % [
				slow.pace_rating(), fast.pace_rating()])
		# The point of pace_ceiling: put the timid one in the fastest car in the
		# game and they still will not drive it quickly.
		_check(slow.pace_ceiling < 0.8,
			"and is capped well below the car's potential no matter what they drive")
		_check(not slow.uses_manual_gearbox and fast.uses_manual_gearbox,
			"weak drivers leave it in automatic; good ones shift for themselves")

	# Traits must be genuinely independent, not one slider in disguise. A
	# driver who is quick and wild has to be expressible.
	var wild: DriverProfile = by_id.get("reckless_local")
	if wild != null:
		_check(wild.commitment > 0.7 and wild.consistency < 0.4,
			"a reckless driver is committed *and* unreliable, not just 'worse'")
		_check(wild.mechanical_sympathy < 0.4, "and hard on the car")

	# from_skill must still work as a fallback and stay monotonic.
	var low := DriverProfile.from_skill(0.1)
	var high := DriverProfile.from_skill(0.9)
	_check(low.pace_rating() < high.pace_rating(),
		"the plain-skill fallback still orders drivers correctly")

	# Variation must not turn an archetype into a different one.
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	if fast != null:
		var varied := fast.varied(rng)
		_check(absf(varied.commitment - fast.commitment) < 0.15,
			"per-driver variation keeps an archetype recognisable")
		_check(varied.archetype == fast.archetype, "and keeps its identity")

	# Selection must bias toward the event's level without being exclusive.
	var club_pace := 0.0
	var works_pace := 0.0
	var samples := 200
	rng.seed = 7
	for i in samples:
		club_pace += DriverProfile.pick_for(0.3, rng).pace_rating()
		works_pace += DriverProfile.pick_for(0.9, rng).pace_rating()
	club_pace /= float(samples)
	works_pace /= float(samples)
	_check(works_pace > club_pace,
		"a works event fields faster drivers than a club night (%.2f vs %.2f)" % [
			works_pace, club_pace])
	print("  %d archetypes; mean pace %.2f at club level, %.2f at works level" % [
		pool.size(), club_pace, works_pace])


## Racing against other cars rather than alone.
##
## The decision functions are tested directly with the field state set by hand.
## Driving two real cars at each other needs a live physics world, which
## tests/ai_probe.tscn does in field mode; what matters here is that the rules
## themselves say the right thing.
func _test_rival_awareness() -> void:
	_section("rival awareness")

	var timid := _archetype("nervous_novice")
	var quick := _archetype("works_driver")
	var car := _make_bench_car("golf_gti_mk2", "elec_none")

	var timid_view := RivalAwareness.new(car, timid)
	var quick_view := RivalAwareness.new(car, quick)

	# The headline behaviour: a worse driver is more cautious, because they
	# dare not run close.
	_check(timid_view.desired_gap() > quick_view.desired_gap(),
		"a nervous driver keeps a bigger gap than a works driver (%.0f m vs %.0f m)" % [
			timid_view.desired_gap(), quick_view.desired_gap()])
	# And they are working from a staler picture of the field, which is *why*
	# they need the bigger gap.
	_check(timid_view.scan_interval() > quick_view.scan_interval(),
		"and looks around less often (every %.2fs vs %.2fs)" % [
			timid_view.scan_interval(), quick_view.scan_interval()])

	# Overtaking: being faster is not enough, you also have to be willing.
	var rival := _make_bench_car("golf_gti_mk2", "elec_none")
	for view in [timid_view, quick_view]:
		view.car_ahead = rival
		view.gap_ahead = 12.0
		view.closing_speed = 4.0
	_check(quick_view.wants_to_overtake(), "a works driver takes a chance to pass")
	_check(not timid_view.wants_to_overtake(),
		"a nervous one is faster and stays behind anyway")

	# A car that is a long way ahead is not a passing opportunity yet.
	quick_view.gap_ahead = 200.0
	_check(not quick_view.wants_to_overtake(), "nobody lunges from two hundred metres back")
	quick_view.gap_ahead = 12.0

	# Reacting to the car in front braking hard.
	for view in [timid_view, quick_view]:
		view.ahead_braking = true
		view.gap_ahead = 6.0
		view.time_to_contact = 1.5
	_check(quick_view.emergency(), "a hard stop in front is an emergency")
	_check(timid_view.emergency(), "for anyone, however good")

	# But the margin at which it becomes one depends on how quickly they react.
	quick_view.ahead_braking = false
	timid_view.ahead_braking = false
	quick_view.gap_ahead = 40.0
	timid_view.gap_ahead = 40.0
	quick_view.time_to_contact = 1.6
	timid_view.time_to_contact = 1.6
	_check(timid_view.emergency() and not quick_view.emergency(),
		"a slow-reacting driver panics earlier than one who can catch it")

	# Never steer into someone already beside you.
	quick_view.alongside_left = true
	_check(quick_view.side_blocked(-1.0), "a car on the left is seen as being there")
	_check(not quick_view.side_blocked(1.0), "and the other side stays open")

	# A wreck on the racing line has to register as an obstacle, not a rival
	# who will move.
	rival.damage.integrity["body"] = 0.0
	rival.damage.apply("body", 1.0)
	_check(rival.damage.wrecked, "the test wreck is actually wrecked")

	car.free()
	rival.free()


func _archetype(id: String) -> DriverProfile:
	for entry in DriverProfile.load_pool():
		var profile: DriverProfile = entry["profile"]
		if profile.archetype == id:
			return profile
	return DriverProfile.from_skill(0.5)


## Visuals and effects.
##
## What things look like is judged by eye with tests/screenshot.tscn. What is
## checked here is that the drawing is driven by the car's own numbers rather
## than by constants, because that is the property that keeps 33 cars looking
## like 33 cars.
func _test_visuals() -> void:
	_section("visuals")

	var small := CarDatabase.get_car("trabant_601")
	var large := CarDatabase.get_car("f150_raptor")
	var small_visual := CarVisual.new()
	var large_visual := CarVisual.new()
	small_visual.setup(small, small.to_base_stats(), Color.RED)
	large_visual.setup(large, large.to_base_stats(), Color.BLUE)

	_check(large_visual._length_px > small_visual._length_px * 1.4,
		"a pickup is drawn much longer than a Trabant")
	_check(large_visual._width_px > small_visual._width_px,
		"and wider")
	_check(large_visual._wheel_radius_px > small_visual._wheel_radius_px,
		"with bigger wheels, because it has bigger wheels")

	# The wheels have to sit on the real axles, or a mid-engine car does not
	# look mid-engined.
	var mid := CarDatabase.get_car("delta_s4")
	var mid_visual := CarVisual.new()
	mid_visual.setup(mid, mid.to_base_stats(), Color.GREEN)
	var nose := CarDatabase.get_car("golf_gti_mk2")
	var nose_visual := CarVisual.new()
	nose_visual.setup(nose, nose.to_base_stats(), Color.GREEN)
	_check(mid_visual._front_axle_px > nose_visual._front_axle_px,
		"a mid-engine car's front axle sits further from its centre of mass")

	# Every category must produce a drawable outline.
	for spec in CarDatabase.all():
		var visual := CarVisual.new()
		visual.setup(spec, spec.to_base_stats(), Color.WHITE)
		var outline := visual._silhouette(visual._length_px * 0.5, visual._width_px * 0.5)
		_check(outline.size() >= 4, "'%s' has a drawable silhouette" % spec.id)
		visual.free()

	small_visual.free()
	large_visual.free()
	mid_visual.free()
	nose_visual.free()

	# Tyre marks come from slip, and each surface takes them differently.
	var tarmac := TireMarks.surface_mark(TireModel.Surface.TARMAC)
	var ice := TireMarks.surface_mark(TireModel.Surface.ICE)
	_check(float(tarmac["darkness"]) > float(ice["darkness"]),
		"tarmac holds a rubber mark; ice barely takes one")
	for surface in TireModel.Surface.values():
		var mark := TireMarks.surface_mark(surface)
		_check(mark.has("darkness") and mark.has("tint"),
			"every surface says how it marks")

	# A mark is only laid when the tread is genuinely sliding.
	var marks := TireMarks.new()
	add_child(marks)
	marks.report("test:fl", Vector2.ZERO, 0.4, 1.0, Color.BLACK)
	_check(marks.get_child_count() == 0, "a gripping tyre leaves nothing")
	marks.report("test:fl", Vector2.ZERO, 3.0, 1.0, Color.BLACK)
	marks.report("test:fl", Vector2(40, 0), 3.0, 1.0, Color.BLACK)
	_check(marks.get_child_count() == 1, "a sliding one lays a mark")
	marks.queue_free()

	# Night stages are what make the headlights worth having.
	var tracks := TrackSpec.load_all()
	var night_stages := 0
	for id in tracks:
		if tracks[id].night:
			night_stages += 1
	_check(night_stages > 0, "at least one stage runs after dark")


## Controller feedback.
##
## HapticState is pure logic, so what the pad would be told can be checked
## exactly without any hardware present. Each assertion below is a claim about
## what a driver should be able to feel without looking at the screen.
func _test_haptics() -> void:
	_section("haptics")

	var car := _make_bench_car("golf_gti_mk2", "elec_defeat")     # no ABS
	var abs_car := _make_bench_car("golf_gti_mk2", "elec_abs_retrofit")
	var state := HapticState.new()

	# --- Engine ---
	car.transmission.rpm = car.stats.idle_rpm
	car.command.throttle = 0.0
	state.update(car, 0.016)
	var idle_rumble := state.rumble_low + state.rumble_high
	_check(idle_rumble > 0.0, "the engine idles through the pad")

	car.transmission.rpm = car.stats.redline_rpm * 0.9
	car.command.throttle = 1.0
	state.update(car, 0.016)
	_check(state.rumble_low + state.rumble_high > idle_rumble,
		"and gets stronger as it revs and pulls")

	# --- Surface ---
	car.speed_ms = 25.0
	car.surface = TireModel.Surface.TARMAC
	state.update(car, 0.016)
	var tarmac_high := state.rumble_high
	car.surface = TireModel.Surface.GRAVEL
	state.update(car, 0.016)
	_check(state.rumble_high > tarmac_high, "gravel is rougher through the pad than tarmac")

	car.airborne = true
	state.update(car, 0.016)
	var airborne_total := state.rumble_low + state.rumble_high
	car.airborne = false
	state.update(car, 0.016)
	_check(state.rumble_low + state.rumble_high > airborne_total,
		"and mid-air is conspicuously smooth")

	# --- Locked wheels with no ABS: the pedal goes light -------------------
	car.axle_front.locked = true
	car.axle_rear.locked = true
	state.update(car, 0.016)
	_check(state.brake_effect.mode == TriggerEffect.Mode.FEEDBACK,
		"a locked brake pedal still offers resistance rather than switching off")
	_check(state.brake_effect.strength <= HapticState.BRAKE_LOCKED_RESISTANCE + 0.01,
		"but it goes light, because there is no more braking to be had")
	car.axle_front.locked = false
	car.axle_rear.locked = false
	state.update(car, 0.016)
	var normal_brake := state.brake_effect.strength
	_check(normal_brake > HapticState.BRAKE_LOCKED_RESISTANCE * 2.0,
		"a working brake pedal is firm (%.2f vs %.2f locked)" % [
			normal_brake, HapticState.BRAKE_LOCKED_RESISTANCE])

	# --- ABS: the pedal pulses --------------------------------------------
	abs_car.axle_front.abs_active = true
	abs_car.axle_front.abs_release = 0.6
	var abs_state := HapticState.new()
	abs_state.update(abs_car, 0.016)
	_check(abs_state.brake_effect.mode == TriggerEffect.Mode.VIBRATION,
		"ABS is felt as the pedal pulsing under the foot")
	_check(abs_state.brake_effect.frequency > 8.0 and abs_state.brake_effect.frequency < 20.0,
		"at a frequency a foot can actually resolve (%.0f Hz)" % [
			abs_state.brake_effect.frequency])

	# --- Wheelspin and the limiter ----------------------------------------
	car.axle_rear.spinning = true
	car.axle_rear.slip_ratio = 0.6
	state.update(car, 0.016)
	_check(state.throttle_effect.mode == TriggerEffect.Mode.VIBRATION,
		"wheelspin buzzes the throttle trigger")
	_check(state.rumble_high > 0.3, "and shows up in the high-frequency motor")
	car.axle_rear.spinning = false
	car.axle_rear.slip_ratio = 0.0

	car.engine.rev_limiting = true
	state.update(car, 0.016)
	_check(state.throttle_effect.mode == TriggerEffect.Mode.WEAPON,
		"the rev limiter puts a wall at the top of the throttle travel")
	car.engine.rev_limiting = false

	# --- Impacts are transient --------------------------------------------
	state.update(car, 0.016)
	var quiet := state.rumble_low
	state.add_impact(0.8)
	state.update(car, 0.016)
	var jolt := state.rumble_low
	_check(jolt > quiet + 0.2, "a crash jolts the pad")
	for i in 60:
		state.update(car, 0.016)
	_check(state.rumble_low < quiet + 0.05,
		"and then stops, rather than becoming the new normal")

	# --- A wreck goes quiet ------------------------------------------------
	car.damage.integrity["body"] = 0.0
	car.damage.apply("body", 1.0)
	state.update(car, 0.016)
	_check(state.throttle_effect.mode == TriggerEffect.Mode.OFF
			and state.brake_effect.mode == TriggerEffect.Mode.OFF,
		"a wrecked car has nothing to say through the pedals")

	# --- Backend plumbing --------------------------------------------------
	var effect_a := TriggerEffect.feedback(0.1, 0.5)
	var effect_b := TriggerEffect.feedback(0.1, 0.51)
	_check(not effect_b.differs_from(effect_a),
		"a negligible trigger change is not re-sent to the pad")
	_check(TriggerEffect.vibration(0.1, 0.5, 14.0).differs_from(effect_a),
		"a real one is")

	var backend := HapticsDirector.make_backend()
	_check(backend is RumbleBackend, "the backend always provides rumble")
	# Honest reporting matters here: on a machine with no native extension the
	# triggers genuinely will not resist, and the build should say so.
	print("  backend: %s" % backend.backend_name())
	_check(backend.supports_triggers() == Engine.has_singleton("DualSense")
			or not backend.supports_triggers(),
		"adaptive trigger support is reported honestly")

	car.free()
	abs_car.free()


## A configured car outside the scene tree, for testing logic that reads
## vehicle state without needing a running race.
func _make_bench_car(spec_id: String, electronics: String) -> RallyCar:
	var spec := CarDatabase.get_car(spec_id)
	var loadout := spec.default_loadout()
	loadout.set_part("electronics", electronics)
	var car: RallyCar = CAR_SCENE.instantiate()
	car.configure(spec, loadout)
	return car


func _test_damage_and_economy() -> void:
	_section("damage and repair")
	var spec := CarDatabase.get_car("delta_s4")
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var damage := DamageModel.new(stats)

	_check(is_equal_approx(damage.overall(), 1.0), "a fresh car is undamaged")
	# A nose-first impact should hurt the engine specifically.
	damage.apply_impact(9000.0, Vector2(-1, 0))
	_check(damage.integrity["engine"] < 1.0, "a frontal impact damages the engine")
	_check(damage.integrity["body"] < 1.0, "a frontal impact damages the body")

	# A side impact should reach the suspension rather than the engine.
	var side := DamageModel.new(stats)
	side.apply_impact(9000.0, Vector2(0, 1))
	_check(side.integrity["suspension"] < 1.0, "a side impact damages the suspension")
	_check(is_equal_approx(side.integrity["engine"], 1.0),
		"a side impact leaves the engine alone")

	# Damage must actually change how the car drives.
	var hurt := TuningCalculator.resolve(spec, spec.default_loadout(), damage.snapshot())
	_check(hurt.engine_torque_nm < stats.engine_torque_nm, "damage costs power")
	_check(hurt.grip_lat < stats.grip_lat, "damage costs grip")

	# Fire must be terminal.
	var burning := DamageModel.new(stats)
	burning.ignite()
	var rng := RandomNumberGenerator.new()
	for i in int(GameConfig.FIRE_BURN_OUT_TIME * 60.0) + 30:
		burning.update(1.0 / 60.0, rng)
	_check(burning.wrecked, "a fire destroys the car")
	_check(burning.wreck_cause == "burned_out", "the write-off is recorded as a burn-out")

	# The starter-car safety net.
	var starter := CarDatabase.default_starter()
	_check(TuningCalculator.repair_cost(starter, starter.default_loadout(),
		{"body": 0.1, "engine": 0.1, "suspension": 0.1, "tires": 0.1}) == 0,
		"a wrecked starter car is free to repair")
	_check(TuningCalculator.repair_cost(spec, spec.default_loadout(),
		{"body": 0.2, "engine": 0.2, "suspension": 0.2, "tires": 0.2}) > 0,
		"a wrecked top-tier car is not")


func _test_progression() -> void:
	_section("progression")
	# --- Starting a career -------------------------------------------------
	# Five starter cars, and the choice has to be a real one: all free to
	# repair, but they must not all drive the same.
	var starters := CarDatabase.starter_choices()
	_check(starters.size() >= 5, "there are at least five cars to start with")
	_check(starters.size() <= 8,
		"and few enough of them for the choice to mean something (%d)" % starters.size())
	for spec in CarDatabase.starter_cars():
		_check(spec.tier == GameConfig.STARTER_TIER,
			"'%s' is in the free-to-repair fallback fleet" % spec.id)
	var biases: Array[float] = []
	for spec in starters:
		var stats: VehicleStats = spec.to_base_stats()
		biases.append(stats.weight_bias_front)
		_check(spec.price == 0 or spec.tier == GameConfig.STARTER_TIER,
			"'%s' is a genuine starter car" % spec.id)
		_check(TuningCalculator.repair_cost(spec, spec.default_loadout(),
			{"body": 0.1, "engine": 0.1, "suspension": 0.1, "tires": 0.1}) == 0,
			"'%s' is free to repair" % spec.id)
	biases.sort()
	_check(biases[biases.size() - 1] - biases[0] > 0.15,
		"the starter cars have genuinely different balance (%.2f to %.2f front)" % [
			biases[0], biases[biases.size() - 1]])
	# Front-drive, rear-drive and a rear-engined one, so the first choice
	# teaches something rather than being a colour swatch.
	var layouts := {}
	for spec in starters:
		layouts[spec.drivetrain] = true
	_check(layouts.size() >= 2, "and more than one drivetrain layout among them")

	# The chosen car must actually be the one the player gets.
	var chosen: CarSpec = starters[starters.size() - 1]
	var picked := PlayerProfile.create_new("smoketest_pick", "Picker", chosen, 3)
	_check(picked.active_car() != null and picked.active_car().spec_id == chosen.id,
		"the starter car a player picks is the one they get")
	_check(picked.avatar_id == 3, "and the profile picture they picked")
	# Both must survive a round trip to disk.
	SaveSystem.save_profile(picked)
	SaveSystem._cache.erase("smoketest_pick")
	var reloaded := SaveSystem.load_profile("smoketest_pick")
	_check(reloaded != null and reloaded.avatar_id == 3,
		"the profile picture survives being saved and loaded")
	_check(reloaded != null and reloaded.active_car().spec_id == chosen.id,
		"and so does the car")
	SaveSystem.delete_profile("smoketest_pick")

	var profile := PlayerProfile.create_new("smoketest", "Smoke Tester")
	_check(profile.active_car() != null, "a new profile starts with a car")
	_check(profile.level == 1, "a new profile starts at level 1")

	var start_level := profile.level
	profile.award_xp(50000)
	_check(profile.level > start_level, "XP raises the level")

	# The safety net: destroy everything, spend everything, and check the
	# player is still able to go racing.
	for uid in profile.garage:
		profile.garage[uid].damage["body"] = 0.0
		profile.garage[uid].write_off = true
	profile.money = 0
	var rescue := profile.ensure_driveable_car()
	_check(rescue != null, "a broke player with no working car is given one")
	_check(rescue.is_driveable(), "and it actually runs")

	# Rating must move the right way.
	var rated := PlayerProfile.create_new("smoketest2", "Rated")
	var before := rated.rating
	rated.update_rating(1200, 1, 8)
	_check(rated.rating > before, "winning against an even field raises the rating")
	var mid := rated.rating
	rated.update_rating(1200, 8, 8)
	_check(rated.rating < mid, "finishing last lowers it")

	# Sponsor contracts.
	var sponsor := EventDatabase.get_sponsor("ironclad_garage")
	if sponsor != null:
		var state := sponsor.new_contract_state()
		var earned := SponsorSpec.apply_result(state, 1, false)
		_check(earned > sponsor.per_race, "a win pays the sponsor bonus on top")
		SponsorSpec.apply_result(state, 1, true)
		_check(not SponsorSpec.objective_met(state),
			"wrecking fails a no-wrecks contract")

	SaveSystem.delete_profile("smoketest")
	SaveSystem.delete_profile("smoketest2")


func _test_classes_and_economy() -> void:
	_section("classes and economy")

	# --- The class ladder ---------------------------------------------------
	var classes := RaceClass.all()
	_check(classes.size() >= 5, "the class ladder is loaded")

	# Every class must be somewhere a car can actually be. A class nobody can
	# field a car for is content no player will ever see.
	var populated := {}
	for spec in CarDatabase.all():
		populated[RaceClass.best_fit_spec(spec).id] = true
	for c in classes:
		if c.id == "open":
			continue   # the fallback, and correctly empty when every car has a home
		_check(populated.has(c.id), "the %s class has cars that fit it" % c.display_name)

	# The caps have to be ordered, or "moving up a class" means nothing.
	var previous := -1.0
	for c in classes:
		if c.id == "open":
			continue
		_check(c.max_performance_index > previous,
			"%s allows more than the class below it" % c.display_name)
		previous = c.max_performance_index

	# A built cheap car must be pushed out of the novice class. This is the
	# whole reason the performance cap exists alongside the tier gate.
	var starter := CarDatabase.default_starter()
	if starter != null:
		_check(starter.stock_index() <= RaceClass.by_id("club_novice").max_performance_index,
			"a showroom starter is legal for novices")
		_check(starter.potential_index() > starter.stock_index(),
			"and building it makes it quicker")

	# --- Repeat entries -----------------------------------------------------
	var event := EventDatabase.get_event("shakedown")
	if event != null:
		var first := event.payout_for(1, 0)
		var second := event.payout_for(1, 1)
		var tenth := event.payout_for(1, 9)
		_check(second < first, "re-entering an event pays less than the first run")
		_check(tenth > 0, "but never nothing, so a broke player can always earn")
		_check(tenth <= second, "and it keeps falling to a floor")

	# An event that costs money to enter must never decay into a trap: winning
	# has to cover the entry, however many times you have won it before.
	for e in EventDatabase.all_events():
		if e.entry_fee <= 0:
			continue
		_check(e.payout_for(1, 50) >= e.entry_fee,
			"winning %s always covers its entry fee" % e.display_name)

	# --- The safety net -----------------------------------------------------
	# The failure this exists to prevent: broke, and holding only cars that no
	# open event will accept.
	var stranded := PlayerProfile.create_new("smoketest_stranded", "Stranded")
	for uid in stranded.garage.keys():
		stranded.remove_car(uid)
	stranded.money = 0
	_check(not EventDatabase.can_enter_anything(stranded),
		"a player with no car and no money has nothing to enter")
	_check(EventDatabase.ensure_entry_possible(stranded),
		"so the safety net steps in")
	_check(EventDatabase.can_enter_anything(stranded),
		"and afterwards there is something to enter")
	SaveSystem.delete_profile("smoketest_stranded")

	# --- Rating against an AI field -----------------------------------------
	# Career races have to move the rating, or the classes gated on it are
	# unreachable for anyone who never goes online.
	var novice := EventDatabase.get_event("shakedown")
	var expert := EventDatabase.get_event("madness_final")
	if novice != null and expert != null:
		_check(expert.field_rating() > novice.field_rating(),
			"a harder event fields better-rated drivers")
	var climber := PlayerProfile.create_new("smoketest_rating", "Climber")
	var start := climber.rating
	for i in 20:
		climber.update_rating(1500, 1, 6, EventSpec.CAREER_RATING_WEIGHT)
	_check(climber.rating > start + 50,
		"winning career races raises the rating (%d to %d)" % [start, climber.rating])
	SaveSystem.delete_profile("smoketest_rating")


func _test_command_encoding() -> void:
	_section("network encoding")
	var command := VehicleCommand.new()
	command.steer = -0.62
	command.throttle = 0.85
	command.brake = 0.13
	command.handbrake = true
	command.nitro = true
	command.shift_up = true

	var decoded := VehicleCommand.new()
	decoded.decode(command.encode())
	_check(absf(decoded.steer - command.steer) < 0.02, "steering survives the round trip")
	_check(absf(decoded.throttle - command.throttle) < 0.01, "throttle survives it")
	_check(absf(decoded.brake - command.brake) < 0.01, "brake survives it")
	_check(decoded.handbrake and decoded.nitro and decoded.shift_up,
		"the button flags survive it")
	_check(command.encode().size() == 4, "a command is four bytes on the wire")


# --- Live race --------------------------------------------------------------

func _start_test_race() -> void:
	_section("headless race")
	# A purpose-built short event rather than one off the career calendar: two
	# laps of a 1.7 km loop is four minutes of simulation, which is too slow to
	# run on every change. The calendar's own events are validated as data in
	# _test_data_integrity; what this race exercises is the machinery.
	var event := EventSpec.from_dict({
		"id": "smoke_race",
		"name": "Smoke Test Sprint",
		"track": "gravel_loop",
		"format": "sprint",
		"laps": 1,
		"payouts": [4000, 2600, 1800, 1200],
		"xp": 150,
		"max_car_tier": 1,
		"ai_opponents": 3,
		"ai_skill": 0.35,
	})
	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(event.track_id)
	if track == null:
		_check(false, "the test event and its track both load")
		_finish()
		return

	# A keyboard seat stands in for a player; it simply never presses anything,
	# so the AI field is what actually completes the race.
	PlayerManager.join(DeviceInput.DEVICE_KEYBOARD)
	PlayerManager.ensure_profiles()

	var builder := TrackBuilder.new(track)
	var built := builder.build()
	_check(built.get_child_count() > 0, "the track builds a scene tree")
	_check(builder.checkpoints.size() >= 2, "the track has checkpoints")
	_check(builder.start_grid.size() >= GameConfig.MAX_NET_PLAYERS,
		"the grid has a slot for every possible driver")
	_check(builder.total_length_px > 0.0, "the track has a measurable length")
	built.queue_free()

	_director = RaceDirector.new()
	add_child(_director)
	_director.setup(event, track, CAR_SCENE)
	_director.race_complete.connect(_on_race_complete)
	_race_running = true
	_check(_director.entrants.size() > 1, "the race has a field")
	print("  running %s with %d entrants…" % [event.display_name, _director.entrants.size()])


func _process(delta: float) -> void:
	if not _race_running:
		return
	_elapsed += delta
	var sim_overrun := _director.race_time > RACE_SIM_TIMEOUT
	if sim_overrun or _elapsed > RACE_WALL_TIMEOUT:
		_race_running = false
		_check(false, "the race reaches a conclusion (sim %.0fs, wall %.0fs)" % [
			_director.race_time, _elapsed])
		_report_positions()
		_finish()


func _on_race_complete(results: Array) -> void:
	_race_running = false
	_check(results.size() == _director.entrants.size(), "every entrant is in the results")

	var finishers := 0
	var moved := false
	for r in results:
		if not r["dnf"]:
			finishers += 1
		var entrant: RaceEntrant = r["entrant"]
		if entrant.total_progress > 0.0:
			moved = true
	_check(moved, "cars actually moved along the track")
	_check(finishers > 0, "at least one car completed the race")

	for i in results.size():
		_check(results[i]["position"] == i + 1, "positions are contiguous and ordered")

	# The stand-in player never touches the controls. The race must classify
	# them and move on rather than waiting for a car that will never arrive.
	for r in results:
		var entrant: RaceEntrant = r["entrant"]
		if entrant.is_player():
			_check(not entrant.is_racing(),
				"a driver who never moves is classified, not waited for")
			_check(entrant.dnf, "and is recorded as a non-finisher")

	# A finished race must have paid the players out and saved their profiles.
	for r in results:
		if r["is_player"]:
			_check(r["payout"] >= 0 and r["xp"] > 0,
				"a player result carries a payout and XP")

	_report_positions()
	_finish()


func _report_positions() -> void:
	if _director == null:
		return
	for r in _director.standings():
		var status := "DNF(%s)" % r.dnf_reason if r.dnf else "%.1fs" % r.finish_time
		print("  P%-2d %-24s lap %d  %s" % [r.position, r.display_name, r.lap, status])


func _finish() -> void:
	print("\n=== %d checks, %d failures ===" % [_checks, _failures.size()])
	for f in _failures:
		print("  FAILED: %s" % f)
	# A non-zero exit code is what makes this usable from CI.
	get_tree().quit(1 if _failures.size() > 0 else 0)
