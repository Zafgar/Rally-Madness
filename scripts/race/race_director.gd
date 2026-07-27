class_name RaceDirector
extends Node
## Runs one race from the grid to the results screen.
##
## Owns the countdown, checkpoint and lap validation, the live standings, the
## per-format win conditions, and the payout that writes back to each player's
## profile. Everything downstream of "the player pressed Race" happens here.

const COUNTDOWN_SECONDS := 3.5
## Once the leader crosses the line the rest of the field races a clock rather
## than each other. Without this, one parked or hopelessly slow car holds the
## results screen open forever — which is exactly what a wrecked player, or a
## player who put the controller down, will do.
const FINISH_WINDOW_SECONDS := 60.0
## A car making no progress at all for this long is classified as retired. This
## catches the case where nobody has finished yet, so the finish window has not
## started, but the field is going nowhere.
const STALL_TIMEOUT_SECONDS := 45.0
## Distance (in pixels along the centreline) that counts as having moved.
const STALL_PROGRESS_EPSILON := 40.0

enum State { SETUP, COUNTDOWN, RACING, FINISHED }

var state: State = State.SETUP
var event: EventSpec
var track_spec: TrackSpec
var builder: TrackBuilder

var entrants: Array[RaceEntrant] = []
var race_time: float = 0.0
var countdown_remaining: float = 0.0

var _car_scene: PackedScene
var _track_root: Node2D
var _entrant_by_car_id: Dictionary = {}
var _next_car_id: int = 1
var _elimination_timer: float = 0.0
## Elimination format drops the last car at this interval.
var _elimination_interval: float = 30.0
## Race time at which the leader finished, or -1 while nobody has.
var _leader_finish_time: float = -1.0
## Shared surface every car lays its tyre marks onto.
var mark_layer: TireMarks

signal standings_updated(ordered: Array)
signal race_complete(results: Array)


func setup(p_event: EventSpec, p_track: TrackSpec, car_scene: PackedScene) -> void:
	event = p_event
	track_spec = p_track
	_car_scene = car_scene

	builder = TrackBuilder.new(track_spec)
	_track_root = builder.build()
	add_child(_track_root)

	# Marks belong to the road, not to the car that laid them.
	mark_layer = TireMarks.new()
	mark_layer.name = "TireMarks"
	add_child(mark_layer)

	for cp in builder.checkpoints:
		cp.car_passed.connect(_on_checkpoint_passed)

	_spawn_players()
	_spawn_ai()
	_share_field()
	_begin_countdown()


# --- Spawning ---------------------------------------------------------------

func _spawn_players() -> void:
	var grid_index := 0
	for seat in PlayerManager.seats:
		if seat.profile == null:
			continue
		var owned := seat.profile.ensure_driveable_car()
		if owned == null:
			push_warning("RaceDirector: seat %d has no driveable car" % seat.slot)
			continue

		var car := _make_car(owned.spec(), owned.loadout, owned.damage, grid_index)
		car.is_locally_controlled = true
		PlayerManager.bind_car(seat.slot, car)

		var entrant := RaceEntrant.new()
		entrant.car = car
		entrant.seat_slot = seat.slot
		entrant.profile = seat.profile
		entrant.display_name = seat.display_name()
		entrant.laps_target = event.laps
		entrants.append(entrant)
		_entrant_by_car_id[car.car_id] = entrant
		grid_index += 1


