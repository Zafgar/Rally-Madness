class_name CornerBoards
extends Node2D
## Distance boards and chevrons at the corners.
##
## A top-down camera shows about eighty metres of road. At forty metres a
## second that is two seconds of warning, which is not enough to brake from
## anything — so a corner that needs a hundred metres of braking arrives
## already lost, and the only way to learn a stage is to crash on it once.
## Every real circuit and every real rally solves this the same way, with boards
## counting down to the braking point and chevrons on the outside of the corner
## saying which way it goes and how hard.
##
## The numbers come from the recce, so they are not decoration. The board
## positions are the corner's own entry minus a distance; the chevrons are the
## corner's own direction and severity. A stage added tomorrow gets them
## without anybody placing anything, and if the geometry changes they move.
##
## Drawn under the cars and over the road, on the outside of the bend — which is
## where a driver is looking on the way in, and out of the racing line so a
## board is never the thing you hit.

## How far before a corner the boards go, in metres.
const BOARD_DISTANCES := [150.0, 100.0, 50.0]
## A corner has to be at least this much slower than the road before it to be
## worth a board. Marking every kink turns the stage into a forest of signs and
## teaches a driver to ignore all of them.
const WORTH_MARKING_RADIUS := 70.0
## Chevrons repeat along the corner at roughly this spacing, in metres.
const CHEVRON_SPACING_M := 14.0

## How far outside the road edge the boards and chevrons sit, in metres.
const VERGE_OFFSET_M := 2.6

const BOARD_COLOURS := [
	Color(0.42, 0.72, 0.38),   # 150 — a long way off
	Color(0.92, 0.76, 0.22),   # 100 — start thinking
	Color(0.86, 0.26, 0.20),   # 50  — brake
]

var model: TrackModel
var _boards: Array = []
var _chevrons: Array = []


func build(p_model: TrackModel) -> void:
	model = p_model
	_boards.clear()
	_chevrons.clear()
	if model == null:
		return

	for corner in model.corners:
		if corner.min_radius > WORTH_MARKING_RADIUS:
			continue
		_place_boards(corner)
		_place_chevrons(corner)
	queue_redraw()


## The countdown boards, on the outside of the corner they warn about.
func _place_boards(corner: TrackModel.Bend) -> void:
	for i in BOARD_DISTANCES.size():
		var distance: float = BOARD_DISTANCES[i]
		var at := corner.entry_s - distance
		if not model.closed and at < 0.0:
			continue
		# Never put a board inside the corner before it: a "50" that is actually
		# in somebody else's apex is worse than no board.
		var previous := model.corner_at(at)
		if previous != null and previous != corner:
			continue
		var index := model.index_at(at)
		# Outside of the bend, which is the side the driver is looking across.
		var side := -corner.direction
		_boards.append({
			"index": index,
			"side": side,
			"text": "%d" % int(distance),
			"colour": BOARD_COLOURS[i],
		})


## Chevrons through the corner itself, pointing the way it turns. More of them,
## and stacked, the tighter it is — which is how a driver reads severity at a
## glance without reading anything.
func _place_chevrons(corner: TrackModel.Bend) -> void:
	var length := corner.length_m()
	var count := maxi(int(length / CHEVRON_SPACING_M), 2)
	# One chevron for a fast bend, three for a hairpin. The convention is old
	# and universal and needs no explaining to anybody who has driven a road.
	var stack := 1
	if corner.min_radius < 45.0:
		stack = 2
	if corner.min_radius < 25.0:
		stack = 3
	for i in range(count + 1):
		var at := corner.entry_s + length * float(i) / float(count)
		_chevrons.append({
			"index": model.index_at(at),
			"side": -corner.direction,
			"stack": stack,
		})


func _draw() -> void:
	if model == null:
		return
	var ppm := GameConfig.PIXELS_PER_METRE
	var edge := (model.width_m * 0.5 + VERGE_OFFSET_M) * ppm

	for chevron in _chevrons:
		var i: int = chevron["index"]
		var origin: Vector2 = model.positions[i] \
			+ model.normals[i] * edge * float(chevron["side"])
		_draw_chevron(origin, model.directions[i], float(chevron["side"]),
			int(chevron["stack"]))

	for board in _boards:
		var i: int = board["index"]
		var origin: Vector2 = model.positions[i] \
			+ model.normals[i] * edge * float(board["side"])
		_draw_board(origin, model.directions[i], String(board["text"]),
			board["colour"])


## A plate on a post, square to the road so it reads from a car coming at it.
func _draw_board(at: Vector2, along: Vector2, text: String, colour: Color) -> void:
	var across := Vector2(-along.y, along.x)
	# Sized in metres, not pixels. The camera shows about eighty metres across a
	# screen, so a twenty-pixel board is under a metre wide and reads as a speck
	# — which is what the first version was. A real distance board is a metre or
	# so and it is meant to be legible from a long way off, so this is generous.
	var w := 2.4 * GameConfig.PIXELS_PER_METRE
	var h := 1.6 * GameConfig.PIXELS_PER_METRE

	# Post and its shadow, so the board sits on the ground rather than floating.
	var post := 1.0 * GameConfig.PIXELS_PER_METRE
	draw_line(at + along * 3.0 + across * 3.0, at + along * 3.0 - across * post,
		Color(0, 0, 0, 0.35), 6.0)
	draw_line(at, at - across * post, Color(0.30, 0.31, 0.33), 5.0)

	var centre := at - across * (post + h * 0.5)
	var plate := PackedVector2Array([
		centre + along * w * 0.5 + across * h * 0.5,
		centre + along * w * 0.5 - across * h * 0.5,
		centre - along * w * 0.5 - across * h * 0.5,
		centre - along * w * 0.5 + across * h * 0.5,
	])
	draw_colored_polygon(plate, Color(0.10, 0.11, 0.13))
	# A coloured band rather than a coloured plate: the number stays legible and
	# the colour is still readable at a glance from a long way off.
	var band := PackedVector2Array([
		centre + along * w * 0.5 + across * h * 0.5,
		centre + along * w * 0.5 + across * h * 0.16,
		centre - along * w * 0.5 + across * h * 0.16,
		centre - along * w * 0.5 + across * h * 0.5,
	])
	draw_colored_polygon(band, colour)
	draw_polyline(plate + PackedVector2Array([plate[0]]),
		Color(0.75, 0.77, 0.80, 0.85), 2.0, true)

	var font := ThemeDB.fallback_font
	var size_px := int(h * 0.62)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	draw_set_transform(centre, along.angle(), Vector2.ONE)
	draw_string(font, Vector2(-width * 0.5, size_px * 0.30), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, Color(0.94, 0.95, 0.97))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## An arrow pointing the way the road goes, stacked for severity.
func _draw_chevron(at: Vector2, along: Vector2, side: float, stack: int) -> void:
	var across := Vector2(-along.y, along.x)
	# Pointing into the corner: the arrow tip is on the side the road turns
	# towards, which is the opposite of the verge it is standing on.
	var point := -across * side
	var size := 1.9 * GameConfig.PIXELS_PER_METRE

	for layer in stack:
		var base := at + point * float(layer) * size * 0.55
		var tip := base + point * size * 0.75
		var wing_a := base - along * size * 0.6
		var wing_b := base + along * size * 0.6
		draw_polyline(PackedVector2Array([wing_a, tip, wing_b]),
			Color(0, 0, 0, 0.5), 9.0, true)
		draw_polyline(PackedVector2Array([wing_a, tip, wing_b]),
			Color(0.95, 0.93, 0.86), 5.0, true)
