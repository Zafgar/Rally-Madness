class_name RaceHUD
extends Control
## Per-seat race HUD.
##
## Built in code rather than in the editor because there is one of these per
## split-screen view and they need to scale down as the viewport shrinks — a
## quarter-screen HUD cannot use the same type sizes as a full-screen one.
##
## Four things a driver needs and cannot get from the camera, arranged so each
## has its own corner: what the car is doing (the instrument cluster), where
## everyone is (the map), where you stand (position, gaps, lap times), and what
## is about to go wrong (the warning lights).

@export var seat_slot: int = 0

var car: RallyCar
var profile: PlayerProfile

var _gear_label: Label
var _mode_label: Label
var _position_label: Label
var _lap_label: Label
var _time_label: Label
var _gap_ahead_label: Label
var _gap_behind_label: Label
var _name_label: Label
var _status_label: Label
var _lap_panel: VBoxContainer
var _last_lap_label: Label
var _best_lap_label: Label
var _retire_hint: Label

var _cluster: DashboardCluster
var _map: TrackMap
var _nitro_bar: ProgressBar
var _fuel_bar: ProgressBar
var _damage_bars: Dictionary = {}
var _indicators: Dictionary = {}
var _warning_lights: Dictionary = {}

## Unlit telemetry lights stay visible but recede, so their layout does not
## shift when one comes on.
const INDICATOR_IDLE := Color(0.32, 0.33, 0.38)
const INDICATOR_ACTIVE := Color(1.0, 0.85, 0.25)
const INDICATOR_ALARM := Color(1.0, 0.30, 0.22)

var race_time: float = 0.0
var position_text: String = ""
var lap_text: String = ""
var gap_ahead: float = 0.0
var gap_behind: float = 0.0
var last_lap: float = 0.0
var best_lap: float = INF
var _status_flash: float = 0.0
## Set true once the car can no longer continue, which is when retiring stops
## being an admission and starts being the only sensible thing to do.
var _stranded: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	EventBus.car_wrecked.connect(_on_car_wrecked)
	EventBus.car_caught_fire.connect(_on_car_fire)
	EventBus.lap_completed.connect(_on_lap_completed)
	EventBus.car_failed.connect(_on_car_failed)


func bind(p_car: RallyCar, p_profile: PlayerProfile) -> void:
	car = p_car
	profile = p_profile
	if _name_label != null:
		_name_label.text = p_profile.display_name if p_profile != null else "Player %d" % (seat_slot + 1)
	if _cluster != null:
		_cluster.bind(p_car)


## Called once the race exists, so the map has a track to draw and cars to
## put on it.
func bind_race(builder: TrackBuilder, all_cars: Array) -> void:
	if _map != null:
		_map.bind(builder, car, all_cars)


func _build() -> void:
	# --- Bottom centre: the instrument cluster ---
	_cluster = DashboardCluster.new()
	_cluster.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_cluster.anchor_left = 0.24
	_cluster.anchor_right = 0.76
	_cluster.offset_top = -132
	_cluster.offset_bottom = -8
	_cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cluster)

	# --- Bottom left: gearbox mode, nitro, fuel, tyre telemetry ---
	var bottom_left := VBoxContainer.new()
	bottom_left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom_left.offset_left = 16
	bottom_left.offset_top = -110
	bottom_left.offset_bottom = -12
	bottom_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom_left)

	var gear_row := HBoxContainer.new()
	gear_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_left.add_child(gear_row)
	_gear_label = _make_label("N", 22, Color(1, 0.85, 0.3))
	gear_row.add_child(_gear_label)
	_mode_label = _make_label("  AUTO", 12, Color(0.7, 0.7, 0.75))
	gear_row.add_child(_mode_label)

	_nitro_bar = _make_bar(Color(0.25, 0.75, 1.0), 8)
	_nitro_bar.custom_minimum_size = Vector2(180, 8)
	bottom_left.add_child(_nitro_bar)

	bottom_left.add_child(_make_label("FUEL", 10, Color(0.65, 0.66, 0.7)))
	_fuel_bar = _make_bar(Color(0.45, 0.80, 0.45), 6)
	_fuel_bar.custom_minimum_size = Vector2(180, 6)
	bottom_left.add_child(_fuel_bar)

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

	# --- Top left: driver, position, lap, time, gaps ---
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

	# Gaps, which are the only way to know whether you are actually racing
	# anybody: the camera shows eighty metres and a rally stage is forty
	# kilometres.
	_gap_ahead_label = _make_label("", 13, Color(0.95, 0.55, 0.45))
	top_left.add_child(_gap_ahead_label)
	_gap_behind_label = _make_label("", 13, Color(0.55, 0.9, 0.6))
	top_left.add_child(_gap_behind_label)

	# --- Top right: the stage map ---
	_map = TrackMap.new()
	_map.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_map.offset_left = -196
	_map.offset_right = -12
	_map.offset_top = 12
	_map.offset_bottom = 160
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map)

	# --- Right, under the map: lap times ---
	_lap_panel = VBoxContainer.new()
	_lap_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_lap_panel.offset_left = -196
	_lap_panel.offset_right = -12
	_lap_panel.offset_top = 166
	_lap_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lap_panel)
	_last_lap_label = _make_label("", 13, Color(0.86, 0.88, 0.92))
	_last_lap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lap_panel.add_child(_last_lap_label)
	_best_lap_label = _make_label("", 13, Color(0.75, 0.55, 1.0))
	_best_lap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lap_panel.add_child(_best_lap_label)

	# --- Bottom right: condition and the warning lights ---
	var damage_box := VBoxContainer.new()
	damage_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	damage_box.offset_left = -168
	damage_box.offset_right = -16
	damage_box.offset_top = -132
	damage_box.offset_bottom = -12
	damage_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(damage_box)

	# The mechanical warning lights sit above the damage bars, because they are
	# the ones that mean "lift off now" rather than "you hit something".
	var warning_row := HBoxContainer.new()
	warning_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	warning_row.add_theme_constant_override("separation", 6)
	damage_box.add_child(warning_row)
	for system in [MechanicalModel.System.OIL, MechanicalModel.System.COOLING,
			MechanicalModel.System.TURBO, MechanicalModel.System.TYRES,
			MechanicalModel.System.BRAKES, MechanicalModel.System.FUEL]:
		var light := _make_label(MechanicalModel.system_name(system).substr(0, 4),
			10, INDICATOR_IDLE)
		warning_row.add_child(light)
		_warning_lights[system] = light

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

	_retire_hint = _make_label("", 15, Color(0.95, 0.6, 0.35))
	_retire_hint.set_anchors_preset(Control.PRESET_CENTER)
	_retire_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_retire_hint.anchor_left = 0.0
	_retire_hint.anchor_right = 1.0
	_retire_hint.offset_top = 46
	add_child(_retire_hint)


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

	if car.transmission != null:
		_gear_label.text = car.transmission.gear_label()
		_mode_label.text = "  " + car.transmission.mode_name()

	if car.nitro != null:
		_nitro_bar.visible = car.nitro.has_nitro()
		_nitro_bar.value = car.nitro.charge_fraction()
		var nfill := _nitro_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if nfill != null:
			# Overheating turns the bottle bar orange as a warning.
			nfill.bg_color = Color(1, 0.5, 0.1) if car.nitro.heat_fraction() > 0.8 \
				else Color(0.25, 0.75, 1.0)

	_update_mechanical()
	_update_retire()

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
	_gap_ahead_label.text = ("▲ %+.1f s" % -gap_ahead) if gap_ahead > 0.0 else ""
	_gap_behind_label.text = ("▼ %+.1f s" % gap_behind) if gap_behind > 0.0 else ""
	_last_lap_label.text = ("LAST %s" % format_time(last_lap)) if last_lap > 0.0 else ""
	_best_lap_label.text = ("BEST %s" % format_time(best_lap)) if best_lap < INF else ""