func _spawn_ai() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(event.id)
	var grid_index := entrants.size()

	# AI cars are drawn from the same catalogue and tier band the event allows,
	# so the field is always something the player could have brought.
	var pool := _eligible_ai_cars()
	if pool.is_empty():
		return

	var ai_tires := _tire_choice_for(track_spec.default_surface)

	for i in event.ai_opponents:
		var spec: CarSpec = pool[rng.randi_range(0, pool.size() - 1)]
		var loadout := spec.default_loadout()
		# Rivals turn up on tires that suit the stage. Without this the whole
		# field arrives at the winter trial on summer rubber and the event is
		# a walkover rather than a test of the player's own tire choice.
		if not ai_tires.is_empty():
			loadout.set_part("tires", ai_tires)
		var car := _make_car(spec, loadout, {}, grid_index)
		car.is_locally_controlled = false

		var entrant := RaceEntrant.new()
		entrant.car = car
		entrant.display_name = _ai_name(i, rng)
		entrant.laps_target = event.laps

		# Rivals are people, not difficulty settings: the archetype decides how
		# they drive, and it is picked from a band around the event's level
		# rather than being the event's level. A club meeting still gets the
		# occasional quick driver and a works event still gets someone out of
		# their depth.
		var driver := DriverProfile.pick_for(event.ai_skill, rng)
		entrant.driver_name = driver.display_name

		# Each rival also gets its own habitual offset from the centreline, so
		# the field spreads across the road instead of queueing up on one line.
		var lane_span := maxf(track_spec.width * 0.5 - 3.0, 1.0)
		entrant.ai = AIDriver.new(car, builder, driver,
			rng.randf_range(-lane_span, lane_span), rng.randi())
		entrants.append(entrant)
		_entrant_by_car_id[car.car_id] = entrant
		grid_index += 1


## The tire an AI driver would sensibly fit for this stage. Kept as data-driven
## as the rest: if the part is missing from the catalogue the AI simply runs
## whatever the car came with.
func _tire_choice_for(surface: TireModel.Surface) -> String:
	var preferred := ""
	match surface:
		TireModel.Surface.TARMAC:
			preferred = "tires_semislick"
		TireModel.Surface.SNOW, TireModel.Surface.ICE:
			preferred = "tires_studded"
		TireModel.Surface.MUD:
			preferred = "tires_mud"
		_:
			preferred = "tires_gravel"
	if PartDatabase.get_part(preferred) == null:
		return ""
	return preferred


func _eligible_ai_cars() -> Array:
	var pool := []
	var band := event.effective_tier_range()
	var cap := event.race_class().max_performance_index
	for spec in CarDatabase.all():
		if spec.tier < band.x or spec.tier > band.y:
			continue
		# Rivals obey the same performance cap the player does, so a class
		# limit means something on both sides of the grid.
		if spec.to_base_stats().performance_index() > cap:
			continue
		if not event.drivetrain_required.is_empty():
			var dt: String = ["FWD", "RWD", "AWD"][spec.drivetrain]
			if not event.drivetrain_required.has(dt):
				continue
		if not event.category_required.is_empty() \
				and not event.category_required.has(spec.category):
			continue
		pool.append(spec)
	return pool


func _make_car(
	spec: CarSpec,
	loadout: TuningLoadout,
	damage: Dictionary,
	grid_index: int
) -> RallyCar:
	var car: RallyCar = _car_scene.instantiate()
	car.car_id = _next_car_id
	_next_car_id += 1
	car.configure(spec, loadout, damage)
	add_child(car)

	var grid := builder.start_grid
	var t: Transform2D = grid[grid_index % grid.size()] if not grid.is_empty() else Transform2D()
	car.set_spawn(t)
	car.mark_layer = mark_layer
	car.lights_on = track_spec.night
	car.wrecked.connect(_on_car_wrecked)
	return car


const AI_FIRST_NAMES := [
	"Mikko", "Sanna", "Petri", "Hanne", "Ove", "Kirsi", "Jussi", "Ari",
	"Lotta", "Timo", "Riikka", "Kari", "Eeva", "Janne", "Tuula", "Olli",
]
const AI_LAST_NAMES := [
	"Aho", "Virtanen", "Nieminen", "Laine", "Koskinen", "Heikkila",
	"Rantanen", "Salo", "Lehto", "Maki", "Hakala", "Kallio",
]


func _ai_name(index: int, rng: RandomNumberGenerator) -> String:
	var first: String = AI_FIRST_NAMES[rng.randi() % AI_FIRST_NAMES.size()]
	var last: String = AI_LAST_NAMES[rng.randi() % AI_LAST_NAMES.size()]
	return "%s %s" % [first, last]


