class_name RaceScene
extends Node2D
## Wires a race together: the director simulates it, the split screen renders
## it, and this node keeps the two in step.
##
## Named so that other scripts can reach the constants that define what a race
## looks like — the night screenshot harness has to darken its scene by exactly
## the amount a real night stage does, or it is testing a night nobody will ever
## play. Without the name the reference parses in a headless run, where nothing
## loads that file, and fails the moment the editor opens the project.

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")
const MENU_SCENE_PATH := "res://scenes/boot.tscn"
## How much light a night stage has before the headlights. Blue, because
## moonlight is, and about a third of daylight, because a driver has to be able
## to see the corner before the beams pick it out.
const NIGHT_LIGHT := Color(0.38, 0.41, 0.52)

@export var event_id: String = "shakedown"

var director: RaceDirector
var split: SplitScreen
var _tracks: Dictionary = {}
var _results_shown: bool = false
var _overlay: RaceOverlay
var _paused: bool = false
## The last thing the countdown said, so each number is announced once.
var _countdown_spoken: String = ""


func _ready() -> void:
	_tracks = TrackSpec.load_all()

	var event := EventDatabase.get_event(event_id)
	if event == null:
		push_error("RaceScene: unknown event '%s'" % event_id)
		return
	var track: TrackSpec = _tracks.get(event.track_id)
	if track == null:
		push_error("RaceScene: event '%s' wants unknown track '%s'" % [event_id, event.track_id])
		return

	# Seats must exist before the director spawns cars for them.
	if PlayerManager.seat_count() == 0:
		PlayerManager.join(DeviceInput.DEVICE_KEYBOARD)
	PlayerManager.ensure_profiles()
	_charge_entry_fees(event)

	director = RaceDirector.new()
	director.name = "RaceDirector"
	add_child(director)
	director.setup(event, track, CAR_SCENE)
	director.race_complete.connect(_on_race_complete)

	split = SplitScreen.new()
	split.name = "SplitScreen"
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	layer.name = "ViewLayer"
	add_child(layer)
	layer.add_child(split)
	split.build(PlayerManager.seats, get_viewport().world_2d)
	split.bind_cars()

	# The map needs the stage and everybody on it, which only exists once the
	# director has spawned the field.
	var all_cars: Array = []
	for entrant in director.entrants:
		all_cars.append(entrant.car)
	for view in split.views:
		view["hud"].bind_race(director.builder, all_cars)

	# The network layer addresses cars by id when replicating.
	if NetManager.is_online():
		for entrant in director.entrants:
			NetManager.tracked_cars[entrant.car.car_id] = entrant.car

	# Pause and results, on their own layer above the split screen.
	var overlay_layer := CanvasLayer.new()
	overlay_layer.name = "OverlayLayer"
	overlay_layer.layer = 10
	# Runs while everything else is stopped, which is what a pause menu is.
	overlay_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(overlay_layer)
	_overlay = RaceOverlay.new()
	_overlay.resume_requested.connect(_resume)
	_overlay.retire_requested.connect(_retire_all_players)
	_overlay.quit_requested.connect(_return_to_menu)
	_overlay.continue_requested.connect(_return_to_menu)
	_overlay.pause_toggled.connect(_toggle_pause)
	_overlay.settings_requested.connect(_open_settings)
	overlay_layer.add_child(_overlay)

	# Night. It existed only in the screenshot harness before this, so a night
	# stage in the actual game was as bright as a summer afternoon and the
	# headlights lit nothing worth seeing.
	#
	# Dark enough to read as night and blue enough to read as moonlight, but
	# nowhere near as dark as real darkness: a top-down game where you cannot
	# see the road until the headlights reach it is not atmospheric, it is
	# unplayable. The headlights then add a genuinely brighter cone on top,
	# which is what makes turning them on worth doing.
	if director != null and director.track_spec != null and director.track_spec.night:
		var dusk := CanvasModulate.new()
		dusk.name = "NightLight"
		dusk.color = NIGHT_LIGHT
		add_child(dusk)

	# Music down but not off while driving: twelve engines have to get past it,
	# and a soundtrack that vanishes the moment the action starts is one nobody
	# ever hears.
	AudioDirector.duck_music(true)
	AudioDirector.music.play("grid")

	_countdown_message(RaceDirector.COUNTDOWN_SECONDS)


## Entry fees come out before the race, not after, so a player feels the cost
## of turning up to something expensive.
func _charge_entry_fees(event: EventSpec) -> void:
	for seat in PlayerManager.seats:
		if seat.profile == null or event.entry_fee <= 0:
			continue
		if not seat.profile.spend(event.entry_fee):
			push_warning("RaceScene: seat %d cannot afford the entry fee" % seat.slot)


## Escape opens the pause menu and closes it again. Available from the moment
## the race exists, because "I want to stop now" is not a request a game should
## make somebody wait for.
func _toggle_pause() -> void:
	if _overlay == null or _results_shown:
		return
	if _paused:
		_resume()
	else:
		_pause()


