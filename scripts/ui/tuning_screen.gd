class_name TuningScreen
extends Control
## The tuning shop: parts you buy, and setup you adjust for free.
##
## The two halves are deliberately separated. Parts cost money, change the car
## permanently and can push it out of its class; setup costs nothing, is
## reversible, and is what a driver changes between stages. Mixing them into one
## list of sliders is how a tuning screen ends up feeling like a spreadsheet.
##
## Parts a chassis cannot accept are shown greyed with the reason, not hidden.
## Seeing that a better shell would take a bigger turbo is half of why a player
## wants one.

signal closed()

const PREVIEW_HEIGHT := 200

var profile: PlayerProfile
var car: OwnedCar

## Slider ranges, keyed the same as TuningLoadout.setup, with the two ends
## named. A slider labelled "-1 .. 1" tells a player nothing.
const SETUP_LABELS := {
	"brake_bias": ["Brake bias", "Rear", "Front"],
	"diff_preload": ["Differential", "Open", "Locked"],
	"ride_height": ["Ride height", "Low", "High"],
	"antiroll_balance": ["Anti-roll balance", "Oversteer", "Understeer"],
	"gear_length": ["Gearing", "Short", "Long"],
	"awd_split": ["Torque split", "Front", "Rear"],
	"boost_pressure": ["Boost pressure", "Safe", "Maximum"],
	"rev_limit": ["Rev limiter", "Standard", "Raised"],
}

var _slot_list: VBoxContainer
var _part_list: VBoxContainer
var _setup_box: VBoxContainer
var _summary: VBoxContainer
var _preview: CarPreview
var _money_label: Label
var _slot: String = "engine"


