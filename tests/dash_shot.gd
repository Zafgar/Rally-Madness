extends Control
## Renders the instrument clusters of several cars side by side.
##
## The whole point of per-car gauges is that they look different from each
## other, which is not something that can be checked by reading the code.
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/dash_shot.tscn -- <out.png> [car_id ...]

const CAR_SCENE := preload("res://scenes/vehicle/rally_car.tscn")

var _out := "user://dash.png"
var _taken := false
var _frames := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://dash.png"
	var ids: Array = args.slice(1) if args.size() > 1 else [
		"lada_2101", "golf_gti_mk2", "impreza_gc8", "starlet_gt",
		"porsche_992_c4s", "huracan_sterrato"]

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.10, 0.11, 0.13)
	add_child(bg)

	var rows := ids.size()
	var height := 1080.0 / float(rows)
	for i in ids.size():
		var spec := CarDatabase.get_car(String(ids[i]))
		if spec == null:
			continue
		var car: RallyCar = CAR_SCENE.instantiate()
		car.car_id = i + 1
		car.is_locally_controlled = false
		car.configure(spec, spec.default_loadout(), {})
		add_child(car)
		# Parked, but with the needles somewhere interesting.
		car.transmission.rpm = spec.to_base_stats().redline_rpm * 0.72
		car.transmission.gear = 3
		car.linear_velocity = Vector2(
			PerformanceModel.top_speed_kmh(car.stats) / 3.6 * 0.62
				* GameConfig.PIXELS_PER_METRE, 0)

		var cluster := DashboardCluster.new()
		cluster.position = Vector2(340, height * float(i) + 8.0)
		cluster.size = Vector2(1500, height - 16.0)
		cluster.bind(car)
		add_child(cluster)

		var label := Label.new()
		label.text = "%s\n%s" % [spec.display_name(),
			DashboardCluster.Style.keys()[
				DashboardCluster.style_for(spec, car.stats)]]
		label.position = Vector2(24, height * float(i) + height * 0.34)
		label.add_theme_font_size_override("font_size", 18)
		add_child(label)


func _process(_delta: float) -> void:
	_frames += 1
	if _taken or _frames < 4:
		return
	_taken = true
	var image := get_viewport().get_texture().get_image()
	image.save_png(_out)
	print("dash_shot: wrote %s" % _out)
	get_tree().quit(0)
