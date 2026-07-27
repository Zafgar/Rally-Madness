class_name TireMarks
extends Node2D
## Marks left on the road by tyres that are sliding.
##
## Driven by the real slip data rather than by "is the handbrake down": a
## locked wheel under braking, a spinning wheel under power and a car sliding
## sideways all leave marks, because in the model all three are the same thing
## — tread moving relative to the road. The physics work is what makes this
## honest rather than decorative.
##
## Marks live in world space, not on the car, so they stay where they were laid.

## Slip past which a wheel starts marking, in normalised slip units where 1.0
## is the grip peak.
const MARK_THRESHOLD := 1.35
## Distance the car must travel before another point is added, in pixels.
## Denser than this is wasted geometry at any sensible zoom.
const POINT_SPACING := 7.0
## Points in one continuous mark before it is closed off and a new one begun.
## Keeps individual Line2D nodes cheap to update.
const MAX_POINTS := 90
## Seconds a finished mark takes to fade away.
const FADE_SECONDS := 14.0
## Hard ceiling on live marks across the whole race. Twelve cars sliding for
## several laps will otherwise fill memory with lines nobody can see.
const MAX_MARKS := 220

const MARK_WIDTH_M := 0.22

class Mark:
	extends RefCounted
	var line: Line2D
	var age: float = 0.0
	var closed: bool = false

## One in-progress mark per wheel, keyed "carid:wheel".
var _active: Dictionary = {}
var _marks: Array[Mark] = []


func _process(delta: float) -> void:
	var i := 0
	while i < _marks.size():
		var mark: Mark = _marks[i]
		if not mark.closed:
			i += 1
			continue
		mark.age += delta
		var life := 1.0 - mark.age / FADE_SECONDS
		if life <= 0.0:
			mark.line.queue_free()
			_marks.remove_at(i)
			continue
		mark.line.modulate.a = life
		i += 1


## Called by a car once per physics frame with the state of one wheel.
##
## `intensity` is normalised slip magnitude; `darkness` lets a surface decide
## how much of a mark it takes at all — tarmac holds rubber, snow does not.
func report(
	key: String,
	world_position: Vector2,
	intensity: float,
	darkness: float,
	tint: Color
) -> void:
	if intensity < MARK_THRESHOLD or darkness <= 0.02:
		_close(key)
		return

	var mark: Mark = _active.get(key)
	if mark == null:
		if _marks.size() >= MAX_MARKS:
			_retire_oldest()
		mark = _begin(world_position, tint)
		_active[key] = mark

	var points := mark.line.points
	if points.size() > 0 and points[points.size() - 1].distance_to(world_position) < POINT_SPACING:
		return
	mark.line.add_point(world_position)
	# Heavier slip lays a darker mark, so a full lock-up is visibly worse than
	# a scrabble out of a corner.
	mark.line.modulate.a = clampf(0.35 + (intensity - MARK_THRESHOLD) * 0.18, 0.2, 0.85) * darkness
	if mark.line.get_point_count() >= MAX_POINTS:
		_close(key)


func _begin(world_position: Vector2, tint: Color) -> Mark:
	var line := Line2D.new()
	line.width = MARK_WIDTH_M * GameConfig.PIXELS_PER_METRE
	line.default_color = tint
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.z_index = -6
	line.add_point(world_position)
	add_child(line)

	var mark := Mark.new()
	mark.line = line
	_marks.append(mark)
	return mark


func _close(key: String) -> void:
	var mark: Mark = _active.get(key)
	if mark == null:
		return
	mark.closed = true
	# A single point is not a mark, it is a dot nobody asked for.
	if mark.line.get_point_count() < 2:
		mark.line.queue_free()
		_marks.erase(mark)
	_active.erase(key)


func _retire_oldest() -> void:
	if _marks.is_empty():
		return
	var oldest: Mark = _marks[0]
	for key in _active.keys():
		if _active[key] == oldest:
			_active.erase(key)
	oldest.line.queue_free()
	_marks.remove_at(0)


## How readily a surface takes a mark, and what colour it leaves. Rubber on
## tarmac is black; on gravel what shows is the scar in the surface, and on
## snow there is barely anything at all.
static func surface_mark(surface: TireModel.Surface) -> Dictionary:
	match surface:
		TireModel.Surface.TARMAC:
			return {"darkness": 1.0, "tint": Color(0.07, 0.07, 0.08)}
		TireModel.Surface.DIRT:
			return {"darkness": 0.55, "tint": Color(0.24, 0.17, 0.11)}
		TireModel.Surface.GRAVEL:
			return {"darkness": 0.45, "tint": Color(0.30, 0.27, 0.22)}
		TireModel.Surface.MUD:
			return {"darkness": 0.65, "tint": Color(0.18, 0.14, 0.09)}
		TireModel.Surface.GRASS:
			return {"darkness": 0.60, "tint": Color(0.15, 0.22, 0.11)}
		TireModel.Surface.SNOW:
			return {"darkness": 0.30, "tint": Color(0.62, 0.66, 0.72)}
		TireModel.Surface.ICE:
			return {"darkness": 0.12, "tint": Color(0.55, 0.66, 0.74)}
	return {"darkness": 0.5, "tint": Color(0.1, 0.1, 0.1)}
