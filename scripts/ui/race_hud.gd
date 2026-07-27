extends Control
## Per-seat race HUD.
##
## Built in code rather than in the editor because there is one of these per
## split-screen view and they need to scale down as the viewport shrinks — a
## quarter-screen HUD cannot use the same type sizes as a full-screen one.

@export var seat_slot: int = 0

var car: RallyCar
var profile: PlayerProfile

var _speed_label: Label
var _gear_label: Label
var _mode_label: Label
var _position_label: Label
var _lap_label: Label
var _time_label: Label
var _name_label: Label
var _status_label: Label

var _rpm_bar: ProgressBar
var _nitro_bar: ProgressBar
var _damage_bars: Dictionary = {}
var _indicators: Dictionary = {}

## Unlit telemetry lights stay visible but recede, so their layout does not
## shift when one comes on.
const INDICATOR_IDLE := Color(0.32, 0.33, 0.38)
const INDICATOR_ACTIVE := Color(1.0, 0.85, 0.25)
const INDICATOR_ALARM := Color(1.0, 0.30, 0.22)

var race_time: float = 0.0
var position_text: String = ""
var lap_text: String = ""
var _status_flash: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	EventBus.car_wrecked.connect(_on_car_wrecked)
	EventBus.car_caught_fire.connect(_on_car_fire)
	EventBus.lap_completed.connect(_on_lap_completed)


func bind(p_car: RallyCar, p_profile: PlayerProfile) -> void:
	car = p_car
	profile = p_profile
	if _name_label != null:
		_name_label.text = p_profile.display_name if p_profile != null else "Player %d" % (seat_slot + 1)


func _build() -> void:
	# --- Bottom left: speed, gear, gearbox mode ---
	var bottom_left := VBoxContainer.new()
	bottom_left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom_left.offset_left = 16
	bottom_left.offset_top = -110
	bottom_left.offset_bottom = -12
	bottom_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom_left)

	_speed_label = _make_label("0", 34, Color(1, 1, 1))
	bottom_left.add_child(_speed_label)

	var gear_row := HBoxContainer.new()
	gear_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_left.add_child(gear_row)
	_gear_label = _make_label("N", 26, Color(1, 0.85, 0.3))
	gear_row.add_child(_gear_label)
	_mode_label = _make_label("  AUTO", 12, Color(0.7, 0.7, 0.75))
	gear_row.add_child(_mode_label)

	_rpm_bar = _make_bar(Color(0.9, 0.25, 0.2), 8)
	_rpm_bar.custom_minimum_size = Vector2(180, 8)
	bottom_left.add_child(_rpm_bar)

	# Tyre-state telemetry. On a pad these are felt rather than read, but they
	# have to be visible too — not every player has a DualSense, and "why did
	# the car not turn just then" deserves an answer on screen.
	var indicator_row := HBoxContainer.new()
	indicator_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	indicator_row.add_theme_constant_override("separation", 8)
	bottom_left.add_child(indicator_row)
	for key in ["ABS", "TC", "LOCK", "SPIN"]:
		var light := _make_label(key, 12, INDICATOR_IDLE)
		indicator_row.add_child(light)
		_indicators[key] = light

	_nitro_bar = _make_bar(Color(0.25, 0.75, 1.0), 8)
	_nitro_bar.custom_minimum_size = Vector2(180, 8)
	bottom_left.add_child(_nitro_bar)

	# --- Top left: driver, position, lap, time ---
	var top_left := VBoxContainer.new()
	top_left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	top_left.offset_left = 16
	top_left.offset_top = 12
	top_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top_left)

	_name_label = _make_label("Player %d" % (seat_slot + 1), 14, Color(0.8, 0.8, 0.85))
	top_left.add_child(_name_label)
	_position_label = _make_label("", 24, Color(1, 1, 1))
	top_left.add_child(_position_label)
	_lap_label = _make_label("", 14, Color(0.85, 0.85, 0.9))
	top_left.add_child(_lap_label)
	_time_label = _make_label("0:00.00", 16, Color(0.9, 0.9, 0.95))
	top_left.add_child(_time_label)

	# --- Bottom right: component condition ---
	var damage_box := VBoxContainer.new()
	damage_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	damage_box.offset_left = -150
	damage_box.offset_right = -16
	damage_box.offset_top = -96
	damage_box.offset_bottom = -12
	damage_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(damage_box)

	for component in DamageModel.COMPONENT_NAMES:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		damage_box.add_child(row)
		var label := _make_label(component.substr(0, 4).to_upper(), 10, Color(0.65, 0.65, 0.7))
		label.custom_minimum_size = Vector2(38, 0)
		row.add_child(label)
		var bar := _make_bar(Color(0.3, 0.85, 0.35), 6)
		bar.custom_minimum_size = Vector2(90, 6)
		row.add_child(bar)
		_damage_bars[component] = bar

	# --- Centre: countdown, wreck and fire warnings ---
	_status_label = _make_label("", 40, Color(1, 0.9, 0.3))
	_status_label.set_anchors_preset(Control.PRESET_CENTER)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.anchor_left = 0.0
	_status_label.anchor_right = 1.0
	_status_label.offset_top = -60
	add_child(_status_label)


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	# An outline keeps the text readable over both snow and tarmac.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _make_bar(color: Color, height: int) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 0.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.45)
	bar.add_theme_stylebox_override("background", bg)
	return bar


