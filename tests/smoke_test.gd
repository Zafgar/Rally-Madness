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

## The tightest centreline radius any stage may contain, in metres.
##
## A road narrower in radius than this is not a corner, it is a wall: the inside
## edge closes to nothing and no car in the game can steer round it. Set just
## under the quarry stages, which are deliberately the tightest thing here and
## are drivable.
const MIN_DRIVABLE_RADIUS_M := 12.0


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
	_test_every_script_parses()
	_test_the_listener_rides_in_the_car()
	_test_screens_can_be_reached_with_a_pad()
	_test_no_stage_is_a_ring()
	_test_the_recce()
	_test_rival_awareness()
	_test_visuals()
	_test_direction_selection()
	_test_grid_launch()
	_test_haptics()
	_test_damage_and_economy()
	_test_used_market()
	_test_progression()
	_test_classes_and_economy()
	_test_mechanical_model()
	_test_audio()
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
				# And it stands clear of everything a car is allowed to drive
				# on. A barrel in the racing line is not scenery: the camera
				# shows two seconds of road, so the only way to learn it is
				# there is to hit it. The builder used to clamp `side` to ±1
				# and then multiply by 0.82, which put every prop on the road
				# no matter what the data asked for.
				#
				# Checked against what the data asks for, not against what the
				# builder ends up doing: the builder holds props clear as a
				# backstop, and a test that only measures the backstop would
				# pass however wrong the data was.
				var reach: float = absf(float(entry["side"])) * track.width * 0.5
				var clear: float = track.width * 0.5 + track.run_off \
					+ TrackBuilder.PROP_CLEARANCE_M + prop.radius_m
				_check(reach >= clear,
					"track '%s' asks for '%s' off the road (%.1f m out, needs %.1f)" % [
						id, entry["prop"], reach, clear])
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


## Every front-end screen has something a pad can move from.
##
## Godot moves focus between controls when a d-pad direction is pressed, and it
## moves it *from* whatever holds focus now. With nothing focused, nothing
## happens — which is why the whole front end was mouse-only despite every
## screen having been given focus styling. There is no way to check "a pad can
## navigate this" headless, but there is a way to check the thing whose absence
## made it impossible.
func _test_screens_can_be_reached_with_a_pad() -> void:
	_section("navigating without a mouse")

	var profile := PlayerProfile.create_new("focus_test", "Focus",
		CarDatabase.default_starter(), 0)
	profile.money = 60000
	# A second car, so the garage has a list rather than a single row.
	profile.add_car(CarDatabase.get_car("golf_gti_mk2"))

	var screens := {
		"career hub": func():
			var s := CareerHub.new()
			s.profile = profile
			return s,
		"calendar": func():
			var s := CareerScreen.new()
			s.profile = profile
			return s,
		"garage": func():
			var s := GarageScreen.new()
			s.profile = profile
			return s,
		"showroom": func():
			var s := ShowroomScreen.new()
			s.profile = profile
			return s,
		"tuning shop": func():
			var s := TuningScreen.new()
			s.profile = profile
			s.car = profile.active_car()
			return s,
		"settings": func():
			return SettingsScreen.new(),
	}
	for name in screens:
		var screen: Control = screens[name].call()
		add_child(screen)
		var target := UiTheme.first_focusable(screen)
		_check(target != null, "the %s has something a pad can start on" % name)
		screen.queue_free()

	# A disabled choice must not be the thing a pad starts on. The opening
	# screen greeted every new player with the highlight sitting on CAREER,
	# which is greyed out until a career exists — so the first button anybody
	# pressed did nothing, and a controller that does nothing reads as broken.
	var holder := VBoxContainer.new()
	add_child(holder)
	var dead := Button.new()
	dead.text = "Not yet"
	UiTheme.set_disabled(dead, true)
	holder.add_child(dead)
	var live := Button.new()
	live.text = "Go"
	holder.add_child(live)
	_check(UiTheme.first_focusable(holder) == live,
		"a pad starts on the first button it can actually press")

	# Emptying a list has to take effect now, not at the end of the frame.
	#
	# This is the bug that killed the pad on the opening screen: taking a seat
	# rebuilt the seat cards and the action buttons, the rebuild used
	# queue_free, and the "has anything still got focus?" check that follows it
	# ran while the doomed button was still alive and still focused. It decided
	# nothing needed doing. The button was deleted a moment later and the
	# screen was left with no focus at all and no way to get any back.
	#
	# Asserting on queue_free directly is what made this untestable before —
	# a synchronous check sees a perfectly valid node either way. Detaching
	# first is what makes it observable: leaving the tree releases focus at
	# once, so both halves of this check fail against the old code.
	live.grab_focus()
	_check(get_viewport().gui_get_focus_owner() == live, "a button can take focus")
	UiTheme.clear(holder)
	_check(holder.get_child_count() == 0, "clearing a list empties it immediately")
	_check(get_viewport().gui_get_focus_owner() == null,
		"and the screen knows it has lost focus in the same frame")
	holder.queue_free()


func _collect_rows(node: Node, into: Array[Button]) -> void:
	for child in node.get_children():
		if child is Button and (child as Button).toggle_mode:
			into.append(child as Button)
		_collect_rows(child, into)


## The world is heard from the car, not from the camera.
##
## A viewport with no listener of its own hears everything from its current
## Camera2D, and the chase camera deliberately is not on the car — it smooths
## its follow and leads the direction of travel, so at speed it sits ten or
## fifteen metres away. Every engine in the game panned and faded as though it
## were somewhere behind its own car.
func _test_the_listener_rides_in_the_car() -> void:
	_section("where the world is heard from")

	var car := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(car)
	var camera := ChaseCamera.new()
	add_child(camera)
	camera.set_target(car)

	var ear: AudioListener2D = camera.get_node_or_null("Ear")
	_check(ear != null, "the camera carries a listener")
	if ear == null:
		camera.queue_free()
		car.queue_free()
		return
	_check(ear.is_current(), "and it is the one the viewport uses")

	# Drag the camera well away from the car, exactly as leading and smoothing
	# do at speed, and step it. The ear has to end up on the car.
	car.global_position = Vector2(4000, 1500)
	camera.global_position = Vector2(0, 0)
	camera._physics_process(1.0 / 60.0)
	var camera_gap := camera.global_position.distance_to(car.global_position)
	var ear_gap := ear.global_position.distance_to(car.global_position)
	_check(camera_gap > 100.0,
		"the camera is still somewhere else after a frame (%.0f px)" % camera_gap)
	_check(ear_gap < 1.0,
		"and the listener is on the car (%.1f px away)" % ear_gap)

	camera.queue_free()
	car.queue_free()

	# And the viewport the player is actually looking through has to be
	# listening at all.
	#
	# The listener above was correct and did nothing, for months, because a
	# SubViewport does not process 2D listeners unless it is told to and
	# nothing told it to. Every AudioStreamPlayer2D in the game was therefore
	# panned against the only viewport that was listening — the root, which has
	# no camera in it during a race and so sits at a fixed point in the middle
	# of the world. That is why the engines came from somewhere off to one
	# side, swelled when the car happened to pass that spot, and faded out
	# when it drove away. Two separate flags, both wrong, and the symptom of
	# each is the same.
	var seats: Array = [PlayerManager.get_seat(0)]
	if seats[0] == null:
		seats = [PlayerManager.join(DeviceInput.DEVICE_KEYBOARD)]
	var split := SplitScreen.new()
	add_child(split)
	split.build(seats, get_viewport().world_2d)
	var listening := 0
	for view in split.views:
		if (view["viewport"] as SubViewport).audio_listener_enable_2d:
			listening += 1
	_check(listening == split.views.size(),
		"every seat's viewport is listening (%d of %d)" % [listening, split.views.size()])
	_check(not get_viewport().audio_listener_enable_2d,
		"and the cameraless root viewport is not listening over the top of them")
	split.queue_free()


