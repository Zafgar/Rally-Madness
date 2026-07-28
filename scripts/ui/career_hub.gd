class_name CareerHub
extends Control
## Where a career lives between races: the driver, the car, and four doors.
##
## One screen owns the navigation so the others do not have to know about each
## other. The garage can ask for the tuning shop and the hub decides what that
## means; nothing below here holds a reference to a sibling screen.

signal race_requested(event: EventSpec)
signal exited()

var profile: PlayerProfile

var _stack: Control
var _home: Control
var _open: Control = null
var _summary: VBoxContainer


func _ready() -> void:
	# The hub is still the front end.
	AudioDirector.music.play("menu")
	theme = UiTheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	add_child(bg)

	_stack = Control.new()
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_stack)

	_home = Control.new()
	_home.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stack.add_child(_home)

	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 48)
	_home.add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	root.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(header)
	var back := Button.new()
	back.text = "< Main menu"
	back.pressed.connect(func(): exited.emit())
	header.add_child(back)
	header.add_child(UiTheme.title("RALLY MADNESS"))
	column.add_child(UiTheme.spacer(UiTheme.GAP))

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	# --- Driver card --------------------------------------------------------
	var card := UiTheme.card()
	card.custom_minimum_size = Vector2(420, 0)
	body.add_child(card)
	_summary = VBoxContainer.new()
	_summary.add_theme_constant_override("separation", UiTheme.GAP)
	card.add_child(_summary)

	# --- Doors --------------------------------------------------------------
	var doors := VBoxContainer.new()
	doors.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	doors.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(doors)

	doors.add_child(_door("Go racing", "The calendar: what you can enter, and what it pays.",
		_open_career))
	doors.add_child(_door("Garage", "Your cars, their condition, and what class they fit.",
		_open_garage))
	doors.add_child(_door("Tuning shop", "Parts, setup, and how close you are to the class limit.",
		_open_tuning))
	doors.add_child(_door("Showroom", "Buy something better. Or something worse but more fun.",
		_open_showroom))
	doors.add_child(UiTheme.expander())


func _door(title: String, blurb: String, action: Callable) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 92)
	button.pressed.connect(action)

	var text := VBoxContainer.new()
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.offset_left = 22
	text.offset_right = -22
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_theme_constant_override("separation", 3)
	text.add_child(UiTheme.label(title, UiTheme.SIZE_HEADING))
	text.add_child(UiTheme.label(blurb, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	button.add_child(text)
	return button


func refresh() -> void:
	if profile == null:
		return
	for child in _summary.get_children():
		child.queue_free()

	var avatar_row := HBoxContainer.new()
	avatar_row.add_theme_constant_override("separation", UiTheme.GAP)
	var avatar := DriverAvatar.new()
	avatar.avatar_id = profile.avatar_id
	avatar.custom_minimum_size = Vector2(72, 72)
	avatar_row.add_child(avatar)
	var who := VBoxContainer.new()
	who.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	who.add_theme_constant_override("separation", 2)
	who.add_child(UiTheme.label(profile.display_name, UiTheme.SIZE_HEADING))
	who.add_child(UiTheme.label(profile.rating_tier_name(), UiTheme.SIZE_SMALL,
		UiTheme.ACCENT))
	avatar_row.add_child(who)
	_summary.add_child(avatar_row)

	_summary.add_child(UiTheme.section("Career"))
	_summary.add_child(UiTheme.stat_row("Money", UiTheme.money(profile.money),
		UiTheme.ACCENT))
	_summary.add_child(UiTheme.stat_row("Level", str(profile.level)))
	var to_next := profile.xp_to_next_level()
	var span := maxi(profile.xp_for_level(profile.level + 1)
		- profile.xp_for_level(profile.level), 1)
	_summary.add_child(UiTheme.stat_bar("Progress to level %d" % (profile.level + 1),
		1.0 - float(to_next) / float(span), "%d XP to go" % to_next))
	_summary.add_child(UiTheme.stat_row("Driver rating", "%d (%s)" % [
		profile.rating, profile.rating_tier_name()]))
	_summary.add_child(UiTheme.stat_row("Races", str(profile.stat_races)))
	_summary.add_child(UiTheme.stat_row("Wins", str(profile.stat_wins)))
	_summary.add_child(UiTheme.stat_row("Wrecks", str(profile.stat_wrecks)))

	var car := profile.active_car()
	if car != null:
		_summary.add_child(UiTheme.section("Current car"))
		var race_class := RaceClass.best_fit(car)
		var name_row := HBoxContainer.new()
		name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
		name_row.add_child(UiTheme.label(car.display_name(), UiTheme.SIZE_LABEL))
		name_row.add_child(UiTheme.badge(race_class.display_name, race_class.colour))
		_summary.add_child(name_row)
		var preview := CarPreview.new()
		preview.custom_minimum_size = Vector2(0, 150)
		preview.show_owned(car)
		_summary.add_child(preview)
		_summary.add_child(UiTheme.stat_bar("Condition", car.condition(),
			"%d%%" % int(car.condition() * 100.0),
			GarageScreen._condition_colour(car.condition())))
		var bill := car.repair_cost()
		if bill > 0:
			_summary.add_child(UiTheme.stat_row("Repairs due", UiTheme.money(bill),
				UiTheme.WARNING))
	_summary.add_child(UiTheme.expander())


# --- Navigation -------------------------------------------------------------

func _push(screen: Control) -> void:
	_close_open()
	_open = screen
	_home.visible = false
	_stack.add_child(screen)
	# So a pad has somewhere to move from the moment the screen appears.
	UiTheme.focus_first(screen)


func _close_open() -> void:
	if _open != null:
		_open.queue_free()
		_open = null
	_home.visible = true
	refresh()
	UiTheme.focus_first(_home)


func _open_career() -> void:
	var screen := CareerScreen.new()
	screen.profile = profile
	screen.closed.connect(_close_open)
	screen.event_chosen.connect(func(event):
		_close_open()
		race_requested.emit(event))
	_push(screen)


func _open_garage() -> void:
	var screen := GarageScreen.new()
	screen.profile = profile
	screen.closed.connect(_close_open)
	screen.tune_requested.connect(func(uid):
		_close_open()
		_open_tuning(uid, true))
	_push(screen)


## `from_garage` is where the player came from, and going back means going back
## there. The tuning screen's own button says "< Garage" — it always did — and
## it went to the hub instead, which is a small lie that costs two extra clicks
## every time somebody fits a part and wants to look at the next car.
func _open_tuning(uid: String = "", from_garage: bool = false) -> void:
	var car: OwnedCar = profile.garage.get(uid) if not uid.is_empty() else profile.active_car()
	if car == null:
		return
	var screen := TuningScreen.new()
	screen.profile = profile
	screen.car = car
	if from_garage:
		screen.closed.connect(func():
			_close_open()
			_open_garage())
	else:
		screen.closed.connect(_close_open)
	_push(screen)
	screen.sync_setup()


func _open_showroom() -> void:
	var screen := ShowroomScreen.new()
	screen.profile = profile
	screen.closed.connect(_close_open)
	_push(screen)
