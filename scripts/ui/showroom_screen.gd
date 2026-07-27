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
## Two dealerships, not one list with a checkbox. A new car is a model at a
## price; a used car is a specific vehicle with a history, and the questions a
## buyer asks about the two are different enough that mixing them makes both
## worse.
enum Lot { NEW, USED }

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
var _lot: Lot = Lot.NEW
## Which manufacturer's models are open. Empty means the list is showing the
## manufacturers themselves.
##
## Seventy-five cars in one scrolling column is a spreadsheet. A buyer thinks
## "what does Lancia make that I can afford", so the list asks that first and
## then shows the models, grouped by tier inside the marque.
var _marque: String = ""
var _lot_row: HBoxContainer
var _listing: UsedCarMarket.Listing = null
var _stock: Array = []
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

	_lot_row = HBoxContainer.new()
	_lot_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	left.add_child(_lot_row)
	_add_lot("New cars", Lot.NEW)
	_add_lot("Used cars", Lot.USED)

	_filter_row = HBoxContainer.new()
	_filter_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	left.add_child(_filter_row)
	_add_filter("Everything", Filter.ALL)
	_add_filter("Can afford", Filter.AFFORDABLE)
	_add_filter("A step up", Filter.UPGRADE)

	_list = UiTheme.scroller(left)
	_list.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)

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

	var detail_row := UiTheme.scroller(right)
	_details = UiTheme.reading_column(detail_row, 540)
	_details.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)


func _add_lot(text: String, lot: Lot) -> void:
	var b := UiTheme.list_row(40)
	b.text = text
	b.pressed.connect(func():
		_lot = lot
		_marque = ""
		_selected = null
		_listing = null
		refresh())
	_lot_row.add_child(b)


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
	for i in _lot_row.get_child_count():
		(_lot_row.get_child(i) as Button).button_pressed = i == _lot
	# The filters are about a catalogue. A forecourt of nine specific cars is
	# short enough to read, so they only get in the way there.
	_filter_row.visible = _lot == Lot.NEW
	if _lot == Lot.USED:
		_stock = UsedCarMarket.stock(profile)
		_rebuild_used_list()
	else:
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

	# One level up: the manufacturers, with what they have and what it costs.
	if _marque.is_empty():
		_rebuild_marque_list(shown)
		return

	_list.add_child(_back_to_marques())
	_list.add_child(UiTheme.title(_marque))
	var mine: Array[CarSpec] = []
	for spec in shown:
		if spec.manufacturer == _marque:
			mine.append(spec)
	if mine.is_empty():
		_list.add_child(UiTheme.label("Nothing from %s matches." % _marque,
			UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))
		return
	if _selected == null or not mine.has(_selected):
		_selected = mine[0]

	# Within a marque, by tier: that is the ladder a buyer is climbing, and it
	# puts the cheap one and the fast one in the same sentence.
	var current_tier := -1
	for spec in mine:
		if spec.tier != current_tier:
			current_tier = spec.tier
			_list.add_child(UiTheme.section(_tier_name(current_tier)))
		_list.add_child(_car_row(spec))


## What a tier means in words. "Tier 3" is a database column; "Group A" is a
## kind of car, and a buyer browsing a marque is thinking in the second.
func _tier_name(tier: int) -> String:
	match tier:
		0: return "Tier 0 — shopping cars"
		1: return "Tier 1 — hot hatches and coupes"
		2: return "Tier 2 — Group A"
		3: return "Tier 3 — modern performance"
		4: return "Tier 4 — Group B"
		_: return "Tier 5 — anything goes"


func _back_to_marques() -> Control:
	var b := UiTheme.list_row(40)
	b.text = "< All manufacturers"
	b.pressed.connect(func():
		_marque = ""
		refresh())
	return b