## Hands every AI the list of cars it might have to avoid. Players are in it
## too: an AI that only sees other AI is not racing, it is performing.
func _share_field() -> void:
	var cars: Array = []
	for e in entrants:
		if e.car != null:
			cars.append(e.car)
	for e in entrants:
		if e.ai != null:
			e.ai.awareness.set_field(cars)


# --- Flow -------------------------------------------------------------------

func _begin_countdown() -> void:
	state = State.COUNTDOWN
	countdown_remaining = COUNTDOWN_SECONDS
	race_time = 0.0
	for e in entrants:
		e.car.command.clear()
	EventBus.race_countdown_started.emit(COUNTDOWN_SECONDS)


func _physics_process(delta: float) -> void:
	match state:
		State.COUNTDOWN:
			countdown_remaining -= delta
			# Cars are held still on the grid; the pads are read but ignored.
			for e in entrants:
				e.car.command.clear()
			if countdown_remaining <= 0.0:
				_start_race()
		State.RACING:
			race_time += delta
			_update_ai(delta)
			_update_progress()
			_check_format_conditions(delta)
		_:
			pass


func _start_race() -> void:
	state = State.RACING
	for e in entrants:
		e.start_lap(0.0)
		e.stall_reference_position = e.car.global_position
		e.stall_reference_time = 0.0
	EventBus.race_started.emit()


func _update_ai(delta: float) -> void:
	for e in entrants:
		if e.ai != null and e.is_racing():
			e.car.command = e.ai.update(delta)


func _update_progress() -> void:
	for e in entrants:
		if e.car == null:
			continue
		var along := builder.progress_at(e.car.global_position)
		e.total_progress = float(e.lap) * builder.total_length_px + along
		if not e.started:
			# Still on the grid, which is measured near the *end* of the lap.
			# Shift it behind zero so a car waiting to start never outranks one
			# that is already going.
			e.total_progress -= builder.total_length_px

		# A car that burned out or was written off is out of the race, but it
		# stays on track as an obstacle for a moment first.
		if e.car.damage != null and e.car.damage.wrecked and e.is_racing():
			e.mark_dnf(e.car.damage.wreck_cause)

		if e.is_racing():
			_check_stalled(e)

	_publish_standings()


## Retires a car that has stopped making progress. Covers the parked
## controller, the car wedged against a barrier facing the wrong way, and the
## wreck that is still technically driveable but going nowhere.
func _check_stalled(e: RaceEntrant) -> void:
	var moved := e.car.global_position.distance_to(e.stall_reference_position)
	if moved > STALL_PROGRESS_EPSILON:
		e.stall_reference_position = e.car.global_position
		e.stall_reference_time = race_time
		return
	if race_time - e.stall_reference_time > STALL_TIMEOUT_SECONDS:
		e.mark_dnf("retired")


func _publish_standings() -> void:
	var ordered := entrants.duplicate()
	ordered.sort_custom(func(a, b):
		var ka: Array = a.standing_key()
		var kb: Array = b.standing_key()
		for i in ka.size():
			if not is_equal_approx(float(ka[i]), float(kb[i])):
				return float(ka[i]) < float(kb[i])
		return false)
	for i in ordered.size():
		ordered[i].position = i + 1
	standings_updated.emit(ordered)


func _check_format_conditions(delta: float) -> void:
	match event.format:
		EventSpec.Format.ELIMINATION:
			_elimination_timer += delta
			if _elimination_timer >= _elimination_interval:
				_elimination_timer = 0.0
				_eliminate_last()
		EventSpec.Format.DERBY:
			# No finish line: the race ends when one car is left running.
			var alive := 0
			for e in entrants:
				if e.is_racing():
					alive += 1
			if alive <= 1:
				for e in entrants:
					if e.is_racing():
						e.finished = true
						e.finish_time = race_time
				_finish_race()
		_:
			pass

	if event.format == EventSpec.Format.DERBY:
		return

	# The first car home starts the clock on everyone else.
	if _leader_finish_time < 0.0:
		for e in entrants:
			if e.finished:
				_leader_finish_time = e.finish_time
				break

	var still_going := false
	for e in entrants:
		if not e.is_racing():
			continue
		# Past the finish window, whoever is left is classified rather than
		# waited for. They keep their placing; they just stop holding up the
		# results.
		if _leader_finish_time >= 0.0 \
				and race_time - _leader_finish_time > FINISH_WINDOW_SECONDS:
			e.mark_dnf("outside the time limit")
			continue
		still_going = true

	if not still_going:
		_finish_race()


