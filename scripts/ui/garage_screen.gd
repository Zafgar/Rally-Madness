class_name GarageScreen
extends Control
## The garage: what you own, what state it is in, and where it can race.
##
## The question this screen exists to answer is "what should I take to the next
## event", and that is not the same as "which of these is fastest". A car has a
## class it fits, a performance allowance it has used up, and a condition that
## decides whether it will finish. Those three are given equal weight here,
## because in this economy a fast car you cannot afford to repair is worse than
## a slow one you can.

signal closed()
signal tune_requested(car_uid: String)

const PREVIEW_HEIGHT := 260

var profile: PlayerProfile

var _list: VBoxContainer
var _preview: CarPreview
var _details: VBoxContainer
var _paint: PaintShop
var _money_label: Label
var _selected_uid: String = ""
var _actions: VBoxContainer


func _ready() -> void:
	# Working on the car.
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

	# --- Header -------------------------------------------------------------
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(header)

	var back := Button.new()
	back.text = "< Back"
	back.pressed.connect(func(): closed.emit())
	header.add_child(back)
	header.add_child(UiTheme.title("GARAGE"))
	header.add_child(UiTheme.expander())
	_money_label = UiTheme.label("", UiTheme.SIZE_NUMBER, UiTheme.ACCENT)
	header.add_child(_money_label)

	# --- Body: list on the left, the chosen car on the right ----------------
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(420, 0)
	left.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(left)
	left.add_child(UiTheme.section("Your cars"))

	_list = UiTheme.scroller(left)
	_list.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)

	# The car and what you do to it in the middle; what it is made of on the
	# right. Stacking the spec sheet under the picture left it in a short
	# scrolling box that always cut off somewhere useful.
	var middle := VBoxContainer.new()
	middle.custom_minimum_size = Vector2(480, 0)
	middle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	middle.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(middle)

	var preview_card := UiTheme.card()
	preview_card.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT)
	middle.add_child(preview_card)
	_preview = CarPreview.new()
	preview_card.add_child(_preview)

	_paint = PaintShop.new()
	_paint.paint_chosen.connect(_on_paint_chosen)
	middle.add_child(_paint)

	middle.add_child(UiTheme.expander())

	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	middle.add_child(_actions)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(right)

	var detail_row := UiTheme.scroller(right)
	_details = UiTheme.reading_column(detail_row, 540)
	_details.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)


func refresh() -> void:
	if profile == null:
		return
	_money_label.text = UiTheme.money(profile.money)
	if _selected_uid.is_empty() or not profile.garage.has(_selected_uid):
		var active := profile.active_car()
		_selected_uid = active.uid if active != null else ""
	_rebuild_list()
	_rebuild_details()


# --- The car list -----------------------------------------------------------

func _rebuild_list() -> void:
	UiTheme.clear(_list)

	# Sorted by what the car can become, so the garage reads as a ladder: the
	# thing you are developing at the top, the cheap runabout you keep for the
	# free events at the bottom.
	var uids := profile.garage.keys()
	uids.sort_custom(func(a, b):
		var sa: CarSpec = (profile.garage[a] as OwnedCar).spec()
		var sb: CarSpec = (profile.garage[b] as OwnedCar).spec()
		var pa := sa.potential_index() if sa else 0.0
		var pb := sb.potential_index() if sb else 0.0
		return pa > pb)

	for uid in uids:
		_list.add_child(_car_row(profile.garage[uid]))


