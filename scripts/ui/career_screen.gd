class_name CareerScreen
extends Control
## The calendar: what you can enter, what you cannot, and why not.
##
## Every locked event states its own reason in words a player can act on —
## "Reach level 6", "Needs a tier 2 car or better", "Too quick for this class".
## A greyed-out row with no explanation is the single most annoying thing a
## career screen can do, and it is also the thing that makes players think a
## game is broken when it is working exactly as designed.
##
## Events are grouped by series rather than listed flat, because the series is
## the unit a player thinks in: you are doing the Clubman Cup, and the National
## Championship is next.

signal closed()
signal event_chosen(event: EventSpec)

var profile: PlayerProfile

var _list: VBoxContainer
var _money_label: Label
var _status: Label


func _ready() -> void:
	# Reading the calendar.
	AudioDirector.music.play("garage")
	theme = UiTheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	add_child(bg)

	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 36)
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	root.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(header)
	var back := Button.new()
	back.text = "< Back"
	back.pressed.connect(func(): closed.emit())
	header.add_child(back)
	header.add_child(UiTheme.title("CALENDAR"))
	header.add_child(UiTheme.expander())
	_money_label = UiTheme.label("", UiTheme.SIZE_NUMBER, UiTheme.ACCENT)
	header.add_child(_money_label)

	_status = UiTheme.caption("")
	column.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", UiTheme.GAP)
	scroll.add_child(_list)


func refresh() -> void:
	if profile == null:
		return
	_money_label.text = UiTheme.money(profile.money)
	var car := profile.active_car()
	_status.text = "Level %d  ·  rating %d (%s)  ·  driving %s" % [
		profile.level, profile.rating, profile.rating_tier_name(),
		car.display_name() if car != null else "nothing"]

	for child in _list.get_children():
		child.queue_free()

	var by_series := {}
	var order: Array[String] = []
	for event in EventDatabase.all_events():
		var key := event.series if not event.series.is_empty() else "Events"
		if not by_series.has(key):
			by_series[key] = []
			order.append(key)
		by_series[key].append(event)

	for series in order:
		var events: Array = by_series[series]
		# A series where nothing has been unlocked yet is worth showing as a
		# single line: knowing what is coming is most of what a calendar is for.
		var any_visible := false
		for event in events:
			if _is_visible(event):
				any_visible = true
				break
		_list.add_child(UiTheme.section(series))
		if not any_visible:
			var teaser := UiTheme.card()
			teaser.add_child(UiTheme.label(
				"Not yet open. Finish a round of the series before it.",
				UiTheme.SIZE_BODY, UiTheme.TEXT_FAINT))
			_list.add_child(teaser)
			continue
		for event in events:
			if _is_visible(event):
				_list.add_child(_event_card(event))


func _is_visible(event: EventSpec) -> bool:
	if event.requires_events.is_empty():
		return true
	return profile.unlocked_events.has(event.id) or profile.completed_events.has(event.id)


