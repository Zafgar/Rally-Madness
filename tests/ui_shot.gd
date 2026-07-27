extends Control
## Renders one front-end screen to a PNG so it can be looked at.
##
## The same argument as tests/screenshot.tscn, applied to the interface: a
## layout reasoned about but never seen is a layout with a bug in it. This sets
## up a plausible career — some money, a few cars, some events finished — and
## draws whichever screen is asked for.
##
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##       res://tests/ui_shot.tscn -- <screen> <out.png>
##
## Screens: hub, calendar, garage, tuning, showroom.

var _out_path := "user://ui.png"
var _taken := false
var _frames := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var which: String = args[0] if args.size() > 0 else "hub"
	_out_path = args[1] if args.size() > 1 else "user://ui.png"

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var profile := _demo_profile()

	var screen: Control
	match which:
		"calendar":
			var s := CareerScreen.new()
			s.profile = profile
			screen = s
		"garage":
			var s := GarageScreen.new()
			s.profile = profile
			screen = s
		"tuning":
			var s := TuningScreen.new()
			s.profile = profile
			s.car = profile.active_car()
			screen = s
		"showroom":
			var s := ShowroomScreen.new()
			s.profile = profile
			screen = s
		"showroom_marque":
			var s := ShowroomScreen.new()
			s.profile = profile
			# Opened on a badge, which is the second level of the list and the
			# one a screenshot of the first level never shows.
			s.ready.connect(func():
				s._marque = "Lancia"
				s.refresh(), CONNECT_ONE_SHOT)
			screen = s
		"used":
			var s := ShowroomScreen.new()
			s.profile = profile
			s.ready.connect(func():
				s._lot = ShowroomScreen.Lot.USED
				s.refresh(), CONNECT_ONE_SHOT)
			screen = s
		_:
			var s := CareerHub.new()
			s.profile = profile
			screen = s
	add_child(screen)


## A career part-way through: enough money to be tempted, enough history for the
## calendar to have opened up, and a garage with more than one thing in it. A
## screen that only ever looks right on a brand new profile is not tested.
func _demo_profile() -> PlayerProfile:
	var profile := PlayerProfile.create_new("ui_shot", "Toni Keskitalo",
		CarDatabase.default_starter(), 2)
	profile.money = 64500
	profile.level = 7
	profile.xp = profile.xp_for_level(7) + 800
	profile.rating = 1288
	profile.stat_races = 24
	profile.stat_wins = 6
	profile.stat_wrecks = 2

	for id in ["golf_gti_mk2", "sierra_cosworth"]:
		var spec := CarDatabase.get_car(id)
		if spec != null:
			var car := profile.add_car(spec)
			car.loadout.paint_color = Color.from_string(
				"#1e5fb4" if id == "golf_gti_mk2" else "#f2b418", Color.RED)
			car.races_entered = 12
			car.wins = 3
			# A car with a season on it: the odometer and the engine agree,
			# because nothing has been swapped.
			car.odometer_km += 4300.0
			car.engine_km = car.odometer_km
			car.oil_life = 0.38
			car.brake_life = 0.62
			profile.active_car_uid = car.uid
	# Bolt a few parts on so the tuning screen has something fitted to show.
	var active := profile.active_car()
	if active != null:
		for pair in [["tires", "tires_gravel"], ["suspension", "susp_rally"],
				["exhaust", "exhaust_sports"], ["intake", "intake_cold"]]:
			var part := PartDatabase.get_part(pair[1])
			if part != null and active.spec().accepts_part(part):
				active.loadout.set_part(pair[0], pair[1])
		active.damage["body"] = 0.72
		active.damage["engine"] = 0.88
		active.damage["suspension"] = 0.55
		active.damage["tires"] = 0.41

	# Open the calendar as far as a level-7 driver would have it.
	for id in ["shakedown", "novice_night", "village_novice", "quarry_novice",
			"club_finale", "club_night", "forest_dash"]:
		profile.complete_event(id, 120.0)
		EventDatabase.apply_unlocks(profile, id)
	return profile


func _process(_delta: float) -> void:
	# Two frames: one to lay out, one with the layout applied.
	_frames += 1
	if _taken or _frames < 3:
		return
	_taken = true
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(_out_path)
	if error != OK:
		push_error("ui_shot: could not write %s (%d)" % [_out_path, error])
	print("ui_shot: wrote %s (%dx%d)" % [_out_path, image.get_width(), image.get_height()])
	get_tree().quit(0)
