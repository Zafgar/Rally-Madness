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
	_test_damage_and_economy()
	_test_progression()
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
	loadout.set_part("turbo", "turbo_big")
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

	# The tire curve must peak at the peak slip angle and fall off past it.
	var peak := TireModel.lateral(TireModel.BASE_PEAK_SLIP_ANGLE * stats.slip_forgiveness, stats)
	var past := TireModel.lateral(TireModel.BASE_PEAK_SLIP_ANGLE * stats.slip_forgiveness * 3.0, stats)
	_check(absf(peak) > absf(past), "grip falls off past the peak slip angle")
	_check(signf(peak) < 0.0, "lateral force opposes the slip angle")

	# The friction ellipse must actually clamp a combined demand.
	var limit := TireModel.combined_limit(900.0, 900.0, 1000.0, 1000.0)
	_check(limit < 1.0, "asking for grip in both directions gets scaled back")
	_check(is_equal_approx(TireModel.combined_limit(100.0, 100.0, 1000.0, 1000.0), 1.0),
		"a modest demand is left alone")

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