func _eliminate_last() -> void:
	var running: Array[RaceEntrant] = []
	for e in entrants:
		if e.is_racing():
			running.append(e)
	if running.size() <= 1:
		return
	running.sort_custom(func(a, b): return a.total_progress < b.total_progress)
	running[0].eliminated = true


# --- Checkpoints ------------------------------------------------------------

func _on_checkpoint_passed(car: RallyCar, index: int) -> void:
	if state != State.RACING:
		return
	var entrant: RaceEntrant = _entrant_by_car_id.get(car.car_id)
	if entrant == null or not entrant.is_racing():
		return
	# Only the checkpoint the car is actually due at counts. This is what makes
	# cutting the course pointless: skip a gate and the next one does nothing.
	if index != entrant.next_checkpoint:
		return

	EventBus.checkpoint_passed.emit(car.car_id, index)
	entrant.last_checkpoint_time = race_time
	entrant.next_checkpoint = (index + 1) % builder.checkpoints.size()

	# Crossing gate zero for the first time is the actual start of the car's
	# race: the grid sits behind the line, so this is where lap timing begins.
	if index == 0 and not entrant.started:
		entrant.started = true
		entrant.start_lap(race_time)
		return

	# Wrapping back to gate zero means a completed lap.
	if entrant.next_checkpoint == 0:
		var lap_time := entrant.complete_lap(race_time)
		EventBus.lap_completed.emit(car.car_id, entrant.lap, lap_time)
		if entrant.lap >= entrant.laps_target:
			entrant.finished = true
			entrant.finish_time = race_time


func _finish_race() -> void:
	if state == State.FINISHED:
		return
	state = State.FINISHED
	_publish_standings()

	var results := _build_results()
	for r in results:
		_apply_result(r)
	PlayerManager.save_all_profiles()
	# The race is over; stop shaking everyone's hands.
	PlayerManager.release_haptics()

	EventBus.race_finished.emit(results)
	race_complete.emit(results)


# --- Results and payouts ----------------------------------------------------

func _build_results() -> Array:
	var ordered := entrants.duplicate()
	ordered.sort_custom(func(a, b):
		var ka: Array = a.standing_key()
		var kb: Array = b.standing_key()
		for i in ka.size():
			if not is_equal_approx(float(ka[i]), float(kb[i])):
				return float(ka[i]) < float(kb[i])
		return false)

	var results := []
	for i in ordered.size():
		var e: RaceEntrant = ordered[i]
		e.position = i + 1
		results.append({
			"entrant": e,
			"position": e.position,
			"name": e.display_name,
			"time": e.finish_time if e.finished else 0.0,
			"best_lap": e.best_lap if e.best_lap < INF else 0.0,
			"dnf": e.dnf,
			"dnf_reason": e.dnf_reason,
			"is_player": e.is_player(),
			"payout": 0,
			"xp": 0,
			"repair_cost": 0,
		})
	return results