func _ready() -> void:
	# Still the garage.
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
	back.text = "< Garage"
	back.pressed.connect(func(): closed.emit())
	header.add_child(back)
	header.add_child(UiTheme.title("TUNING SHOP"))
	header.add_child(UiTheme.expander())
	_money_label = UiTheme.label("", UiTheme.SIZE_NUMBER, UiTheme.ACCENT)
	header.add_child(_money_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	# --- Slots --------------------------------------------------------------
	var slots_column := VBoxContainer.new()
	slots_column.custom_minimum_size = Vector2(230, 0)
	slots_column.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(slots_column)
	slots_column.add_child(UiTheme.section("Component"))
	_slot_list = UiTheme.scroller(slots_column)
	_slot_list.add_theme_constant_override("separation", 2)

	# --- Parts in the chosen slot -------------------------------------------
	var parts_column := VBoxContainer.new()
	parts_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parts_column.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(parts_column)
	parts_column.add_child(UiTheme.section("Catalogue"))
	_part_list = UiTheme.scroller(parts_column)
	_part_list.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)

	# --- The car, and the free setup ----------------------------------------
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(400, 0)
	right.add_theme_constant_override("separation", UiTheme.GAP)
	body.add_child(right)

	var preview_card := UiTheme.card()
	preview_card.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT)
	right.add_child(preview_card)
	_preview = CarPreview.new()
	preview_card.add_child(_preview)

	var right_column := UiTheme.scroller(right)
	right_column.add_theme_constant_override("separation", UiTheme.GAP)

	_summary = VBoxContainer.new()
	_summary.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	right_column.add_child(_summary)

	right_column.add_child(UiTheme.section("Setup"))
	right_column.add_child(UiTheme.wrapped(
		"Free to change, and changeable between stages. Nothing here is bought.",
		UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	_setup_box = VBoxContainer.new()
	_setup_box.add_theme_constant_override("separation", UiTheme.GAP)
	right_column.add_child(_setup_box)
	_build_setup()


func refresh() -> void:
	if profile == null or car == null:
		return
	_money_label.text = UiTheme.money(profile.money)
	_preview.show_owned(car)
	_rebuild_slots()
	_rebuild_parts()
	_rebuild_summary()


# --- Slots ------------------------------------------------------------------

func _rebuild_slots() -> void:
	UiTheme.clear(_slot_list)
	var spec := car.spec()
	for slot in PartSpec.SLOTS:
		var fitted_id: String = car.loadout.get_part(slot)
		var fitted := PartDatabase.get_part(fitted_id)

		# A slot the chassis has no parts for at all is not worth a row: it just
		# teaches the player that some rows never do anything.
		var any_fits := false
		for part in PartDatabase.for_slot(slot):
			if spec.accepts_part(part):
				any_fits = true
				break
		if not any_fits and fitted == null:
			continue

		var button := UiTheme.list_row(46)
		button.button_pressed = slot == _slot
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func():
			_slot = slot
			_rebuild_slots()
			_rebuild_parts())

		var row := HBoxContainer.new()
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 12
		row.offset_right = -12
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(row)
		var text := VBoxContainer.new()
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text.add_theme_constant_override("separation", 0)
		text.add_child(UiTheme.label(slot.capitalize(), UiTheme.SIZE_BODY))
		text.add_child(UiTheme.label(
			fitted.display_name if fitted != null else "Standard",
			UiTheme.SIZE_SMALL, UiTheme.TEXT_FAINT))
		row.add_child(text)
		_slot_list.add_child(button)


# --- Parts ------------------------------------------------------------------

func _rebuild_parts() -> void:
	UiTheme.clear(_part_list)
	var spec := car.spec()
	var stats := car.resolved_stats()
	var fitted_id: String = car.loadout.get_part(_slot)
	# Measured on an undamaged car, and compared against an undamaged trial.
	# Using the car's current (damaged) index as the baseline made every part
	# look like an upgrade, because the trial silently repaired the car.
	var baseline := TuningCalculator.resolve(spec, car.loadout).performance_index()

	for entry in PartDatabase.catalogue_for(_slot, spec, stats):
		var part: PartSpec = entry["part"]
		var blocked: String = entry["blocked_reason"]
		_part_list.add_child(_part_card(part, blocked, part.id == fitted_id, baseline))


func _part_card(part: PartSpec, blocked: String, fitted: bool, baseline: float) -> Control:
	var spec := car.spec()
	var affordable := part.price <= profile.money

	var card := UiTheme.card(_tier_colour(part.tier) if blocked.is_empty() else UiTheme.LINE)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP)
	card.add_child(row)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 3)
	row.add_child(text)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	name_row.add_child(UiTheme.label(part.display_name, UiTheme.SIZE_LABEL,
		UiTheme.TEXT if blocked.is_empty() else UiTheme.TEXT_FAINT))
	name_row.add_child(UiTheme.badge("T%d" % part.tier, _tier_colour(part.tier)))
	if fitted:
		name_row.add_child(UiTheme.badge("FITTED", UiTheme.POSITIVE))
	text.add_child(name_row)
	text.add_child(UiTheme.wrapped(part.description, UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))

	if blocked.is_empty():
		# What fitting it would actually do, resolved through the same
		# calculator the car uses. Listing raw modifiers would be honest and
		# useless: "grip_lat x1.08" is not a decision, "+12 index" is.
		var trial := car.loadout.clone()
		trial.set_part(_slot, part.id)
		var after := TuningCalculator.resolve(spec, trial).performance_index()
		var delta := after - baseline
		var effect := HBoxContainer.new()
		effect.add_theme_constant_override("separation", UiTheme.GAP)
		effect.add_child(UiTheme.label("%+.0f index" % delta, UiTheme.SIZE_SMALL,
			UiTheme.delta_colour(delta)))
		var new_class := RaceClass.best_fit_spec(spec, after)
		var old_class := RaceClass.best_fit(car)
		if new_class.id != old_class.id:
			effect.add_child(UiTheme.badge("moves to %s" % new_class.display_name,
				new_class.colour))
		text.add_child(effect)
	else:
		text.add_child(UiTheme.wrapped(blocked, UiTheme.SIZE_SMALL, UiTheme.NEGATIVE))

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(140, 0)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	row.add_child(right)

	var price := UiTheme.label(
		UiTheme.money(part.price) if part.price > 0 else "Standard",
		UiTheme.SIZE_LABEL,
		UiTheme.TEXT if affordable else UiTheme.NEGATIVE)
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(price)

	if fitted:
		right.add_child(UiTheme.label("Fitted", UiTheme.SIZE_SMALL, UiTheme.TEXT_FAINT))
	elif blocked.is_empty():
		var buy := UiTheme.primary_button("Fit") if affordable else Button.new()
		if not affordable:
			buy.text = "Too dear"
			UiTheme.set_disabled(buy, true)
		buy.pressed.connect(_on_fit.bind(part))
		right.add_child(buy)
	return card


func _on_fit(part: PartSpec) -> void:
	if not profile.spend(part.price):
		return
	car.loadout.set_part(_slot, part.id)
	refresh()


