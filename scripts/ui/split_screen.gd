class_name SplitScreen
extends Control
## Builds one viewport per local seat and lays them out.
##
## Every seat gets its own SubViewport sharing the single World2D, its own
## chase camera and its own HUD. That is what lets four people on one couch
## each have a real view rather than a shared one.
##
## Layouts: 1 = full screen, 2 = stacked horizontally (wide is better than tall
## for a racer), 3 = one on top and two below, 4 = quarters.

const HUD_SCENE := preload("res://scenes/ui/race_hud.tscn")

var views: Array[Dictionary] = []   # [{ slot, container, viewport, camera, hud }]

## Whether the root viewport was listening before the race took the job over.
var _root_listened: bool = false


func build(seats: Array, world: World2D) -> void:
	_clear()
	var count := clampi(seats.size(), 1, GameConfig.MAX_LOCAL_PLAYERS)
	var rects := _layout_rects(count)
	_silence_the_root_listener()

	for i in count:
		var seat = seats[i]
		var container := SubViewportContainer.new()
		container.stretch = true
		container.anchor_left = rects[i].position.x
		container.anchor_top = rects[i].position.y
		container.anchor_right = rects[i].end.x
		container.anchor_bottom = rects[i].end.y
		container.offset_left = 0
		container.offset_top = 0
		container.offset_right = 0
		container.offset_bottom = 0
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(container)

		var viewport := SubViewport.new()
		viewport.handle_input_locally = false
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		# Sharing the World2D is what makes this a split screen rather than
		# four separate simulations.
		viewport.world_2d = world
		# A SubViewport does not listen by default, and this is why the engines
		# used to come from somewhere off to one side and stay there. Every car
		# voice is an AudioStreamPlayer2D, and Godot only pans one against
		# viewports whose listener flag is set. With the flag off, the seat's
		# own chase camera was not a listener at all and the only listener left
		# was the root viewport — which has no camera, so it sat at a fixed
		# point in the middle of the world while the car drove away from it.
		viewport.audio_listener_enable_2d = true
		container.add_child(viewport)

		var camera := ChaseCamera.new()
		camera.enabled = true
		viewport.add_child(camera)
		camera.make_current()

		var hud = HUD_SCENE.instantiate()
		hud.seat_slot = seat.slot
		# The HUD sits above the viewport in the main tree, not inside it, so
		# it is not scaled by the camera zoom.
		var hud_holder := Control.new()
		hud_holder.anchor_left = rects[i].position.x
		hud_holder.anchor_top = rects[i].position.y
		hud_holder.anchor_right = rects[i].end.x
		hud_holder.anchor_bottom = rects[i].end.y
		hud_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_holder.add_child(hud)
		add_child(hud_holder)

		views.append({
			"slot": seat.slot,
			"container": container,
			"viewport": viewport,
			"camera": camera,
			"hud": hud,
		})

	_add_dividers(count, rects)
	AudioDirector.set_listener_count(count)


## Attaches each view's camera and HUD to the car that seat is driving.
func bind_cars() -> void:
	for view in views:
		var seat = PlayerManager.get_seat(view["slot"])
		if seat == null or seat.car == null:
			continue
		view["camera"].set_target(seat.car)
		view["hud"].bind(seat.car, seat.profile)


func get_camera(slot: int) -> ChaseCamera:
	for view in views:
		if view["slot"] == slot:
			return view["camera"]
	return null


func get_hud(slot: int):
	for view in views:
		if view["slot"] == slot:
			return view["hud"]
	return null


## Anchor rects in 0..1 space, one per seat.
static func _layout_rects(count: int) -> Array[Rect2]:
	match count:
		1:
			return [Rect2(0, 0, 1, 1)]
		2:
			# Full-width bands. A racer needs horizontal view far more than
			# vertical, so two players get letterboxes, not columns.
			return [Rect2(0, 0, 1, 0.5), Rect2(0, 0.5, 1, 0.5)]
		3:
			return [
				Rect2(0, 0, 1, 0.5),
				Rect2(0, 0.5, 0.5, 0.5),
				Rect2(0.5, 0.5, 0.5, 0.5),
			]
		_:
			return [
				Rect2(0, 0, 0.5, 0.5), Rect2(0.5, 0, 0.5, 0.5),
				Rect2(0, 0.5, 0.5, 0.5), Rect2(0.5, 0.5, 0.5, 0.5),
			]


func _add_dividers(count: int, rects: Array[Rect2]) -> void:
	if count < 2:
		return
	for rect in rects:
		var border := Panel.new()
		border.anchor_left = rect.position.x
		border.anchor_top = rect.position.y
		border.anchor_right = rect.end.x
		border.anchor_bottom = rect.end.y
		border.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = Color(0.05, 0.05, 0.06)
		style.set_border_width_all(3)
		border.add_theme_stylebox_override("panel", style)
		add_child(border)


## The root viewport is a 2D listener by default and it has no camera, so it
## hears the whole race from a fixed point near the world origin. Left on, it
## sums with the seat listeners and every engine arrives twice: once correctly
## from the car and once from a spot on the map that never moves. That second
## copy is the swelling, lagging, disappearing sound — it is loudest when the
## car happens to drive past the origin and gone when it does not.
##
## Turned off for as long as a split screen exists, and put back afterwards so
## the menus keep whatever the project asked for.
func _silence_the_root_listener() -> void:
	var root := get_viewport()
	if root == null:
		return
	_root_listened = root.audio_listener_enable_2d
	root.audio_listener_enable_2d = false


func _exit_tree() -> void:
	var root := get_viewport()
	if root != null and _root_listened:
		root.audio_listener_enable_2d = true
	AudioDirector.set_listener_count(1)


func _clear() -> void:
	for child in get_children():
		child.queue_free()
	views.clear()
