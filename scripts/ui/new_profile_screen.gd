class_name NewProfileScreen
extends PanelContainer
## Starting a career: a name, a face, and a first car.
##
## The car choice is the point. The five starter cars are all slow and all free
## to repair, but they are not the same: one is rear-engined and will swap ends
## if lifted mid-corner, one is front-drive and simply pushes, one weighs six
## hundred kilos. Picking one is the first real decision a player makes, so the
## screen shows the numbers that decide it rather than just a name.

signal created(profile: PlayerProfile)
signal cancelled()

const AVATAR_TILE := 64
const CAR_TILE_WIDTH := 190

var _name_field: LineEdit
var _avatar_row: HBoxContainer
var _car_row: HBoxContainer
var _confirm: Button
var _detail: RichTextLabel

var _avatar_id: int = 0
var _starters: Array[CarSpec] = []
var _chosen_car: int = 0


func _ready() -> void:
	_starters.assign(CarDatabase.starter_cars())
	_build()
	_refresh()


func _build() -> void:
	custom_minimum_size = Vector2(880, 560)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.15)
	style.border_color = Color(1, 0.8, 0.35, 0.5)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 26)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	column.add_child(_heading("NEW CAREER", 30, Color(1, 0.8, 0.35)))

	# --- Name ---
	column.add_child(_heading("Driver name", 16, Color(0.72, 0.73, 0.78)))
	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Enter a name"
	_name_field.max_length = 20
	_name_field.text_changed.connect(func(_t): _refresh())
	column.add_child(_name_field)

	# --- Avatar ---
	column.add_child(_heading("Profile picture", 16, Color(0.72, 0.73, 0.78)))
	_avatar_row = HBoxContainer.new()
	_avatar_row.add_theme_constant_override("separation", 8)
	column.add_child(_avatar_row)
	for i in DriverAvatar.preset_count():
		var button := Button.new()
		button.custom_minimum_size = Vector2(AVATAR_TILE, AVATAR_TILE)
		button.toggle_mode = true
		button.pressed.connect(_on_avatar_chosen.bind(i))
		var avatar := DriverAvatar.new()
		avatar.avatar_id = i
		avatar.background = Color(0, 0, 0, 0)
		avatar.set_anchors_preset(Control.PRESET_FULL_RECT)
		avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(avatar)
		_avatar_row.add_child(button)

	# --- Starter car ---
	column.add_child(_heading("Your first car", 16, Color(0.72, 0.73, 0.78)))
	var hint := Label.new()
	hint.text = "All five are free to repair, forever. They do not drive alike."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.55, 0.56, 0.62))
	column.add_child(hint)

	_car_row = HBoxContainer.new()
	_car_row.add_theme_constant_override("separation", 8)
	column.add_child(_car_row)
	for i in _starters.size():
		var button := Button.new()
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(CAR_TILE_WIDTH, 0)
		button.text = _starters[i].display_name()
		button.pressed.connect(_on_car_chosen.bind(i))
		_car_row.add_child(button)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.custom_minimum_size = Vector2(0, 130)
	column.add_child(_detail)

	# --- Actions ---
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func(): cancelled.emit())
	actions.add_child(cancel)

	_confirm = Button.new()
	_confirm.text = "START CAREER"
	_confirm.custom_minimum_size = Vector2(200, 44)
	_confirm.pressed.connect(_on_confirm)
	actions.add_child(_confirm)


func _heading(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label


func _on_avatar_chosen(index: int) -> void:
	_avatar_id = index
	_refresh()


func _on_car_chosen(index: int) -> void:
	_chosen_car = index
	_refresh()


func _refresh() -> void:
	for i in _avatar_row.get_child_count():
		(_avatar_row.get_child(i) as Button).button_pressed = (i == _avatar_id)
	for i in _car_row.get_child_count():
		(_car_row.get_child(i) as Button).button_pressed = (i == _chosen_car)

	_confirm.disabled = _name_field.text.strip_edges().is_empty() or _starters.is_empty()
	if _starters.is_empty():
		_detail.text = "[color=#dd7f7f]No starter cars in the catalogue.[/color]"
		return

	var spec := _starters[_chosen_car]
	var stats := TuningCalculator.resolve(spec, spec.default_loadout())
	var perf: Dictionary = PerformanceModel.summary(stats)
	var layout: String = ["Front-wheel drive", "Rear-wheel drive", "Four-wheel drive"][spec.drivetrain]

	var text := "[b]%s[/b]  (%d)\n%s\n\n" % [spec.display_name(), spec.year, spec.description]
	text += "%-16s %s\n" % ["Layout", layout]
	text += "%-16s %.0f kg\n" % ["Mass", stats.mass_kg]
	text += "%-16s %.0f hp at %.0f rpm\n" % ["Power", perf["power_hp"], perf["power_rpm"]]
	text += "%-16s %.0f Nm at %.0f rpm\n" % ["Torque", perf["torque_nm"], perf["torque_rpm"]]
	text += "%-16s %.0f km/h\n" % ["Top speed", perf["top_speed_kmh"]]
	text += "%-16s %.1f s\n" % ["0-100 km/h", perf["zero_to_100"]]
	# The bit that actually decides how it behaves, said plainly.
	text += "%-16s %.0f%% front\n" % ["Weight on nose", stats.weight_bias_front * 100.0]
	text += "\n[color=#9a9aa2]%s[/color]" % _handling_note(stats)
	_detail.text = text


## One sentence on what the numbers mean for the driver, because "40% front"
## tells a first-time player nothing on its own.
func _handling_note(stats: VehicleStats) -> String:
	if stats.weight_bias_front < 0.45:
		return "Weight over the tail. Traction off the line, and it will try to swap ends if you lift mid-corner."
	if stats.weight_bias_front > 0.60:
		return "Nose-heavy. Stable and hard to spin, but it will run wide if you ask too much of the front."
	return "Fairly balanced. It will do what you ask and let you know when you have asked too much."


func _on_confirm() -> void:
	var name := _name_field.text.strip_edges()
	if name.is_empty() or _starters.is_empty():
		return
	var profile := SaveSystem.create_profile(name, _starters[_chosen_car], _avatar_id)
	created.emit(profile)