func _process(delta: float) -> void:
	if _status_flash > 0.0:
		_status_flash -= delta
		if _status_flash <= 0.0 and _status_label != null:
			_status_label.text = ""

	if car == null or not is_instance_valid(car) or car.stats == null:
		return

	_speed_label.text = "%d km/h" % int(car.speed_kmh())

	if car.transmission != null:
		_gear_label.text = car.transmission.gear_label()
		_mode_label.text = "  " + car.transmission.mode_name()
		_rpm_bar.value = clampf(car.transmission.rpm / maxf(car.stats.redline_rpm, 1.0), 0.0, 1.0)
		# The bar goes red as the limiter approaches, which is the cue a manual
		# driver actually shifts on.
		var near_limit := _rpm_bar.value > 0.92
		var fill := _rpm_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if fill != null:
			fill.bg_color = Color(1, 0.2, 0.15) if near_limit else Color(0.9, 0.55, 0.2)

	if car.nitro != null:
		_nitro_bar.visible = car.nitro.has_nitro()
		_nitro_bar.value = car.nitro.charge_fraction()
		var nfill := _nitro_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if nfill != null:
			# Overheating turns the bottle bar orange as a warning.
			nfill.bg_color = Color(1, 0.5, 0.1) if car.nitro.heat_fraction() > 0.8 \
				else Color(0.25, 0.75, 1.0)

	_set_indicator("ABS", car.abs_engaged(), INDICATOR_ACTIVE)
	_set_indicator("TC", car.traction_control_engaged(), INDICATOR_ACTIVE)
	# Locked and spinning are failures, not assists, so they read as warnings.
	_set_indicator("LOCK", car.wheels_locked(), INDICATOR_ALARM)
	_set_indicator("SPIN", car.wheels_spinning(), INDICATOR_ALARM)

	if car.damage != null:
		for component in _damage_bars:
			var bar: ProgressBar = _damage_bars[component]
			var value: float = car.damage.integrity[component]
			bar.value = value
			var dfill := bar.get_theme_stylebox("fill") as StyleBoxFlat
			if dfill != null:
				dfill.bg_color = Color(0.85, 0.2, 0.15) if value < 0.3 \
					else (Color(0.9, 0.75, 0.2) if value < 0.6 else Color(0.3, 0.85, 0.35))

	_position_label.text = position_text
	_lap_label.text = lap_text
	_time_label.text = format_time(race_time)


func _set_indicator(key: String, active: bool, colour: Color) -> void:
	var light: Label = _indicators.get(key)
	if light == null:
		return
	light.add_theme_color_override("font_color", colour if active else INDICATOR_IDLE)


func set_race_info(p_position: int, field: int, lap: int, laps: int, time: float) -> void:
	position_text = "P%d/%d" % [p_position, field]
	lap_text = "LAP %d/%d" % [mini(lap + 1, laps), laps]
	race_time = time


func show_status(text: String, duration: float = 2.0, color: Color = Color(1, 0.9, 0.3)) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)
	_status_flash = duration


static func format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "--:--.--"
	var minutes := int(seconds) / 60
	var secs := seconds - float(minutes * 60)
	return "%d:%05.2f" % [minutes, secs]


func _on_car_wrecked(car_id: int, cause: String) -> void:
	if car == null or car_id != car.car_id:
		return
	var text := "BURNED OUT" if cause == "burned_out" else "WRECKED"
	show_status(text, 5.0, Color(1, 0.25, 0.2))


func _on_car_fire(car_id: int) -> void:
	if car == null or car_id != car.car_id:
		return
	show_status("FIRE!", 3.0, Color(1, 0.45, 0.1))


func _on_lap_completed(car_id: int, lap: int, lap_time: float) -> void:
	if car == null or car_id != car.car_id:
		return
	show_status("LAP %d  %s" % [lap, format_time(lap_time)], 2.0)