static func _tier_colour(tier: int) -> Color:
	return [
		UiTheme.TEXT_FAINT,
		Color(0.45, 0.72, 0.55),
		Color(0.42, 0.66, 0.86),
		Color(0.86, 0.60, 0.32),
		Color(0.82, 0.42, 0.72),
	][clampi(tier, 0, 4)]


# --- The running total ------------------------------------------------------

func _rebuild_summary() -> void:
	UiTheme.clear(_summary)
	var spec := car.spec()
	var stats := car.resolved_stats()
	var summary: Dictionary = PerformanceModel.summary(stats)
	var race_class := RaceClass.best_fit(car)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UiTheme.GAP)
	head.add_child(UiTheme.heading(car.display_name(), UiTheme.TEXT))
	head.add_child(UiTheme.badge(race_class.display_name, race_class.colour))
	_summary.add_child(head)

	_summary.add_child(UiTheme.stat_row("Power", "%d hp" % int(summary["power_hp"])))
	_summary.add_child(UiTheme.stat_row("Weight", "%d kg" % int(stats.mass_kg)))
	_summary.add_child(UiTheme.stat_row("Top speed",
		"%d km/h" % int(summary["top_speed_kmh"])))
	var used := race_class.headroom_used(car)
	if used > 0.0:
		_summary.add_child(UiTheme.stat_bar("%s allowance" % race_class.display_name,
			used,
			"%d of %d" % [int(stats.performance_index()),
				int(race_class.max_performance_index)],
			race_class.colour))
	else:
		_summary.add_child(UiTheme.stat_row("Performance index",
			str(int(stats.performance_index()))))

	# What the chassis will never allow. This is the honest answer to "why can I
	# not fit the big turbo", and it is the argument for buying a better car.
	_summary.add_child(UiTheme.stat_row("Chassis accepts",
		"up to tier %d parts" % spec.upgrade_ceiling, UiTheme.TEXT_DIM))
	var remaining := spec.full_build_cost() - car.loadout.total_value()
	if remaining > 0:
		_summary.add_child(UiTheme.stat_row("Left to finish this build",
			UiTheme.money(remaining), UiTheme.TEXT_DIM))


# --- Setup sliders ----------------------------------------------------------

func _build_setup() -> void:
	for key in TuningLoadout.new().setup:
		if not SETUP_LABELS.has(key):
			continue
		var names: Array = SETUP_LABELS[key]
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)

		var head := HBoxContainer.new()
		head.add_child(UiTheme.label(String(names[0]), UiTheme.SIZE_BODY, UiTheme.TEXT_DIM))
		head.add_child(UiTheme.expander())
		var value := UiTheme.label("0", UiTheme.SIZE_BODY)
		head.add_child(value)
		box.add_child(head)

		var slider := HSlider.new()
		slider.min_value = -1.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.custom_minimum_size = Vector2(0, 18)
		slider.value_changed.connect(_on_setup_changed.bind(key, value, names))
		slider.set_meta("setup_key", key)
		box.add_child(slider)
		_on_setup_changed(0.0, key, value, names)

		var ends := HBoxContainer.new()
		ends.add_child(UiTheme.label(String(names[1]), UiTheme.SIZE_SMALL, UiTheme.TEXT_FAINT))
		ends.add_child(UiTheme.expander())
		ends.add_child(UiTheme.label(String(names[2]), UiTheme.SIZE_SMALL, UiTheme.TEXT_FAINT))
		box.add_child(ends)

		_setup_box.add_child(box)


func _on_setup_changed(value: float, key: String, readout: Label, names: Array) -> void:
	if car != null:
		car.loadout.setup[key] = value
	# Named, not numeric: "Front +40%" means something, "0.40" does not.
	if absf(value) < 0.03:
		readout.text = "Neutral"
		readout.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	else:
		var end: String = String(names[2] if value > 0.0 else names[1])
		readout.text = "%s %d%%" % [end, int(absf(value) * 100.0)]
		readout.add_theme_color_override("font_color", UiTheme.ACCENT)


## Pushes the car's saved setup back onto the sliders. Called when the screen is
## opened for a different car.
func sync_setup() -> void:
	if car == null:
		return
	for box in _setup_box.get_children():
		for child in box.get_children():
			if child is HSlider and child.has_meta("setup_key"):
				var key: String = child.get_meta("setup_key")
				child.value = float(car.loadout.setup.get(key, 0.0))