## Every script in the project has to parse.
##
## This exists because of a bug that could not have been found any other way
## here. A test harness referenced RaceScene.NIGHT_LIGHT, and RaceScene had no
## class_name, so the identifier did not resolve. Nothing caught it: a headless
## run only loads the scripts it actually uses, and nothing in this suite used
## that harness. The editor loads everything, so the first person to open the
## project got a parse error on a file that had been broken for a while.
##
## Loading a GDScript parses it without running any of it, so this is cheap and
## it covers the tools and benches as well as the game.
func _test_every_script_parses() -> void:
	_section("every script parses")
	var checked := 0
	var broken: Array[String] = []
	for folder in ["res://scripts", "res://tests", "res://scenes"]:
		checked += _parse_folder(folder, broken)
	for path in broken:
		_check(false, "%s parses" % path)
	_check(broken.is_empty(),
		"all %d scripts in the project parse (%d broken)" % [checked, broken.size()])


func _parse_folder(path: String, broken: Array[String]) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with("."):
				count += _parse_folder(full, broken)
		elif name.ends_with(".gd"):
			count += 1
			# load() makes the parser run over the file, but it does not return
			# null when the parse fails — it hands back a GDScript that could
			# not be compiled, and the first version of this test happily
			# accepted them. can_instantiate() is the flag that actually tells
			# the two apart, verified against a deliberately broken script.
			var script := load(full)
			if script == null or (script is GDScript and not script.can_instantiate()):
				broken.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return count


## No stage in the game is a plain ring.
##
## "A big circle you just hold flat is a boring track" is a complaint that turns
## out to be measurable, and measuring it is what showed how bad it was: several
## stages never changed direction at all, and two of them carried the game's
## finales. Corners per kilometre alone will not catch it — the recce counts
## anything tighter than a ninety-metre radius as a corner, so a constant-radius
## ring scores as nothing but corner and looks excellent on paper.
##
## What tells them apart is how often the road changes hands. A ring scores
## exactly zero. Anything a driver would call a route scores several per
## kilometre, because that is what makes them keep working.
func _test_no_stage_is_a_ring() -> void:
	_section("stages are routes, not rings")

	# An arena is exempt, and only an arena. A demolition derby is held in a
	# bowl because a bowl is the point — there is no route to be twisty, and
	# ninety metres of it is width.
	var arenas := ["derby_bowl"]

	for id in TrackSpec.load_all():
		if arenas.has(id):
			continue
		var spec: TrackSpec = TrackSpec.load_all()[id]
		var builder := TrackBuilder.new(spec)
		# The centreline only: everything measurable about a stage comes from
		# it, and building the collision shapes and the scenery for two dozen
		# tracks costs a minute for nothing.
		builder.walk()
		var model := TrackModel.analyse(builder)
		var km := maxf(model.length_m / 1000.0, 0.001)

		var changes := 0
		for i in range(1, model.corners.size()):
			if signf(model.corners[i].direction) != signf(model.corners[i - 1].direction):
				changes += 1
		if model.closed and model.corners.size() >= 2:
			if signf(model.corners[0].direction) \
					!= signf(model.corners[model.corners.size() - 1].direction):
				changes += 1

		_check(model.corners.size() >= 3,
			"'%s' has corners to speak of (%d)" % [id, model.corners.size()])
		# Both a count and a rate. The rate alone would let a very long stage
		# pass on three switchbacks in eight kilometres; the count alone would
		# fail a nine-hundred-metre sprint that is busy the whole way round.
		_check(changes >= 3 and float(changes) / km >= 1.0,
			"'%s' turns both ways (%d changes, %.1f per km over %.2f km)" % [
				id, changes, float(changes) / km, km])


