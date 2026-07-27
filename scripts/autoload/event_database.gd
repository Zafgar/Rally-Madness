extends Node
## Career calendar and sponsor catalogue.

const EVENTS_PATH := "res://data/events.json"
const SPONSORS_PATH := "res://data/sponsors.json"

var _events: Dictionary = {}     # id -> EventSpec
var _ordered: Array[EventSpec] = []
var _sponsors: Dictionary = {}   # id -> SponsorSpec
## Events available with no prerequisites at all — the career's entry points.
var _root_events: Array[String] = []


func _ready() -> void:
	load_events()
	load_sponsors()


func load_events(path: String = EVENTS_PATH) -> void:
	_events.clear()
	_ordered.clear()
	_root_events.clear()

	var parsed := _read_json(path)
	if parsed.is_empty():
		return
	for entry in parsed.get("events", []):
		var e := EventSpec.from_dict(entry)
		if e.id.is_empty() or _events.has(e.id):
			push_error("EventDatabase: bad or duplicate event id '%s'" % e.id)
			continue
		_events[e.id] = e
		_ordered.append(e)
		if e.requires_events.is_empty() and e.min_level <= 1:
			_root_events.append(e.id)

	# Cross-check unlock edges so a typo surfaces at load rather than as an
	# event that silently never appears.
	for e in _ordered:
		for target in e.unlocks_events:
			if not _events.has(target):
				push_error("Event '%s' unlocks unknown event '%s'" % [e.id, target])
	print("EventDatabase: loaded %d events (%d starting)" % [_events.size(), _root_events.size()])


func load_sponsors(path: String = SPONSORS_PATH) -> void:
	_sponsors.clear()
	var parsed := _read_json(path)
	if parsed.is_empty():
		return
	for entry in parsed.get("sponsors", []):
		var s := SponsorSpec.from_dict(entry)
		if not s.id.is_empty():
			_sponsors[s.id] = s
	print("EventDatabase: loaded %d sponsors" % _sponsors.size())


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("EventDatabase: cannot open %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("EventDatabase: %s is not a JSON object" % path)
		return {}
	return parsed


func get_event(id: String) -> EventSpec:
	return _events.get(id)


func get_sponsor(id: String) -> SponsorSpec:
	return _sponsors.get(id)


func all_events() -> Array[EventSpec]:
	return _ordered


func root_events() -> Array[String]:
	return _root_events


## Everything this profile is currently allowed to enter, which is the career
## screen's main list.
func available_for(profile: PlayerProfile) -> Array[EventSpec]:
	var out: Array[EventSpec] = []
	for e in _ordered:
		if not e.profile_can_enter(profile):
			continue
		# An event is visible if it needs nothing, or if the profile has
		# explicitly unlocked it by finishing a prerequisite.
		var is_open := e.requires_events.is_empty() or profile.unlocked_events.has(e.id)
		if is_open:
			out.append(e)
	return out


## Applied after a career race: pushes the unlock edges into the profile and
## returns the ids that were newly opened, for the results screen to celebrate.
func apply_unlocks(profile: PlayerProfile, event_id: String) -> Array[String]:
	var e := get_event(event_id)
	if e == null:
		return []
	var newly: Array[String] = []
	for target in e.unlocks_events:
		if profile.unlock_event(target):
			newly.append(target)
			EventBus.event_unlocked.emit(-1, target)
	return newly


## Sponsors willing to talk to this profile right now.
func sponsor_offers_for(profile: PlayerProfile, offered_ids: Array[String]) -> Array[SponsorSpec]:
	var out: Array[SponsorSpec] = []
	for id in offered_ids:
		var s: SponsorSpec = _sponsors.get(id)
		if s == null:
			continue
		if profile.level < s.min_level or profile.rating < s.min_rating:
			continue
		if profile.sponsors.has(id):
			continue
		out.append(s)
	return out