func _event_card(event: EventSpec) -> Control:
	var race_class := event.race_class()
	var track: TrackSpec = TrackSpec.load_all().get(event.track_id)
	var driver_reason := event.profile_rejection_reason(profile)
	var car := _best_car_for(event)
	var car_reason := ""
	if car == null:
		var active := profile.active_car()
		car_reason = event.car_ineligible_reason(active) if active != null else "No car"
	var repeats := profile.times_completed(event.id)
	var enterable := driver_reason.is_empty() and car != null \
		and event.entry_fee <= profile.money

	var card := UiTheme.card(race_class.colour)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	card.add_child(row)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	row.add_child(text)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	name_row.add_child(UiTheme.label(event.display_name, UiTheme.SIZE_HEADING,
		UiTheme.TEXT if enterable else UiTheme.TEXT_DIM))
	name_row.add_child(UiTheme.badge(race_class.display_name, race_class.colour))
	name_row.add_child(UiTheme.badge(event.format_name(), UiTheme.TEXT_DIM))
	if repeats > 0:
		name_row.add_child(UiTheme.badge("RUN %d" % repeats, UiTheme.TEXT_FAINT))
	text.add_child(name_row)

	var where := "%s  ·  %d %s" % [
		track.display_name if track != null else event.track_id,
		event.laps, "lap" if event.laps == 1 else "laps"]
	if track != null and track.night:
		where += "  ·  night"
	text.add_child(UiTheme.label(where, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	text.add_child(UiTheme.wrapped(event.description, UiTheme.SIZE_SMALL, UiTheme.TEXT_FAINT))

	if not driver_reason.is_empty():
		text.add_child(UiTheme.label(driver_reason, UiTheme.SIZE_SMALL, UiTheme.NEGATIVE))
	elif not car_reason.is_empty():
		text.add_child(UiTheme.label(car_reason, UiTheme.SIZE_SMALL, UiTheme.NEGATIVE))
	elif event.entry_fee > profile.money:
		text.add_child(UiTheme.label(
			"Entry is %s — you are %s short" % [
				UiTheme.money(event.entry_fee),
				UiTheme.money(event.entry_fee - profile.money)],
			UiTheme.SIZE_SMALL, UiTheme.NEGATIVE))
	elif car != null:
		text.add_child(UiTheme.label("Entering in your %s" % car.display_name(),
			UiTheme.SIZE_SMALL, UiTheme.POSITIVE))

	# --- Money ---------------------------------------------------------------
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(250, 0)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_theme_constant_override("separation", 2)
	row.add_child(right)

	right.add_child(UiTheme.stat_row("Win pays",
		UiTheme.money(event.payout_for(1, repeats)), UiTheme.ACCENT))
	right.add_child(UiTheme.stat_row("Third",
		UiTheme.money(event.payout_for(3, repeats)), UiTheme.TEXT_DIM))
	right.add_child(UiTheme.stat_row("Entry",
		UiTheme.money(event.entry_fee) if event.entry_fee > 0 else "Free",
		UiTheme.NEGATIVE if event.entry_fee > profile.money else UiTheme.TEXT_DIM))
	right.add_child(UiTheme.stat_row("Rivals",
		"%d, rated ~%d" % [event.ai_opponents, event.field_rating()], UiTheme.TEXT_DIM))
	_build_entry_list(right, event, profile)
	if repeats > 0:
		right.add_child(UiTheme.caption("Repeat entry pays %d%% of the advertised purse"
			% int(EventSpec.repeat_scale(repeats) * 100.0)))

	var enter := UiTheme.primary_button("Enter") if enterable else Button.new()

	if not enterable:
		enter.text = "Locked"
		enter.disabled = true
	enter.custom_minimum_size = Vector2(130, 60)
	enter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	enter.pressed.connect(func(): event_chosen.emit(event))
	row.add_child(enter)
	return card


func _best_car_for(event: EventSpec) -> OwnedCar:
	var best: OwnedCar = null
	var best_index := -1.0
	for uid in profile.garage:
		var car: OwnedCar = profile.garage[uid]
		if not event.car_ineligible_reason(car).is_empty():
			continue
		var index := car.resolved_stats().performance_index()
		if index > best_index:
			best_index = index
			best = car
	return best


## Who is entered, once the player is known well enough to be told.
##
## Two ratings per rival and they are not the same thing. A driver rating is
## how good the person is; a car rating is what they turned up in. A works
## driver in a tired hatchback and a novice in a Group A car are completely
## different races, and one combined number for "difficulty" hides precisely
## the thing worth knowing before you decide what to spend money on.
func _build_entry_list(column: VBoxContainer, event: EventSpec,
		profile: PlayerProfile) -> void:
	if not FieldPreview.visible_to(profile.rating):
		column.add_child(UiTheme.caption(
			"Entry list withheld — reach %d to be told who is entered"
				% FieldPreview.ENTRY_LIST_RATING))
		return
	var entries := FieldPreview.build(event)
	if entries.is_empty():
		return

	column.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))
	column.add_child(UiTheme.section("Entry list"))
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	column.add_child(header)
	header.add_child(UiTheme.label("Driver", UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	header.add_child(UiTheme.expander())
	header.add_child(UiTheme.label("drv / car", UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	# Sorted by the car, because that is the order a player scans an entry list
	# in: what is the quickest thing here, and who is driving it.
	entries.sort_custom(func(a, b): return a.car_rating > b.car_rating)
	for entry in entries:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
		column.add_child(row)
		var who := UiTheme.label(entry.car.display_name(), UiTheme.SIZE_SMALL,
			UiTheme.TEXT)
		who.tooltip_text = "%s — %s" % [entry.archetype_name, entry.prepared]
		row.add_child(who)
		row.add_child(UiTheme.expander())
		# The driver first, then the car, in the colour of whichever is the
		# bigger threat relative to the player.
		row.add_child(UiTheme.label("%d" % entry.driver_rating, UiTheme.SIZE_SMALL,
			UiTheme.WARNING if entry.driver_rating > profile.rating
				else UiTheme.TEXT_DIM))
		row.add_child(UiTheme.label("/", UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
		row.add_child(UiTheme.label("%d" % entry.car_rating, UiTheme.SIZE_SMALL,
			UiTheme.TEXT_DIM))
		column.add_child(UiTheme.caption("   %s · %s"
			% [entry.archetype_name, entry.prepared]))