## The recce: reading a road, finding a line through it, and solving what a
## given car can do on it.
##
## Every claim here is one that can be wrong silently. A line that is slower
## than the centreline still looks like a line; a speed profile that ignores the
## car it was given still returns numbers. Both of those shipped during
## development and both were caught here rather than by watching a race.
func _test_the_recce() -> void:
	_section("reading the road")

	var spec: TrackSpec = TrackSpec.load_all().get("gravel_loop")
	if spec == null:
		_check(false, "the bench track exists")
		return
	var builder := TrackBuilder.new(spec)
	builder.build()
	var model := TrackModel.analyse(builder)

	_check(model.length_m > 100.0, "the road has a length (%.0f m)" % model.length_m)
	_check(model.positions.size() > 20, "and enough samples to read it (%d)"
		% model.positions.size())

	# Corners have to be corners. A road sampled every three metres produces a
	# little curvature noise everywhere, and without a length threshold that
	# noise becomes a hundred one-sample "corners" — which looks like a working
	# corner finder right up until the AI tries to plan for them.
	var shortest := 100000.0
	for corner in model.corners:
		shortest = minf(shortest, corner.length_m())
		_check(corner.min_radius > 0.5,
			"corner at %.0f m has a real radius (%.0f m)" % [
				corner.entry_s, corner.min_radius])
	if not model.corners.is_empty():
		_check(shortest >= TrackModel.MIN_CORNER_LENGTH_M - 0.01,
			"no corner is shorter than the threshold (%.0f m)" % shortest)

	# A corner has to be found where the road actually bends.
	var bendiest := 0
	for i in model.curvature.size():
		if absf(model.curvature[i]) > absf(model.curvature[bendiest]):
			bendiest = i
	if absf(model.curvature[bendiest]) > TrackModel.CORNER_CURVATURE:
		_check(model.corner_at(model.distance_of(bendiest)) != null,
			"the tightest point on the road is inside a corner")

	# --- The line ------------------------------------------------------------
	var line := RacingLine.solve(model)
	var half := model.width_m * 0.5
	var widest := 0.0
	for value in line.offsets:
		widest = maxf(widest, absf(value))
	_check(widest <= half,
		"the line stays on the road (%.1f m from centre, half-width %.1f)" % [
			widest, half])
	# The one claim the whole thing rests on. A "racing line" measurably slower
	# than the road it is drawn on is worse than no line at all, and two
	# separate implementations produced exactly that before this check existed.
	_check(line.gain_over_centreline() >= 0.0,
		"and is never slower through a corner than the centreline (%.1f%%)"
			% line.gain_over_centreline())

	# --- The profile ---------------------------------------------------------
	var slow_car := CarDatabase.get_car("trabant_601")
	var fast_car := CarDatabase.get_car("delta_s4")
	var slow := SpeedProfile.solve(model, line,
		TuningCalculator.resolve(slow_car, slow_car.default_loadout()))
	var fast := SpeedProfile.solve(model, line,
		TuningCalculator.resolve(fast_car, fast_car.default_loadout()))
	_check(fast.lap_estimate() < slow.lap_estimate(),
		"a Group B car is quicker round it than a Trabant (%.1fs against %.1fs)" % [
			fast.lap_estimate(), slow.lap_estimate()])
	for v in fast.speeds:
		if v <= 0.5:
			_check(false, "every target speed is a speed the car can drive")
			break

	# Parts have to reach the driving. If they do not, the garage is decoration.
	var base := CarDatabase.get_car("impreza_gc8")
	var built := base.default_loadout()
	built.set_part("tires", "tires_gravel")
	var stock_lap := SpeedProfile.solve(model, line,
		TuningCalculator.resolve(base, base.default_loadout())).lap_estimate()
	var built_lap := SpeedProfile.solve(model, line,
		TuningCalculator.resolve(base, built)).lap_estimate()
	_check(built_lap < stock_lap,
		"gravel tyres make the car quicker on gravel (%.1fs against %.1fs)" % [
			built_lap, stock_lap])

	# --- Corner boards -------------------------------------------------------
	# A board is only useful if it is somewhere a driver will see it and nowhere
	# a driver will hit it, and both of those are geometry rather than opinion.
	var boards := CornerBoards.new()
	boards.build(model)
	var marked := 0
	for corner in model.corners:
		if corner.min_radius <= CornerBoards.WORTH_MARKING_RADIUS:
			marked += 1
	if marked > 0:
		_check(boards._chevrons.size() >= marked,
			"every corner worth marking gets chevrons (%d for %d corners)" % [
				boards._chevrons.size(), marked])
		_check(boards._boards.size() > 0,
			"and there are countdown boards before them (%d)" % boards._boards.size())
	# The verge, not the road. A sign in the racing line is not a warning, it is
	# the thing the warning was about.
	_check(CornerBoards.VERGE_OFFSET_M > 0.0,
		"boards stand outside the road edge (%.1f m clear)"
			% CornerBoards.VERGE_OFFSET_M)
	# And on the outside of the bend, which is where a driver is looking on the
	# way in — the inside is where the apex is and where the car will be.
	for entry in boards._chevrons:
		var corner := model.corner_at(model.distance_of(int(entry["index"])))
		if corner == null:
			continue
		_check(is_equal_approx(float(entry["side"]), -corner.direction),
			"and chevrons stand on the outside of the corner they mark")
		break

	# --- The calibration -----------------------------------------------------
	# The plan is only worth having if the grip it assumes is grip the car has.
	# Both of these numbers were wrong once and both failures looked identical
	# from outside: the field crashed, and it crashed worse the faster it was.
	# The grip probe measures them against real cars; this stops them drifting
	# back up without anybody re-running it.
	for id in ["trabant_601", "impreza_gc8", "porsche_gt2_rs"]:
		var probe_car := CarDatabase.get_car(id)
		var probe_stats := TuningCalculator.resolve(
			probe_car, probe_car.default_loadout())
		for surface in [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL]:
			var peak := TireModel.surface_mu(probe_stats, surface, true) * 9.81
			var corner := SpeedProfile.cornering_accel(probe_stats, surface)
			var stop := SpeedProfile.straight_line_decel(probe_stats, surface)
			_check(corner < peak * 0.70,
				"%s plans to corner below peak grip on %s (%.1f of %.1f)" % [
					probe_car.display_name(), TireModel.surface_name(surface),
					corner, peak])
			_check(stop < peak * 0.70,
				"and to brake below it (%.1f of %.1f)" % [stop, peak])

	# The braking point is the whole reason the profile exists. Somewhere before
	# the tightest corner there has to be a point where the plan is already
	# asking for less speed than the straight before it allows.
	if not model.corners.is_empty():
		var tightest: TrackModel.Bend = model.corners[0]
		for corner in model.corners:
			if corner.min_radius < tightest.min_radius:
				tightest = corner
		var at_apex := fast.speed_at(tightest.apex_s)
		var before := fast.speed_at(tightest.entry_s - 60.0)
		_check(before > at_apex,
			"the plan is slower at the apex than sixty metres before it (%.0f against %.0f km/h)"
				% [at_apex * 3.6, before * 3.6])
		var braking := fast.distance_to_slower(tightest.entry_s - 60.0, before, 120.0)
		_check(braking < INF,
			"and there is a braking point in front of it (%.0f m ahead)" % braking)


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

	# At a road speed, because a following distance is a time: standing still,
	# every driver alive leaves the same car length and there is nothing to
	# tell them apart.
	car.speed_ms = 30.0

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
		# A rival being caught, not a parked one: those are different decisions
		# and leaving this at zero was quietly testing the second.
		view.speed_ahead = 26.0
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

	# --- Instrument clusters ------------------------------------------------
	# The point of per-car gauges is that they differ, and the rules that pick
	# them are stacked in a specific order — an F40 is a hypercar, a classic
	# and an Italian, and only one of those is the dashboard it had. A rule
	# added in the wrong place silently steals cars from another.
	var clusters := {}
	for car_spec in CarDatabase.all():
		var style := DashboardCluster.style_for(car_spec,
			car_spec.to_base_stats())
		clusters[style] = int(clusters.get(style, 0)) + 1
	_check(clusters.size() >= 8,
		"the field is spread across the instrument styles (%d of %d in use)" % [
			clusters.size(), DashboardCluster.Style.size()])
	for style in DashboardCluster.Style.values():
		var palette := DashboardCluster._palette_for(style)
		_check(palette.has("face") and palette.has("needle") and palette.has("warn"),
			"instrument style %d has a complete palette" % style)

	var expectations := {
		"ferrari_f40": DashboardCluster.Style.VEGLIA,
		"alfa_gtv6": DashboardCluster.Style.VEGLIA,
		"mustang_gt_fox": DashboardCluster.Style.MUSCLE,
		"corvette_c5_z06": DashboardCluster.Style.MUSCLE,
		# Still a truck, despite the badge on the front of it.
		"f150_raptor": DashboardCluster.Style.TRUCK,
		# Still Group B, despite being Italian.
		"delta_s4": DashboardCluster.Style.GROUP_B,
		# Still the cheapest instrument that would pass type approval, despite
		# being Italian.
		"fiat_126p": DashboardCluster.Style.SEVENTIES,
		"porsche_gt2_rs": DashboardCluster.Style.PORSCHE,
	}
	for id in expectations:
		var car_spec := CarDatabase.get_car(id)
		if car_spec == null:
			continue
		_check(DashboardCluster.style_for(car_spec, car_spec.to_base_stats())
				== expectations[id],
			"%s gets the cluster it had" % car_spec.display_name())

	# Every category must produce a drawable outline, and every car must be the
	# shape a car is. These are the checks that would have caught the artwork
	# being wrong: the bodies were drawn 1.4x their wheelbase when real cars are
	# 1.65x, so the wheels hung out past the bumpers, and the body width was a
	# multiple of track that had no idea how wide the tyres beneath it were, so
	# they hung out of the sides as well.
	for spec in CarDatabase.all():
		var visual := CarVisual.new()
		var stats := spec.to_base_stats()
		visual.setup(spec, stats, Color.WHITE)
		var half_l := visual._length_px * 0.5
		var half_w := visual._width_px * 0.5
		var outline := visual._silhouette(half_l, half_w)
		_check(outline.size() >= 4, "'%s' has a drawable silhouette" % spec.id)

		var ppm := GameConfig.PIXELS_PER_METRE
		var wheel_edge := stats.track_width_m * 0.5 * ppm + visual._wheel_width_px
		_check(wheel_edge <= half_w,
			"'%s' keeps its tyres inside its bodywork" % spec.id)
		var axle_edge: float = maxf(visual._front_axle_px, absf(visual._rear_axle_px)) \
			+ visual._wheel_radius_px
		_check(axle_edge <= half_l,
			"'%s' keeps its wheels inside its bumpers" % spec.id)

		# Proportion, against the real cars: a saloon is about two and a half
		# times as long as it is wide, and nothing on the road is under two.
		var ratio := visual._length_px / visual._width_px
		# The stubbiest real car in the fleet is the Sport quattro S1 at 2.28,
		# and the longest for its width is the Raptor. Nothing should fall
		# outside that with room to spare.
		_check(ratio > 1.95 and ratio < 3.2,
			"'%s' is %.2f times as long as it is wide" % [spec.id, ratio])

		# The cabin has to be on the car, not hanging off either end of it.
		var cabin := visual._cabin(half_l, half_w)
		_check(float(cabin["screen_front"]) < half_l and float(cabin["screen_rear"]) > -half_l,
			"'%s' has its cabin between its bumpers" % spec.id)
		visual.free()

	# A turbo over the back axle is fed through the flanks, not through a hole
	# in a bonnet with nothing under it.
	var rear_engined := CarVisual.new()
	rear_engined.setup(CarDatabase.get_car("porsche_992_c4s"),
		CarDatabase.get_car("porsche_992_c4s").to_base_stats(), Color.WHITE)
	_check(not rear_engined._has_scoop and rear_engined._has_side_intakes,
		"a rear-engined turbo car takes its air in through the sides")
	var front_engined := CarVisual.new()
	front_engined.setup(CarDatabase.get_car("impreza_gc8"),
		CarDatabase.get_car("impreza_gc8").to_base_stats(), Color.WHITE)
	_check(front_engined._has_scoop and not front_engined._has_side_intakes,
		"a front-engined turbo car takes it in through the bonnet")
	rear_engined.free()
	front_engined.free()

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

	# --- Stage geometry -------------------------------------------------------
	# A stage must not pass close to a distant part of itself. A car's position
	# on the road is worked out from the nearest point on the centreline, so at
	# a crossing that answer is ambiguous and a car can be credited with a
	# kilometre it never drove. Two of the new stages did exactly this, and it
	# is invisible from inside the car — you have to look at the map.
	for id in TrackSpec.load_all():
		var stage: TrackSpec = TrackSpec.load_all()[id]
		var curve := stage.build_curve()
		if curve.point_count < 2:
			continue
		var total := curve.get_baked_length()
		var ppm := GameConfig.PIXELS_PER_METRE
		# Sampled every twenty metres, which is fine enough to catch a crossing
		# and coarse enough to run on every stage on every test run.
		var samples := PackedVector2Array()
		var walk := 0.0
		while walk <= total:
			samples.append(curve.sample_baked(walk))
			walk += 20.0 * ppm
		var clearance := stage.width * 1.2 * ppm
		var worst := INF
		for a in samples.size():
			for b in range(a + 1, samples.size()):
				var apart_along := float(b - a) * 20.0 * ppm
				if stage.closed:
					apart_along = minf(apart_along, total - apart_along)
				# Only parts of the road that are a long way apart along it.
				if apart_along < clearance * 4.0:
					continue
				worst = minf(worst, samples[a].distance_to(samples[b]))
		_check(worst > clearance,
			"'%s' never doubles back onto itself (closest %.0f m, needs %.0f)" % [
				id, worst / ppm, clearance / ppm])

		# And a stage has to be long enough to be a stage.
		_check(total / ppm > 400.0,
			"'%s' is %.0f m long" % [id, total / ppm])

	# Night stages are what make the headlights worth having.
	var tracks := TrackSpec.load_all()
	var night_stages := 0
	for id in tracks:
		if tracks[id].night:
			night_stages += 1
	_check(night_stages > 0, "at least one stage runs after dark")

	# No corner may be tighter than a car can go round.
	#
	# Harbour Night had a four-metre radius where its last waypoint overshot the
	# start line, so closing the loop needed a hundred-and-eighty-seven-degree
	# reversal. Fjord Road had an eight-metre one where a single waypoint
	# carried a whole switchback. Neither is a corner; both are a wall you drive
	# into, and the second was reported as a stage you could not get out of.
	# Nothing here could see them — the road is generated from a spline, so a
	# bad waypoint produces a perfectly valid road that happens to be
	# undrivable.
	for id in tracks:
		var built := TrackBuilder.new(tracks[id])
		built.build()
		var road := TrackModel.analyse(built)
		var tightest := 100000.0
		for i in road.curvature.size():
			tightest = minf(tightest, road.radius_at(i))
		_check(tightest >= MIN_DRIVABLE_RADIUS_M,
			"'%s' has nothing tighter than a car can turn (%.0f m)" % [id, tightest])


