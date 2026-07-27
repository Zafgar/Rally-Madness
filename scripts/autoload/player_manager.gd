extends Node
## Local seats.
##
## Up to four people share one screen. Each seat owns a physical device, a
## profile loaded from this machine, and a car in the race. A device belongs to
## exactly one seat, which is why input is polled per-device rather than
## through the global InputMap.
##
## Joining is drop-in: pressing Options/Start on an unassigned pad claims the
## next free seat.

class LocalPlayer:
	extends RefCounted
	var slot: int = 0
	var device: DeviceInput
	var profile: PlayerProfile
	var car: RallyCar
	var haptics: HapticsDirector
	var ready_to_race: bool = false

	func display_name() -> String:
		if profile != null:
			return profile.display_name
		return "Player %d" % (slot + 1)


var seats: Array[LocalPlayer] = []
## True while the lobby is listening for new pads.
var accepting_joins: bool = true

var _claimed_devices: Dictionary = {}   # device_id -> slot


func _ready() -> void:
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


func _process(delta: float) -> void:
	if accepting_joins:
		_poll_for_joins()
	for seat in seats:
		if seat.device != null and seat.car != null and seat.car.is_locally_controlled:
			seat.car.command = seat.device.poll()
		if seat.haptics != null:
			seat.haptics.update(delta)


func _notification(what: int) -> void:
	# Never leave a pad buzzing because the window lost focus or the game quit.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_PREDELETE:
		release_haptics()


func _poll_for_joins() -> void:
	if seats.size() >= GameConfig.MAX_LOCAL_PLAYERS:
		return
	for device_id in Input.get_connected_joypads():
		if _claimed_devices.has(device_id):
			continue
		if Input.is_joy_button_pressed(device_id, DeviceInput.BTN_OPTIONS) \
				or Input.is_joy_button_pressed(device_id, DeviceInput.BTN_CROSS):
			join(device_id)
			return
	# The keyboard counts as a device so one player can always start without a pad.
	if not _claimed_devices.has(DeviceInput.DEVICE_KEYBOARD) \
			and Input.is_key_pressed(KEY_ENTER):
		join(DeviceInput.DEVICE_KEYBOARD)


func join(device_id: int) -> LocalPlayer:
	if seats.size() >= GameConfig.MAX_LOCAL_PLAYERS:
		return null
	if _claimed_devices.has(device_id):
		return null

	var seat := LocalPlayer.new()
	seat.slot = _next_free_slot()
	seat.device = DeviceInput.new(device_id)
	# Each seat drives its own pad: in a four-way split screen the four pads
	# have to be telling four different stories.
	seat.haptics = HapticsDirector.new(device_id, HapticsDirector.make_backend())
	seats.append(seat)
	_claimed_devices[device_id] = seat.slot
	EventBus.local_player_joined.emit(seat.slot, device_id)
	return seat


func leave(slot: int) -> void:
	for i in seats.size():
		if seats[i].slot == slot:
			var device_id := seats[i].device.device_id
			_claimed_devices.erase(device_id)
			seats.remove_at(i)
			EventBus.local_player_left.emit(slot)
			return


func get_seat(slot: int) -> LocalPlayer:
	for seat in seats:
		if seat.slot == slot:
			return seat
	return null


func seat_count() -> int:
	return seats.size()


## Attaches a profile to a seat. Each seat saves independently, so four people
## on one couch keep four careers on this machine.
func assign_profile(slot: int, profile: PlayerProfile) -> void:
	var seat := get_seat(slot)
	if seat == null:
		return
	seat.profile = profile
	EventBus.profile_loaded.emit(slot, profile)


## Convenience for a quick session: give every seat that has no profile a
## default one named after the seat.
func ensure_profiles() -> void:
	for seat in seats:
		if seat.profile == null:
			var id := "player_%d" % (seat.slot + 1)
			seat.profile = SaveSystem.get_or_create(id, "Player %d" % (seat.slot + 1))
			EventBus.profile_loaded.emit(seat.slot, seat.profile)


func save_all_profiles() -> void:
	for seat in seats:
		if seat.profile != null:
			SaveSystem.save_profile(seat.profile)


## Hands a seat the car it will drive, and wires that seat's pad to it.
func bind_car(slot: int, car: RallyCar) -> void:
	var seat := get_seat(slot)
	if seat == null:
		return
	seat.car = car
	if seat.haptics != null:
		seat.haptics.bind(car)


func release_haptics() -> void:
	for seat in seats:
		if seat.haptics != null:
			seat.haptics.release()


func clear_cars() -> void:
	release_haptics()
	for seat in seats:
		seat.car = null


func _next_free_slot() -> int:
	var used := {}
	for seat in seats:
		used[seat.slot] = true
	for i in GameConfig.MAX_LOCAL_PLAYERS:
		if not used.has(i):
			return i
	return seats.size()


func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
	if connected:
		return
	# A pad unplugging mid-race should not delete the seat — the player may be
	# swapping batteries. The seat keeps its profile and simply stops steering.
	if _claimed_devices.has(device_id):
		push_warning("PlayerManager: device %d disconnected, seat kept" % device_id)