func _car_row(car: OwnedCar) -> Control:
	var race_class := RaceClass.best_fit(car)
	var button := UiTheme.list_row(78)
	button.button_pressed = car.uid == _selected_uid
	# Selecting a car must not rebuild the list it lives in: doing that frees
	# the very button whose signal is still running, and with it the focus a pad
	# needs to move from. Marking the rows and redrawing the detail panel is all
	# a selection actually changes.
	button.pressed.connect(func():
		_selected_uid = car.uid
		for sibling in _list.get_children():
			if sibling is Button:
				(sibling as Button).button_pressed = sibling == button
		button.grab_focus()
		_rebuild_details())

	var body := HBoxContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 14
	body.offset_right = -14
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", UiTheme.GAP)
	button.add_child(body)

	var text := VBoxContainer.new()
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.add_theme_constant_override("separation", 2)
	body.add_child(text)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	name_row.add_child(UiTheme.label(car.display_name(), UiTheme.SIZE_LABEL))
	if car.uid == profile.active_car_uid:
		name_row.add_child(UiTheme.badge("ACTIVE", UiTheme.ACCENT))
	text.add_child(name_row)

	var status := "%s  ·  %d index" % [
		race_class.display_name, int(car.resolved_stats().performance_index())]
	if not car.is_driveable():
		status = "Wrecked  ·  " + status
	text.add_child(UiTheme.label(status, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	body.add_child(UiTheme.expander())

	var condition := car.condition()
	var right := VBoxContainer.new()
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.custom_minimum_size = Vector2(96, 0)
	right.add_theme_constant_override("separation", 3)
	var pct := UiTheme.label("%d%%" % int(condition * 100.0), UiTheme.SIZE_LABEL,
		_condition_colour(condition))
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(pct)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = condition
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 4)
	bar.add_theme_stylebox_override("background",
		UiTheme.panel(UiTheme.SURFACE_SUNKEN, Color(0, 0, 0, 0), 2))
	bar.add_theme_stylebox_override("fill",
		UiTheme.panel(_condition_colour(condition), Color(0, 0, 0, 0), 2))
	right.add_child(bar)
	body.add_child(right)

	# The class colour down the left edge, so the ladder is visible without
	# reading a word of it.
	var tag := Panel.new()
	tag.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	tag.offset_right = 4
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_stylebox_override("panel",
		UiTheme.panel(race_class.colour, Color(0, 0, 0, 0), 0))
	button.add_child(tag)
	return button


static func _condition_colour(condition: float) -> Color:
	if condition > 0.75:
		return UiTheme.POSITIVE
	if condition > 0.40:
		return UiTheme.WARNING
	return UiTheme.NEGATIVE


# --- The selected car -------------------------------------------------------

func _rebuild_details() -> void:
	UiTheme.clear(_details)
	UiTheme.clear(_actions)

	var car: OwnedCar = profile.garage.get(_selected_uid)
	if car == null:
		_details.add_child(UiTheme.label("Nothing in the garage.", UiTheme.SIZE_LABEL,
			UiTheme.TEXT_DIM))
		return
	var spec := car.spec()
	if spec == null:
		return

	_preview.show_owned(car)
	_paint.set_current(car.loadout.paint_color)

	var stats := car.resolved_stats()
	var summary: Dictionary = PerformanceModel.summary(stats)
	var race_class := RaceClass.best_fit(car)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UiTheme.GAP)
	title_row.add_child(UiTheme.heading(car.display_name(), UiTheme.TEXT))
	title_row.add_child(UiTheme.badge(race_class.display_name, race_class.colour))
	title_row.add_child(UiTheme.badge(["FWD", "RWD", "AWD"][spec.drivetrain], UiTheme.TEXT_DIM))
	_details.add_child(title_row)
	_details.add_child(UiTheme.wrapped(spec.description, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	# --- What it does -------------------------------------------------------
	_details.add_child(UiTheme.section("Performance"))
	_details.add_child(UiTheme.stat_row("Power",
		"%d hp" % int(summary["power_hp"])))
	_details.add_child(UiTheme.stat_row("Torque",
		"%d Nm" % int(summary["torque_nm"])))
	_details.add_child(UiTheme.stat_row("Weight",
		"%d kg" % int(stats.mass_kg)))
	_details.add_child(UiTheme.stat_row("Power to weight",
		"%.0f hp/t" % (summary["power_hp"] / maxf(stats.mass_kg / 1000.0, 0.1))))
	_details.add_child(UiTheme.stat_row("Top speed",
		"%d km/h" % int(summary["top_speed_kmh"])))
	var zero_to_100: float = summary["zero_to_100"]
	_details.add_child(UiTheme.stat_row("0-100 km/h",
		("%.1f s" % zero_to_100) if zero_to_100 < 60.0 else "-"))

	# --- Where it can race --------------------------------------------------
	_details.add_child(UiTheme.section("Eligibility"))
	var used := race_class.headroom_used(car)
	if used > 0.0:
		_details.add_child(UiTheme.stat_bar(
			"%s allowance" % race_class.display_name, used,
			"%d of %d" % [int(stats.performance_index()),
				int(race_class.max_performance_index)],
			race_class.colour))
		_details.add_child(UiTheme.wrapped(
			"Add more than %d index and this car moves up a class."
			% int(race_class.max_performance_index - stats.performance_index()),
			UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	else:
		_details.add_child(UiTheme.stat_row("Performance index",
			str(int(stats.performance_index()))))
	_details.add_child(UiTheme.stat_row("Built ceiling",
		"%d index" % int(spec.potential_index()), UiTheme.TEXT_DIM))

	# --- Wear and servicing -------------------------------------------------
	# Kept separate from crash damage, because they are different problems with
	# different bills. Damage is what a corner did; wear is what the whole
	# season did, and it is what decides whether the car gets to the finish.
	_details.add_child(UiTheme.section("Wear"))
	_details.add_child(UiTheme.stat_row("Odometer",
		"%s km" % UiTheme.thousands(int(car.odometer_km))))
	_details.add_child(UiTheme.stat_row("On this engine",
		"%s km" % UiTheme.thousands(int(car.engine_km)),
		UiTheme.WARNING if car.engine_km > MechanicalModel.ENGINE_FRESH_KM
			else UiTheme.TEXT))
	var engine_output := car.engine_health_multiplier()
	if engine_output < 0.999:
		_details.add_child(UiTheme.stat_row("Engine output",
			"%d%% of factory" % int(engine_output * 100.0), UiTheme.WARNING))
	for item in OwnedCar.SERVICE_ITEMS:
		var life := car.service_life(item)
		_details.add_child(UiTheme.stat_bar(item.capitalize(), life,
			"%d%%" % int(life * 100.0), _condition_colour(life)))
	_details.add_child(UiTheme.wrapped(
		"Worn parts do not slow the car down much. They raise the chance of it "
		+ "stopping altogether, and the dashboard warns you first.",
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	# --- Condition ----------------------------------------------------------
	_details.add_child(UiTheme.section("Crash damage"))
	for component in ["body", "engine", "suspension", "tires"]:
		var value := float(car.damage.get(component, 1.0))
		_details.add_child(UiTheme.stat_bar(component.capitalize(), value,
			"%d%%" % int(value * 100.0), _condition_colour(value)))
	var bill := car.repair_cost()
	if bill > 0:
		_details.add_child(UiTheme.stat_row("Repair bill", UiTheme.money(bill),
			UiTheme.POSITIVE if bill <= profile.money else UiTheme.NEGATIVE))
	elif car.condition() < 0.999:
		_details.add_child(UiTheme.stat_row("Repair bill", "Free (starter car)",
			UiTheme.POSITIVE))

	_details.add_child(UiTheme.section("History"))
	_details.add_child(UiTheme.stat_row("Races", str(car.races_entered)))
	_details.add_child(UiTheme.stat_row("Wins", str(car.wins)))
	_details.add_child(UiTheme.stat_row("Distance", "%.0f km" % car.odometer_km))
	_details.add_child(UiTheme.stat_row("Trade-in value", UiTheme.money(car.sale_value()),
		UiTheme.TEXT_DIM))
	_details.add_child(UiTheme.stat_row("Held back by mileage",
		"%d%%" % int((1.0 - car.mileage_value_multiplier()) * 100.0), UiTheme.TEXT_DIM))

	_build_actions(car, bill)


func _build_actions(car: OwnedCar, bill: int) -> void:
	if car.uid != profile.active_car_uid and car.is_driveable():
		var use := UiTheme.primary_button("Drive this")
		use.pressed.connect(func():
			profile.active_car_uid = car.uid
			refresh())
		_actions.add_child(use)

	if bill > 0:
		var repair := Button.new()
		repair.text = "Repair  %s" % UiTheme.money(bill)
		UiTheme.set_disabled(repair, bill > profile.money)
		repair.pressed.connect(func():
			if profile.spend(bill):
				car.repair()
				refresh())
		_actions.add_child(repair)
	elif car.condition() < 0.999:
		var free_repair := Button.new()
		free_repair.text = "Repair  free"
		free_repair.pressed.connect(func():
			car.repair()
			refresh())
		_actions.add_child(free_repair)

	# One button per service item, priced individually — a set of tyres and an
	# oil change are not the same money, and a player short of credits should be
	# able to buy the one that matters.
	for item in OwnedCar.SERVICE_ITEMS:
		var cost := car.service_cost(item)
		if cost <= 0:
			continue
		var button := Button.new()
		button.text = "Replace %s  %s" % [item, UiTheme.money(cost)]
		UiTheme.set_disabled(button, cost > profile.money)
		button.pressed.connect(func():
			if profile.spend(cost):
				car.service(item)
				refresh())
		_actions.add_child(button)

	# An engine swap is the answer to a high-mileage bargain: the car is cheap
	# because its engine is tired, and this is how that becomes fixable rather
	# than simply a worse car.
	if car.engine_km > MechanicalModel.ENGINE_FRESH_KM:
		for rebuilt in [true, false]:
			var cost := car.engine_swap_cost(rebuilt)
			var swap := Button.new()
			swap.text = "%s engine  %s" % [
				"Rebuilt" if rebuilt else "New", UiTheme.money(cost)]
			swap.tooltip_text = ("Starts at 70 000 km and costs less."
				if rebuilt else "Starts at zero and makes full power.")
			UiTheme.set_disabled(swap, cost > profile.money)
			swap.pressed.connect(func():
				if profile.spend(cost):
					car.swap_engine(rebuilt)
					refresh())
			_actions.add_child(swap)

	var tune := Button.new()
	tune.text = "Tuning shop"
	tune.pressed.connect(func(): tune_requested.emit(car.uid))
	_actions.add_child(tune)

	var sell := Button.new()
	sell.text = "Sell  %s" % UiTheme.money(car.sale_value())
	# Never let a player sell their way out of having something to drive.
	UiTheme.set_disabled(sell, profile.garage.size() <= 1)
	sell.tooltip_text = "You cannot sell your only car." if sell.disabled else ""
	sell.pressed.connect(func():
		if profile.sell_car(car.uid) > 0:
			_selected_uid = ""
			refresh())
	_actions.add_child(sell)


func _on_paint_chosen(colour: Color) -> void:
	var car: OwnedCar = profile.garage.get(_selected_uid)
	if car == null:
		return
	car.loadout.paint_color = colour
	_preview.set_paint(colour)
