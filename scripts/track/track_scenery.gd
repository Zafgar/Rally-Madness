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

## Metres between scenery items along each side of the road.
const SCENERY_SPACING := 14.0
## How far beyond the barrier scenery starts and stops, in metres.
const SCENERY_NEAR := 3.0
const SCENERY_FAR := 34.0
## Surface speckles per hundred metres of road.
const SPECKLE_DENSITY := 90.0
## Large soft patches of ground colour, so the surround is not one flat green.
const PATCH_DENSITY := 34.0
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
	var inner := half_width_px
	var outer := half_width_px + VERGE_WIDTH * ppm
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
	var count := int(length_m / 100.0 * PATCH_DENSITY)
	for i in count:
		var s: Dictionary = samples[_rng.randi() % samples.size()]
		var side: float = 1.0 if _rng.randf() > 0.5 else -1.0
		var out_m := _rng.randf_range(4.0, 70.0)
		_patches.append({
			"pos": s["pos"] + s["normal"] * (half_width_px + out_m * ppm) * side
				+ s["dir"] * _rng.randf_range(-40.0, 40.0) * ppm,
			"radius": _rng.randf_range(5.0, 18.0) * ppm,
			"shade": _rng.randf_range(-0.035, 0.035),
		})


## Trees, rocks and posts outside the barriers.
func _scatter_scenery() -> void:
	_items.clear()
	if samples.is_empty():
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var step := maxi(int(SCENERY_SPACING * ppm / TrackBuilder.SAMPLE_STEP), 1)

	for i in range(0, samples.size(), step):
		var s: Dictionary = samples[i]
		var surface := spec.surface_at_waypoint(int(s["waypoint"]))
		var style: Dictionary = SURROUND.get(surface, SURROUND[TireModel.Surface.GRAVEL])
		for side in [-1.0, 1.0]:
			# Two or three items per station, thinning out with distance.
			for n in _rng.randi_range(1, 3):
				var out_m := _rng.randf_range(SCENERY_NEAR, SCENERY_FAR)
				var along := _rng.randf_range(-6.0, 6.0) * ppm
				var pos: Vector2 = s["pos"] + s["dir"] * along \
					+ s["normal"] * (half_width_px + out_m * ppm) * side
				_items.append({
					"pos": pos,
					"kind": style["kind"],
					"radius": _rng.randf_range(1.1, 2.9) * ppm,
					"tone": _rng.randf_range(-0.12, 0.12),
				})

	# Marker posts right at the edge, close enough together to read as a line
	# at speed. These are what a driver actually uses to judge a corner.
	var post_step := maxi(int(9.0 * ppm / TrackBuilder.SAMPLE_STEP), 1)
	for i in range(0, samples.size(), post_step):
		var s: Dictionary = samples[i]
		for side in [-1.0, 1.0]:
			_items.append({
				"pos": s["pos"] + s["normal"] * (half_width_px + 0.9 * ppm) * side,
				"kind": "post",
				"radius": 0.32 * ppm,
				"tone": 0.0,
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
		draw_circle(patch["pos"], patch["radius"],
			Color(base.r + shade, base.g + shade, base.b + shade, 0.35))


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
		var pos: Vector2 = item["pos"]
		var r: float = item["radius"]
		var tone: float = item["tone"]
		match item["kind"]:
			"tree":
				# A canopy with a darker rim reads as a tree from directly
				# above, which is all a top-down view ever sees of one.
				draw_circle(pos + Vector2(r * 0.18, r * 0.24), r, Color(0, 0, 0, 0.28))
				draw_circle(pos, r, Color(0.13 + tone, 0.26 + tone, 0.11 + tone))
				draw_circle(pos, r * 0.55, Color(0.17 + tone, 0.33 + tone, 0.14 + tone))
			"snowtree":
				draw_circle(pos + Vector2(r * 0.18, r * 0.24), r, Color(0, 0, 0, 0.20))
				draw_circle(pos, r, Color(0.16, 0.27, 0.20))
				draw_circle(pos, r * 0.52, Color(0.88, 0.92, 0.96))
			"hedge":
				# Overlapping blobs, because a rectangle of slightly different
				# green reads as a missing texture rather than as a bush.
				for k in 3:
					var lump := pos + Vector2(r * (k - 1) * 0.9, r * (0.2 if k == 1 else 0.0))
					draw_circle(lump, r * 0.72, Color(0.14 + tone, 0.25 + tone, 0.12 + tone))
			"post":
				draw_circle(pos, r, Color(0.92, 0.92, 0.88))
				draw_circle(pos, r * 0.5, Color(0.82, 0.16, 0.12))
			_:
				draw_circle(pos, r, Color(0.42 + tone, 0.40 + tone, 0.37 + tone))
