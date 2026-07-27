extends Control
## Front end: seat joining, event selection and starting a race.
##
## Deliberately plain. It exists so the systems underneath are reachable and
## testable from a running build; the real menus, garage and showroom come
## later and will use the same PlayerManager / EventDatabase calls this does.

const RACE_SCENE_PATH := "res://scenes/race.tscn"
const NEW_PROFILE_SCENE := preload("res://scenes/ui/new_profile.tscn")

var _seat_list: VBoxContainer
var _event_list: ItemList
var _info_label: RichTextLabel
var _start_button: Button
var _net_status: Label
var _address_field: LineEdit

var _available: Array[EventSpec] = []
var _profile_screen: NewProfileScreen = null
var _career_hub: CareerHub = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	PlayerManager.accepting_joins = true
	EventBus.local_player_joined.connect(_on_seat_changed)
	EventBus.local_player_left.connect(_on_seat_changed)
	EventBus.net_state_changed.connect(_on_net_state_changed)
	EventBus.net_peer_joined.connect(func(_id, _name): _refresh_net())
	EventBus.net_peer_left.connect(func(_id): _refresh_net())
	_build()
	_refresh_seats()
	_refresh_events()


func _build() -> void:
	theme = UiTheme.theme()
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	add_child(bg)

	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 48)
	root.add_theme_constant_override("margin_right", 48)
	root.add_theme_constant_override("margin_top", 32)
	root.add_theme_constant_override("margin_bottom", 32)
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	root.add_child(column)

	var title := Label.new()
	title.text = "RALLY MADNESS"
	title.add_theme_font_size_override("font_size", 46)
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Press Options on a pad (or Enter) to take a seat — up to %d locally, %d online." % [
		GameConfig.MAX_LOCAL_PLAYERS, GameConfig.MAX_NET_PLAYERS]
	subtitle.add_theme_color_override("font_color", Color(0.65, 0.66, 0.72))
	column.add_child(subtitle)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 32)
	column.add_child(body)

	# --- Seats ---
	var seats_panel := VBoxContainer.new()
	seats_panel.custom_minimum_size = Vector2(320, 0)
	body.add_child(seats_panel)
	seats_panel.add_child(_heading("Drivers"))
	_seat_list = VBoxContainer.new()
	seats_panel.add_child(_seat_list)

	seats_panel.add_child(_heading("LAN"))
	_net_status = Label.new()
	_net_status.text = "Offline"
	_net_status.add_theme_color_override("font_color", Color(0.65, 0.66, 0.72))
	seats_panel.add_child(_net_status)

	_address_field = LineEdit.new()
	_address_field.placeholder_text = "Host address (e.g. 192.168.1.20)"
	seats_panel.add_child(_address_field)

	var net_row := HBoxContainer.new()
	seats_panel.add_child(net_row)
	var host_button := Button.new()
	host_button.text = "Host"
	host_button.pressed.connect(_on_host_pressed)
	net_row.add_child(host_button)
	var join_button := Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(_on_join_pressed)
	net_row.add_child(join_button)
	var leave_button := Button.new()
	leave_button.text = "Disconnect"
	leave_button.pressed.connect(func(): NetManager.shutdown())
	net_row.add_child(leave_button)

	# --- Events ---
	var events_panel := VBoxContainer.new()
	events_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(events_panel)
	events_panel.add_child(_heading("Calendar"))
	_event_list = ItemList.new()
	_event_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_event_list.item_selected.connect(_on_event_selected)
	events_panel.add_child(_event_list)

	# --- Detail ---
	var detail_panel := VBoxContainer.new()
	detail_panel.custom_minimum_size = Vector2(360, 0)
	body.add_child(detail_panel)
	detail_panel.add_child(_heading("Event"))
	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_child(_info_label)

	_start_button = UiTheme.primary_button("START RACE")
	_start_button.custom_minimum_size = Vector2(0, 52)
	_start_button.pressed.connect(_on_start_pressed)
	detail_panel.add_child(_start_button)

	# Everything a career does between races. The seat list stays here because
	# it is about who is playing on this machine; the hub is about one driver.
	var career_button := Button.new()
	career_button.text = "CAREER  —  calendar, garage, tuning, showroom"
	career_button.custom_minimum_size = Vector2(0, 44)
	career_button.pressed.connect(_open_career_hub)
	detail_panel.add_child(career_button)


