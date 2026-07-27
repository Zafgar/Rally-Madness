class_name DashboardCluster
extends Control
## The instrument cluster, drawn to suit the car it belongs to.
##
## Two things make this worth doing properly rather than printing a number.
##
## First, the gauges are scaled to the actual car. A Lada's tachometer ends at
## 5600 and its speedometer at 140, a Group B car's at 9000 and 300. A needle
## sweeping the same arc on both is what makes them feel different at the same
## indicated speed — the Lada is flat out and the Group B car is idling.
##
## Second, the style comes from the car. A 1974 saloon gets a cream dial with a
## thin needle; a nineties rally car gets a black one with a red band; a modern
## car gets a digital readout with a bar tacho; a Porsche gets its central
## rev counter with the speedometer beside it; a Lamborghini gets the angular
## hexagonal cluster. Same data, and you always know what you are sitting in.

## Which cluster a car gets. Chosen from the car's own data rather than authored
## per model, so every one of the 57 cars gets something appropriate and a new
## car needs no extra work.
enum Style {
	CLASSIC,     ## cream dial, thin needle, 1960s-80s saloon
	RALLY,       ## black dial, chunky needle, red band — the club racer default
	MODERN,      ## dark dial with a digital speed readout
	DIGITAL,     ## bar tachometer and large digits, nineties Japanese turbo
	PORSCHE,     ## central rev counter, flanking dials
	LAMBORGHINI, ## angular hexagonal cluster, sweeping bar
}

const NEEDLE_SMOOTHING := 14.0
## Gauges sweep this many radians, from lower-left round to lower-right.
const SWEEP := PI * 1.5
const SWEEP_START := PI * 0.75

var car: RallyCar

var _style: Style = Style.RALLY
var _redline: float = 7000.0
var _tacho_max: float = 8000.0
var _speed_max: float = 200.0
var _shown_rpm: float = 0.0
var _shown_speed: float = 0.0
var _speed_step: float = 20.0
var _palette: Dictionary = {}


## The interval a dial is marked in. Real speedometers are marked every 10, 20,
## 25 or 50 km/h and never every 22.5, which is what dividing the maximum by a
## fixed number of ticks produces.
static func _nice_step(maximum: float) -> float:
	for candidate in [10.0, 20.0, 25.0, 50.0, 100.0]:
		if maximum / candidate <= 9.0:
			return candidate
	return 100.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


## Sizes every gauge to this car and picks the cluster it deserves.
func bind(p_car: RallyCar) -> void:
	car = p_car
	if car == null or car.stats == null:
		return
	_style = style_for(car.spec, car.stats)
	_palette = _palette_for(_style)
	_redline = car.stats.redline_rpm
	# Round the dial up to a sensible round number past the redline, the way a
	# real one is printed: a 6400 rpm engine gets an 8000 rpm dial.
	_tacho_max = ceilf((_redline * 1.14) / 1000.0) * 1000.0
	var top := PerformanceModel.top_speed_kmh(car.stats)
	_speed_max = maxf(ceilf((top * 1.12) / 20.0) * 20.0, 80.0)
	_speed_step = _nice_step(_speed_max)
	queue_redraw()


## The cluster a car gets, from what the car is rather than a lookup table of
## model names — so it keeps working when cars are added.
static func style_for(spec: CarSpec, stats: VehicleStats) -> Style:
	if spec == null:
		return Style.RALLY
	# The two the player asked for by name. Checked first, because a 992 is
	# also modern and a Huracan is also a hypercar.
	if spec.manufacturer == "Porsche":
		return Style.PORSCHE
	if spec.manufacturer == "Lamborghini":
		return Style.LAMBORGHINI
	if spec.category == "classic" or spec.year < 1980:
		return Style.CLASSIC
	if spec.year >= 2005 or spec.category == "hyper":
		return Style.MODERN
	# A nineties turbo car with a high redline had a digital dash more often
	# than not, and it suits the ones that do.
	if spec.year >= 1988 and stats.turbo_boost > 1.05:
		return Style.DIGITAL
	return Style.RALLY