## Writes one entrant's result back to their profile: prize money, XP,
## sponsors, rating, unlocks and the damage their car came home with.
func _apply_result(result: Dictionary) -> void:
	var entrant: RaceEntrant = result["entrant"]
	if not entrant.is_player() or entrant.profile == null:
		return
	var profile: PlayerProfile = entrant.profile

	# Counted before the result is recorded, so the first run pays in full.
	var repeats := profile.times_completed(event.id)
	var payout := 0
	var xp := 0
	if not entrant.dnf:
		payout = event.payout_for(entrant.position, repeats)
		xp = int(event.xp_reward * lerpf(1.0, 1.6, _position_score(entrant))
			* EventSpec.repeat_scale(repeats))
	else:
		# A DNF still pays a token amount so a wreck is a setback, not a wall.
		payout = int(event.payout_for(entrants.size(), repeats) * 0.25)
		xp = int(event.xp_reward * 0.2)
		profile.stat_wrecks += 1

	payout += _apply_sponsors(profile, entrant)

	profile.earn(payout)
	var levels := profile.award_xp(xp)
	profile.stat_races += 1
	if entrant.position == 1 and not entrant.dnf:
		profile.stat_wins += 1

	# Persist the damage the car actually took, so it is still bent in the pits.
	var owned := profile.get_car(profile.active_car_uid)
	if owned != null and entrant.car.damage != null:
		owned.damage = entrant.car.damage.snapshot()
		owned.write_off = entrant.car.damage.wrecked
		owned.races_entered += 1
		if entrant.position == 1:
			owned.wins += 1
		result["repair_cost"] = owned.repair_cost()

	if not entrant.dnf:
		profile.complete_event(event.id, entrant.finish_time)
		result["unlocked"] = EventDatabase.apply_unlocks(profile, event.id)
		result["sponsor_offers"] = EventDatabase.sponsor_offers_for(
			profile, event.sponsor_offers)

	# Online races move the rating at full weight against the real field.
	# Career races move it too, at reduced weight against what the AI field is
	# worth — several classes are gated on rating, and a player who never goes
	# online still has to be able to reach them.
	if NetManager.is_online():
		result["rating_delta"] = profile.update_rating(
			_field_average_rating(), entrant.position, entrants.size())
	else:
		result["rating_delta"] = profile.update_rating(
			event.field_rating(), entrant.position, entrants.size(),
			EventSpec.CAREER_RATING_WEIGHT)

	result["payout"] = payout
	result["xp"] = xp
	result["levels_gained"] = levels

	EventBus.money_changed.emit(entrant.seat_slot, profile.money, payout)
	if levels > 0:
		EventBus.level_changed.emit(entrant.seat_slot, profile.level)


func _position_score(entrant: RaceEntrant) -> float:
	if entrants.size() <= 1:
		return 1.0
	return 1.0 - float(entrant.position - 1) / float(entrants.size() - 1)


func _apply_sponsors(profile: PlayerProfile, entrant: RaceEntrant) -> int:
	var earned := 0
	var expired: Array[String] = []
	for sponsor_id in profile.sponsors:
		var state: Dictionary = profile.sponsors[sponsor_id]
		earned += SponsorSpec.apply_result(state, entrant.position, entrant.dnf)
		if int(state.get("races_remaining", 0)) <= 0:
			expired.append(sponsor_id)

	for sponsor_id in expired:
		var state: Dictionary = profile.sponsors[sponsor_id]
		var sponsor := EventDatabase.get_sponsor(sponsor_id)
		if sponsor != null:
			if SponsorSpec.objective_met(state):
				earned += sponsor.completion_bonus
			else:
				earned -= sponsor.failure_penalty
		profile.sponsors.erase(sponsor_id)
	return earned


func _field_average_rating() -> int:
	var sum := 0
	var count := 0
	for e in entrants:
		if e.profile != null:
			sum += e.profile.rating
			count += 1
	if count == 0:
		return PlayerProfile.DEFAULT_RATING
	return int(sum / count)


func _on_car_wrecked(car_id: int, cause: String) -> void:
	var entrant: RaceEntrant = _entrant_by_car_id.get(car_id)
	if entrant != null:
		entrant.mark_dnf(cause)


# --- Queries for the HUD ----------------------------------------------------

func entrant_for_seat(slot: int) -> RaceEntrant:
	for e in entrants:
		if e.seat_slot == slot:
			return e
	return null


func standings() -> Array[RaceEntrant]:
	var ordered := entrants.duplicate()
	ordered.sort_custom(func(a, b): return a.position < b.position)
	return ordered
