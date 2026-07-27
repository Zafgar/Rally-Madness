class_name ShowroomScreen
extends Control
## Buying a car.
##
## The hard part of a showroom is not listing prices, it is answering "why would
## I buy this when the car I have is faster". Often the answer is that the car
## you have is finished and this one is not: a fully built hot hatch outscores a
## showroom four-wheel-drive car and will still lose to it once both are done.
##
## So every car shows two numbers — what it is now, and what it becomes fully
## built — with the class each of those lands in, and what the build would cost
## on top of the purchase. That is the actual decision.

signal closed()

const PREVIEW_HEIGHT := 300

enum Filter { ALL, AFFORDABLE, UPGRADE }

var profile: PlayerProfile

var _list: VBoxContainer
var _preview: CarPreview
var _details: VBoxContainer
var _paint: PaintShop
var _money_label: Label
var _filter_row: HBoxContainer
var _actions: VBoxContainer
var _selected: CarSpec = null
var _filter: Filter = Filter.ALL
var _paint_choice: Color = Color.from_string("#c8272d", Color.RED)


func _ready() -> void:
	# Being sold something.
	AudioDirector.music.play("showroom")
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
	header.add_child(UiTheme.title("SHOWROOM"))
	header.add_child(UiTheme.expander())
	_money_label = UiTheme.label("", UiTheme.SIZE_NUMBER, UiTheme.ACCENT)
	header.add_child(_money_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(480, 0)
	left.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(left)

	_filter_row = HBoxContainer.new()
	_filter_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	left.add_child(_filter_row)
	_add_filter("Everything", Filter.ALL)
	_add_filter("Can afford", Filter.AFFORDABLE)
	_add_filter("A step up", Filter.UPGRADE)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	scroll.add_child(_list)

	var middle := VBoxContainer.new()
	middle.custom_minimum_size = Vector2(500, 0)
	middle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	middle.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(middle)

	var preview_card := UiTheme.card()
	preview_card.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT)
	middle.add_child(preview_card)
	_preview = CarPreview.new()
	preview_card.add_child(_preview)

	_paint = PaintShop.new()
	_paint.paint_chosen.connect(func(colour):
		_paint_choice = colour
		_preview.set_paint(colour))
	middle.add_child(_paint)

	middle.add_child(UiTheme.expander())

	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	middle.add_child(_actions)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(right)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(detail_scroll)
	var detail_row := VBoxContainer.new()
	detail_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(detail_row)
	_details = UiTheme.reading_column(detail_row, 540)
	_details.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)


func _add_filter(text: String, mode: Filter) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = mode == _filter
	b.pressed.connect(func():
		_filter = mode
		refresh())
	_filter_row.add_child(b)


func refresh() -> void:
	if profile == null:
		return
	_money_label.text = UiTheme.money(profile.money)
	for i in _filter_row.get_child_count():
		(_filter_row.get_child(i) as Button).button_pressed = i == _filter
	_rebuild_list()
	_rebuild_details()


# --- The list ---------------------------------------------------------------

func _best_owned_potential() -> float:
	var best := 0.0
	for uid in profile.garage:
		var spec := (profile.garage[uid] as OwnedCar).spec()
		if spec != null:
			best = maxf(best, spec.potential_index())
	return best


func _rebuild_list() -> void:
	for child in _list.get_children():
		child.queue_free()

	var owned_ceiling := _best_owned_potential()
	var shown: Array[CarSpec] = []
	for spec in CarDatabase.all():
		match _filter:
			Filter.AFFORDABLE:
				if spec.price > profile.money:
					continue
			Filter.UPGRADE:
				if spec.potential_index() <= owned_ceiling:
					continue
			_:
				pass
		shown.append(spec)

	shown.sort_custom(func(a, b): return a.price < b.price)
	if shown.is_empty():
		_list.add_child(UiTheme.label("Nothing here matches.", UiTheme.SIZE_LABEL,
			UiTheme.TEXT_DIM))
		return
	if _selected == null or not shown.has(_selected):
		_selected = shown[0]

	var current_tier := -1
	for spec in shown:
		if spec.tier != current_tier:
			current_tier = spec.tier
			_list.add_child(UiTheme.section("Tier %d" % current_tier))
		_list.add_child(_car_row(spec))