static func _palette_for(style: Style) -> Dictionary:
	match style:
		Style.CLASSIC:
			return {
				"face": Color(0.90, 0.87, 0.78), "ink": Color(0.16, 0.14, 0.12),
				"needle": Color(0.14, 0.13, 0.12), "warn": Color(0.72, 0.16, 0.12),
				"bezel": Color(0.55, 0.50, 0.42), "accent": Color(0.42, 0.35, 0.24),
			}
		Style.MODERN:
			return {
				"face": Color(0.09, 0.10, 0.12), "ink": Color(0.82, 0.85, 0.90),
				"needle": Color(0.95, 0.96, 1.0), "warn": Color(0.92, 0.22, 0.18),
				"bezel": Color(0.30, 0.33, 0.38), "accent": Color(0.35, 0.72, 0.95),
			}
		Style.DIGITAL:
			return {
				"face": Color(0.05, 0.07, 0.08), "ink": Color(0.35, 0.95, 0.72),
				"needle": Color(0.45, 1.0, 0.80), "warn": Color(1.0, 0.34, 0.20),
				"bezel": Color(0.14, 0.22, 0.22), "accent": Color(0.35, 0.95, 0.72),
			}
		Style.PORSCHE:
			return {
				"face": Color(0.08, 0.08, 0.09), "ink": Color(0.92, 0.90, 0.86),
				"needle": Color(0.94, 0.78, 0.16), "warn": Color(0.90, 0.20, 0.16),
				"bezel": Color(0.42, 0.40, 0.36), "accent": Color(0.94, 0.78, 0.16),
			}
		Style.LAMBORGHINI:
			return {
				"face": Color(0.06, 0.06, 0.07), "ink": Color(0.90, 0.92, 0.95),
				"needle": Color(1.0, 0.72, 0.10), "warn": Color(1.0, 0.24, 0.10),
				"bezel": Color(0.22, 0.24, 0.28), "accent": Color(0.62, 0.90, 0.25),
			}
		_:
			return {
				"face": Color(0.07, 0.075, 0.09), "ink": Color(0.86, 0.88, 0.92),
				"needle": Color(0.98, 0.94, 0.88), "warn": Color(0.95, 0.24, 0.18),
				"bezel": Color(0.28, 0.30, 0.34), "accent": Color(1.0, 0.72, 0.20),
			}


func _process(delta: float) -> void:
	if car == null or car.transmission == null:
		return
	# Needles have mass. Snapping them to the value makes a dial look like a
	# progress bar; a little lag makes it look like an instrument.
	var t := clampf(delta * NEEDLE_SMOOTHING, 0.0, 1.0)
	_shown_rpm = lerpf(_shown_rpm, car.transmission.rpm, t)
	_shown_speed = lerpf(_shown_speed, absf(car.speed_kmh()), t)
	queue_redraw()


func _draw() -> void:
	if car == null or car.stats == null:
		return
	match _style:
		Style.PORSCHE: _draw_porsche()
		Style.LAMBORGHINI: _draw_lamborghini()
		Style.DIGITAL: _draw_digital()
		_: _draw_twin_dials()


# --- Layouts ----------------------------------------------------------------

## The default: two round dials side by side, tachometer on the left. Covers
## classic, rally and modern with nothing but a palette change.
func _draw_twin_dials() -> void:
	var r := minf(size.y * 0.46, size.x * 0.22)
	var cy := size.y * 0.5
	var tacho := Vector2(size.x * 0.5 - r * 1.15, cy)
	var speedo := Vector2(size.x * 0.5 + r * 1.15, cy)

	_dial(tacho, r, _shown_rpm, _tacho_max, 1000.0, "RPM x1000", 0.001,
		_redline / _tacho_max)
	_dial(speedo, r, _shown_speed, _speed_max, _speed_step, "km/h", 1.0, -1.0)

	# The gear goes inside the rev counter, low down, which is where a car with
	# one puts it — and there is no room between two dials for a digit big
	# enough to read at a glance.
	_gear_readout(tacho + Vector2(0, r * 0.30), r * 0.36)
	if _style == Style.MODERN:
		_digits(speedo + Vector2(0, r * 0.30), r * 0.32, "%d" % int(_shown_speed))


