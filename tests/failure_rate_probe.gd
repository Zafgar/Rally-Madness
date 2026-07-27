extends Node
## How often a rival breaks down, measured directly.
##
## The race probe answers this too, but a race takes minutes to simulate and
## tuning a rate against a minutes-long feedback loop is how you end up
## guessing. This runs the mechanical model on its own, over a race's worth of
## running, for a whole grid — many times over — and prints the proportion that
## fail. Seconds, not minutes.
##
## The number to aim at: a rival letting go in a cloud of smoke is one of the
## best moments in a rally game, and it stops being a moment the second it
## happens every time. Roughly one car in a nine-car field, most races.
##
##   godot --headless --path . res://tests/failure_rate_probe.tscn -- [minutes]

const FIELDS := 240
const FIELD_SIZE := 9


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var minutes: float = float(args[0]) if args.size() > 0 else 4.0
	var seconds := minutes * 60.0

	print("=== breakdowns over a %.0f-minute race, %d fields of %d ===" % [
		minutes, FIELDS, FIELD_SIZE])
	print("%-22s %8s %8s %8s  %s" % [
		"event skill", "failed", "per race", "stranded", "most common"])

	for skill in [0.30, 0.55, 0.80]:
		var failures := 0
		var stranded := 0
		var cars := 0
		var reasons := {}
		for field in FIELDS:
			for slot in FIELD_SIZE:
				cars += 1
				var result := _run_one(skill, field * 100 + slot, seconds)
				if not result["failed"].is_empty():
					failures += 1
					for text in result["failed"]:
						reasons[text] = int(reasons.get(text, 0)) + 1
				if result["stranded"]:
					stranded += 1

		var common := ""
		var best := 0
		for text in reasons:
			if int(reasons[text]) > best:
				best = int(reasons[text])
				common = "%s (%d)" % [text, reasons[text]]
		print("%-22.2f %7.1f%% %8.2f %7.1f%%  %s" % [
			skill,
			100.0 * float(failures) / float(maxi(cars, 1)),
			float(failures) / float(FIELDS),
			100.0 * float(stranded) / float(maxi(cars, 1)),
			common])

	print("\n(stranded = engine or fuel: the car stops. Anything else is a")
	print(" wounded car that can still get to the finish.)")
	get_tree().quit(0)


## One rival, prepared and driven the way the race director prepares and drives
## them, for a race's worth of running.
func _run_one(skill: float, seed_value: int, seconds: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var profile := DriverProfile.pick_for(skill, rng)
	var pool := CarDatabase.all()
	var spec: CarSpec = pool[rng.randi_range(0, pool.size() - 1)]
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var damage := DamageModel.new(stats)
	var mech := MechanicalModel.new(stats, damage)

	# Exactly what RaceDirector._apply_ai_mechanical_state does.
	var carelessness := clampf(1.0 - profile.mechanical_sympathy, 0.0, 1.0)
	mech.boost_setting = carelessness * rng.randf_range(0.20, 0.78)
	mech.rev_limit_setting = carelessness * rng.randf_range(0.0, 0.62)
	mech.engine_km = rng.randf_range(15000.0, 35000.0 + carelessness * 150000.0)
	mech.oil_life = rng.randf_range(0.40 + profile.mechanical_sympathy * 0.45, 1.0)
	mech.brake_life = rng.randf_range(0.45 + profile.mechanical_sympathy * 0.45, 1.0)
	mech.turbo_life = rng.randf_range(0.42 + profile.mechanical_sympathy * 0.45, 1.0)

	# Driven hard: a rally car spends most of a stage near full load and well up
	# the rev range, which is the condition the failure rates care about.
	var step := 0.1
	var elapsed := 0.0
	var rpm := stats.redline_rpm * 0.78
	var power := stats.engine_torque_nm * rpm * 0.10472 * 0.80
	while elapsed < seconds:
		mech.update(step, 24.0, rpm, 0.85, power, rng, Vector2.ZERO)
		elapsed += step

	var texts: Array[String] = []
	for system in mech.failed:
		texts.append(String(mech.failed[system]))
	return {"failed": texts, "stranded": mech.is_stranded()}