## The manufacturers, each with how many models it has here and what they cost.
## A buyer with nine thousand credits wants to know which badges are even worth
## opening, and that is two numbers per marque rather than seventy-five rows.
func _rebuild_marque_list(shown: Array[CarSpec]) -> void:
	var by_marque := {}
	for spec in shown:
		if not by_marque.has(spec.manufacturer):
			by_marque[spec.manufacturer] = []
		(by_marque[spec.manufacturer] as Array).append(spec)

	var names := by_marque.keys()
	names.sort()
	for name in names:
		var models: Array = by_marque[name]
		var cheapest := 999999999
		var dearest := 0
		var affordable := 0
		for spec in models:
			cheapest = mini(cheapest, spec.price)
			dearest = maxi(dearest, spec.price)
			if spec.price <= profile.money:
				affordable += 1

		var row := UiTheme.list_row(58)
		row.pressed.connect(func():
			_marque = String(name)
			_selected = null
			refresh())
		_list.add_child(row)

		var inner := HBoxContainer.new()
		inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inner.add_theme_constant_override("separation", UiTheme.GAP)
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(inner)
		inner.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))

		var text := VBoxContainer.new()
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(text)
		text.add_child(UiTheme.label(String(name), UiTheme.SIZE_LABEL, UiTheme.TEXT))
		text.add_child(UiTheme.label(
			"%d model%s   %s" % [models.size(), "" if models.size() == 1 else "s",
				("%s – %s" % [UiTheme.money(cheapest), UiTheme.money(dearest)])
					if cheapest != dearest else UiTheme.money(cheapest)],
			UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

		inner.add_child(UiTheme.expander())
		# How many you could actually drive away in, which is the number that
		# decides whether this badge is worth opening at all.
		inner.add_child(UiTheme.label(
			"%d in reach" % affordable if affordable > 0 else "none in reach",
			UiTheme.SIZE_SMALL,
			UiTheme.POSITIVE if affordable > 0 else UiTheme.TEXT_DIM))
		inner.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))


## The forecourt. Nine specific cars, each with its own mileage and its own
## story, sorted by asking price.
##
## Deliberately not filtered or grouped: it is short enough to read top to
## bottom, and reading all of it is how you spot the one that is cheap for what
## it is. A filter would hide exactly the car worth finding.
func _rebuild_used_list() -> void:
	for child in _list.get_children():
		child.queue_free()

	if _stock.is_empty():
		_list.add_child(UiTheme.label("The forecourt is empty today.",
			UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))
		return
	if _listing == null or not _stock.has(_listing):
		_listing = _stock[0]
		_selected = _listing.spec

	_list.add_child(UiTheme.caption(UsedCarMarket.rotation_hint(profile)))
	for listing in _stock:
		_list.add_child(_used_row(listing))