## Controller feedback.
##
## HapticState is pure logic, so what the pad would be told can be checked
## exactly without any hardware present. Each assertion below is a claim about
## what a driver should be able to feel without looking at the screen.
## Selecting a direction in an automatic.
##
## Reverse is worth its own test because it went wrong twice in opposite
## directions: first it would not engage at all, and then the fix for that made
## braking to a standstill select it and drive the car backwards out of the
## corner. Both are checked here.
func _test_direction_selection() -> void:
	_section("choosing a direction")

	var car := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(car)
	var dwell: float = RallyCar.REVERSE_ENGAGE_DWELL
	var step := 1.0 / 60.0

	# Stationary, brake held: reverse, after the dwell and not before.
	car.transmission.engage_for(1)
	car._reverse_dwell = 0.0
	car._auto_engage_gear(step, 0.0, 0.0, 1.0)
	_check(car.transmission.gear >= 0,
		"a single frame of brake at a standstill does not select reverse")
	var frames := int(ceil(dwell / step)) + 2
	for i in frames:
		car._auto_engage_gear(step, 0.0, 0.0, 1.0)
	_check(car.transmission.gear < 0,
		"holding it for %.2f s does" % dwell)

	# The bug the fix created: over-braking into a hairpin must not select
	# reverse, because in reverse the brake pedal is the accelerator. A driver
	# who stops a fraction too early sits on the brake for a couple of tenths
	# before turning in, and that must not launch them backwards.
	var stopping := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(stopping)
	stopping.transmission.engage_for(1)
	stopping._reverse_dwell = 0.0
	var speed := 12.0
	while speed > 0.0:
		stopping._auto_engage_gear(step, speed, 0.0, 1.0)
		speed = maxf(speed - 0.30, 0.0)
	for i in int(0.25 / step):
		stopping._auto_engage_gear(step, 0.0, 0.0, 1.0)
	_check(stopping.transmission.gear > 0,
		"over-braking into a corner leaves the car in a forward gear")

	# And keeping the brake on past that still gets you reverse — the dwell
	# delays it, it does not deny it.
	for i in frames:
		stopping._auto_engage_gear(step, 0.0, 0.0, 1.0)
	_check(stopping.transmission.gear < 0,
		"and holding the brake after that still selects reverse")

	# Throttle always wins, immediately, in either direction.
	stopping._auto_engage_gear(step, 0.0, 1.0, 0.0)
	_check(stopping.transmission.gear > 0, "throttle pulls away without waiting")

	car.queue_free()
	stopping.queue_free()


## Getting off the start line.
##
## Cars were reported sitting on the grid going nowhere, and they were: a
## following distance was written as a fixed number of metres, so every driver
## on the grid wanted more room than a grid gives them, braked for the
## stationary car in front, and since that car was doing the same the field
## deadlocked before it moved. These are the claims that make a start work.
func _test_grid_launch() -> void:
	_section("getting off the line")

	var car := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(car)
	var rival := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(rival)
	var view := RivalAwareness.new(car, _archetype("clubman"))

	# A following distance is a time, so it collapses to a car length at rest
	# and opens out with speed.
	var standing := view.desired_gap()
	_check(standing <= RivalAwareness.STANDING_GAP_M + 0.01,
		"a stationary driver wants only a car length of room (%.1f m)" % standing)
	_check(standing < 6.0, "which is less than a start grid gives them")
	car.speed_ms = 40.0
	var moving := view.desired_gap()
	_check(moving > standing * 4.0,
		"at 144 km/h they want far more (%.0f m)" % moving)
	car.speed_ms = 0.0

	# Two stationary cars are not an emergency however close they are parked,
	# short of touching.
	view.car_ahead = rival
	view.gap_ahead = 8.5
	view.speed_ahead = 0.0
	view.closing_speed = 0.0
	view.time_to_contact = INF
	_check(not view.emergency(),
		"a car stopped 8.5 m behind another stopped car is not an emergency")

	# But it does want to go around it, because a parked car is scenery and
	# waiting for a closing speed that can never appear is waiting forever.
	_check(view.wants_to_overtake(),
		"and it goes around rather than queueing behind it")

	# A car ahead that is genuinely pulling away is neither.
	view.speed_ahead = 30.0
	view.closing_speed = -8.0
	view.gap_ahead = 20.0
	_check(not view.emergency() and not view.wants_to_overtake(),
		"a rival pulling away is left alone")

	# Wheelspin has to reach the right foot, or a powerful car leaves the line
	# slower than a shopping hatchback.
	var launcher := _make_bench_car("impreza_gc8", "elec_none")
	add_child(launcher)
	launcher.axle_front.slip_ratio = 0.9
	launcher.axle_rear.slip_ratio = 0.9
	_check(launcher.driven_slip_ratio() > 0.5,
		"a car with its driven wheels spinning reports it")
	# And a locked wheel under braking is not wheelspin, or the AI would lift
	# in the middle of a stop.
	launcher.axle_front.slip_ratio = -0.9
	launcher.axle_rear.slip_ratio = -0.9
	_check(is_equal_approx(launcher.driven_slip_ratio(), 0.0),
		"a locked wheel is not reported as wheelspin")

	# An AI must never be handed the pad convenience that makes the brake pedal
	# drive the car backwards: a computer sitting on the brakes behind a stopped
	# rival would select reverse and drive itself back down the stage.
	var robot := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(robot)
	robot.auto_reverse = false
	robot.transmission.engage_for(1)
	for i in 120:
		robot._auto_engage_gear(1.0 / 60.0, 0.0, 0.0, 1.0)
	_check(robot.transmission.gear > 0,
		"two seconds of held brake never puts an AI car into reverse")

	robot.queue_free()
	car.queue_free()
	rival.queue_free()
	launcher.queue_free()
	view = null


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


