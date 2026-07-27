extends Control
## Renders the opening menu so it can actually be looked at.
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/menu_shot.tscn -- <out.png> [seated|career]
const BOOT := preload("res://scenes/boot.tscn")
var _out := "user://menu.png"
var _frames := 0
var _taken := false
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://menu.png"
	var mode: String = args[1] if args.size() > 1 else "fresh"
	if mode != "fresh":
		PlayerManager.join(DeviceInput.DEVICE_KEYBOARD)
		if mode == "career":
			var profile := PlayerProfile.create_new("menu_shot", "Toni Keskitalo",
				CarDatabase.default_starter(), 2)
			profile.money = 24000
			profile.level = 4
			PlayerManager.assign_profile(0, profile)
	add_child(BOOT.instantiate())
func _process(_d: float) -> void:
	_frames += 1
	if _taken or _frames < 4:
		return
	_taken = true
	get_viewport().get_texture().get_image().save_png(_out)
	SaveSystem.delete_profile("menu_shot")
	get_tree().quit(0)