func _used_row(listing: UsedCarMarket.Listing) -> Control:
	var car: OwnedCar = listing.car
	var row := UiTheme.list_row(84)
	row.button_pressed = listing == _listing
	row.pressed.connect(func():
		_listing = listing
		_selected = listing.spec
		refresh())

	var inner := HBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.add_theme_constant_override("separation", UiTheme.GAP)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(inner)
	inner.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))

	var text := VBoxContainer.new()
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(text)
	text.add_child(UiTheme.label(listing.spec.display_name(), UiTheme.SIZE_LABEL,
		UiTheme.TEXT))
	# The two numbers that decide it, on one line: how far it has gone and how
	# much of it is left.
	text.add_child(UiTheme.label(
		"%s km   ·   %d%% condition" % [
			UiTheme.thousands(int(car.odometer_km)),
			int(round(car.condition() * 100.0))],
		UiTheme.SIZE_SMALL,
		UiTheme.TEXT_DIM if car.condition() > 0.7 else UiTheme.WARNING))
	text.add_child(UiTheme.label(listing.note, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	inner.add_child(UiTheme.expander())
	var money := VBoxContainer.new()
	money.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	money.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(money)
	var price := UiTheme.label(UiTheme.money(listing.price), UiTheme.SIZE_LABEL,
		UiTheme.ACCENT if listing.price <= profile.money else UiTheme.NEGATIVE)
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(price)
	var saving := UiTheme.label("%s new" % UiTheme.money(listing.new_price),
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM)
	saving.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(saving)
	inner.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))
	return row


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
	# A used car is shown as itself: the paint the last owner chose, the parts
	# they fitted, and the mileage they put on it. Describing the model instead
	# had the list saying 316,500 km and the panel beside it saying 217,500 —
	# two different cars on one screen.
	var used: OwnedCar = _listing.car if _lot == Lot.USED and _listing != null else null
	_paint.visible = used == null
	if used != null:
		_preview.show_owned(used)
	else:
		_preview.show_spec(spec, _paint_choice)
	var stats := TuningCalculator.resolve(spec,
		used.loadout if used != null else spec.default_loadout())
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

	_details.add_child(UiTheme.section(
		"This car, as it stands" if used != null else "As it leaves the showroom"))
	_details.add_child(UiTheme.stat_row("Power", "%d hp" % int(summary["power_hp"])))
	_details.add_child(UiTheme.stat_row("Torque", "%d Nm" % int(summary["torque_nm"])))
	_details.add_child(UiTheme.stat_row("Weight", "%d kg" % int(stats.mass_kg)))
	# Nothing here is sold new. What it has already done is half the price.
	var km := used.odometer_km if used != null else spec.showroom_km()
	_details.add_child(UiTheme.stat_row("Mileage", "%s km" % UiTheme.thousands(int(km)),
		UiTheme.WARNING if km > MechanicalModel.ENGINE_FRESH_KM else UiTheme.TEXT))
	if used != null:
		# The engine can be younger than the car, and on a used forecourt that
		# is one of the few things genuinely worth paying more for.
		if used.engine_km < used.odometer_km * 0.9:
			_details.add_child(UiTheme.stat_row("Engine since new",
				"%s km" % UiTheme.thousands(int(used.engine_km)), UiTheme.POSITIVE))
		_details.add_child(UiTheme.stat_row("Condition",
			"%d%%" % int(round(used.condition() * 100.0)),
			UiTheme.POSITIVE if used.condition() > 0.85
				else (UiTheme.WARNING if used.condition() > 0.6 else UiTheme.NEGATIVE)))
		_details.add_child(UiTheme.section("What the last owner did"))
		var fitted := FieldPreview.preparation_text(spec, used.loadout)
		_details.add_child(UiTheme.wrapped(fitted, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
		for pair in [["Oil", used.oil_life], ["Brakes", used.brake_life],
				["Turbo", used.turbo_life]]:
			var life: float = pair[1]
			if pair[0] == "Turbo" and stats.turbo_boost <= 1.01:
				continue
			_details.add_child(UiTheme.stat_row(String(pair[0]),
				"%d%% left" % int(round(life * 100.0)),
				UiTheme.NEGATIVE if life < 0.3
					else (UiTheme.WARNING if life < 0.6 else UiTheme.TEXT_DIM)))
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
	if _lot == Lot.USED:
		_build_used_actions()
		return
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



## Buying the specific car in front of you, not the model.
##
## The paint shop is deliberately not offered here: a used car is the colour
## somebody else chose, and having to live with that — or pay to change it in
## the garage — is part of what buying second hand is.
func _build_used_actions() -> void:
	if _listing == null:
		return
	var affordable: bool = _listing.price <= profile.money
	if not affordable:
		var short := Button.new()
		short.text = "Need %s more" % UiTheme.money(_listing.price - profile.money)
		short.disabled = true
		_actions.add_child(short)
		return

	var buy := UiTheme.primary_button("Buy this one  %s"
		% UiTheme.money(_listing.price))
	buy.pressed.connect(func():
		var bought := profile.buy_used_car(_listing.car, _listing.price)
		if bought != null:
			profile.active_car_uid = bought.uid
			# Off the forecourt: somebody bought it, and it was this one.
			_stock.erase(_listing)
			_listing = null
			refresh())
	_actions.add_child(buy)

	# What it will cost to put right, which is the number a used-car buyer
	# actually has to add to the asking price.
	var work: int = _listing.car.repair_cost()
	for item in OwnedCar.SERVICE_ITEMS:
		work += _listing.car.service_cost(item)
	if work > 0:
		_actions.add_child(UiTheme.label(
			"Needs about %s of work" % UiTheme.money(work),
			UiTheme.SIZE_SMALL,
			UiTheme.WARNING if work > _listing.price / 3 else UiTheme.TEXT_DIM))
		_actions.add_child(UiTheme.label(
			"All in: %s" % UiTheme.money(_listing.price + work),
			UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
