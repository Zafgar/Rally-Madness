extends Node
## Where the frame time goes in a running race.
##
## "The game lags" is a report, not a diagnosis, and optimising by guessing at
## it is how you spend an afternoon speeding up something that was never the
## problem. This runs a real race headless and times the systems inside a
## physics frame separately, so the answer is a number next to a name.
##
## Headless means no rendering, so what comes out is the simulation cost only.
## That is the right half to measure first: if the simulation alone does not fit
## in a frame, no amount of graphics work will help.
##
##   godot --headless --path . res://tests/frame_probe.tscn -- [track] [cars]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
## Frames to time. Enough that one slow frame does not decide the answer.
const FRAMES := 600
## What a physics frame has to fit in, in microseconds, at 60 Hz.
const BUDGET_US := 16666.0

var _director: RaceDirector
var _frames := 0
var _totals := {}
var _setup_ms := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	var field: int = int(args[1]) if args.size() > 1 else 8

	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("frame_probe: no track '%s'" % track_id)
		get_tree().quit(1)
		return

	var event := EventSpec.from_dict({
		"id": "frame_probe", "name": "Frame Probe", "track": track_id,
		"format": "sprint", "laps": 9, "payouts": [0], "xp": 0,
		"max_car_tier": 3, "ai_opponents": field, "ai_skill": 0.6,
	})

	PlayerManager.ensure_profiles()

	# Setup broken down, because "the race takes five seconds to start" needs to
	# name which part of it does.
	var t0 := Time.get_ticks_usec()
	var builder := TrackBuilder.new(track)
	var root := builder.build()
	var t1 := Time.get_ticks_usec()
	for phase in builder.build_timings:
		print("  %-26s %8.0f ms" % [phase, float(builder.build_timings[phase]) / 1000.0])
	var model := TrackModel.analyse(builder)
	var t2 := Time.get_ticks_usec()
	var racing_line := RacingLine.solve(model)
	var t3 := Time.get_ticks_usec()
	var probe_car := CarDatabase.get_car("impreza_gc8")
	var one_profile := SpeedProfile.solve(model, racing_line,
		TuningCalculator.resolve(probe_car, probe_car.default_loadout()))
	var t4 := Time.get_ticks_usec()
	root.queue_free()

	print("=== frame cost — %s, %d cars ===" % [track.display_name, field + 1])
	print("%-28s %8.0f ms" % ["build the track", float(t1 - t0) / 1000.0])
	print("%-28s %8.0f ms" % ["read the road", float(t2 - t1) / 1000.0])
	print("%-28s %8.0f ms" % ["solve the line", float(t3 - t2) / 1000.0])
	print("%-28s %8.0f ms" % ["one speed profile", float(t4 - t3) / 1000.0])

	var began := Time.get_ticks_usec()
	_director = RaceDirector.new()
	add_child(_director)
	_director.setup(event, track, CAR_SCENE)
	_setup_ms = float(Time.get_ticks_usec() - began) / 1000.0
	print("%-28s %8.0f ms" % ["whole race setup", _setup_ms])


func _physics_process(_delta: float) -> void:
	if _director == null:
		return
	# The director drives everything from its own _physics_process, so the way
	# to attribute cost is to time the pieces here rather than to wrap it.
	_time("progress lookups", func():
		for e in _director.entrants:
			if e.car != null:
				e.last_along = _director.builder.progress_at(
					e.car.global_position, e.last_along))

	_time("ai think", func():
		for e in _director.entrants:
			if e.ai != null and e.car != null and not e.car.damage.wrecked:
				e.ai.update(1.0 / 60.0))

	_time("rival awareness", func():
		for e in _director.entrants:
			if e.ai != null and e.ai.awareness != null:
				e.ai.awareness.update(1.0 / 60.0))

	_frames += 1
	if _frames >= FRAMES:
		_report()


func _time(name: String, work: Callable) -> void:
	var began := Time.get_ticks_usec()
	work.call()
	_totals[name] = float(_totals.get(name, 0.0)) + float(Time.get_ticks_usec() - began)


func _report() -> void:
	print("\n%-22s %12s %10s" % ["system", "per frame", "of budget"])
	var total := 0.0
	var names: Array = _totals.keys()
	names.sort()
	for name in names:
		var per_frame: float = float(_totals[name]) / float(_frames)
		total += per_frame
		print("%-22s %9.0f us %9.1f%%" % [
			name, per_frame, per_frame / BUDGET_US * 100.0])
	print("%-22s %9.0f us %9.1f%%" % ["measured total", total,
		total / BUDGET_US * 100.0])
	print("\n(a 60 Hz physics frame is %d us. Rendering is not in this number —" % int(BUDGET_US))
	print(" headless draws nothing — so anything close to full here is already")
	print(" too slow before a single pixel is put on the screen.)")
	get_tree().quit(0)
