class_name RaceOverlay
extends Control
## The two screens a race needs that are not the race: pause, and results.
##
## Both exist because there was no way out. A player who wanted to stop had to
## close the game, and a player who won sat looking at a status line with
## nothing to press. A race has to be leavable at any moment and it has to end
## with somewhere to go.

signal resume_requested()
signal retire_requested()
signal quit_requested()
signal continue_requested()
## Escape, from either state. The overlay owns this because it is the only node
## in the race that still gets input while the tree is paused — a paused scene
## cannot un-pause itself.
signal pause_toggled()

var _panel: PanelContainer
var _title: Label
var _body: VBoxContainer
var _buttons: VBoxContainer
var _mode: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = UiTheme.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Nothing to click when nothing is shown, so the race keeps the mouse.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	_panel = UiTheme.card()
	_panel.custom_minimum_size = Vector2(560, 0)
	centre.add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.GAP)
	_panel.add_child(column)

	_title = UiTheme.title("PAUSED")
	column.add_child(_title)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	column.add_child(_body)

	column.add_child(UiTheme.spacer(UiTheme.GAP))

	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", UiTheme.GAP_TIGHT)
	column.add_child(_buttons)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# The results screen is not dismissable with escape: there is a Continue
	# button and pressing it is the only way on, so a player cannot skip past
	# their own prize money by reflex.
	if _mode == "results" and visible:
		return
	get_viewport().set_input_as_handled()
	pause_toggled.emit()


func is_open() -> bool:
	return visible


## The pause menu. Available at any moment, which is the point.
func show_pause(event_name: String, can_retire: bool) -> void:
	_mode = "pause"
	_title.text = "PAUSED"
	_clear()
	_body.add_child(UiTheme.label(event_name, UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))

	var resume := UiTheme.primary_button("Resume")
	resume.pressed.connect(func(): resume_requested.emit())
	_buttons.add_child(resume)

	if can_retire:
		var retire := Button.new()
		retire.text = "Retire from this race"
		retire.tooltip_text = "You keep whatever a DNF pays and the damage you have done."
		retire.pressed.connect(func(): retire_requested.emit())
		_buttons.add_child(retire)

	var quit := Button.new()
	quit.text = "Abandon and return to the menu"
	quit.pressed.connect(func(): quit_requested.emit())
	_buttons.add_child(quit)

	_open()
	resume.grab_focus()


## The results, with somewhere to go afterwards.
func show_results(event_name: String, results: Array, own: Array) -> void:
	_mode = "results"
	_title.text = "RESULTS"
	_clear()
	_body.add_child(UiTheme.label(event_name, UiTheme.SIZE_LABEL, UiTheme.TEXT_DIM))
	_body.add_child(UiTheme.spacer(UiTheme.GAP_TIGHT))

	# The finishing order, with the people playing picked out of it.
	for r in results:
		var entrant: RaceEntrant = r["entrant"]
		var mine: bool = own.has(entrant)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UiTheme.GAP)
		var place := UiTheme.label("P%d" % int(r["position"]), UiTheme.SIZE_BODY,
			UiTheme.ACCENT if mine else UiTheme.TEXT_DIM)
		place.custom_minimum_size = Vector2(44, 0)
		row.add_child(place)
		row.add_child(UiTheme.label(entrant.display_name, UiTheme.SIZE_BODY,
			UiTheme.TEXT if mine else UiTheme.TEXT_DIM))
		row.add_child(UiTheme.expander())
		var time_text: String = "DNF" if r["dnf"] else RaceHUD.format_time(float(r["time"]))
		row.add_child(UiTheme.label(time_text, UiTheme.SIZE_BODY,
			UiTheme.NEGATIVE if r["dnf"] else UiTheme.TEXT_DIM))
		_body.add_child(row)

	# What it was worth, for each seat.
	for r in results:
		if not own.has(r["entrant"]):
			continue
		_body.add_child(UiTheme.section((r["entrant"] as RaceEntrant).display_name))
		if r["dnf"]:
			_body.add_child(UiTheme.stat_row("Did not finish", String(r["dnf_reason"]),
				UiTheme.NEGATIVE))
		_body.add_child(UiTheme.stat_row("Prize money",
			UiTheme.money(int(r["payout"])), UiTheme.ACCENT))
		_body.add_child(UiTheme.stat_row("Experience", "%d XP" % int(r["xp"])))
		if int(r.get("levels_gained", 0)) > 0:
			_body.add_child(UiTheme.stat_row("Levels gained",
				str(int(r["levels_gained"])), UiTheme.POSITIVE))
		var repair := int(r.get("repair_cost", 0))
		if repair > 0:
			_body.add_child(UiTheme.stat_row("Repairs needed", UiTheme.money(repair),
				UiTheme.WARNING))
		var service := int(r.get("service_cost", 0))
		if service > 0:
			_body.add_child(UiTheme.stat_row("Servicing due", UiTheme.money(service),
				UiTheme.WARNING))
		var failures := String(r.get("failures", ""))
		if not failures.is_empty():
			_body.add_child(UiTheme.stat_row("Broke on the stage", failures,
				UiTheme.NEGATIVE))
		var unlocked: Array = r.get("unlocked", [])
		for id in unlocked:
			var event := EventDatabase.get_event(String(id))
			_body.add_child(UiTheme.stat_row("Unlocked",
				event.display_name if event != null else String(id), UiTheme.POSITIVE))

	var carry_on := UiTheme.primary_button("Continue")
	carry_on.pressed.connect(func(): continue_requested.emit())
	_buttons.add_child(carry_on)

	_open()
	carry_on.grab_focus()


func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _open() -> void:
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP


func _clear() -> void:
	for child in _body.get_children():
		child.queue_free()
	for child in _buttons.get_children():
		child.queue_free()