## Fuel gauge and the warning lights, both straight off the mechanical model —
## the light on the dash is the same number the failure roll uses, so it is a
## real warning rather than a hint.
func _update_mechanical() -> void:
	var mech := car.mechanical
	if mech == null:
		return
	_fuel_bar.value = mech.fuel_fraction()
	var ffill := _fuel_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if ffill != null:
		ffill.bg_color = Color(0.85, 0.25, 0.2) if mech.fuel_fraction() < 0.08 \
			else (Color(0.9, 0.72, 0.25) if mech.fuel_fraction() < 0.2
				else Color(0.45, 0.80, 0.45))

	for system in _warning_lights:
		var light: Label = _warning_lights[system]
		match mech.level_of(system):
			MechanicalModel.Level.CRITICAL:
				light.add_theme_color_override("font_color", INDICATOR_ALARM)
			MechanicalModel.Level.WARNING:
				light.add_theme_color_override("font_color", INDICATOR_ACTIVE)
			_:
				light.add_theme_color_override("font_color", INDICATOR_IDLE)

	_stranded = mech.is_stranded() or (car.damage != null and car.damage.wrecked)


## Tells a stranded driver where the way out is. Retiring itself lives in the
## pause menu, so there is one place to do it rather than a hidden hold on a key
## that also opens the menu.
func _update_retire() -> void:
	_retire_hint.text = "Car is out — press ESC to retire" if _stranded else ""


func _set_indicator(key: String, active: bool, colour: Color) -> void:
	var light: Label = _indicators.get(key)
	if light == null:
		return
	light.add_theme_color_override("font_color", colour if active else INDICATOR_IDLE)


func set_race_info(p_position: int, field: int, lap: int, laps: int, time: float) -> void:
	position_text = "P%d/%d" % [p_position, field]
	lap_text = "LAP %d/%d" % [mini(lap + 1, laps), laps]
	race_time = time


## Seconds to the car in front and the car behind, from the director.
func set_gaps(ahead: float, behind: float) -> void:
	gap_ahead = ahead
	gap_behind = behind


func show_status(text: String, duration: float = 2.0, color: Color = Color(1, 0.9, 0.3)) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)
	_status_flash = duration


static func format_time(seconds: float) -> String:
	if seconds <= 0.0 or seconds >= INF:
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


## A mechanical failure is worth a bigger announcement than a warning light,
## because unlike a light it is not something the driver can still act on.
func _on_car_failed(car_id: int, _system: String, description: String) -> void:
	if car == null or car_id != car.car_id:
		return
	show_status(description.to_upper(), 3.5, Color(1, 0.42, 0.2))


func _on_lap_completed(car_id: int, lap: int, lap_time: float) -> void:
	if car == null or car_id != car.car_id:
		return
	last_lap = lap_time
	var improved := lap_time < best_lap
	if improved:
		best_lap = lap_time
	# A personal best is the one thing worth interrupting the driver for.
	if improved and lap > 1:
		show_status("LAP %d  %s  BEST" % [lap, format_time(lap_time)], 2.4,
			Color(0.78, 0.58, 1.0))
	else:
		show_status("LAP %d  %s" % [lap, format_time(lap_time)], 2.0)