func _heading(text: String) -> Label:
	return UiTheme.heading(text)


# --- Career hub -------------------------------------------------------------

## Opens the between-races screens for the first seated driver. It is one
## driver's career, so it belongs to a seat rather than to the machine.
func _open_career_hub() -> void:
	if _career_hub != null:
		return
	var seat := PlayerManager.get_seat(0)
	var profile: PlayerProfile = seat.profile if seat != null else null
	if profile == null:
		_info_label.text = "[color=#dd7f7f]Take a seat and load a profile first.[/color]"
		return

	var layer := CanvasLayer.new()
	layer.name = "CareerHubLayer"
	add_child(layer)
	_career_hub = CareerHub.new()
	_career_hub.profile = profile
	_career_hub.exited.connect(_close_career_hub)
	_career_hub.race_requested.connect(_on_career_race_requested)
	layer.add_child(_career_hub)


func _close_career_hub() -> void:
	var layer := get_node_or_null("CareerHubLayer")
	if layer != null:
		layer.queue_free()
	_career_hub = null
	# Buying, selling and tuning all change what the seat can enter.
	_refresh_seats()
	_refresh_events()


func _on_career_race_requested(event: EventSpec) -> void:
	_close_career_hub()
	_start_event(event)


# --- Seats ------------------------------------------------------------------

func _on_seat_changed(_a = null, _b = null) -> void:
	_refresh_seats()
	_refresh_events()


func _refresh_seats() -> void:
	for child in _seat_list.get_children():
		child.queue_free()

	if PlayerManager.seat_count() == 0:
		var empty := Label.new()
		empty.text = "No drivers yet."
		empty.add_theme_color_override("font_color", Color(0.55, 0.56, 0.62))
		_seat_list.add_child(empty)
		return

	for seat in PlayerManager.seats:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_seat_list.add_child(row)

		var profile := seat.profile
		if profile == null:
			# A seat with no career gets an invitation, not a silent default.
			var setup := Button.new()
			setup.text = "P%d  —  set up a career" % (seat.slot + 1)
			setup.pressed.connect(_open_profile_setup.bind(seat.slot))
			row.add_child(setup)
			var existing := SaveSystem.list_profiles()
			if not existing.is_empty():
				var load_button := MenuButton.new()
				load_button.text = "Load"
				var menu := load_button.get_popup()
				for i in existing.size():
					menu.add_item("%s  (Lv%d)" % [existing[i]["name"], existing[i]["level"]], i)
				menu.id_pressed.connect(_on_profile_picked.bind(seat.slot, existing))
				row.add_child(load_button)
			continue

		var face := DriverAvatar.new()
		face.avatar_id = profile.avatar_id
		face.background = Color(0, 0, 0, 0)
		face.custom_minimum_size = Vector2(28, 28)
		row.add_child(face)

		var car := profile.active_car()
		var line := Label.new()
		line.text = "P%d  %s  —  Lv%d  %d cr  %s  [%s]" % [
			seat.slot + 1,
			seat.display_name(),
			profile.level,
			profile.money,
			car.display_name() if car != null else "no car",
			seat.device.device_name() if seat.device else "?",
		]
		row.add_child(line)


# --- Events -----------------------------------------------------------------

func _refresh_events() -> void:
	_event_list.clear()
	_available.clear()

	var seat = PlayerManager.get_seat(0)
	if seat == null or seat.profile == null:
		_event_list.add_item("Take a seat to see the calendar")
		return

	_available = EventDatabase.available_for(seat.profile)
	if _available.is_empty():
		_event_list.add_item("No events available")
		return
	for e in _available:
		var fee := "free" if e.entry_fee == 0 else "%d cr" % e.entry_fee
		_event_list.add_item("%s  —  %s, %s" % [e.display_name, e.format_name(), fee])
	_event_list.select(0)
	_on_event_selected(0)


