extends Control
## Renders several cars large, side by side, so the artwork can be judged.
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/car_art_shot.tscn -- <out.png> [car_id ...]
var _out := "user://cars.png"
var _frames := 0
var _taken := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://cars.png"
	var ids: Array = args.slice(1) if args.size() > 1 else [
		"lada_2101", "citroen_2cv", "golf_gti_mk2", "impreza_gc8",
		"peugeot_205_t16", "porsche_992_c4s", "f150_raptor", "huracan_sterrato"]

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.26, 0.27, 0.29)
	add_child(bg)

	var paints := ["#c8272d", "#1e5fb4", "#f2b418", "#e8e9ec",
		"#1f6b3f", "#e8641c", "#131417", "#7fbfe0"]

	# Build the visuals first, so the biggest car can set the scale. Fixing the
	# scale up front meant an F-150 ran off the bottom of its cell and over the
	# next car's caption, which made the artwork look broken when it was not.
	var visuals: Array[CarVisual] = []
	var specs: Array[CarSpec] = []
	var longest := 1.0
	for id in ids:
		var spec := CarDatabase.get_car(String(id))
		if spec == null:
			continue
		var visual := CarVisual.new()
		visual.setup(spec, TuningCalculator.resolve(spec, spec.default_loadout()),
			Color.from_string(String(paints[specs.size() % paints.size()]), Color.RED))
		visual.steer_angle = 0.16
		visual.braking = specs.size() % 3 == 0
		longest = maxf(longest, visual.body_size().x)
		visuals.append(visual)
		specs.append(spec)

	var cols: int = maxi(1, mini(4, specs.size()))
	var rows: int = int(ceil(float(specs.size()) / float(cols)))
	var size := get_viewport_rect().size
	var cell := Vector2(size.x / float(cols), size.y / float(rows))
	# Leave room under each car for its caption, and a margin either side.
	var scale_factor: float = minf(
		(cell.y - 66.0) / longest, cell.x * 0.62 / longest * 2.4)

	for i in specs.size():
		var centre := Vector2(
			cell.x * (float(i % cols) + 0.5), cell.y * (float(i / cols) + 0.42))
		var holder := Node2D.new()
		holder.position = centre
		holder.scale = Vector2(scale_factor, scale_factor)
		holder.rotation = -PI * 0.5
		holder.add_child(visuals[i])
		add_child(holder)

		var label := Label.new()
		label.text = "%s\n%s" % [specs[i].display_name(), specs[i].category]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size = Vector2(cell.x, 44.0)
		label.position = Vector2(centre.x - cell.x * 0.5,
			centre.y + longest * scale_factor * 0.5 + 10.0)
		label.add_theme_font_size_override("font_size", 17)
		add_child(label)

func _process(_d: float) -> void:
	_frames += 1
	if _taken or _frames < 4:
		return
	_taken = true
	get_viewport().get_texture().get_image().save_png(_out)
	get_tree().quit(0)