## The two dealerships.
##
## A forecourt that is generated rather than stored has one thing that must be
## true above all others: the same moment produces the same nine cars. If it
## does not, a player who leaves a screen and comes back finds the car they
## were about to buy has vanished.
func _test_used_market() -> void:
	_section("the used forecourt")

	# A part bought for a car stays bought.
	#
	# The shop charged full price every time anything was fitted, so taking the
	# gravel tyres off to try the tarmac ones and then putting the gravel tyres
	# back cost two sets of gravel tyres — and the first set simply vanished.
	# That makes experimenting something only a rich player can do, which is the
	# opposite of what a tuning shop is for.
	var shelf_car := OwnedCar.create(CarDatabase.default_starter(), "shelf_test")
	var a := PartDatabase.get_part("tires_gravel")
	var b := PartDatabase.get_part("tires_sport")
	if a != null and b != null:
		var first := shelf_car.price_to_fit(a)
		_check(first == a.price,
			"a part the car has never had costs its price (%d)" % first)
		shelf_car.buy_part(a.id)
		shelf_car.loadout.set_part("tires", a.id)
		_check(shelf_car.price_to_fit(a) == 0, "and nothing to fit again once bought")
		# Swap to something else; the first set goes on the shelf, not in a skip.
		shelf_car.buy_part(b.id)
		shelf_car.remember_fitted()
		shelf_car.loadout.set_part("tires", b.id)
		_check(shelf_car.price_to_fit(a) == 0,
			"the set that came off is still owned and free to refit")
		# And it survives a save and a load, which is where "it did not save"
		# would actually have come from if the shelf had existed and not been
		# written out.
		var reloaded := OwnedCar.from_dict(shelf_car.to_dict())
		_check(reloaded.price_to_fit(a) == 0 and reloaded.price_to_fit(b) == 0,
			"and both are still owned after a save and a load")
		# A save from before the shelf existed owns whatever is bolted on.
		var legacy := shelf_car.to_dict()
		legacy.erase("owned_parts")
		var old_save := OwnedCar.from_dict(legacy)
		_check(old_save.price_to_fit(b) == 0,
			"an old save is not charged again for the parts already on the car")

	var profile := PlayerProfile.create_new("used_test", "Buyer",
		CarDatabase.default_starter(), 0)
	profile.money = 40000

	var first := UsedCarMarket.stock(profile)
	var again := UsedCarMarket.stock(profile)
	_check(first.size() > 0, "the forecourt has stock (%d cars)" % first.size())
	_check(first.size() == again.size(), "and asking twice gives the same number")
	var identical := true
	for i in first.size():
		if first[i].spec.id != again[i].spec.id or first[i].price != again[i].price:
			identical = false
	_check(identical, "with the same cars at the same prices")

	# Rotating means rotating: a different period is a different forecourt.
	var later := PlayerProfile.create_new("used_later", "Buyer",
		CarDatabase.default_starter(), 0)
	later.money = 40000
	later.event_runs["shakedown"] = UsedCarMarket.RACES_PER_ROTATION * 3
	var rotated := UsedCarMarket.stock(later)
	var changed := false
	for i in mini(first.size(), rotated.size()):
		if first[i].spec.id != rotated[i].spec.id:
			changed = true
	_check(changed, "and a few races later the stock has turned over")

	# Every listing has to be a coherent car, or the panel beside it lies.
	for listing in first:
		_check(listing.price > 0, "'%s' has a price" % listing.spec.id)
		_check(listing.car != null and listing.car.spec_id == listing.spec.id,
			"'%s' listing carries the car it advertises" % listing.spec.id)
		_check(listing.car.odometer_km > 0.0,
			"'%s' has been somewhere" % listing.spec.id)
		# The whole point of used: it is cheaper than new.
		_check(listing.price < listing.new_price,
			"'%s' is cheaper than new (%d vs %d)" % [
				listing.spec.id, listing.price, listing.new_price])
		_check(listing.car.condition() > 0.0 and listing.car.condition() <= 1.0,
			"'%s' has a condition between nothing and perfect" % listing.spec.id)

	# Buying takes the specific car, history and all — not a fresh one.
	var target = first[0]
	var before := profile.money
	var bought := profile.buy_used_car(target.car, target.price)
	_check(bought != null, "the car can be bought")
	if bought != null:
		_check(profile.money == before - target.price, "and it costs the asking price")
		_check(is_equal_approx(bought.odometer_km, target.car.odometer_km),
			"and arrives with its mileage on it, not a fresh odometer")
		_check(profile.garage.has(bought.uid), "and lands in the garage")

	SaveSystem.delete_profile("used_test")
	SaveSystem.delete_profile("used_later")


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