func _on_event_selected(index: int) -> void:
	if index < 0 or index >= _available.size():
		return
	var e := _available[index]
	var seat = PlayerManager.get_seat(0)
	var profile: PlayerProfile = seat.profile if seat != null else null

	var text := "[b]%s[/b]\n%s\n\n" % [e.display_name, e.description]
	text += "Format: %s, %d lap(s)\n" % [e.format_name(), e.laps]
	text += "Entry fee: %s\n" % ("free" if e.entry_fee == 0 else "%d cr" % e.entry_fee)
	text += "Winner takes: %d cr\n" % e.payout_for(1)
	text += "Car tiers: %d–%s\n" % [e.min_car_tier, "any" if e.max_car_tier > 90 else str(e.max_car_tier)]
	if not e.drivetrain_required.is_empty():
		text += "Drivetrain: %s\n" % "/".join(e.drivetrain_required)
	text += "\n"

	# Say plainly whether every seated player can actually start, and why not.
	var blocked := false
	for s in PlayerManager.seats:
		if s.profile == null:
			continue
		var car := s.profile.active_car()
		var reason := ""
		if car == null:
			reason = "no car"
		else:
			reason = e.car_ineligible_reason(car)
		if not e.profile_can_enter(s.profile):
			reason = "level %d required" % e.min_level
		elif reason.is_empty() and not e.can_afford_entry(s.profile):
			reason = "cannot afford the entry fee"
		if reason.is_empty():
			text += "[color=#7fdd7f]P%d ready[/color]\n" % (s.slot + 1)
		else:
			text += "[color=#dd7f7f]P%d blocked: %s[/color]\n" % [s.slot + 1, reason]
			blocked = true

	_info_label.text = text
	_start_button.disabled = blocked or profile == null


func _open_profile_setup(slot: int) -> void:
	if _profile_screen != null:
		return
	_profile_screen = NEW_PROFILE_SCENE.instantiate()
	_profile_screen.set_anchors_preset(Control.PRESET_CENTER)
	_profile_screen.created.connect(_on_profile_created.bind(slot))
	_profile_screen.cancelled.connect(_close_profile_setup)
	var layer := CanvasLayer.new()
	layer.name = "ProfileSetupLayer"
	add_child(layer)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	layer.add_child(centre)
	centre.add_child(_profile_screen)


func _close_profile_setup() -> void:
	if _profile_screen == null:
		return
	var layer := get_node_or_null("ProfileSetupLayer")
	if layer != null:
		layer.queue_free()
	_profile_screen = null


func _on_profile_created(profile: PlayerProfile, slot: int) -> void:
	PlayerManager.assign_profile(slot, profile)
	_close_profile_setup()
	_refresh_seats()
	_refresh_events()


func _on_profile_picked(index: int, slot: int, listing: Array) -> void:
	if index < 0 or index >= listing.size():
		return
	var profile := SaveSystem.load_profile(listing[index]["id"])
	if profile != null:
		PlayerManager.assign_profile(slot, profile)
		_refresh_seats()
		_refresh_events()


func _on_start_pressed() -> void:
	var index := _event_list.get_selected_items()
	if index.is_empty() or _available.is_empty():
		return
	_start_event(_available[index[0]])


func _start_event(e: EventSpec) -> void:
	PlayerManager.accepting_joins = false
	var packed: PackedScene = load(RACE_SCENE_PATH)
	var scene := packed.instantiate()
	scene.event_id = e.id
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene


# --- Networking -------------------------------------------------------------

func _on_host_pressed() -> void:
	var err := NetManager.host_game()
	if err != OK:
		_net_status.text = "Could not host (error %d)" % err


func _on_join_pressed() -> void:
	var address := _address_field.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var err := NetManager.join_game(address)
	if err != OK:
		_net_status.text = "Could not reach %s (error %d)" % [address, err]


func _on_net_state_changed(_state: int) -> void:
	_refresh_net()


func _refresh_net() -> void:
	match NetManager.state:
		NetManager.State.OFFLINE:
			_net_status.text = "Offline"
		NetManager.State.HOSTING:
			_net_status.text = "Hosting — %d/%d drivers, avg rating %d" % [
				NetManager.total_drivers(), GameConfig.MAX_NET_PLAYERS,
				NetManager.lobby_average_rating()]
		NetManager.State.CONNECTING:
			_net_status.text = "Connecting…"
		NetManager.State.CONNECTED:
			_net_status.text = "Connected — %d drivers, avg rating %d" % [
				NetManager.total_drivers(), NetManager.lobby_average_rating()]
