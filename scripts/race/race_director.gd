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
## Once every human in the race is home, the rest of the field gets this long to
## cross the line before it is classified where it stands.
##
## Waiting the full finish window for the AI meant a player who had just won sat
## looking at an empty road for up to a minute wondering whether the game had
## noticed. Nobody is watching the computer finish; they want their result.
const PLAYER_FINISH_GRACE := 5.0
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
## Race time at which the last human entrant stopped racing, or -1 while any of
## them still is.
var _player_done_time: float = -1.0
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

	AudioDirector.clear_local_cars()
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
		# Sound is mixed relative to the cars people are actually sitting in.
		AudioDirector.add_local_car(car)
		# The car arrives as tired as it left the garage. This is the whole
		# point of the servicing economy: what a player skipped shows up here.
		car.mechanical.load_condition(owned)
		PlayerManager.bind_car(seat.slot, car)

		var entrant := RaceEntrant.new()
		entrant.car = car
		entrant.owned_car = owned
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

		# Rivals run their own cars the way they treat them. A driver with no
		# mechanical sympathy turns the boost up, raises the limiter and arrives
		# on a car that has never been serviced — and sometimes does not finish
		# because of it. The same model decides that as decides the player's.
		_apply_ai_mechanical_state(car, driver, i)

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


## How hard a rival is on its own machinery, and how well kept that machinery
## is. Both come from mechanical_sympathy, so "the reckless one blew up" is a
## consequence of who they are rather than a scripted event.
## Given its own generator rather than the field's, seeded per entrant. Drawing
## from the shared one would shift every selection made after it, which quietly
## changed which cars and drivers turned up — a subsystem must not perturb an
## unrelated one just by existing.
func _apply_ai_mechanical_state(
	car: RallyCar,
	driver: DriverProfile,
	index: int
) -> void:
	if car.mechanical == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(event.id) * 31 + index
	var carelessness := clampf(1.0 - driver.mechanical_sympathy, 0.0, 1.0)
	car.mechanical.boost_setting = carelessness * rng.randf_range(0.3, 1.0)
	car.mechanical.rev_limit_setting = carelessness * rng.randf_range(0.0, 0.9)
	# A privateer running an old car is the normal case in this game, so rivals
	# carry mileage and imperfect servicing rather than arriving factory fresh.
	car.mechanical.engine_km = rng.randf_range(20000.0, 40000.0
		+ carelessness * 190000.0)
	car.mechanical.oil_life = rng.randf_range(0.35 + driver.mechanical_sympathy * 0.5, 1.0)
	car.mechanical.brake_life = rng.randf_range(0.4 + driver.mechanical_sympathy * 0.5, 1.0)
	car.mechanical.turbo_life = rng.randf_range(0.4 + driver.mechanical_sympathy * 0.5, 1.0)


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

		# A car with no engine or no fuel is not going anywhere. Saying so
		# immediately is kinder than making the player sit out the stall timer
		# wondering whether it will restart.
		if e.is_racing() and e.car.mechanical != null and e.car.mechanical.is_stranded():
			e.mark_dnf(e.car.mechanical.failure_text())

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


## A player giving up. Distinct from stalling out: it is immediate, and the
## reason says so on the results screen.
func retire_seat(slot: int) -> void:
	for e in entrants:
		if e.seat_slot == slot and e.is_racing():
			e.mark_dnf("retired by the driver")
			_publish_standings()
			return


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
	_update_gaps(ordered)
	standings_updated.emit(ordered)


## Time gaps along the road, estimated from the distance between two cars and
## the speed of the one doing the chasing.
##
## An exact gap needs a history of when each car passed each point, which is a
## lot of bookkeeping for a number that is only ever read to one decimal place.
## Distance over speed is what the driver is actually asking — "how long until
## I am there" — and it is right whenever it matters, which is when the cars are
## near each other and travelling at similar speeds.
func _update_gaps(ordered: Array) -> void:
	var ppm := GameConfig.PIXELS_PER_METRE
	for i in ordered.size():
		var e: RaceEntrant = ordered[i]
		e.gap_ahead = 0.0
		e.gap_behind = 0.0
		if not e.is_racing():
			continue
		# Floor the reference speed: a stationary car would otherwise report an
		# infinite gap, and "+inf" tells a driver nothing at all.
		var own_speed := maxf(e.car.speed_ms, 8.0) * ppm
		if i > 0:
			var lead: RaceEntrant = ordered[i - 1]
			e.gap_ahead = maxf(lead.total_progress - e.total_progress, 0.0) / own_speed
		if i + 1 < ordered.size():
			var chaser: RaceEntrant = ordered[i + 1]
			var chaser_speed := maxf(chaser.car.speed_ms, 8.0) * ppm
			e.gap_behind = maxf(e.total_progress - chaser.total_progress, 0.0) / chaser_speed


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

	# The first car home starts the clock on everyone else. Taken as the
	# earliest finish rather than the first one found in the list, which was
	# only the same thing by accident.
	for e in entrants:
		if e.finished and (_leader_finish_time < 0.0 or e.finish_time < _leader_finish_time):
			_leader_finish_time = e.finish_time

	# The window the field actually gets. Short once the people playing are
	# done, because from that moment the race is over as far as anyone in the
	# room is concerned.
	var window := FINISH_WINDOW_SECONDS
	var players_done := _all_players_done()
	if players_done and _player_done_time >= 0.0:
		window = minf(window, (_player_done_time - maxf(_leader_finish_time, 0.0))
			+ PLAYER_FINISH_GRACE)

	var still_going := false
	for e in entrants:
		if not e.is_racing():
			continue
		# Past the window, whoever is left is classified rather than waited for.
		# They keep their placing; they just stop holding up the results.
		if _leader_finish_time >= 0.0 and race_time - _leader_finish_time > window:
			e.mark_dnf("outside the time limit")
			continue
		still_going = true

	if not still_going:
		_finish_race()


## Whether every entrant somebody is actually sitting in front of is done —
## finished, retired or out. An AI-only field never satisfies this, which is
## correct: with nobody playing there is nobody to keep waiting.
func _all_players_done() -> bool:
	var any_player := false
	for e in entrants:
		if not e.is_player():
			continue
		any_player = true
		if e.is_racing():
			return false
	if any_player and _player_done_time < 0.0:
		_player_done_time = race_time
	return any_player


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

	# Persist what the race did to the car: the damage it took, and the wear it
	# put on. Mileage keeps counting whether the race went well or not.
	var owned: OwnedCar = entrant.owned_car
	if owned == null:
		owned = profile.get_car(profile.active_car_uid)
	if owned != null and entrant.car.damage != null:
		owned.damage = entrant.car.damage.snapshot()
		owned.write_off = entrant.car.damage.wrecked
		owned.races_entered += 1
		if entrant.position == 1:
			owned.wins += 1
		if entrant.car.mechanical != null:
			entrant.car.mechanical.store_condition(owned)
			result["distance_km"] = entrant.car.mechanical.odometer_km
			result["failures"] = entrant.car.mechanical.failure_text()
		result["repair_cost"] = owned.repair_cost()
		result["service_cost"] = _service_bill(owned)

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


## What it would cost to put every worn service item back to new. Shown on the
## results screen so a player is told about it rather than discovering it as a
## failure two events later.
func _service_bill(owned: OwnedCar) -> int:
	var total := 0
	for item in OwnedCar.SERVICE_ITEMS:
		total += owned.service_cost(item)
	return total


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
