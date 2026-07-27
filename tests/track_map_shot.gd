extends Control
## Draws every stage as a map, so the shapes can be judged.
##
## The in-game screenshot puts a camera on a car, which shows what a corner
## looks like and tells you nothing about whether the stage as a whole is any
## good. A track that doubles back through itself, has a kink at the start
## line, or is really three corners repeated is obvious from above and
## invisible from inside.
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/track_map_shot.tscn -- <out.png> [track_id ...]

var _out := "user://maps.png"
var _frames := 0
var _taken := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://maps.png"

	var all := TrackSpec.load_all()
	var ids: Array = args.slice(1) if args.size() > 1 else all.keys()

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.10, 0.11, 0.13)
	add_child(bg)

	var cols: int = mini(4, maxi(1, ids.size()))
	var rows: int = int(ceil(float(ids.size()) / float(cols)))
	var size := get_viewport_rect().size
	var cell := Vector2(size.x / float(cols), size.y / float(rows))

	for i in ids.size():
		var spec: TrackSpec = all.get(String(ids[i]))
		if spec == null:
			continue
		var map := TrackMapView.new()
		map.spec = spec
		map.position = Vector2(cell.x * float(i % cols), cell.y * float(i / cols))
		map.size = cell
		add_child(map)


func _process(_d: float) -> void:
	_frames += 1
	if _taken or _frames < 4:
		return
	_taken = true
	get_viewport().get_texture().get_image().save_png(_out)
	get_tree().quit(0)