## Central rev counter with the speedometer to its right, which is the layout
## every road car from Stuttgart has had for sixty years.
func _draw_porsche() -> void:
	var r := minf(size.y * 0.48, size.x * 0.20)
	var cy := size.y * 0.5
	var centre := Vector2(size.x * 0.5, cy)

	_dial(centre, r * 1.18, _shown_rpm, _tacho_max, 1000.0, "", 0.001,
		_redline / _tacho_max)
	_dial(centre + Vector2(r * 2.05, 0), r * 0.86, _shown_speed, _speed_max,
		_speed_step * 2.0, "km/h", 1.0, -1.0)
	# Left-hand dial is oil temperature, because on this car it always is.
	_dial(centre - Vector2(r * 2.05, 0), r * 0.86,
		car.mechanical.oil_c if car.mechanical else 90.0, 180.0, 45.0, "OIL C", 1.0,
		MechanicalModel.OIL_WARN_C / 180.0)
	_gear_readout(centre + Vector2(0, r * 0.36), r * 0.50)


## Angular, hexagonal, and a rev bar that sweeps across the top — the modern
## Sant'Agata idiom rather than a round dial.
func _draw_lamborghini() -> void:
	var w := size.x * 0.78
	var h := size.y * 0.72
	var origin := Vector2((size.x - w) * 0.5, (size.y - h) * 0.5)

	_hex_panel(Rect2(origin, Vector2(w, h)))

	# Rev bar across the top, segmented, going red at the limit.
	var bar := Rect2(origin + Vector2(w * 0.06, h * 0.14), Vector2(w * 0.88, h * 0.16))
	var fraction := clampf(_shown_rpm / _tacho_max, 0.0, 1.0)
	var segments := 28
	for i in segments:
		var t := float(i) / float(segments - 1)
		var lit := t <= fraction
		var seg := Rect2(
			bar.position + Vector2(bar.size.x * t * 0.965, 0.0),
			Vector2(bar.size.x / float(segments) * 0.72, bar.size.y))
		var colour: Color = _palette["accent"]
		if t > _redline / _tacho_max:
			colour = _palette["warn"]
		elif t > 0.72:
			colour = Color(1.0, 0.80, 0.16)
		draw_rect(seg, colour if lit else Color(colour.r, colour.g, colour.b, 0.16))

	_digits(origin + Vector2(w * 0.5, h * 0.62), h * 0.34, "%d" % int(_shown_speed))
	_label(origin + Vector2(w * 0.5, h * 0.90), "km/h")
	_gear_readout(origin + Vector2(w * 0.86, h * 0.62), h * 0.30)


## Bar tachometer and big digits: the nineties Japanese turbo dash.
func _draw_digital() -> void:
	var w := size.x * 0.74
	var h := size.y * 0.70
	var origin := Vector2((size.x - w) * 0.5, (size.y - h) * 0.5)

	var panel := Rect2(origin, Vector2(w, h))
	draw_rect(panel, _palette["face"])
	draw_rect(panel, _palette["bezel"], false, 2.0)

	# Rev bar down the left, rising — literally the "rising tachometer".
	var bar_w := w * 0.16
	var bar := Rect2(origin + Vector2(w * 0.05, h * 0.12), Vector2(bar_w, h * 0.76))
	draw_rect(bar, Color(0, 0, 0, 0.35))
	var fraction := clampf(_shown_rpm / _tacho_max, 0.0, 1.0)
	var rows := 16
	for i in rows:
		var t := float(i) / float(rows - 1)
		var lit := t <= fraction
		var y := bar.position.y + bar.size.y * (1.0 - t) - bar.size.y / float(rows) * 0.8
		var colour: Color = _palette["ink"]
		if t > _redline / _tacho_max:
			colour = _palette["warn"]
		elif t > 0.78:
			colour = Color(1.0, 0.82, 0.24)
		draw_rect(Rect2(Vector2(bar.position.x, y),
			Vector2(bar.size.x, bar.size.y / float(rows) * 0.66)),
			colour if lit else Color(colour.r, colour.g, colour.b, 0.14))

	_digits(origin + Vector2(w * 0.58, h * 0.44), h * 0.42, "%d" % int(_shown_speed))
	_label(origin + Vector2(w * 0.58, h * 0.72), "km/h")
	_gear_readout(origin + Vector2(w * 0.88, h * 0.44), h * 0.28)


# --- Primitives -------------------------------------------------------------

