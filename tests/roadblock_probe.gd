extends Node
## Does the field get past a car that is in its way?
##
## Written for a specific complaint: being slow at the front and having nobody
## come past. That is a general problem with a stable failure mode — a follower
## slows to match the car ahead, which drops its closing speed to nothing, and
## every rule that justifies a pass by "am I catching them?" then says no
## forever. The queue never resolves because the queue is what caused it.
##
## So this puts one car in the way and asks two questions with numbers rather
## than impressions: how long does each of the others take to get past it, and
## how many of them never do.
##
##   godot --headless --path . res://tests/roadblock_probe.tscn \
##       -- <track_id> [seconds] [field] [skill] [where]
##
## `where` is "grid" (the blocker starts on pole and never moves), "track" (it
## stops after a few seconds, mid-lap, in front of everybody), or "slow" (it
## drives the stage at a crawl, which is the harder case: a stopped car is
## obviously an obstacle, and a slow one is a rival that never gets away).

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
## How fast the "slow" blocker is allowed to go, in m/s. About thirty km/h:
## plainly moving, plainly not racing, and well clear of the speed below which
## the AI is already willing to call something an obstacle.
const SLOW_BLOCKER_MS := 8.0
## How far ahead of the blocker counts as past it, in metres.
const CLEAR_AHEAD_M := 8.0
## How close behind counts as queueing, in metres.
const QUEUE_GAP_M := 12.0

var _director: RaceDirector
var _blocker: RaceEntrant
var _elapsed: float = 0.0
var _limit: float = 60.0
var _where: String = "grid"
## When each entrant first got clear ahead of the blocker, in seconds.
var _passed_at: Dictionary = {}
## How long each one has spent sitting right behind it.
var _queued: Dictionary = {}
var _done: bool = false


## Holds the blocker back.
##
## Its own node, added after the director, because the director is a child of
## the probe and so runs its AI *after* the probe's own physics step — anything
## the probe wrote would simply be overwritten. The first version of this did
## exactly that and produced two identical result tables for two different
## scenarios, which is how it was caught.
class _Hold extends Node:
	var car: RallyCar
	var mode: String = "grid"
	var elapsed: float = 0.0

	func _physics_process(delta: float) -> void:
		elapsed += delta
		if car == null or not is_instance_valid(car):
			return
		if mode == "slow":
			# Still steered by its own driver, so it stays on the road; simply
			# never allowed above a crawl.
			var speed := car.speed_ms
			car.command.throttle = 0.4 if speed < SLOW_BLOCKER_MS else 0.0
			car.command.brake = 1.0 if speed > SLOW_BLOCKER_MS * 1.15 else 0.0
			car.command.nitro = false
			car.command.handbrake = false
		elif mode == "grid" or elapsed > 6.0:
			car.command.throttle = 0.0
			car.command.brake = 1.0
			car.command.handbrake = true


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "gravel_loop"
	_limit = float(args[1]) if args.size() > 1 else 60.0
	var field: int = int(args[2]) if args.size() > 2 else 7
	var skill: float = float(args[3]) if args.size() > 3 else 0.55
	_where = args[4] if args.size() > 4 else "grid"

	var track: TrackSpec = TrackSpec.load_all().get(track_id)
	if track == null:
		push_error("roadblock_probe: no track '%s'" % track_id)
		get_tree().quit(1)
		return

	var event := EventSpec.from_dict({
		"id": "roadblock", "name": "Roadblock", "track": track_id,
		"format": "sprint", "laps": 5, "payouts": [0], "xp": 0,
		"max_car_tier": 2, "ai_opponents": field, "ai_skill": skill,
	})
	PlayerManager.ensure_profiles()
	_director = RaceDirector.new()
	add_child(_director)
	_director.setup(event, track, CAR_SCENE)

	# The blocker is whoever starts on pole, so everybody else is behind it.
	_blocker = _director.entrants[0]
	for e in _director.entrants:
		if e != _blocker:
			_passed_at[e] = -1.0
			_queued[e] = 0.0

	var hold := _Hold.new()
	hold.car = _blocker.car
	hold.mode = _where
	add_child(hold)

	print("%s — %d cars, skill %.2f, blocker '%s' (%s)" % [
		track.display_name, _director.entrants.size(), skill,
		_blocker.display_name, _where])


func _physics_process(delta: float) -> void:
	if _director == null or _done:
		return
	_elapsed += delta

	# Measured by the running order the director keeps, not by comparing raw
	# progress. On the grid the blocker sits just *behind* the start line, so
	# its lap progress is almost a full lap — and every follower "passed" it the
	# moment they completed their own first lap. That reading said 6 of 6 got
	# past in seventeen seconds while the field was in fact still queued up
	# behind a parked car.
	var ppm := GameConfig.PIXELS_PER_METRE
	for e in _passed_at:
		var entrant: RaceEntrant = e
		if entrant.car == null or not is_instance_valid(entrant.car):
			continue
		if _blocker.car != null and is_instance_valid(_blocker.car):
			var gap_m := entrant.car.global_position.distance_to(
				_blocker.car.global_position) / ppm
			if gap_m < QUEUE_GAP_M and entrant.position > _blocker.position:
				_queued[e] = float(_queued[e]) + delta
		if float(_passed_at[e]) < 0.0 and entrant.position < _blocker.position:
			_passed_at[e] = _elapsed

	if _elapsed >= _limit:
		_report()


func _report() -> void:
	_done = true
	print("\nblocker finished at %.1f m/s, P%d" % [
		_blocker.car.speed_ms if _blocker.car != null else 0.0, _blocker.position])
	print("after %.0f s:" % _elapsed)
	print("  %-24s %10s %10s" % ["driver", "got past", "queued"])
	var past := 0
	var total := 0.0
	var queued_total := 0.0
	for e in _passed_at:
		var entrant: RaceEntrant = e
		var at: float = float(_passed_at[e])
		if at >= 0.0:
			past += 1
			total += at
		queued_total += float(_queued[e])
		print("  %-24s %10s %9.1fs" % [
			entrant.display_name,
			("%.1fs" % at) if at >= 0.0 else "never",
			float(_queued[e])])
	print("\n%d of %d got past" % [past, _passed_at.size()])
	if past > 0:
		print("mean time to get past: %.1f s" % (total / float(past)))
	print("total time spent stuck behind it: %.1f s" % queued_total)
	get_tree().quit(0)
