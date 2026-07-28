class_name SettingsScreen
extends Control
## The window and the mix, in one place.
##
## Nothing here was reachable before: the game launched into whatever size the
## project file said, and the six audio buses the mix was carefully split into
## could only be changed by editing a script. Both are the sort of thing a
## player expects to find within ten seconds of starting a game they intend to
## keep, and not finding them reads as an unfinished game.
##
## The resolution list is not a fixed table. It starts with the monitor this
## window is actually on and then offers the standard sizes that fit inside it,
## so nobody can pick a window bigger than their screen and lose the title bar.
##
## Every control is a focusable widget in reading order, so a pad walks the
## screen top to bottom without anything special being wired up.

signal closed

const WINDOW_MODE_NAMES := ["Windowed", "Borderless full screen", "Exclusive full screen"]

var _mode_button: OptionButton
var _resolution_button: OptionButton
var _resolution_row: Control
var _vsync_button: CheckButton
var _sliders: Dictionary = {}   # bus -> HSlider
var _readouts: Dictionary = {}  # bus -> Label


func _ready() -> void:
	theme = UiTheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_sync()
	UiTheme.focus_first(self)


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.GAP)
	margin.add_child(column)

	column.add_child(UiTheme.title("SETTINGS"))
	column.add_child(UiTheme.label(
		"Saved on this machine, so everyone sharing this screen gets them.",
		UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTheme.GAP_WIDE)
	column.add_child(body)

	body.add_child(_display_panel())
	body.add_child(_audio_panel())

	var back := UiTheme.primary_button("Back")
	back.pressed.connect(_close)
	column.add_child(back)


func _display_panel() -> Control:
	var card := UiTheme.card()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UiTheme.GAP)
	card.add_child(box)
	box.add_child(UiTheme.section("Display"))

	_mode_button = OptionButton.new()
	for i in WINDOW_MODE_NAMES.size():
		_mode_button.add_item(String(WINDOW_MODE_NAMES[i]), i)
	_mode_button.item_selected.connect(_on_mode_chosen)
	box.add_child(_labelled("Window", _mode_button))

	_resolution_button = OptionButton.new()
	for size in Settings.resolution_choices():
		var native: Vector2i = Settings.native_resolution()
		var text := "%d × %d" % [size.x, size.y]
		if size == native:
			# Named, so a player can find their own monitor in the list instead
			# of having to know what it is.
			text += "   (this screen)"
		_resolution_button.add_item(text)
		_resolution_button.set_item_metadata(_resolution_button.item_count - 1, size)
	_resolution_button.item_selected.connect(_on_resolution_chosen)
	_resolution_row = _labelled("Size", _resolution_button)
	box.add_child(_resolution_row)

	_vsync_button = CheckButton.new()
	_vsync_button.toggled.connect(_on_vsync_toggled)
	box.add_child(_labelled("Wait for the monitor", _vsync_button))

	box.add_child(UiTheme.wrapped(
		"Full screen uses the whole monitor at its own resolution, so the size "
		+ "below only applies to a window.", UiTheme.SIZE_SMALL, UiTheme.TEXT_DIM))
	box.add_child(UiTheme.expander())
	return card


func _audio_panel() -> Control:
	var card := UiTheme.card()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UiTheme.GAP)
	card.add_child(box)
	box.add_child(UiTheme.section("Sound"))

	# The buses the mix is already split into, so turning the engines down does
	# not take the co-driver and the music with them.
	for pair in [["Master", "Everything"], ["Engine", "Engines"],
			["Tyres", "Tyres and gravel"], ["Impacts", "Crashes"],
			["Music", "Music"], ["Interface", "Menus"]]:
		box.add_child(_volume_row(String(pair[0]), String(pair[1])))
	box.add_child(UiTheme.expander())
	return card


func _volume_row(bus: String, label: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP)

	var name_label := UiTheme.label(label, UiTheme.SIZE_LABEL, UiTheme.TEXT)
	name_label.custom_minimum_size = Vector2(150, 0)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.custom_minimum_size = Vector2(240, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_volume_changed.bind(bus))
	row.add_child(slider)
	_sliders[bus] = slider

	var readout := UiTheme.label("100%", UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM)
	readout.custom_minimum_size = Vector2(56, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	_readouts[bus] = readout
	return row


static func _labelled(text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.GAP)
	var label := UiTheme.label(text, UiTheme.SIZE_LABEL, UiTheme.TEXT)
	label.custom_minimum_size = Vector2(150, 0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


## Pushes the saved settings onto the widgets. Signals are live, so every write
## here is guarded by the fact that setting a widget to the value it already
## represents changes nothing.
func _sync() -> void:
	_mode_button.select(clampi(Settings.window_mode, 0, WINDOW_MODE_NAMES.size() - 1))
	for i in _resolution_button.item_count:
		if _resolution_button.get_item_metadata(i) == Settings.resolution:
			_resolution_button.select(i)
			break
	_vsync_button.button_pressed = Settings.vsync
	for bus in _sliders:
		var slider: HSlider = _sliders[bus]
		slider.set_value_no_signal(float(Settings.volumes.get(bus, 1.0)))
		_show_volume(String(bus))
	_update_resolution_row()


## A window size means nothing in full screen, so the row says so rather than
## sitting there looking like it works.
func _update_resolution_row() -> void:
	var windowed := Settings.window_mode == Settings.WindowMode.WINDOWED
	_resolution_button.disabled = not windowed
	_resolution_button.focus_mode = Control.FOCUS_ALL if windowed else Control.FOCUS_NONE
	_resolution_row.modulate = Color(1, 1, 1, 1.0 if windowed else 0.45)


func _show_volume(bus: String) -> void:
	var readout: Label = _readouts[bus]
	readout.text = "%d%%" % int(round(float(Settings.volumes.get(bus, 1.0)) * 100.0))


func _on_mode_chosen(index: int) -> void:
	Settings.window_mode = index
	Settings.apply()
	Settings.save_settings()
	_update_resolution_row()


func _on_resolution_chosen(index: int) -> void:
	Settings.resolution = _resolution_button.get_item_metadata(index)
	Settings.apply()
	Settings.save_settings()


func _on_vsync_toggled(on: bool) -> void:
	Settings.vsync = on
	Settings.apply()
	Settings.save_settings()


## Every drag writes through to the mixer so the player hears the change while
## they are making it — a volume slider that only takes effect on Back is a
## slider nobody can set correctly.
func _on_volume_changed(value: float, bus: String) -> void:
	Settings.set_volume(bus, value)
	_show_volume(bus)
	Settings.save_settings()
	if AudioDirector.interface != null:
		AudioDirector.interface.play("move")


func _close() -> void:
	Settings.save_settings()
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()