## One round dial. `warn_fraction` below zero means no red band.
func _dial(
	centre: Vector2,
	radius: float,
	value: float,
	maximum: float,
	step: float,
	caption: String,
	label_scale: float,
	warn_fraction: float
) -> void:
	draw_circle(centre, radius * 1.06, _palette["bezel"])
	draw_circle(centre, radius, _palette["face"])

	# Red band from the redline round to the end of the dial.
	if warn_fraction > 0.0 and warn_fraction < 1.0:
		var from := SWEEP_START + SWEEP * warn_fraction
		draw_arc(centre, radius * 0.86, from, SWEEP_START + SWEEP, 24,
			_palette["warn"], radius * 0.10, true)

	var ticks := int(maximum / maxf(step, 1.0))
	for i in range(ticks + 1):
		var t := float(i) / float(maxi(ticks, 1))
		var angle := SWEEP_START + SWEEP * t
		var dir := Vector2(cos(angle), sin(angle))
		draw_line(centre + dir * radius * 0.78, centre + dir * radius * 0.93,
			_palette["ink"], 2.0, true)
		# Numbers on the majors only, or a small dial turns to soup.
		if ticks <= 10 or i % 2 == 0:
			var text := "%d" % int(round(step * float(i) * label_scale))
			_small_text(centre + dir * radius * 0.62, text, _palette["ink"],
				int(maxf(radius * 0.20, 8.0)))

	# Bottom centre, in the gap the sweep leaves between its two ends. Anywhere
	# on the face itself lands on a number: the sweep passes through the top and
	# both sides, and only the bottom is free.
	if not caption.is_empty():
		_small_text(centre + Vector2(0, radius * 0.58), caption,
			Color(_palette["ink"].r, _palette["ink"].g, _palette["ink"].b, 0.6),
			int(maxf(radius * 0.14, 7.0)))

	# Needle.
	var fraction := clampf(value / maxf(maximum, 1.0), 0.0, 1.0)
	var needle_angle := SWEEP_START + SWEEP * fraction
	var needle := Vector2(cos(needle_angle), sin(needle_angle))
	var tip := centre + needle * radius * 0.88
	var tail := centre - needle * radius * 0.16
	var thickness: float = 3.5 if _style == Style.CLASSIC else 5.0
	draw_line(tail, tip, _palette["needle"], thickness, true)
	draw_circle(centre, radius * 0.12, _palette["bezel"])
	draw_circle(centre, radius * 0.07, _palette["needle"])


func _hex_panel(rect: Rect2) -> void:
	var cut := rect.size.y * 0.22
	var p := PackedVector2Array([
		rect.position + Vector2(cut, 0),
		rect.position + Vector2(rect.size.x - cut, 0),
		rect.position + Vector2(rect.size.x, rect.size.y * 0.5),
		rect.position + Vector2(rect.size.x - cut, rect.size.y),
		rect.position + Vector2(cut, rect.size.y),
		rect.position + Vector2(0, rect.size.y * 0.5),
	])
	draw_colored_polygon(p, _palette["face"])
	var closed := PackedVector2Array(p)
	closed.append(p[0])
	draw_polyline(closed, _palette["bezel"], 2.0, true)


## The selected gear, and the gearbox mode under it.
func _gear_readout(centre: Vector2, radius: float) -> void:
	if car.transmission == null:
		return
	var gear := car.transmission.gear
	var text := "N"
	if gear > 0:
		text = str(gear)
	elif gear < 0:
		text = "R"
	var colour: Color = _palette["accent"]
	# On the limiter, the gear number is the thing a driver is looking at, so
	# that is what turns red.
	if _shown_rpm > _redline * 0.97:
		colour = _palette["warn"]
	_digits(centre, radius * 1.5, text, colour)


func _digits(centre: Vector2, height: float, text: String, colour: Color = Color.TRANSPARENT) -> void:
	var font := ThemeDB.fallback_font
	var chosen: Color = colour if colour.a > 0.0 else _palette["ink"]
	var size_px := int(maxf(height, 8.0))
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	draw_string(font, centre + Vector2(-width * 0.5, size_px * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, chosen)


func _label(centre: Vector2, text: String) -> void:
	_small_text(centre, text,
		Color(_palette["ink"].r, _palette["ink"].g, _palette["ink"].b, 0.7), 11)


func _small_text(centre: Vector2, text: String, colour: Color, size_px: int) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	draw_string(font, centre + Vector2(-width * 0.5, size_px * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, colour)
