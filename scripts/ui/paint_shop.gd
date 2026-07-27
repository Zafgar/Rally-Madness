class_name PaintShop
extends VBoxContainer
## Choosing what colour a car is.
##
## A named palette rather than a colour wheel. Rally cars are a period thing and
## most of the memorable ones are one of about twenty colours; offering a full
## RGB picker gets you a garage full of mud-brown hatchbacks. The names are half
## the pleasure of it.

signal paint_chosen(colour: Color)

const SWATCH := 34
const COLUMNS := 8

## Grouped roughly by where they came from, which is also roughly how they look
## next to each other.
const PALETTE: Array = [
	["Works White", "#e8e9ec"],
	["Rally Blue", "#1e5fb4"],
	["Martini Red", "#c8272d"],
	["Sunburst Yellow", "#f2b418"],
	["Forest Green", "#1f6b3f"],
	["Gulf Orange", "#e8641c"],
	["Night Black", "#131417"],
	["Gunmetal", "#4a4f58"],

	["Alpine Silver", "#b9bdc4"],
	["Ice Blue", "#7fbfe0"],
	["Rosso Corsa", "#d81f26"],
	["Mustard", "#c99a20"],
	["Pine", "#2c4a38"],
	["Copper", "#a55a2a"],
	["Charcoal", "#232630"],
	["Slate", "#5b6470"],

	["Cream", "#e5dcc2"],
	["Petrol", "#1d5a63"],
	["Maroon", "#7c1f27"],
	["Sand", "#c8a97a"],
	["Lime", "#8cbf3f"],
	["Bronze", "#7d5a2b"],
	["Ink", "#1a2130"],
	["Primer Grey", "#7a7d80"],
]

var _current: Color = Color(0.85, 0.2, 0.15)
var _name_label: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	add_child(UiTheme.section("Paint"))

	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", UiTheme.GAP_TIGHT)
	grid.add_theme_constant_override("v_separation", UiTheme.GAP_TIGHT)
	add_child(grid)

	for entry in PALETTE:
		var colour := Color.from_string(String(entry[1]), Color.WHITE)
		var button := Button.new()
		button.custom_minimum_size = Vector2(SWATCH, SWATCH)
		button.tooltip_text = String(entry[0])
		button.add_theme_stylebox_override("normal",
			UiTheme.panel(colour, UiTheme.LINE, UiTheme.RADIUS_SMALL))
		button.add_theme_stylebox_override("hover",
			UiTheme.panel(colour.lightened(0.12), UiTheme.LINE_STRONG, UiTheme.RADIUS_SMALL))
		button.add_theme_stylebox_override("pressed",
			UiTheme.panel(colour, Color.WHITE, UiTheme.RADIUS_SMALL))
		button.add_theme_stylebox_override("focus",
			UiTheme.panel(colour, UiTheme.ACCENT, UiTheme.RADIUS_SMALL))
		button.pressed.connect(_on_swatch.bind(colour, String(entry[0])))
		grid.add_child(button)
		_buttons.append(button)

	_name_label = UiTheme.caption("")
	add_child(_name_label)
	_update_name()


func current() -> Color:
	return _current


func set_current(colour: Color) -> void:
	_current = colour
	_update_name()


func _on_swatch(colour: Color, name: String) -> void:
	_current = colour
	_name_label.text = name
	paint_chosen.emit(colour)


## Names the closest palette entry to whatever the car is currently wearing, so
## the label is right even for a colour set before this screen existed.
func _update_name() -> void:
	var best := ""
	var best_distance := INF
	for entry in PALETTE:
		var colour := Color.from_string(String(entry[1]), Color.WHITE)
		var d := (Vector3(colour.r, colour.g, colour.b)
			- Vector3(_current.r, _current.g, _current.b)).length()
		if d < best_distance:
			best_distance = d
			best = String(entry[0])
	_name_label.text = best if best_distance < 0.08 else "Custom"
