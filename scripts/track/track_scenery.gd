class_name TrackScenery
extends Node2D
## Everything beside and on the road that is not the road.
##
## Drawn in a handful of `_draw()` passes rather than as thousands of nodes:
## Godot batches within one CanvasItem, so a forest costs about what a single
## polygon costs, where a thousand Polygon2D nodes would not.
##
## All of it is seeded from the track id, so a track looks the same every time
## it loads without any of it being stored.

## Metres between scenery stations along each side of the road. Closer than
## this and a forest costs real time to build; further apart and the road is
## not lined with anything, it merely has some trees near it.
const SCENERY_SPACING := 7.0
## How far beyond the barrier scenery starts and stops, in metres.
const SCENERY_NEAR := 3.0
const SCENERY_FAR := 34.0
## Surface speckles per hundred metres of road.
const SPECKLE_DENSITY := 90.0
## Ground mottling, per hundred metres of road, at three scales.
##
## Ground seen from above is mottled at every scale at once: broad changes in
## soil and shade, clumps of vegetation within those, and fine texture within
## those. One layer of large soft discs is not terrain, it is a smear — which
## is exactly what it looked like.
const PATCH_LAYERS := [
	# radius range in metres, count per 100 m, shade range, alpha
	{"radius": [26.0, 60.0], "density": 14.0, "shade": 0.022, "alpha": 0.16},
	{"radius": [7.0, 20.0], "density": 60.0, "shade": 0.038, "alpha": 0.24},
	{"radius": [1.6, 5.0], "density": 210.0, "shade": 0.070, "alpha": 0.26},
]
## Width of the graded verge either side of the road, in metres.
const VERGE_WIDTH := 1.6

## What grows beside each kind of road.
const SURROUND := {
	TireModel.Surface.TARMAC: {"ground": Color(0.20, 0.30, 0.17), "kind": "tree"},
	TireModel.Surface.DIRT: {"ground": Color(0.19, 0.28, 0.15), "kind": "tree"},
	TireModel.Surface.GRAVEL: {"ground": Color(0.18, 0.27, 0.14), "kind": "tree"},
	TireModel.Surface.GRASS: {"ground": Color(0.22, 0.33, 0.18), "kind": "tree"},
	TireModel.Surface.SNOW: {"ground": Color(0.78, 0.82, 0.88), "kind": "snowtree"},
	TireModel.Surface.ICE: {"ground": Color(0.74, 0.80, 0.86), "kind": "snowtree"},
	TireModel.Surface.MUD: {"ground": Color(0.21, 0.26, 0.15), "kind": "tree"},
}

var spec: TrackSpec
## [{ pos, dir, normal, offset, waypoint }] from the builder.
var samples: Array[Dictionary] = []
var half_width_px: float = 100.0

var _rng := RandomNumberGenerator.new()
var _items: Array[Dictionary] = []
var _speckles: Array[Dictionary] = []
var _patches: Array[Dictionary] = []
var _verge_left: PackedVector2Array
var _verge_right: PackedVector2Array


func build(p_spec: TrackSpec, p_samples: Array[Dictionary], p_half_width: float) -> void:
	spec = p_spec
	samples = p_samples
	half_width_px = p_half_width
	_rng.seed = hash(spec.id)
	_build_verges()
	_scatter_patches()
	_scatter_speckles()
	_scatter_scenery()
	queue_redraw()


func _build_verges() -> void:
	var ppm := GameConfig.PIXELS_PER_METRE
	var inner := half_width_px + spec.run_off * ppm
	var outer := inner + VERGE_WIDTH * ppm
	_verge_left = _band(-1.0, inner, outer)
	_verge_right = _band(1.0, inner, outer)


