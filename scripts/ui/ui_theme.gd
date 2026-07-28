class_name UiTheme
extends RefCounted
## One place that decides what the game looks like.
##
## Every screen — the garage, the tuning shop, the showroom, the calendar —
## builds itself from these colours, spacings and widget factories. That is the
## only way a UI stays consistent: not by everyone remembering the same hex
## codes, but by there being nowhere else to get them from.
##
## The palette is warm-neutral on near-black, which is what a car game wants:
## the interface stays out of the way and the paintwork is the brightest thing
## on screen. Accent is the only saturated colour, so anything wearing it is
## something the player is meant to act on.

# --- Palette ----------------------------------------------------------------

const BG := Color(0.055, 0.06, 0.075)
const SURFACE := Color(0.10, 0.11, 0.135)
const SURFACE_RAISED := Color(0.135, 0.147, 0.175)
const SURFACE_SUNKEN := Color(0.075, 0.082, 0.10)
const LINE := Color(1, 1, 1, 0.08)
const LINE_STRONG := Color(1, 1, 1, 0.16)

const TEXT := Color(0.92, 0.93, 0.95)
const TEXT_DIM := Color(0.62, 0.64, 0.70)
const TEXT_FAINT := Color(0.42, 0.44, 0.50)

const ACCENT := Color(1.0, 0.72, 0.20)
const ACCENT_DIM := Color(0.55, 0.40, 0.13)
const POSITIVE := Color(0.42, 0.80, 0.48)
const NEGATIVE := Color(0.90, 0.36, 0.32)
const WARNING := Color(0.95, 0.68, 0.25)

# --- Metrics ----------------------------------------------------------------

const RADIUS := 8
const RADIUS_SMALL := 5
const GAP := 12
const GAP_TIGHT := 6
const GAP_WIDE := 24
const PAD := 18

const SIZE_TITLE := 40
const SIZE_HEADING := 22
const SIZE_LABEL := 15
const SIZE_BODY := 14
const SIZE_SMALL := 12
const SIZE_NUMBER := 26

## Row height everywhere a list is scrolled with a pad. Consistent row heights
## are what make a d-pad feel accurate rather than approximate.
const ROW_HEIGHT := 44


# --- Styleboxes -------------------------------------------------------------

