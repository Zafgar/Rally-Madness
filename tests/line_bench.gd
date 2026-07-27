extends Node
## What the AI's recce of each track produces, in numbers.
##
## Three things are being checked, and none of them can be checked by reading
## the code:
##
##   The model has to read the road the way a person would. A stage described
##   as "twelve corners, three of them slow" should come out of the geometry
##   with roughly twelve corners, not two and not ninety.
##
##   The racing line has to be faster than the centreline. It is constructed
##   from a textbook and then smoothed, and both of those can go wrong in ways
##   that quietly produce a line with a smaller radius than the road it is on.
##
##   The speed profile has to respond to the car. If fitting better tyres does
##   not lower the implied lap time, the parts are not reaching the driving and
##   the whole exercise is decoration.
##
##   godot --headless --path . res://tests/line_bench.tscn -- [track_id]

## The cars the profile is solved for, chosen to be different in the ways the
## solve cares about: grip, brakes, power and drivetrain.
const CARS := ["trabant_601", "golf_gti_mk2", "impreza_gc8", "delta_s4"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var only: String = args[0] if args.size() > 0 else ""

	var tracks := TrackSpec.load_all()
	var ids: Array = tracks.keys()
	ids.sort()

	print("=== how the AI reads each stage ===")
	print("%-26s %8s %8s %7s %8s %9s %9s %8s" % [
		"track", "length", "corners", "slow", "passes", "line gain", "tightest",
		"solve"])

	for id in ids:
		if not only.is_empty() and String(id) != only:
			continue
		var spec: TrackSpec = tracks[id]
		var builder := TrackBuilder.new(spec)
		builder.build()
		# The whole recce runs once when a race starts, and a race start is the
		# one moment a player is watching a loading bar. Worth knowing.
		var began := Time.get_ticks_usec()
		var model := TrackModel.analyse(builder)
		var line := RacingLine.solve(model)
		var solve_ms := float(Time.get_ticks_usec() - began) / 1000.0

		var slow := 0
		for corner in model.corners:
			if corner.is_slow():
				slow += 1
		# The tightest radius anywhere on the road, whether or not the corner
		# finder called it a corner. Reporting only the tightest *detected*
		# corner cannot tell "this stage is genuinely open" from "the corner
		# finder missed everything", and those need completely different fixes.
		var tightest := 100000.0
		for i in model.curvature.size():
			tightest = minf(tightest, model.radius_at(i))
		print("%-26s %7.0fm %8d %7d %8d %8.1f%% %8.0fm %6.0fms" % [
			spec.display_name, model.length_m, model.corners.size(), slow,
			model.pass_zones.size(), line.gain_over_centreline(),
			tightest if tightest < 99999.0 else 0.0, solve_ms])

	if not only.is_empty():
		_detail(tracks.get(only))
	else:
		_car_response(tracks)
	get_tree().quit(0)


## Every corner on one stage, written out the way a co-driver would call them.
## This is the check that matters most and the only one a person can actually
## judge: if the notes do not match the shape of the road on the map, the model
## is not reading it.
func _detail(spec: TrackSpec) -> void:
	if spec == null:
		return
	var builder := TrackBuilder.new(spec)
	builder.build()
	var model := TrackModel.analyse(builder)
	var line := RacingLine.solve(model)

	print("\n=== %s, corner by corner ===" % spec.display_name)
	print(model.describe())
	print("%6s %-34s %9s %9s" % ["at", "corner", "road r", "line r"])
	for corner in model.corners:
		print("%5.0fm %-34s %8.0fm %8.0fm" % [
			corner.entry_s, corner.describe(),
			model.radius_at(corner.apex), line.radius_at(corner.apex)])

	print("\nwhere a pass is on:")
	for zone in model.pass_zones:
		print("  %5.0fm to %5.0fm (%3.0f m of road) into %s" % [
			zone.start_s, zone.end_s, zone.length_m(),
			zone.into.describe() if zone.into != null else "the finish"])


## The same stage solved for different cars, and then for one car with better
## parts. Both differences have to show up or the profile is not reading the
## car it was given.
func _car_response(tracks: Dictionary) -> void:
	var spec: TrackSpec = tracks.get("gravel_loop")
	if spec == null:
		var first: Array = tracks.keys()
		spec = tracks[first[0]]
	var builder := TrackBuilder.new(spec)
	builder.build()
	var model := TrackModel.analyse(builder)
	var line := RacingLine.solve(model)

	print("\n=== the same road, solved for different cars — %s ===" % spec.display_name)
	print("%-28s %10s %10s %10s" % ["car", "lap", "slowest", "fastest"])
	for id in CARS:
		var car := CarDatabase.get_car(id)
		if car == null:
			continue
		var stats := TuningCalculator.resolve(car, car.default_loadout())
		var profile := SpeedProfile.solve(model, line, stats)
		var slowest := 1000.0
		var fastest := 0.0
		for v in profile.speeds:
			slowest = minf(slowest, v)
			fastest = maxf(fastest, v)
		print("%-28s %9.1fs %8.0f km/h %8.0f km/h" % [
			car.display_name(), profile.lap_estimate(),
			slowest * 3.6, fastest * 3.6])

	# The claim that has to hold for any of this to be worth having: parts
	# bought in the garage change where the car can be driven, not just what
	# the spec sheet says.
	var base := CarDatabase.get_car("impreza_gc8")
	if base == null:
		return
	print("\n=== and the same car, with parts on it ===")
	print("%-28s %10s %10s" % ["build", "lap", "against stock"])
	# Parts that suit the road the test is run on. Fitting slicks for a gravel
	# stage is a real decision with a real answer, and the answer is that they
	# make the car slower — which is correct, and useless as a check that the
	# profile reads the car at all.
	var builds := {
		"showroom stock": {},
		"gravel tyres": {"tires": "tires_gravel"},
		"and big brakes": {"tires": "tires_gravel", "brakes": "brakes_bigger"},
		"and a stage 1 engine": {"tires": "tires_gravel", "brakes": "brakes_bigger",
			"engine": "engine_stage2"},
		"and rally suspension": {"tires": "tires_gravel", "brakes": "brakes_bigger",
			"engine": "engine_stage2", "suspension": "susp_rally_raised"},
	}
	var stock_lap := 0.0
	for name in builds:
		var loadout := base.default_loadout()
		for slot in builds[name]:
			loadout.set_part(slot, builds[name][slot])
		var stats := TuningCalculator.resolve(base, loadout)
		var profile := SpeedProfile.solve(model, line, stats)
		var lap := profile.lap_estimate()
		if stock_lap <= 0.0:
			stock_lap = lap
		print("%-28s %9.1fs %9.1fs" % [name, lap, lap - stock_lap])