## A ribbon between two lateral offsets, running the length of the road.
func _band(side: float, inner: float, outer: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for s in samples:
		out.append(s["pos"] + s["normal"] * inner * side)
	for i in range(samples.size() - 1, -1, -1):
		out.append(samples[i]["pos"] + samples[i]["normal"] * outer * side)
	return out


## Loose stones, patches and streaks on the road itself. Without them the
## surface is a flat colour and there is nothing to judge speed against.
func _scatter_speckles() -> void:
	_speckles.clear()
	if samples.is_empty():
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var length_m := float(samples.size()) * TrackBuilder.SAMPLE_STEP / ppm
	var count := int(length_m / 100.0 * SPECKLE_DENSITY)

	for i in count:
		var s: Dictionary = samples[_rng.randi() % samples.size()]
		var lateral := _rng.randf_range(-0.92, 0.92) * half_width_px
		var pos: Vector2 = s["pos"] + s["normal"] * lateral
		# Stretched along the road, because that is how surfaces wear.
		var length := _rng.randf_range(0.6, 2.4) * ppm
		var width := _rng.randf_range(0.15, 0.5) * ppm
		_speckles.append({
			"pos": pos,
			"angle": (s["dir"] as Vector2).angle() + _rng.randf_range(-0.25, 0.25),
			"size": Vector2(length, width),
			"shade": _rng.randf_range(-0.30, 0.30),
		})


## Broad, soft variation in the ground either side. A single flat colour reads
## as a placeholder no matter what else is drawn on top of it.
func _scatter_patches() -> void:
	_patches.clear()
	if samples.is_empty():
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var length_m := float(samples.size()) * TrackBuilder.SAMPLE_STEP / ppm
	# Coarse layers first so the fine ones land on top of them, which is the
	# order that reads as ground rather than as circles.
	for layer in PATCH_LAYERS:
		var radius: Array = layer["radius"]
		var count := int(length_m / 100.0 * float(layer["density"]))
		var shade_range: float = layer["shade"]
		for i in count:
			var s: Dictionary = samples[_rng.randi() % samples.size()]
			var side: float = 1.0 if _rng.randf() > 0.5 else -1.0
			# Nearer the road for the fine layers: that is where the eye is,
			# and mottling a kilometre away costs the same and is never seen.
			var reach: float = 90.0 if float(radius[1]) > 20.0 else 46.0
			var out_m := _rng.randf_range(2.0, reach)
			_patches.append({
				"pos": s["pos"] + s["normal"] * (half_width_px + out_m * ppm) * side
					+ s["dir"] * _rng.randf_range(-40.0, 40.0) * ppm,
				"radius": _rng.randf_range(float(radius[0]), float(radius[1])) * ppm,
				# Green ground varies more in green than in red or blue, which
				# is what stops the variation looking like a grey wash.
				"shade": _rng.randf_range(-shade_range, shade_range),
				"alpha": float(layer["alpha"]),
			})


## Trees, rocks and posts outside the barriers.
## Scatters props from the catalogue rather than from a hard-coded list, so a
## new entry in props.json appears beside every track of that theme without any
## track data changing.
func _scatter_scenery() -> void:
	_items.clear()
	if samples.is_empty():
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var step := maxi(int(SCENERY_SPACING * ppm / TrackBuilder.SAMPLE_STEP), 1)
	var palette := TrackProp.for_theme(spec.scenery_theme(), TrackProp.Kind.SCENERY)
	if palette.is_empty():
		palette = TrackProp.for_theme("", TrackProp.Kind.SCENERY)

	for i in range(0, samples.size(), step):
		var s: Dictionary = samples[i]
		for side in [-1.0, 1.0]:
			# Several items per station. The road wants to be lined with
			# scenery, not merely to have some in the general area.
			for n in _rng.randi_range(2, 4):
				var prop := TrackProp.pick(palette, _rng)
				if prop == null:
					continue
				# Squared so most of it clusters against the roadside and it
				# thins out with distance, which is how a cleared road looks
				# from above. A flat spread put as much of a forest forty
				# metres away as beside the road, and neither read as either.
				var bias := _rng.randf()
				var out_m: float = lerpf(prop.near_m, prop.far_m, bias * bias)
				var along := _rng.randf_range(-6.0, 6.0) * ppm
				# Measured from the last drivable metre, not from the white
				# line. A stage with run-off has ground beside the road that a
				# car is meant to be able to use, and a pine tree standing in
				# the middle of it is not scenery, it is a wall nobody drew.
				var pos: Vector2 = s["pos"] + s["dir"] * along \
					+ s["normal"] * (half_width_px \
						+ (spec.run_off + out_m) * ppm) * side
				var scale := 1.0 + _rng.randf_range(
					-prop.radius_variance, prop.radius_variance)
				_items.append({
					"pos": pos,
					"prop": prop,
					"radius": prop.radius_m * scale * ppm,
					"angle": _rng.randf_range(0.0, TAU),
					"seed": _rng.randi(),
				})

	# Marker posts right at the edge, close enough together to read as a line
	# at speed. These are what a driver actually uses to judge a corner.
	var post := TrackProp.by_id("marker_post")
	if post == null:
		return
	var post_step := maxi(int(9.0 * ppm / TrackBuilder.SAMPLE_STEP), 1)
	for i in range(0, samples.size(), post_step):
		var s: Dictionary = samples[i]
		for side in [-1.0, 1.0]:
			_items.append({
				"pos": s["pos"] + s["normal"] * (half_width_px + 0.9 * ppm) * side,
				"prop": post,
				"radius": post.radius_m * ppm,
				"angle": 0.0,
				"seed": i,
			})


func _draw() -> void:
	if samples.is_empty():
		return
	_draw_patches()
	_draw_verges()
	_draw_speckles()
	_draw_scenery()


func _draw_patches() -> void:
	var base: Color = SURROUND.get(spec.default_surface,
		SURROUND[TireModel.Surface.GRAVEL])["ground"]
	for patch in _patches:
		var shade: float = patch["shade"]
		draw_circle(patch["pos"], patch["radius"], Color(
			clampf(base.r + shade * 0.55, 0.0, 1.0),
			clampf(base.g + shade, 0.0, 1.0),
			clampf(base.b + shade * 0.40, 0.0, 1.0),
			float(patch.get("alpha", 0.32))))


func _draw_verges() -> void:
	var colour := Color(0.30, 0.33, 0.22)
	match spec.default_surface:
		TireModel.Surface.SNOW, TireModel.Surface.ICE:
			colour = Color(0.86, 0.89, 0.94)
		TireModel.Surface.TARMAC:
			colour = Color(0.42, 0.40, 0.36)
	if _verge_left.size() > 2:
		draw_colored_polygon(_verge_left, colour)
	if _verge_right.size() > 2:
		draw_colored_polygon(_verge_right, colour)


func _draw_speckles() -> void:
	var road := TrackBuilder.surface_colour(spec.default_surface)
	for speck in _speckles:
		var size: Vector2 = speck["size"]
		var half := size * 0.5
		var corners := PackedVector2Array([
			Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y)])
		var angle: float = speck["angle"]
		var origin: Vector2 = speck["pos"]
		for i in corners.size():
			corners[i] = corners[i].rotated(angle) + origin
		var shade: float = speck["shade"]
		var tint := Color(
			clampf(road.r + shade, 0.0, 1.0),
			clampf(road.g + shade, 0.0, 1.0),
			clampf(road.b + shade, 0.0, 1.0), 0.55)
		draw_colored_polygon(corners, tint)


func _draw_scenery() -> void:
	for item in _items:
		var prop: TrackProp = item["prop"]
		prop.draw_at(self, item["pos"], item["angle"], item["radius"], item["seed"])
