extends Node
## Runs a full race and reports what happened in it.
##
## Written to answer two questions that cannot be answered by reading the AI:
## does it actually overtake, and is it quick enough to be worth racing?
##
## An AI that only ever follows and avoids is not an opponent, it is traffic.
## And a field that is comfortably slower than the player is not a race, it is
## a lap of honour. So this counts overtakes, tracks how the order changes,
## and reports every driver's best lap against the best anybody managed —
## which is the only fair measure of pace when they are all on the same road.
##
##   godot --headless --path . res://tests/race_probe.tscn \
##       -- <track_id> [laps] [ai_skill] [field_size]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

var _director: RaceDirector
var _order: Array[int] = []
var _overtakes: int = 0
var _lead_changes: int = 0
var _leader: int = -1
## Per entrant: how many places it has gained and lost over the whole race.
var _gained: Array[int] = []
var _lost: Array[int] = []
var _best_lap: Array[float] = []
## How long an order has to hold before a change in it counts as a pass.
const SETTLE_SECONDS := 1.5

var _confirmed: Array[int] = []
var _settle: float = SETTLE_SECONDS
## Seconds each car spent below walking pace, and off the road.
var _crawling: Array[float] = []
var _off_road_time: Array[float] = []
var _worst_off: Array[float] = []
## Seconds spent committed to an overtaking line.
var _committed: Array[float] = []
var _elapsed: float = 0.0
var _limit: float = 600.0
var _done := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	var laps: int = int(args[1]) if args.size() > 1 else 3
	var skill: float = float(args[2]) if args.size() > 2 else 0.55
	var field: int = int(args[3]) if args.size() > 3 else 9

	var tracks := TrackSpec.load_all()
	var track: TrackSpec = tracks.get(track_id)
	if track == null:
		push_error("race_probe: no track '%s'" % track_id)
		get_tree().quit(1)
		return

	var event := EventSpec.from_dict({
		"id": "race_probe", "name": "Race Probe", "track": track_id,
		"format": "sprint", "laps": laps, "payouts": [0], "xp": 0,
		"max_car_tier": 2, "ai_opponents": field, "ai_skill": skill,
	})

	# No human seat: every car is driven by the model, so the pace spread that
	# comes out is the model's own and not an artefact of a parked car.
	PlayerManager.ensure_profiles()
	_director = RaceDirector.new()
	add_child(_director)
	_director.setup(event, track, CAR_SCENE)
	_director.race_complete.connect(_on_complete)

	for i in _director.entrants.size():
		_order.append(i)
		_confirmed.append(i)
		_gained.append(0)
		_lost.append(0)
		_best_lap.append(INF)
		_crawling.append(0.0)
		_off_road_time.append(0.0)
		_worst_off.append(0.0)
		_committed.append(0.0)

	print("%s — %d laps, %.0f m, %d cars, skill %.2f" % [
		track.display_name, laps,
		_director.builder.total_length_px / GameConfig.PIXELS_PER_METRE,
		_director.entrants.size(), skill])
	print("field:")
	for e in _director.entrants:
		print("  %-24s %-28s %s" % [e.display_name,
			e.car.spec.display_name() if e.car != null and e.car.spec != null else "?",
			e.driver_name])


func _physics_process(delta: float) -> void:
	if _director == null or _done:
		return
	_elapsed += delta

	# The running order, by progress along the road. Every swap between
	# adjacent entrants is one car passing another.
	var ranked: Array[int] = []
	for i in _director.entrants.size():
		ranked.append(i)
	ranked.sort_custom(func(a, b):
		return _director.entrants[a].total_progress > _director.entrants[b].total_progress)

	# A pass only counts once it has stuck. Comparing the order frame by frame
	# counted every wobble between two cars running nose to tail as an
	# overtake, and gave three hundred of them in a nine-car race — a number
	# that says nothing except that the two cars were close.
	_settle -= delta
	if _settle <= 0.0:
		_settle = SETTLE_SECONDS
		for place in ranked.size():
			var who := ranked[place]
			var was := _confirmed.find(who)
			if was > place:
				_gained[who] += was - place
				_overtakes += was - place
			elif was < place:
				_lost[who] += place - was
		_confirmed = ranked.duplicate()
	_order = ranked

	# What each car is actually doing, which is the only way to tell a slow
	# driver from a stuck one.
	for i in _director.entrants.size():
		var car := _director.entrants[i].car
		if car == null:
			continue
		# Only while the car is still in the race. Counting the winner sitting
		# on the finish line waiting for everyone else gave the leader the worst
		# "stopped" figure on the sheet, which is exactly backwards and cost a
		# round of chasing the wrong thing.
		if car.speed_ms < 2.0 and _director.entrants[i].is_racing():
			_crawling[i] += delta
		# Committed to a move: the driver has picked a side and is holding it.
		# This is the direct answer to "does it overtake or only follow" —
		# position changes alone cannot tell a pass from a rival slowing down.
		var ai := _director.entrants[i].ai
		if ai != null and not is_zero_approx(ai._overtake_side):
			_committed[i] += delta
		var off := _off_road(car)
		if off > 0.0:
			_off_road_time[i] += delta
			_worst_off[i] = maxf(_worst_off[i], off)

	# The lead, counted from the settled order rather than the raw one. Reading
	# it every physics frame counted two cars running nose to tail swapping the
	# lead a hundred and seventy times in three laps, which is not a lead change
	# — it is the same lead being measured very precisely.
	if not _confirmed.is_empty() and _confirmed[0] != _leader:
		if _leader >= 0:
			_lead_changes += 1
		_leader = _confirmed[0]

	for i in _director.entrants.size():
		var e: RaceEntrant = _director.entrants[i]
		if e.best_lap > 0.0 and e.best_lap < _best_lap[i]:
			_best_lap[i] = e.best_lap

	if _elapsed > _limit:
		print("\n(timed out after %.0f s)" % _limit)
		_report([])