func _test_mechanical_model() -> void:
	_section("wear, heat and failures")
	var spec := CarDatabase.get_car("impreza_gc8")
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	# --- A healthy car, driven hard, must simply work ------------------------
	# This is the load-bearing claim of the whole system. If a standard car
	# loses power or breaks during ordinary racing then every car in the game is
	# slower for no reason a player can see, which is exactly what happened the
	# first time these numbers were written.
	var healthy := MechanicalModel.new(stats, DamageModel.new(stats))
	for i in 12000:   # 200 simulated seconds at full load
		healthy.update(1.0 / 60.0, 40.0, stats.redline_rpm * 0.8, 1.0, 140000.0,
			rng, Vector2.ZERO)
	_check(healthy.failed.is_empty(),
		"a fresh car at full load does not break (%s)" % healthy.failure_text())
	_check(healthy.coolant_c < MechanicalModel.COOLANT_WARN_C,
		"and does not overheat (%.0f C, warning at %.0f)" % [
			healthy.coolant_c, MechanicalModel.COOLANT_WARN_C])
	_check(is_equal_approx(healthy.power_multiplier(), 1.0),
		"and makes full power throughout (%.2f)" % healthy.power_multiplier())
	_check(healthy.level_of(MechanicalModel.System.ENGINE) == MechanicalModel.Level.OK,
		"and lights no warnings")

	# --- Fuel use has to be realistic in both directions ---------------------
	var used := healthy.tank_l - healthy.fuel_l
	_check(used > 0.5 and used < healthy.tank_l * 0.75,
		"200 seconds at full power uses some fuel but nowhere near a tank (%.1f of %.0f L)"
			% [used, healthy.tank_l])

	# --- The settings a player turns up have to cost something ---------------
	var pushed := MechanicalModel.new(stats, DamageModel.new(stats))
	pushed.boost_setting = 1.0
	pushed.rev_limit_setting = 1.0
	pushed.engine_km = MechanicalModel.ENGINE_TIRED_KM
	pushed.oil_life = 0.05
	pushed.turbo_life = 0.05
	_check(pushed.engine_stress() > healthy.engine_stress() * 2.0,
		"maximum boost and a raised limiter on a tired engine is far more stress")
	_check(pushed.boost_gain() > 1.0, "and does make more power")
	_check(pushed.engine_wear() > 0.9, "a very high mileage engine reads as worn out")
	_check(healthy.engine_wear() < 0.1, "a fresh one does not")

	# Over a long stage that combination should usually break something, and an
	# identical stage in a healthy car should break nothing. Both are run
	# several times: one trial of a probabilistic system tells you nothing, and
	# the contrast between the two is the claim worth testing.
	var broke := 0
	var healthy_broke := 0
	for attempt in 12:
		var victim := MechanicalModel.new(stats, DamageModel.new(stats))
		victim.boost_setting = 1.0
		victim.rev_limit_setting = 1.0
		victim.engine_km = MechanicalModel.ENGINE_TIRED_KM
		victim.oil_life = 0.02
		victim.turbo_life = 0.02
		for i in 36000:   # ten simulated minutes
			victim.update(1.0 / 60.0, 40.0, stats.redline_rpm * 0.95, 1.0, 180000.0,
				rng, Vector2.ZERO)
		if not victim.failed.is_empty():
			broke += 1

		var sound := MechanicalModel.new(stats, DamageModel.new(stats))
		for i in 36000:
			sound.update(1.0 / 60.0, 40.0, stats.redline_rpm * 0.85, 1.0, 150000.0,
				rng, Vector2.ZERO)
		if not sound.failed.is_empty():
			healthy_broke += 1
	_check(broke >= 6, "a worn car pushed to the limit usually breaks (%d of 12)" % broke)
	_check(healthy_broke == 0,
		"a well kept one over the same distance never does (%d of 12)" % healthy_broke)

	# --- Brakes are a consumable, not a decoration --------------------------
	# For a long time brake_life was read by the fade model, the failure roll,
	# the garage bill and the used-car listing, and written by nothing at all:
	# a set of pads lasted forever and the "Replace brakes" button bought air.
	var braked := MechanicalModel.new(stats, DamageModel.new(stats))
	for i in 12000:   # 200 seconds, a fifth of it hard on the pedal
		var on_pedal := fmod(float(i) / 60.0, 5.0) > 4.0
		braked.update(1.0 / 60.0, 32.0, stats.redline_rpm * 0.6, 0.5, 60000.0,
			rng, Vector2.ZERO, 1.0 if on_pedal else 0.0)
	_check(braked.brake_life < 0.97,
		"braking wears the pads out (%.0f%% left after a stage)" % (braked.brake_life * 100.0))
	_check(braked.brake_life > 0.5,
		"but one stage does not use a whole set (%.0f%% left)" % (braked.brake_life * 100.0))

	var coasted := MechanicalModel.new(stats, DamageModel.new(stats))
	for i in 12000:
		coasted.update(1.0 / 60.0, 32.0, stats.redline_rpm * 0.6, 0.5, 60000.0,
			rng, Vector2.ZERO, 0.0)
	_check(is_equal_approx(coasted.brake_life, 1.0),
		"and a car that never brakes never needs pads")

	# --- Reliability is something a player can buy ---------------------------
	# Every part below claims a number in its description. The claim is only
	# worth printing if it reaches the model, so each one is checked against
	# the same car driven the same way.
	# The top of the shelf only bolts to a chassis that will take it, so this
	# runs on a Group B car rather than the Impreza used above — which accepts
	# tier 2 and would silently refuse every part here.
	var big_car := CarDatabase.get_car("delta_s4")
	var big_stock := TuningCalculator.resolve(big_car, big_car.default_loadout())

	var hard := TuningLoadout.new()
	hard.set_part("internals", "internals_dry_sump")
	var protected := TuningCalculator.resolve(big_car, hard)
	_check(protected.oil_wear_rate < 0.5, "a dry sump halves how fast the oil ages")
	_check(protected.reliability > 2.0, "and makes the engine far less likely to let go")

	var pads := TuningLoadout.new()
	pads.set_part("brakes", "brakes_4pot")
	_check(TuningCalculator.resolve(big_car, pads).brake_wear_rate < 0.8,
		"race calipers make a set of pads last longer")

	var antilag := TuningLoadout.new()
	antilag.set_part("exhaust", "exhaust_antilag")
	_check(TuningCalculator.resolve(big_car, antilag).turbo_wear_rate > 1.4,
		"and anti-lag eats turbos, which is exactly what it does in life")

	var oil_a := MechanicalModel.new(big_stock, DamageModel.new(big_stock))
	var oil_b := MechanicalModel.new(protected, DamageModel.new(protected))
	for i in 6000:
		oil_a.update(1.0 / 60.0, 40.0, big_stock.redline_rpm * 0.85, 1.0, 150000.0,
			rng, Vector2.ZERO)
		oil_b.update(1.0 / 60.0, 40.0, protected.redline_rpm * 0.85, 1.0, 150000.0,
			rng, Vector2.ZERO)
	_check(oil_b.oil_life > oil_a.oil_life + 0.01,
		"and the difference shows up over a stage (%.0f%% left against %.0f%%)"
			% [oil_b.oil_life * 100.0, oil_a.oil_life * 100.0])

	# --- How much fuel you choose to carry ----------------------------------
	var big := TuningLoadout.new()
	big.set_part("fuel", "fuel_long_range")
	var small := TuningLoadout.new()
	small.set_part("fuel", "fuel_cell_light")
	var big_tank := MechanicalModel.new(TuningCalculator.resolve(big_car, big), null)
	var small_tank := MechanicalModel.new(TuningCalculator.resolve(big_car, small), null)
	var stock_tank := MechanicalModel.new(big_stock, null)
	_check(big_tank.tank_l > stock_tank.tank_l,
		"a long-range tank carries more fuel (%.0f L against %.0f)" % [
			big_tank.tank_l, stock_tank.tank_l])
	_check(small_tank.tank_l < stock_tank.tank_l,
		"and a light cell carries less, for less weight (%.0f L)" % small_tank.tank_l)
	_check(TuningCalculator.resolve(big_car, small).mass_kg < big_stock.mass_kg,
		"which is the whole reason to fit one")

	# --- What a failure does ------------------------------------------------
	var punctured := MechanicalModel.new(stats, DamageModel.new(stats))
	punctured.punctured_axle = 0
	_check(punctured.axle_grip_multiplier(0) < 0.6, "a puncture ruins that axle's grip")
	_check(punctured.axle_grip_multiplier(1) > 0.9, "and leaves the other one alone")
	_check(punctured.puncture_drag() > 0.0, "and drags")

	var blown := MechanicalModel.new(stats, DamageModel.new(stats))
	blown._fail(MechanicalModel.System.TURBO, "test")
	_check(blown.power_multiplier() < 0.9 / stats.turbo_boost + 0.2,
		"a blown turbo takes the boost away")
	_check(blown.power_multiplier() > 0.0, "but the car still runs")

	var dead := MechanicalModel.new(stats, DamageModel.new(stats))
	dead._fail(MechanicalModel.System.ENGINE, "test")
	_check(is_zero_approx(dead.power_multiplier()), "a failed engine makes no power")
	_check(dead.is_stranded(), "and strands the car")

	var dry := MechanicalModel.new(stats, DamageModel.new(stats))
	dry.fuel_l = 0.0
	dry._fail(MechanicalModel.System.FUEL, "test")
	_check(dry.is_stranded(), "so does an empty tank")

	# --- Warnings have to arrive before the failure, not with it -------------
	var hot := MechanicalModel.new(stats, DamageModel.new(stats))
	hot.coolant_c = MechanicalModel.COOLANT_WARN_C + 2.0
	_check(hot.level_of(MechanicalModel.System.COOLING) == MechanicalModel.Level.WARNING,
		"a hot engine warns before it is critical")
	hot.coolant_c = MechanicalModel.COOLANT_CRITICAL_C + 2.0
	_check(hot.level_of(MechanicalModel.System.COOLING) == MechanicalModel.Level.CRITICAL,
		"and goes critical when it really is")

	# --- Mileage, servicing and engine swaps --------------------------------
	var owned := OwnedCar.create(spec, "test_wear")
	_check(owned.odometer_km > 0.0,
		"a car bought in this game has been driven before (%.0f km)" % owned.odometer_km)
	_check(is_equal_approx(owned.engine_km, owned.odometer_km),
		"and its engine has done the same distance")

	var fresh_value := owned.sale_value()
	owned.odometer_km += 200000.0
	_check(owned.sale_value() < fresh_value, "mileage lowers what a car is worth")
	_check(owned.mileage_value_multiplier() > 0.4,
		"but never to nothing (%.2f)" % owned.mileage_value_multiplier())

	owned.engine_km = 260000.0
	var tired_power := owned.engine_health_multiplier()
	owned.swap_engine(false)
	_check(is_zero_approx(owned.engine_km), "a new engine starts at zero kilometres")
	_check(owned.engine_health_multiplier() > tired_power,
		"and makes more power than the one it replaced")
	_check(owned.odometer_km > 200000.0,
		"while the car keeps the distance it has actually covered")
	owned.swap_engine(true)
	_check(owned.engine_km > 0.0, "a rebuilt engine arrives with some mileage on it")
	_check(owned.engine_swap_cost(true) < owned.engine_swap_cost(false),
		"and costs less than a new one")

	owned.oil_life = 0.1
	var oil_bill := owned.service_cost("oil")
	_check(oil_bill > 0, "worn oil costs something to change (%d cr)" % oil_bill)
	_check(oil_bill < owned.repair_cost() + 2000,
		"and routine servicing is not the expensive part of owning a car")
	owned.service("oil")
	_check(is_equal_approx(owned.service_life("oil"), 1.0), "and changing it works")
	_check(owned.service_cost("oil") == 0, "with nothing to pay when nothing is worn")