static func panel(bg: Color = SURFACE, border: Color = LINE, radius: int = RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.content_margin_left = PAD
	s.content_margin_right = PAD
	s.content_margin_top = PAD
	s.content_margin_bottom = PAD
	return s


## A panel with a coloured strip down its left edge — used to carry a
## competition class's colour onto a card without tinting the whole thing.
static func tagged_panel(tag: Color, bg: Color = SURFACE) -> StyleBoxFlat:
	var s := panel(bg)
	s.border_width_left = 5
	# A StyleBoxFlat has one border colour for all four sides, so the other
	# three are dropped to zero width rather than being outlined in the class
	# colour — an accent down one edge reads as a tag, an outline reads as
	# selection.
	s.border_width_top = 0
	s.border_width_right = 0
	s.border_width_bottom = 0
	s.border_color = tag
	return s


static func button_style(bg: Color, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0.0 else 0)
	s.set_corner_radius_all(RADIUS_SMALL)
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	return s


# --- The theme itself -------------------------------------------------------

## Built once and shared. Assigning this to the root Control of a screen styles
## every standard widget inside it, so screens only style the things that are
## genuinely specific to them.
static var _theme: Theme = null


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = SIZE_BODY

	# Buttons: flat, quiet at rest, accented on focus. Focus rather than hover
	# is the important state — this game is played with a pad as often as a
	# mouse, and an unfocusable-looking UI is unusable with one.
	t.set_stylebox("normal", "Button", button_style(SURFACE_RAISED, LINE))
	t.set_stylebox("hover", "Button", button_style(SURFACE_RAISED.lightened(0.08), LINE_STRONG))
	# Toggled list rows use this, so it has to read as "this one" rather than as
	# a lit-up warning. A raised surface with an accent outline does that; a
	# filled accent block shouts.
	t.set_stylebox("pressed", "Button", button_style(SURFACE_RAISED.lightened(0.10), ACCENT))
	t.set_stylebox("focus", "Button", button_style(SURFACE_RAISED.lightened(0.05), ACCENT))
	t.set_stylebox("disabled", "Button", button_style(SURFACE_SUNKEN, LINE))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_focus_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_font_size("font_size", "Button", SIZE_LABEL)

	t.set_stylebox("panel", "PanelContainer", panel())

	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", SIZE_BODY)

	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font_size("normal_font_size", "RichTextLabel", SIZE_BODY)

	t.set_stylebox("normal", "LineEdit", panel(SURFACE_SUNKEN, LINE, RADIUS_SMALL))
	t.set_stylebox("focus", "LineEdit", panel(SURFACE_SUNKEN, ACCENT, RADIUS_SMALL))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", ACCENT)

	t.set_stylebox("scroll", "HSlider", panel(SURFACE_SUNKEN, LINE, 3))
	t.set_stylebox("grabber_area", "HSlider", panel(ACCENT_DIM, Color(0, 0, 0, 0), 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", panel(ACCENT, Color(0, 0, 0, 0), 3))

	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("background", "ProgressBar", panel(SURFACE_SUNKEN, LINE, 3))
	t.set_stylebox("fill", "ProgressBar", panel(ACCENT, Color(0, 0, 0, 0), 3))

	_theme = t
	return t


# --- Widget factories -------------------------------------------------------
#
# Anything a screen needs more than once lives here. A helper is cheaper than a
# convention nobody follows.

static func title(text: String) -> Label:
	return label(text, SIZE_TITLE, TEXT)


static func heading(text: String, colour: Color = ACCENT) -> Label:
	return label(text, SIZE_HEADING, colour)


static func caption(text: String) -> Label:
	return label(text, SIZE_SMALL, TEXT_DIM)


static func label(text: String, size: int = SIZE_BODY, colour: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


## A small uppercase divider with a rule running off to the right. Cheap, and it
## does more for a dense screen than any amount of spacing.
static func section(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	var l := label(text.to_upper(), SIZE_SMALL, TEXT_DIM)
	row.add_child(l)
	var rule := Panel.new()
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rule.add_theme_stylebox_override("panel", panel(LINE, Color(0, 0, 0, 0), 0))
	row.add_child(rule)
	return row


static func spacer(height: int = GAP) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


static func expander() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


## Puts the keyboard and pad focus on the first thing in `root` that can take
## it, once the tree has settled.
##
## Every screen in the game was built with focus styling — a highlighted border,
## a brighter label, the lot — and nothing ever called grab_focus. With no
## focused control there is nothing for a d-pad direction to move *from*, so
## pressing up or down on a pad did nothing at all and the entire front end was
## mouse-only. The styles were there the whole time; this is the one line that
## was missing.
##
## Deferred because a screen is usually focused in the same frame it is added,
## and a control cannot take focus before it is in the tree.
static func focus_first(root: Control) -> void:
	if root == null:
		return
	Callable(UiTheme, "_grab_first").call_deferred(root)


static func _grab_first(root: Control) -> void:
	if root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return
	var target := first_focusable(root)
	if target != null:
		target.grab_focus()


## The first focusable control in a subtree, depth first, which is reading
## order for every screen here.
static func first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.visible and not control.is_queued_for_deletion() \
					and control.focus_mode == Control.FOCUS_ALL:
				return control
		var deeper := first_focusable(child)
		if deeper != null:
			return deeper
	return null


## Width to keep clear for a vertical scrollbar.
const SCROLLBAR_WIDTH := 16


## A scrolling column, added to `parent`, whose contents are inset from the
## scrollbar. Returns the column to put things in.
##
## Godot draws a ScrollContainer's scrollbar *over* the content rather than
## beside it, so the right-hand strip of every row underneath is hidden. On a
## screen full of right-aligned figures that means the last character of every
## number — "216 km/h" reading as "216 km/" — which looks like a text bug and
## is really a layout one. Everything that scrolls goes through here.
static func scroller(parent: Control) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", SCROLLBAR_WIDTH)
	scroll.add_child(inset)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(column)
	return column


## A label/value pair on one line, value right-aligned. The workhorse of every
## spec sheet in the game.
static func stat_row(name: String, value: String, colour: Color = TEXT) -> Control:
	var row := HBoxContainer.new()
	row.add_child(label(name, SIZE_BODY, TEXT_DIM))
	row.add_child(expander())
	var v := label(value, SIZE_BODY, colour)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return row


## A named bar, 0..1, with the value written on it. Used for grip, power,
## condition, and how much of a class's performance allowance a car is using.
static func stat_bar(
	name: String,
	value: float,
	text: String = "",
	fill: Color = ACCENT
) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.add_child(stat_row(name, text if not text.is_empty() else "%d%%" % int(value * 100.0)))
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = clampf(value, 0.0, 1.0)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 6)
	bar.add_theme_stylebox_override("background", panel(SURFACE_SUNKEN, Color(0, 0, 0, 0), 3))
	bar.add_theme_stylebox_override("fill", panel(fill, Color(0, 0, 0, 0), 3))
	box.add_child(bar)
	return box


## A short coloured word on a pill — a class name, an eligibility verdict, a
## drivetrain. Reads at a glance, which is the point.
static func badge(text: String, colour: Color) -> Control:
	var wrap := PanelContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var style := panel(Color(colour.r, colour.g, colour.b, 0.16), colour, RADIUS_SMALL)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	wrap.add_theme_stylebox_override("panel", style)
	wrap.add_child(label(text, SIZE_SMALL, colour))
	return wrap


## A column held to a readable width inside a wider space.
##
## Label-value rows are unreadable when they span a 1920-pixel screen: the eye
## loses the line between the name on the left and the number on the right. Spec
## sheets go in one of these; only lists and cards get the full width.
##
## Returns the column to fill; the wrapper it sits in is added to `parent`.
static func reading_column(parent: Node, width: int = 520) -> VBoxContainer:
	var wrapper := HBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(wrapper)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(width, 0)
	column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_theme_constant_override("separation", GAP_TIGHT)
	wrapper.add_child(column)
	# Soaks up anything past the readable width rather than stretching the rows.
	var slack := Control.new()
	slack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_child(slack)
	return column


## A label that wraps rather than forcing its container wider. Descriptions and
## blurbs use this; without it one long sentence sets the minimum width of a
## whole column and pushes everything else off the screen.
static func wrapped(text: String, size: int = SIZE_BODY, colour: Color = TEXT) -> Label:
	var l := label(text, size, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(120, 0)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func card(tag: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var p := PanelContainer.new()
	if tag.a > 0.0:
		p.add_theme_stylebox_override("panel", tagged_panel(tag))
	else:
		p.add_theme_stylebox_override("panel", panel())
	return p


## A selectable row in a list.
##
## Styled explicitly rather than inheriting the Button theme: a row is not a
## push button. Selected means "you are looking at this one", so it is a lifted
## surface with an accent edge — a filled accent block reads as a warning, and
## in a list of cars every row would take turns shouting.
static func list_row(height: int = 72) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.toggle_mode = true
	b.add_theme_stylebox_override("normal", _row_style(SURFACE, LINE))
	b.add_theme_stylebox_override("hover", _row_style(SURFACE_RAISED, LINE_STRONG))
	b.add_theme_stylebox_override("pressed", _row_style(SURFACE_RAISED, ACCENT))
	b.add_theme_stylebox_override("hover_pressed", _row_style(SURFACE_RAISED, ACCENT))
	b.add_theme_stylebox_override("focus", _row_style(SURFACE_RAISED, Color.WHITE))
	b.add_theme_stylebox_override("disabled", _row_style(SURFACE_SUNKEN, LINE))
	return _give_voice(b, "select")


## Gives a button its noises. Every button in the game goes through one of the
## factories in this file, so hanging the sounds here means the front end is
## audible everywhere rather than wherever somebody remembered.
##
## Focus rather than hover for the tick: with a pad there is no hover, and a
## menu that only clicks for mouse users is a menu that is silent for half the
## people playing.
static func _give_voice(b: Button, press_sound: String) -> Button:
	b.focus_entered.connect(func():
		if AudioDirector.interface != null:
			AudioDirector.interface.play("move"))
	b.pressed.connect(func():
		if AudioDirector.interface != null:
			AudioDirector.interface.play("deny" if b.disabled else press_sound))
	return b


static func _row_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(RADIUS_SMALL)
	return s


static func primary_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_stylebox_override("normal", button_style(ACCENT_DIM, ACCENT))
	b.add_theme_stylebox_override("hover", button_style(ACCENT_DIM.lightened(0.12), ACCENT))
	b.add_theme_stylebox_override("pressed", button_style(ACCENT, ACCENT))
	b.add_theme_stylebox_override("focus", button_style(ACCENT_DIM.lightened(0.08), Color.WHITE))
	b.add_theme_color_override("font_color", Color(1, 0.93, 0.80))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color(0.1, 0.08, 0.04))
	b.add_theme_font_size_override("font_size", SIZE_LABEL)
	return _give_voice(b, "confirm")


static func money(amount: int) -> String:
	return "%s cr" % thousands(amount)


## 1234567 -> "1 234 567". A thin space rather than a comma, because prices sit
## next to metric figures everywhere else in this game.
static func thousands(amount: int) -> String:
	var negative := amount < 0
	var digits := str(absi(amount))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = " " + out
	return ("-" + out) if negative else out


## Green above, red below, for a figure where more is better.
static func delta_colour(delta: float) -> Color:
	if absf(delta) < 0.0001:
		return TEXT_DIM
	return POSITIVE if delta > 0.0 else NEGATIVE


static func signed(value: float, decimals: int = 1) -> String:
	var fmt := "%+.*f" % [decimals, value]
	return fmt