## How far outside the road edge a car is, in metres. Zero when it is on it.
func _off_road(car: RallyCar) -> float:
	var ppm := GameConfig.PIXELS_PER_METRE
	var along := _director.builder.progress_at(car.global_position)
	var centre := _director.builder.curve.sample_baked(
		clampf(along, 0.0, _director.builder.total_length_px))
	var lateral := car.global_position.distance_to(centre) / ppm
	return maxf(lateral - _director.builder.spec.width * 0.5, 0.0)


func _on_complete(results: Array) -> void:
	_report(results)


func _report(results: Array) -> void:
	if _done:
		return
	_done = true

	print("\n--- what happened ---")
	print("overtakes            %d" % _overtakes)
	print("lead changes         %d" % _lead_changes)

	print("\n%-22s %5s %8s %6s %6s %7s %7s %6s  %s" % [
		"driver", "place", "best lap", "gain", "lose", "stopped", "attack",
		"hits", "result"])
	var finished := 0
	var fastest := INF
	for i in _best_lap.size():
		fastest = minf(fastest, _best_lap[i])
	for place in _order.size():
		var i := _order[place]
		var e: RaceEntrant = _director.entrants[i]
		var lap := _best_lap[i]
		var outcome := "running"
		for r in results:
			if r["entrant"] == e:
				outcome = "DNF (%s)" % r["dnf_reason"] if r["dnf"] else "P%d" % int(r["position"])
				if not r["dnf"]:
					finished += 1
		print("%-22s %5d %8s %6d %6d %6.0fs %6.0fs %5.0f  %s" % [
			e.display_name, place + 1,
			("%.2f" % lap) if lap < INF else "-",
			_gained[i], _lost[i], _crawling[i], _committed[i],
			float(e.car.contacts_with_cars) if e.car != null else 0.0, outcome])

	# The spread of pace across the field. Too tight and every race is a
	# procession decided at the start; too wide and the back half is scenery.
	var laps: Array[float] = []
	for lap in _best_lap:
		if lap < INF:
			laps.append(lap)
	if laps.size() >= 2:
		laps.sort()
		var spread := (laps[-1] - laps[0]) / maxf(laps[0], 0.001) * 100.0
		print("\nbest lap %.2f s, slowest %.2f s — the field is spread over %.1f%%"
			% [laps[0], laps[-1], spread])
		print("median   %.2f s" % laps[laps.size() / 2])

	# Where the spread comes from. A field strung out over fifty per cent is a
	# procession, but the fix is completely different depending on whether the
	# back markers are in slower cars or are slower drivers — and those two are
	# indistinguishable from lap times alone.
	print("\n%-22s %8s %8s %8s" % ["driver", "best lap", "car", "driver"])
	for i in _director.entrants.size():
		var e: RaceEntrant = _director.entrants[i]
		var index := 0.0
		if e.car != null and e.car.stats != null:
			index = e.car.stats.performance_index()
		print("%-22s %8s %8.0f %8d" % [
			e.display_name,
			("%.2f" % _best_lap[i]) if _best_lap[i] < INF else "-",
			index,
			FieldPreview.rating_for(e.ai.profile) if e.ai != null else 0])
	var attacking := 0.0
	for t in _committed:
		attacking += t
	print("time spent committed to a pass, across the field: %.0f s" % attacking)
	# What actually ended each car's race. Guessing at this cost two rounds of
	# fixes aimed at the wrong thing.
	var causes := {}
	for e in _director.entrants:
		var why := "still running"
		if e.car != null and e.car.damage != null and e.car.damage.wrecked:
			why = "wrecked"
		elif e.car != null and e.car.mechanical != null \
				and not e.car.mechanical.failed.is_empty():
			why = e.car.mechanical.failure_text()
		causes[why] = int(causes.get(why, 0)) + 1
	print("\nwhat ended each race:")
	for why in causes:
		print("  %-40s %d" % [why, causes[why]])

	# What the stage actually consumed, driven rather than assumed. The service
	# probe answers this from a made-up duty cycle; this answers it from the
	# pedals the AI genuinely used, which is the only version that can be wrong
	# in a way worth knowing about.
	print("\n%-22s %8s %8s %8s %8s" % ["driver", "oil left", "pads", "tyres", "fuel"])
	for e in _director.entrants:
		if e.car == null or e.car.mechanical == null:
			continue
		var m := e.car.mechanical
		print("%-22s %7.0f%% %7.0f%% %7.0f%% %7.0f%%" % [
			e.display_name, m.oil_life * 100.0, m.brake_life * 100.0,
			float(e.car.damage.integrity.get("tires", 1.0)) * 100.0,
			m.fuel_l / maxf(m.tank_l, 1.0) * 100.0])

	var contacts := 0
	var wrecked := 0
	for e in _director.entrants:
		if e.car == null:
			continue
		contacts += e.car.contacts_with_cars
		if e.car.damage != null and e.car.damage.wrecked:
			wrecked += 1
	print("car-to-car contacts %d, wrecked %d" % [contacts, wrecked])
	print("finished %d of %d" % [finished, _director.entrants.size()])
	get_tree().quit(0)
