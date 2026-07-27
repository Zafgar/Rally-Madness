class_name DriverAvatar
extends Control
## A driver's profile picture, drawn rather than loaded.
##
## Helmets are drawn from polygons so a profile has a face without the project
## carrying image assets, and so the same avatar renders crisply at any size —
## a 32 px seat badge and a 200 px picker tile are the same code. Swapping this
## for real artwork later means replacing one _draw().

## Shell colour, stripe colour, stripe style. Style 0 is a centre stripe, 1 is
## a pair of flanking stripes, 2 is a band across the brow, 3 is plain.
const PRESETS := [
	[Color(0.86, 0.20, 0.16), Color(0.96, 0.94, 0.90), 0],
	[Color(0.13, 0.35, 0.68), Color(0.98, 0.78, 0.20), 1],
	[Color(0.96, 0.94, 0.90), Color(0.20, 0.22, 0.26), 0],
	[Color(0.16, 0.60, 0.38), Color(0.96, 0.94, 0.90), 2],
	[Color(0.20, 0.22, 0.26), Color(0.90, 0.40, 0.10), 1],
	[Color(0.98, 0.78, 0.20), Color(0.20, 0.22, 0.26), 2],
	[Color(0.55, 0.24, 0.68), Color(0.96, 0.94, 0.90), 3],
	[Color(0.90, 0.45, 0.62), Color(0.24, 0.26, 0.30), 0],
]

const VISOR_COLOR := Color(0.14, 0.18, 0.24)
const VISOR_GLINT := Color(0.45, 0.62, 0.78, 0.55)

@export var avatar_id: int = 0:
	set(value):
		avatar_id = posmod(value, PRESETS.size())
		queue_redraw()

## Drawn behind the helmet. Set to transparent for an inline badge.
@export var background: Color = Color(0.12, 0.13, 0.16)


static func preset_count() -> int:
	return PRESETS.size()


func _draw() -> void:
	var box := Vector2(size.x, size.y)
	var r := minf(box.x, box.y)
	var origin := (box - Vector2(r, r)) * 0.5

	if background.a > 0.0:
		draw_rect(Rect2(Vector2.ZERO, box), background)

	var preset: Array = PRESETS[posmod(avatar_id, PRESETS.size())]
	var shell: Color = preset[0]
	var stripe: Color = preset[1]
	var style: int = preset[2]

	# Everything is expressed as a fraction of the box so the helmet scales.
	var p := func(x: float, y: float) -> Vector2:
		return origin + Vector2(x * r, y * r)

	# Shell: a rounded dome sitting on a slightly narrower chin bar.
	var dome := PackedVector2Array([
		p.call(0.16, 0.62), p.call(0.16, 0.44), p.call(0.24, 0.26),
		p.call(0.40, 0.17), p.call(0.60, 0.17), p.call(0.76, 0.26),
		p.call(0.84, 0.44), p.call(0.84, 0.62), p.call(0.78, 0.78),
		p.call(0.62, 0.86), p.call(0.38, 0.86), p.call(0.22, 0.78),
	])
	draw_colored_polygon(dome, shell)

	match style:
		0:
			draw_colored_polygon(PackedVector2Array([
				p.call(0.44, 0.17), p.call(0.56, 0.17),
				p.call(0.57, 0.50), p.call(0.43, 0.50)]), stripe)
		1:
			for offset in [-0.13, 0.13]:
				draw_colored_polygon(PackedVector2Array([
					p.call(0.46 + offset, 0.18), p.call(0.52 + offset, 0.18),
					p.call(0.53 + offset, 0.50), p.call(0.45 + offset, 0.50)]), stripe)
		2:
			draw_colored_polygon(PackedVector2Array([
				p.call(0.19, 0.36), p.call(0.81, 0.36),
				p.call(0.82, 0.45), p.call(0.18, 0.45)]), stripe)

	# Visor, and a glint so it reads as glass rather than a hole.
	var visor := PackedVector2Array([
		p.call(0.24, 0.50), p.call(0.76, 0.50),
		p.call(0.72, 0.68), p.call(0.28, 0.68)])
	draw_colored_polygon(visor, VISOR_COLOR)
	draw_colored_polygon(PackedVector2Array([
		p.call(0.30, 0.53), p.call(0.46, 0.53),
		p.call(0.40, 0.60), p.call(0.29, 0.60)]), VISOR_GLINT)

	# Chin bar.
	draw_colored_polygon(PackedVector2Array([
		p.call(0.30, 0.72), p.call(0.70, 0.72),
		p.call(0.64, 0.84), p.call(0.36, 0.84)]), shell.darkened(0.25))
