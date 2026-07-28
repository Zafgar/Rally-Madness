extends Control
## The first thing anybody sees.
##
## It used to be a seat list, a calendar and a LAN panel side by side, which is
## everything the game can do arranged so that none of it is obviously the thing
## to do first. A player launching this for the first time could not tell what
## to press, which is the one job an opening screen has.
##
## So it now asks one question at a time. A banner states the single next step
## in plain words, and a choice that is not yet possible says why instead of
## sitting there greyed out and silent. Everything else — the calendar, the
## garage, the tuning shop, the showroom — lives behind CAREER, because that is
## where a career lives.

const RACE_SCENE_PATH := "res://scenes/race.tscn"
const NEW_PROFILE_SCENE := preload("res://scenes/ui/new_profile.tscn")

var _next_step: Label
var _seat_column: VBoxContainer
var _action_column: VBoxContainer
var _net_panel: VBoxContainer
var _net_status: Label
var _address_field: LineEdit

var _profile_screen: NewProfileScreen = null
var _career_hub: CareerHub = null


func _ready() -> void:
	# The front end.
	AudioDirector.music.play("menu")
	theme = UiTheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	PlayerManager.accepting_joins = true
	EventBus.local_player_joined.connect(_on_seat_changed)
	EventBus.local_player_left.connect(_on_seat_changed)
	EventBus.net_state_changed.connect(func(_s): _refresh())
	EventBus.net_peer_joined.connect(func(_id, _name): _refresh())
	EventBus.net_peer_left.connect(func(_id): _refresh())
	_build()
	_refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	add_child(bg)

	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 56)
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	root.add_child(column)

	column.add_child(UiTheme.label("RALLY MADNESS", 64, UiTheme.TEXT))
	column.add_child(UiTheme.label(
		"Top-down rally. Up to four of you on this screen, twelve over a network.",
		UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))

	# The one line that always says what to do next. Everything about this
	# screen's clarity rests on it being right.
	var banner := UiTheme.card(UiTheme.ACCENT)
	column.add_child(banner)
	_next_step = UiTheme.label("", UiTheme.SIZE_HEADING, UiTheme.ACCENT)
	_next_step.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_child(_next_step)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	# --- Who is playing -----------------------------------------------------
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(540, 0)
	left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(left)
	left.add_child(UiTheme.section("Drivers"))
	_seat_column = VBoxContainer.new()
	_seat_column.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	left.add_child(_seat_column)
	left.add_child(UiTheme.wrapped(
		"Press Enter, or Options on a controller, to take a seat. Every seat is "
		+ "a separate career saved on this machine, so four people can play their "
		+ "own game on one screen.",
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	left.add_child(UiTheme.expander())

	# --- What to do ---------------------------------------------------------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(right)
	_action_column = VBoxContainer.new()
	_action_column.add_theme_constant_override("separation", UiTheme.GAP)
	right.add_child(_action_column)

	_net_panel = VBoxContainer.new()
	_net_panel.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	_net_panel.visible = false
	right.add_child(_net_panel)
	_build_net_panel()

	right.add_child(UiTheme.expander())

	_build_controls(column)


## The controls, on the first screen, where somebody who has never played can
## read them before they are moving. The bottom half of this menu was empty and
## the one question a new player has — how do I drive it — was answered nowhere.
func _build_controls(column: VBoxContainer) -> void:
	column.add_child(UiTheme.expander())
	column.add_child(UiTheme.section("Controls"))

	var grid := HBoxContainer.new()
	grid.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(grid)

	var keyboard := [
		["Steer", "A / D"], ["Accelerate", "W"], ["Brake and reverse", "S"],
		["Handbrake", "Space"], ["Nitro", "Shift"], ["Change gear", "Q / E"],
		["Manual gearbox", "T"], ["Back on the road", "R"],
		["Headlights", "L"], ["Horn", "H"], ["Pause", "Esc"]]
	var pad := [
		["Steer", "Left stick"], ["Accelerate", "R2"], ["Brake and reverse", "L2"],
		["Handbrake", "Cross"], ["Nitro", "Circle"], ["Change gear", "L1 / R1"],
		["Manual gearbox", "Triangle"], ["Back on the road", "Options"],
		["Headlights", "Square"], ["Horn", "Stick click"],
		["Pause", "Esc / Start"]]

	for pair in [["Keyboard", keyboard], ["Controller", pad]]:
		var card := UiTheme.card()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(card)
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
		card.add_child(inner)
		inner.add_child(UiTheme.label(String(pair[0]), UiTheme.SIZE_LABEL, UiTheme.TEXT))
		for binding in (pair[1] as Array):
			inner.add_child(UiTheme.stat_row(String(binding[0]), String(binding[1])))


func _build_net_panel() -> void:
	_net_panel.add_child(UiTheme.section("Local network"))
	_net_status = UiTheme.label("Offline", UiTheme.SIZE_BODY, UiTheme.TEXT_DIM)
	_net_panel.add_child(_net_status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	_net_panel.add_child(row)
	var host := UiTheme.primary_button("Host a game")
	host.pressed.connect(_on_host_pressed)
	row.add_child(host)
	_address_field = LineEdit.new()
	_address_field.placeholder_text = "Host address"
	_address_field.text = "127.0.0.1"
	_address_field.custom_minimum_size = Vector2(200, 0)
	row.add_child(_address_field)
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_on_join_pressed)
	row.add_child(join)
	var leave := Button.new()
	leave.text = "Disconnect"
	leave.pressed.connect(func():
		NetManager.shutdown()
		_refresh())
	row.add_child(leave)


# --- Refresh ----------------------------------------------------------------

func _on_seat_changed(_a = null, _b = null) -> void:
	_refresh()


func _refresh() -> void:
	_refresh_seats()
	_refresh_actions()
	_refresh_net()
	_refresh_next_step()
	# The action buttons are rebuilt by _refresh_actions, so whatever had focus
	# has just been freed. Put it back or the pad goes dead after every change.
	if get_viewport() != null and get_viewport().gui_get_focus_owner() == null:
		_focus_menu()


## The single most useful thing on the screen: what to do now, in words.
func _refresh_next_step() -> void:
	if PlayerManager.seat_count() == 0:
		_next_step.text = "Press Enter to take a seat — or Options on a controller."
		return
	var seat = PlayerManager.get_seat(0)
	if seat != null and seat.profile == null:
		_next_step.text = "Now set up a career: a name, a face, and your first car."
		return
	_next_step.text = "Open CAREER to enter an event, work on your car, or go shopping."


func _refresh_seats() -> void:
	for child in _seat_column.get_children():
		child.queue_free()

	if PlayerManager.seat_count() == 0:
		var empty := UiTheme.card()
		empty.add_child(UiTheme.label("Nobody is sitting down yet.",
			UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))
		_seat_column.add_child(empty)
		return

	for seat in PlayerManager.seats:
		_seat_column.add_child(_seat_card(seat))


func _seat_card(seat) -> Control:
	var card := UiTheme.card(UiTheme.ACCENT if seat.profile != null else UiTheme.LINE_STRONG)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP)
	card.add_child(row)

	var profile: PlayerProfile = seat.profile
	if profile == null:
		# A seat with no career gets an invitation, not a silent default.
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text.add_theme_constant_override("separation", 2)
		text.add_child(UiTheme.label("Seat %d" % (seat.slot + 1), UiTheme.SIZE_LABEL))
		text.add_child(UiTheme.label(
			seat.device.device_name() if seat.device else "unknown device",
			UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
		row.add_child(text)

		var new_career := UiTheme.primary_button("New career")
		new_career.pressed.connect(_open_profile_setup.bind(seat.slot))
		row.add_child(new_career)

		var existing := SaveSystem.list_profiles()
		if not existing.is_empty():
			var load_button := MenuButton.new()
			load_button.text = "Load career"
			var menu := load_button.get_popup()
			for i in existing.size():
				menu.add_item("%s  (Lv%d)" % [existing[i]["name"], existing[i]["level"]], i)
			menu.id_pressed.connect(_on_profile_picked.bind(seat.slot, existing))
			row.add_child(load_button)
		return card

	var face := DriverAvatar.new()
	face.avatar_id = profile.avatar_id
	face.background = Color(0, 0, 0, 0)
	face.custom_minimum_size = Vector2(44, 44)
	row.add_child(face)

	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	who.add_theme_constant_override("separation", 2)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	name_row.add_child(UiTheme.label("P%d  %s" % [seat.slot + 1, seat.display_name()],
		UiTheme.SIZE_LABEL))
	name_row.add_child(UiTheme.badge("Lv %d" % profile.level, UiTheme.ACCENT))
	who.add_child(name_row)
	var car := profile.active_car()
	who.add_child(UiTheme.label("%s  ·  %s" % [
		UiTheme.money(profile.money),
		car.display_name() if car != null else "no car"],
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	row.add_child(who)

	# Anything that would spoil this seat's race, said out loud here rather than
	# discovered at the start line.
	if car != null and car.repair_cost() > 0:
		row.add_child(UiTheme.badge("DAMAGED", UiTheme.NEGATIVE))
	if car != null and car.needs_service():
		row.add_child(UiTheme.badge("SERVICE DUE", UiTheme.WARNING))
	return card


func _focus_menu() -> void:
	# The boot screen is the first thing a player sees, and until now a pad
	# could not move on it at all: nothing held focus, so a d-pad direction had
	# nowhere to move from.
	UiTheme.focus_first(self)


func _refresh_actions() -> void:
	for child in _action_column.get_children():
		child.queue_free()
	_action_column.add_child(UiTheme.section("Play"))

	var seat = PlayerManager.get_seat(0)
	var ready := seat != null and seat.profile != null

	_action_column.add_child(_big_button("CAREER",
		"The calendar, your garage, the tuning shop and the showroom.",
		"" if ready else "Take a seat and set up a career first.",
		_open_career_hub))

	_action_column.add_child(_big_button("LOCAL NETWORK",
		"Host a game on this network, or join one. Up to twelve cars.",
		"", func(): _net_panel.visible = not _net_panel.visible))

	_action_column.add_child(_big_button("QUIT", "Close the game.", "",
		func(): get_tree().quit()))


## One of the menu's choices: a title, a line of explanation, and — when it
## cannot be used — the reason in place of that explanation.
func _big_button(title: String, blurb: String, blocked_reason: String,
		action: Callable) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 86)
	button.disabled = not blocked_reason.is_empty()
	if button.disabled:
		button.tooltip_text = blocked_reason
	else:
		button.pressed.connect(action)

	var text := VBoxContainer.new()
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.offset_left = 22
	text.offset_right = -22
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_theme_constant_override("separation", 3)
	text.add_child(UiTheme.label(title, UiTheme.SIZE_HEADING,
		UiTheme.TEXT if not button.disabled else UiTheme.TEXT_FAINT))
	text.add_child(UiTheme.label(
		blocked_reason if button.disabled else blurb,
		UiTheme.SIZE_SMALL,
		UiTheme.WARNING if button.disabled else UiTheme.TEXT_DIM))
	button.add_child(text)
	return button


func _refresh_net() -> void:
	if _net_status == null:
		return
	match NetManager.state:
		NetManager.State.HOSTING:
			_net_status.text = "Hosting — %d drivers connected" % NetManager.total_drivers()
			_net_status.add_theme_color_override("font_color", UiTheme.POSITIVE)
		NetManager.State.CONNECTED:
			_net_status.text = "Connected to the host"
			_net_status.add_theme_color_override("font_color", UiTheme.POSITIVE)
		NetManager.State.CONNECTING:
			_net_status.text = "Connecting…"
			_net_status.add_theme_color_override("font_color", UiTheme.WARNING)
		_:
			_net_status.text = "Offline"
			_net_status.add_theme_color_override("font_color", UiTheme.TEXT_DIM)


# --- Career -----------------------------------------------------------------

func _open_career_hub() -> void:
	if _career_hub != null:
		return
	var seat = PlayerManager.get_seat(0)
	var profile: PlayerProfile = seat.profile if seat != null else null
	if profile == null:
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
	_focus_menu()
	var layer := get_node_or_null("CareerHubLayer")
	if layer != null:
		layer.queue_free()
	_career_hub = null
	# Buying, selling, servicing and tuning all change what a seat can enter.
	_refresh()


func _on_career_race_requested(event: EventSpec) -> void:
	_close_career_hub()
	_start_event(event)


# --- Profiles ---------------------------------------------------------------

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
	_focus_menu()
	if _profile_screen == null:
		return
	var layer := get_node_or_null("ProfileSetupLayer")
	if layer != null:
		layer.queue_free()
	_profile_screen = null


func _on_profile_created(profile: PlayerProfile, slot: int) -> void:
	PlayerManager.assign_profile(slot, profile)
	_close_profile_setup()
	_refresh()


func _on_profile_picked(index: int, slot: int, listing: Array) -> void:
	if index < 0 or index >= listing.size():
		return
	var profile := SaveSystem.load_profile(listing[index]["id"])
	if profile != null:
		PlayerManager.assign_profile(slot, profile)
		_refresh()


# --- Starting a race --------------------------------------------------------

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
		_net_status.add_theme_color_override("font_color", UiTheme.NEGATIVE)


func _on_join_pressed() -> void:
	var address := _address_field.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var err := NetManager.join_game(address)
	if err != OK:
		_net_status.text = "Could not reach %s (error %d)" % [address, err]
		_net_status.add_theme_color_override("font_color", UiTheme.NEGATIVE)
