extends Node2D
## Wires a race together: the director simulates it, the split screen renders
## it, and this node keeps the two in step.

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

@export var event_id: String = "shakedown"

var director: RaceDirector
var split: SplitScreen
var _tracks: Dictionary = {}
var _results_shown: bool = false


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
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	layer.name = "ViewLayer"
	add_child(layer)
	layer.add_child(split)
	split.build(PlayerManager.seats, get_viewport().world_2d)
	split.bind_cars()

	# The network layer addresses cars by id when replicating.
	if NetManager.is_online():
		for entrant in director.entrants:
			NetManager.tracked_cars[entrant.car.car_id] = entrant.car

	_countdown_message(RaceDirector.COUNTDOWN_SECONDS)


## Entry fees come out before the race, not after, so a player feels the cost
## of turning up to something expensive.
func _charge_entry_fees(event: EventSpec) -> void:
	for seat in PlayerManager.seats:
		if seat.profile == null or event.entry_fee <= 0:
			continue
		if not seat.profile.spend(event.entry_fee):
			push_warning("RaceScene: seat %d cannot afford the entry fee" % seat.slot)


func _process(_delta: float) -> void:
	if director == null or split == null:
		return
	# Clients send their intent up; the host is the one simulating.
	if NetManager.state == NetManager.State.CONNECTED:
		var seat = PlayerManager.get_seat(0)
		if seat != null and seat.device != null:
			NetManager.send_local_command(seat.device.poll())

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

	if director.state == RaceDirector.State.COUNTDOWN:
		_countdown_message(director.countdown_remaining)


func _countdown_message(remaining: float) -> void:
	if split == null:
		return
	var text := "GO!" if remaining <= 0.5 else str(int(ceil(remaining - 0.5)))
	for view in split.views:
		view["hud"].show_status(text, 0.6, Color(1, 0.95, 0.4))


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
		view["hud"].show_status(line, 8.0, Color(0.6, 1.0, 0.6))
	print_rich(_results_table(results))


func _results_table(results: Array) -> String:
	var lines := ["[b]%s — results[/b]" % director.event.display_name]
	for r in results:
		var time_text: String = "DNF" if r["dnf"] else RaceHUDFormat.time(r["time"])
		lines.append("%2d. %-22s %10s  best %s" % [
			r["position"], r["name"], time_text, RaceHUDFormat.time(r["best_lap"])])
	return "\n".join(lines)


## Small shim so the results printout can reuse the HUD's time formatting
## without instantiating a HUD.
class RaceHUDFormat:
	static func time(seconds: float) -> String:
		if seconds <= 0.0:
			return "--:--.--"
		var minutes := int(seconds) / 60
		var secs := seconds - float(minutes * 60)
		return "%d:%05.2f" % [minutes, secs]