func _car_row(spec: CarSpec) -> Control:
	var stock_class := RaceClass.best_fit_spec(spec)
	var owned := profile.owns_model(spec.id)
	var affordable := spec.price <= profile.money

	var button := UiTheme.list_row(72)
	button.button_pressed = spec == _selected
	button.pressed.connect(func():
		_selected = spec
		refresh())

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", UiTheme.GAP)
	button.add_child(row)

	var text := VBoxContainer.new()
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 2)
	row.add_child(text)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	name_row.add_child(UiTheme.label(spec.display_name(), UiTheme.SIZE_LABEL))
	if owned:
		name_row.add_child(UiTheme.badge("OWNED", UiTheme.POSITIVE))
	text.add_child(name_row)
	text.add_child(UiTheme.label(
		"%s  ·  %d hp  ·  %d index, %d built" % [
			["FWD", "RWD", "AWD"][spec.drivetrain],
			int(PerformanceModel.peak_power_hp(
				TuningCalculator.resolve(spec, spec.default_loadout()))),
			int(spec.stock_index()), int(spec.potential_index())],
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	var price := UiTheme.label(UiTheme.money(spec.price), UiTheme.SIZE_LABEL,
		UiTheme.TEXT if affordable else UiTheme.TEXT_FAINT)
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price.custom_minimum_size = Vector2(120, 0)
	price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(price)

	var tag := Panel.new()
	tag.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	tag.offset_right = 4
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_stylebox_override("panel",
		UiTheme.panel(stock_class.colour, Color(0, 0, 0, 0), 0))
	button.add_child(tag)
	return button


# --- The chosen car ---------------------------------------------------------

func _rebuild_details() -> void:
	for child in _details.get_children():
		child.queue_free()
	for child in _actions.get_children():
		child.queue_free()
	if _selected == null:
		return

	var spec := _selected
	_preview.show_spec(spec, _paint_choice)
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var summary: Dictionary = PerformanceModel.summary(stats)
	var stock_class := RaceClass.best_fit_spec(spec)
	var built_class := RaceClass.best_fit_spec(spec, spec.potential_index())

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UiTheme.GAP)
	title_row.add_child(UiTheme.heading(spec.display_name(), UiTheme.TEXT))
	title_row.add_child(UiTheme.badge(str(spec.year), UiTheme.TEXT_DIM))
	title_row.add_child(UiTheme.badge(["FWD", "RWD", "AWD"][spec.drivetrain], UiTheme.TEXT_DIM))
	_details.add_child(title_row)
	_details.add_child(UiTheme.wrapped(spec.description, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	_details.add_child(UiTheme.section("As it leaves the showroom"))
	_details.add_child(UiTheme.stat_row("Power", "%d hp" % int(summary["power_hp"])))
	_details.add_child(UiTheme.stat_row("Torque", "%d Nm" % int(summary["torque_nm"])))
	_details.add_child(UiTheme.stat_row("Weight", "%d kg" % int(stats.mass_kg)))
	# Nothing here is sold new. What it has already done is half the price.
	var km := spec.showroom_km()
	_details.add_child(UiTheme.stat_row("Mileage", "%s km" % UiTheme.thousands(int(km)),
		UiTheme.WARNING if km > MechanicalModel.ENGINE_FRESH_KM else UiTheme.TEXT))
	_details.add_child(UiTheme.stat_row("Top speed",
		"%d km/h" % int(summary["top_speed_kmh"])))
	var zero_to_100: float = summary["zero_to_100"]
	_details.add_child(UiTheme.stat_row("0-100 km/h",
		("%.1f s" % zero_to_100) if zero_to_100 < 60.0 else "-"))
	var stock_row := HBoxContainer.new()
	stock_row.add_child(UiTheme.label("Races in", UiTheme.SIZE_BODY, UiTheme.TEXT_DIM))
	stock_row.add_child(UiTheme.expander())
	stock_row.add_child(UiTheme.badge(stock_class.display_name, stock_class.colour))
	_details.add_child(stock_row)

	# --- What it becomes ----------------------------------------------------
	# The reason to buy a car is usually not what it is, it is what it will be.
	_details.add_child(UiTheme.section("Fully built"))
	_details.add_child(UiTheme.stat_row("Chassis accepts",
		"parts up to tier %d" % spec.upgrade_ceiling))
	_details.add_child(UiTheme.stat_row("Performance index",
		"%d  (from %d)" % [int(spec.potential_index()), int(spec.stock_index())],
		UiTheme.POSITIVE))
	var built_row := HBoxContainer.new()
	built_row.add_child(UiTheme.label("Would race in", UiTheme.SIZE_BODY, UiTheme.TEXT_DIM))
	built_row.add_child(UiTheme.expander())
	built_row.add_child(UiTheme.badge(built_class.display_name, built_class.colour))
	_details.add_child(built_row)
	_details.add_child(UiTheme.stat_row("Cost of the build",
		UiTheme.money(spec.full_build_cost()), UiTheme.TEXT_DIM))
	_details.add_child(UiTheme.stat_row("Car and build together",
		UiTheme.money(spec.price + spec.full_build_cost()), UiTheme.TEXT_DIM))

	# --- Against what you already have --------------------------------------
	var current := profile.active_car()
	if current != null and current.spec() != null and current.spec().id != spec.id:
		_details.add_child(UiTheme.section("Against your %s" % current.display_name()))
		var mine := current.spec()
		_details.add_child(_comparison("Now", current.resolved_stats().performance_index(),
			spec.stock_index()))
		_details.add_child(_comparison("Fully built", mine.potential_index(),
			spec.potential_index()))

	_build_actions(spec)


## One line of "yours vs theirs", coloured by which way it goes.
func _comparison(name: String, mine: float, theirs: float) -> Control:
	var delta := theirs - mine
	var row := HBoxContainer.new()
	row.add_child(UiTheme.label(name, UiTheme.SIZE_BODY, UiTheme.TEXT_DIM))
	row.add_child(UiTheme.expander())
	row.add_child(UiTheme.label("%d vs %d" % [int(theirs), int(mine)], UiTheme.SIZE_BODY))
	row.add_child(UiTheme.label("  %+d" % int(delta), UiTheme.SIZE_BODY,
		UiTheme.delta_colour(delta)))
	return row


func _build_actions(spec: CarSpec) -> void:
	var owned := profile.owns_model(spec.id)
	var affordable := spec.price <= profile.money

	if owned:
		var again := Button.new()
		again.text = "Buy another  %s" % UiTheme.money(spec.price)
		again.disabled = not affordable
		again.pressed.connect(func():
			var extra := profile.buy_car(spec)
			if extra != null:
				extra.loadout.paint_color = _paint_choice
				refresh())
		_actions.add_child(again)
		_actions.add_child(UiTheme.label("Already in your garage.",
			UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	elif affordable:
		var buy := UiTheme.primary_button("Buy  %s" % UiTheme.money(spec.price))
		buy.pressed.connect(func():
			var bought := profile.buy_car(spec)
			if bought != null:
				bought.loadout.paint_color = _paint_choice
				profile.active_car_uid = bought.uid
				refresh())
		_actions.add_child(buy)
	else:
		var short := Button.new()
		short.text = "Need %s more" % UiTheme.money(spec.price - profile.money)
		short.disabled = true
		_actions.add_child(short)