func _pause() -> void:
	_paused = true
	get_tree().paused = true
	var name := director.event.display_name if director != null else "Race"
	_overlay.show_pause(name, _any_player_racing())


func _resume() -> void:
	_paused = false
	get_tree().paused = false
	_overlay.close()


func _any_player_racing() -> bool:
	if director == null:
		return false
	for e in director.entrants:
		if e.is_player() and e.is_racing():
			return true
	return false


## Retiring from the pause menu. Everyone sitting here is out, and the race then
## wraps up on its own through the normal path — so the player still gets their
## result and their DNF money rather than nothing.
func _retire_all_players() -> void:
	if director != null:
		for e in director.entrants:
			if e.is_player() and e.is_racing():
				director.retire_seat(e.seat_slot)
	_resume()


## The sound sliders, from the pause menu, while the race is stopped. On its own
## layer above the overlay and running while paused, like everything else here.
func _open_settings() -> void:
	if get_node_or_null("SettingsLayer") != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "SettingsLayer"
	layer.layer = 20
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	var screen := SettingsScreen.new()
	screen.closed.connect(func():
		remove_child(layer)
		layer.queue_free()
		# Back to the pause menu the player opened it from, still paused.
		if _overlay != null and not _results_shown:
			_pause())
	layer.add_child(screen)


## Back to the career the race was entered from. Abandoning mid-race pays
## nothing, which is why it is worded as abandoning and retiring is not.
func _return_to_menu() -> void:
	get_tree().paused = false
	# A race is entered from the calendar, so this is where it should end up.
	GameConfig.resume_career = true
	AudioDirector.duck_music(false)
	AudioDirector.clear_local_cars()
	PlayerManager.release_haptics()
	var packed: PackedScene = load(MENU_SCENE_PATH)
	if packed == null:
		return
	var scene := packed.instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene


func _process(delta: float) -> void:
	if director == null or split == null:
		return
	# Clients send their intent up; the host is the one simulating.
	if NetManager.state == NetManager.State.CONNECTED:
		var seat = PlayerManager.get_seat(0)
		if seat != null and seat.device != null:
			NetManager.send_local_command(seat.device.poll(delta))

	for view in split.views:
		var entrant := director.entrant_for_seat(view["slot"])
		if entrant == null:
			continue
		view["hud"].set_race_info(
			entrant.position,
			director.entrants.size(),
			entrant.lap,
			entrant.laps_target,
			director.race_time)
		view["hud"].set_gaps(entrant.gap_ahead, entrant.gap_behind)

	if director.state == RaceDirector.State.COUNTDOWN:
		_countdown_message(director.countdown_remaining)


func _countdown_message(remaining: float) -> void:
	if split == null:
		return
	var text := "GO!" if remaining <= 0.5 else str(int(ceil(remaining - 0.5)))
	for view in split.views:
		view["hud"].show_status(text, 0.6, Color(1, 0.95, 0.4))
	# One beep per number and a higher one for GO. Called every frame during
	# the countdown, so it only fires when the number on screen changes.
	if text != _countdown_spoken:
		_countdown_spoken = text
		if AudioDirector.interface != null:
			AudioDirector.interface.play("go" if text == "GO!" else "countdown")
		# And the tense grid loop stops the moment the race does not need it.
		if text == "GO!":
			AudioDirector.music.play("")


func _on_race_complete(results: Array) -> void:
	if _results_shown:
		return
	_results_shown = true
	for view in split.views:
		var entrant := director.entrant_for_seat(view["slot"])
		if entrant == null:
			continue
		var line := "FINISHED  P%d" % entrant.position
		for r in results:
			if r["entrant"] == entrant:
				line = "P%d   +%d cr   +%d xp" % [r["position"], r["payout"], r["xp"]]
				if r["dnf"]:
					line = "DNF (%s)   +%d cr" % [r["dnf_reason"], r["payout"]]
				break
		view["hud"].show_status(line, 4.0, Color(0.6, 1.0, 0.6))
	print_rich(_results_table(results))

	var own: Array = []
	for view in split.views:
		var entrant := director.entrant_for_seat(view["slot"])
		if entrant != null:
			own.append(entrant)
	if _overlay != null:
		var name := director.event.display_name if director != null else "Race"
		_overlay.show_results(name, results, own)
	# The one screen the music is allowed to be pleased on.
	AudioDirector.duck_music(false)
	AudioDirector.music.play("results")


func _results_table(results: Array) -> String:
	var lines := ["[b]%s — results[/b]" % director.event.display_name]
	for r in results:
		var time_text: String = "DNF" if r["dnf"] else RaceHUD.format_time(r["time"])
		var entrant: RaceEntrant = r["entrant"]
		# Naming the archetype makes the field legible: it explains why one
		# rival was three seconds a lap quicker and another put it in a ditch.
		var kind := "you" if entrant.is_player() else entrant.driver_name
		lines.append("%2d. %-22s %-18s %10s  best %s" % [
			r["position"], r["name"], kind, time_text, RaceHUD.format_time(r["best_lap"])])
	return "\n".join(lines)


