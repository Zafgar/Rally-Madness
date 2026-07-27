class_name TrackMapView
extends Control
## One stage drawn as a map, fitted to whatever box it is given.
##
## Drawn from the same baked curve the game builds the road from, not from the
## raw waypoints, so what is shown is the road that will actually exist —
## including the smoothing, which is where kinks and doubling-back come from.

var spec: TrackSpec


func _draw() -> void:
	if spec == null:
		return
	var curve := spec.build_curve()
	if curve.point_count < 2:
		return

	# Sample the baked curve rather than the control points: the spline between
	# two waypoints is where a badly placed pair shows itself.
	var length := curve.get_baked_length()
	var points := PackedVector2Array()
	var step := maxf(length / 400.0, 1.0)
	var at := 0.0
	while at <= length:
		points.append(curve.sample_baked(at))
		at += step

	# Fit to the box with a margin, preserving the aspect ratio so a long
	# stage looks long.
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := (hi - lo)
	var margin := 34.0
	var usable := size - Vector2(margin, margin) * 2.0 - Vector2(0, 40.0)
	var scale: float = minf(usable.x / maxf(span.x, 1.0), usable.y / maxf(span.y, 1.0))
	var origin := Vector2(margin, margin) + (usable - span * scale) * 0.5

	var screen := PackedVector2Array()
	for p in points:
		screen.append(origin + (p - lo) * scale)

	# The road, at its real width, so a narrow stage looks narrow.
	var road_px: float = maxf(spec.width * GameConfig.PIXELS_PER_METRE * scale, 2.0)
	draw_polyline(screen, Color(0.22, 0.23, 0.26), road_px, true)
	draw_polyline(screen, Color(0.42, 0.45, 0.50), maxf(road_px * 0.12, 1.0), true)

	# Start, and finish if there is a separate one.
	draw_circle(screen[0], 6.0, Color(0.35, 0.95, 0.45))
	if not spec.closed:
		draw_circle(screen[-1], 6.0, Color(0.95, 0.35, 0.30))

	# Every twentieth sample gets a direction tick, which makes it obvious
	# where the stage doubles back on itself.
	for i in range(0, screen.size() - 4, 20):
		var dir := (screen[i + 4] - screen[i]).normalized()
		var side := Vector2(-dir.y, dir.x)
		draw_line(screen[i] - side * road_px * 0.5,
			screen[i] + side * road_px * 0.5, Color(0, 0, 0, 0.25), 1.0)

	var font := ThemeDB.fallback_font
	if font != null:
		draw_string(font, Vector2(margin, size.y - 22.0),
			"%s   %.2f km   %s%s" % [spec.display_name, length
				/ GameConfig.PIXELS_PER_METRE / 1000.0,
				"loop" if spec.closed else "point to point",
				"   night" if spec.night else ""],
			HORIZONTAL_ALIGNMENT_LEFT, size.x - margin * 2.0, 15,
			Color(0.85, 0.87, 0.92))