func _test_audio() -> void:
	_section("audio")
	var rng := RandomNumberGenerator.new()
	rng.seed = 8181

	# --- The three mixing faults that made the game sound broken -------------
	# All reported together, all separate causes, all invisible in the waveform
	# tests below because none of them is about the waveform.

	# A range threshold with no hysteresis is an oscillator. A car near the
	# boundary — in a race, most of the field most of the time — crossed it
	# every few frames and had its loops started and stopped over and over,
	# which is heard as sound swelling, lagging and vanishing.
	_check(CarAudio.RANGE_HYSTERESIS > 1.05,
		"a car has to go further to fall silent than it did to be heard (%.2fx)"
			% CarAudio.RANGE_HYSTERESIS)

	# Lifting off has to be audible as a drop in volume, not only a change of
	# timbre. At 0.75 the engine stayed loud with the pedal up.
	_check(CarAudio.OVERRUN_LEVEL < 0.6,
		"overrun is clearly quieter than pulling (%.2f of it)" % CarAudio.OVERRUN_LEVEL)

	# Losing grip has to make a noise on every surface. It was tarmac only, and
	# almost every stage in the game is gravel — so the one thing a racing game
	# must tell you was the one thing it was silent about.
	for surface in [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL,
			TireModel.Surface.DIRT, TireModel.Surface.SNOW, TireModel.Surface.ICE,
			TireModel.Surface.MUD, TireModel.Surface.GRASS]:
		_check(float(CarAudio.SQUEAL_BY_SURFACE.get(surface, 0.0)) > 0.0,
			"a sliding tyre is audible on %s" % TireModel.surface_name(surface))
	_check(float(CarAudio.SQUEAL_BY_SURFACE[TireModel.Surface.TARMAC])
			> float(CarAudio.SQUEAL_BY_SURFACE[TireModel.Surface.GRAVEL]),
		"and it still screams loudest on the surface that actually grips")

	# --- Firing frequency is the whole ball game -----------------------------
	# If this is wrong every engine in the game is the wrong note, and no amount
	# of mixing rescues it.
	var i4 := EngineLayout.from_dict({"cylinders": 4, "config": "inline"})
	_check(is_equal_approx(i4.firing_hz(6000.0), 200.0),
		"an inline four at 6000 rpm fires at 200 Hz (%.1f)" % i4.firing_hz(6000.0))
	var v10 := EngineLayout.from_dict({"cylinders": 10, "config": "vee"})
	_check(is_equal_approx(v10.firing_hz(6000.0), 500.0),
		"a V10 at the same revs fires two and a half times as often")
	var two_stroke := EngineLayout.from_dict({"cylinders": 2, "two_stroke": true})
	_check(is_equal_approx(two_stroke.firing_hz(6000.0), 200.0),
		"a two-stroke twin fires as often as a four-stroke four")
	_check(is_equal_approx(i4.cycle_revolutions(), 2.0),
		"a four-stroke's pattern repeats every two revolutions")
	_check(is_equal_approx(two_stroke.cycle_revolutions(), 1.0),
		"a two-stroke's, every one")

	# --- Firing patterns ----------------------------------------------------
	var inline_events := i4.firing_events()
	_check(inline_events.size() == 4, "an inline four has four firings in a cycle")
	var even := true
	for i in inline_events.size():
		if absf(float(inline_events[i]["at"]) - float(i) * 0.25) > 0.001:
			even = false
	_check(even, "and they are evenly spaced")

	var boxer := EngineLayout.from_dict({"cylinders": 4, "config": "flat"})
	var boxer_events := boxer.firing_events()
	var uneven := false
	for i in boxer_events.size():
		if absf(float(boxer_events[i]["at"]) - float(i) * 0.25) > 0.005:
			uneven = true
	_check(uneven, "a flat four's are not — that unevenness is the rumble")

	# --- The baked waveform -------------------------------------------------
	var spec := CarDatabase.get_car("golf_gti_mk2")
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var voice := EngineVoice.bake(stats, spec.engine_layout, 0, 0)
	_check(voice.on_load.size() == EngineVoice.BAND_POSITIONS.size(),
		"an engine bakes one loop per rev band")
	_check(voice.off_load.size() == voice.on_load.size(),
		"and an off-throttle layer for each")

	var top := voice.on_load.size() - 1
	var samples := _pcm_of(voice.on_load[top])
	var rpm := voice.band_rpm[top]
	var firing := spec.engine_layout.firing_hz(rpm)

	# The signal has to actually be at the frequency the maths says. Measured
	# with a single-bin Fourier transform against a frequency that is not a
	# harmonic, so a broadband roar cannot pass by accident.
	var at_firing := AudioSynth.energy_at(samples, firing)
	var off_note := AudioSynth.energy_at(samples, firing * 1.37)
	_check(at_firing > off_note * 1.5,
		"the baked loop's energy really is at the firing frequency (%.4f vs %.4f)"
			% [at_firing, off_note])

	_check(AudioSynth.peak(samples) <= 1.0, "nothing clips")
	_check(AudioSynth.peak(samples) > 0.5, "and it is not nearly silent either")
	var mean := 0.0
	for value in samples:
		mean += value
	mean /= float(maxi(samples.size(), 1))
	_check(absf(mean) < 0.02, "there is no DC offset (%.4f)" % mean)

	# A loop's seam has to look like the rest of the waveform. Measured relative
	# to the signal's own sample-to-sample movement, because the absolute step
	# means nothing on its own.
	var seam := AudioSynth.loop_discontinuity(samples)
	_check(seam < 6.0, "the loop joins without a click (%.1f x the normal step)" % seam)

	# The loop must be a whole number of engine cycles or the rhythm drifts.
	var expected_samples := AudioSynth.seconds_to_samples(
		spec.engine_layout.cycle_seconds(rpm)) * EngineVoice.CYCLES_PER_LOOP
	_check(absi(samples.size() - expected_samples) <= 2,
		"and is a whole number of engine cycles (%d vs %d)" % [
			samples.size(), expected_samples])

	# --- Cars have to sound different from one another ----------------------
	# This is the reason the system exists. Fifty-seven cars that are one sound
	# at fifty-seven pitches would be a failure however good that sound is.
	var lada := CarDatabase.get_car("lada_2101")
	var huracan := CarDatabase.get_car("huracan_sterrato")
	_check(lada.engine_layout.cylinders != huracan.engine_layout.cylinders,
		"a Lada and a Huracan do not have the same engine")
	var lada_hz := lada.engine_layout.firing_hz(5000.0)
	var huracan_hz := huracan.engine_layout.firing_hz(5000.0)
	_check(huracan_hz > lada_hz * 2.0,
		"so at the same revs they are nowhere near the same note (%.0f vs %.0f Hz)"
			% [huracan_hz, lada_hz])

	# Every car in the catalogue must have an engine, or it falls back to a
	# generic four and quietly sounds like everything else.
	var without := 0
	var layouts := {}
	for car in CarDatabase.all():
		if car.engine_layout == null:
			without += 1
			continue
		layouts[car.engine_layout.display_name()] = true
	_check(without == 0, "every car says what engine it has (%d do not)" % without)
	_check(layouts.size() >= 8,
		"and the field has real variety in them (%d distinct)" % layouts.size())

	# --- Parts have to change the sound -------------------------------------
	# Fitting an exhaust that does not alter the note is a part nobody would buy
	# twice.
	var loud := EngineVoice.bake(stats, spec.engine_layout, 4, 4)
	var stock_centroid := AudioSynth.spectral_centroid(samples)
	var loud_centroid := AudioSynth.spectral_centroid(_pcm_of(loud.on_load[top]))
	_check(loud_centroid > stock_centroid,
		"a straight-through exhaust is brighter than the standard one (%.0f vs %.0f Hz)"
			% [loud_centroid, stock_centroid])

	# On and off the throttle are different sounds, not one sound quieter.
	var off_centroid := AudioSynth.spectral_centroid(_pcm_of(voice.off_load[top]))
	_check(absf(off_centroid - stock_centroid) > 60.0,
		"lifting off changes the sound, not just the volume (%.0f vs %.0f Hz)"
			% [off_centroid, stock_centroid])

	# --- Turbos ---------------------------------------------------------------
	var small := _pcm_of(EffectVoices.bake_turbo_whistle(1.4, 0.05, rng))
	var big := _pcm_of(EffectVoices.bake_turbo_whistle(1.9, 0.9, rng))
	_check(AudioSynth.spectral_centroid(big) < AudioSynth.spectral_centroid(small),
		"a big laggy turbo whistles lower than a small one (%.0f vs %.0f Hz)" % [
			AudioSynth.spectral_centroid(big), AudioSynth.spectral_centroid(small)])

	# --- Impacts -------------------------------------------------------------
	var nudge := _pcm_of(EffectVoices.bake_impact(0.1, rng))
	var shunt := _pcm_of(EffectVoices.bake_impact(1.0, rng))
	_check(shunt.size() > nudge.size(),
		"a heavy crash rings for longer than a nudge")
	_check(AudioSynth.rms(shunt) > 0.0 and AudioSynth.rms(nudge) > 0.0,
		"and both actually make a noise")
	_check(AudioSynth.peak(shunt) > AudioSynth.peak(nudge),
		"with the heavy one louder")

	# --- The wiring ----------------------------------------------------------
	# Everything above tests the synthesis in isolation. This runs one car's
	# voices end to end through the same call the car itself makes, so a system
	# that bakes perfect waveforms and never reaches a speaker cannot pass.
	var wired := CarDatabase.get_car("impreza_gc8")
	var wired_car := CAR_SCENE.instantiate() as RallyCar
	wired_car.configure(wired, wired.default_loadout())
	add_child(wired_car)
	var rig := CarAudio.new()
	add_child(rig)
	rig.setup(wired_car, wired.engine_layout, wired.default_loadout())
	var players := 0
	for child in rig.get_children():
		if child is AudioStreamPlayer2D and child.stream != null:
			players += 1
	_check(players >= 6, "a car builds its full set of voices (%d)" % players)
	_check(rig.voice != null and rig.voice.on_load.size() > 0,
		"and an engine voice to drive them")
	# A car built the ordinary way carries its own audio, and only bothers when
	# there is a device to play it on.
	_check(GameConfig.audio_enabled() == (DisplayServer.get_name() != "headless"),
		"audio is built when, and only when, there is something to hear it")
	_check(wired_car.get_node_or_null("Audio") != null or not GameConfig.audio_enabled(),
		"a car carries its own audio node")
	rig.queue_free()
	wired_car.queue_free()

	# --- Lights and horn ------------------------------------------------------
	var switched := _make_bench_car("golf_gti_mk2", "elec_none")
	add_child(switched)
	var was_lit := switched.lights_on
	switched.command.toggle_lights = true
	switched._physics_process(1.0 / 60.0)
	_check(switched.lights_on != was_lit, "the light switch turns the lights on")
	switched._physics_process(1.0 / 60.0)
	_check(switched.lights_on == was_lit, "and pressing it again turns them off")

	# A horn is two horns a minor third apart, and its pitch is the car's: a
	# two-tonne pickup does not sound like a Trabant.
	var horn_rng := RandomNumberGenerator.new()
	horn_rng.seed = 4
	var light_horn := EffectVoices.bake_horn(600.0, 1975, horn_rng)
	var heavy_horn := EffectVoices.bake_horn(2500.0, 2021, horn_rng)
	_check(light_horn.data.size() > 0 and heavy_horn.data.size() > 0,
		"every car has a horn")
	_check(AudioSynth.spectral_centroid(_wav_samples(light_horn))
		> AudioSynth.spectral_centroid(_wav_samples(heavy_horn)),
		"and a small car's is higher than a big one's")
	_check(light_horn.loop_mode == AudioStreamWAV.LOOP_FORWARD,
		"a horn sounds for as long as it is held")
	switched.queue_free()

	# --- The music ------------------------------------------------------------
	# Checked in full by music_bench; what matters here is that the theory the
	# whole thing rests on is sound, because every part is generated from it and
	# a wrong scale puts every note in the game in the wrong place.
	for scale_name in MusicTheory.SCALES:
		var steps: Array = MusicTheory.SCALES[scale_name]
		var ascending := true
		for i in range(1, steps.size()):
			if int(steps[i]) <= int(steps[i - 1]):
				ascending = false
		_check(ascending and int(steps[0]) == 0 and int(steps[-1]) < 12,
			"'%s' is a scale: ascending, rooted at zero, inside an octave" % scale_name)
		var size := steps.size()
		_check(MusicTheory.degree_to_midi(60, scale_name, size)
			- MusicTheory.degree_to_midi(60, scale_name, 0) == 12,
			"'%s' spans exactly an octave" % scale_name)
		# The one that catches integer division on negatives, which would put
		# the note below the root on top of the root.
		_check(MusicTheory.degree_to_midi(60, scale_name, 0)
			- MusicTheory.degree_to_midi(60, scale_name, -size) == 12,
			"'%s' walks downwards correctly too" % scale_name)
	_check(is_equal_approx(MusicTheory.midi_to_hz(69.0), 440.0),
		"A above middle C is 440 Hz")
	_check(is_equal_approx(MusicTheory.midi_to_hz(81.0), 880.0),
		"and an octave above it is 880")

	# Every chord in every progression has to come out of its own scale.
	for progression in MusicTheory.PROGRESSIONS:
		for bar in 4:
			var notes := MusicTheory.chord_notes(60, "minor", progression, bar, true)
			_check(notes.size() == 4, "'%s' bar %d is a four-note chord" % [progression, bar])
			var in_key := true
			for note in notes:
				if MusicTheory.nearest_in_scale(60, "minor", note) != note:
					in_key = false
			_check(in_key, "and every note of it is in the key")

	# --- Every loop in the game -----------------------------------------------
	for surface in [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL,
			TireModel.Surface.SNOW]:
		var scrub := _pcm_of(EffectVoices.bake_surface_scrub(surface, rng))
		_check(AudioSynth.peak(scrub) <= 1.0,
			"the %s scrub loop does not clip" % TireModel.surface_name(surface))
		_check(AudioSynth.loop_discontinuity(scrub) < 6.0,
			"and joins cleanly (%.1f)" % AudioSynth.loop_discontinuity(scrub))
	var squeal := _pcm_of(EffectVoices.bake_tyre_squeal(rng))
	_check(AudioSynth.spectral_centroid(squeal) > 900.0,
		"tyre squeal is a high sound (%.0f Hz)" % AudioSynth.spectral_centroid(squeal))


## Pulls the samples back out of a baked stream, so the tests measure exactly
## what the game will play rather than an intermediate buffer.
static func _pcm_of(stream: AudioStreamWAV) -> PackedFloat32Array:
	var data := stream.data
	var out := PackedFloat32Array()
	out.resize(data.size() / 2)
	for i in out.size():
		out[i] = float(data.decode_s16(i * 2)) / 32768.0
	return out


func _wav_samples(stream: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(stream.data.size() / 2)
	for i in out.size():
		out[i] = float(stream.data.decode_s16(i * 2)) / 32767.0
	return out


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
