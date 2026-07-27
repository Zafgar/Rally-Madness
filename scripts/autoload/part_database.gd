extends Node
## Loads the tuning parts catalogue from JSON.

const PARTS_PATH := "res://data/parts.json"

var _parts: Dictionary = {}       # id -> PartSpec
var _by_slot: Dictionary = {}     # slot -> Array[PartSpec]


func _ready() -> void:
	load_catalogue()


func load_catalogue(path: String = PARTS_PATH) -> void:
	_parts.clear()
	_by_slot.clear()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PartDatabase: cannot open %s" % path)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("PartDatabase: %s is not a JSON object" % path)
		return

	for entry in parsed.get("parts", []):
		var part := PartSpec.from_dict(entry)
		if part.id.is_empty():
			continue
		if _parts.has(part.id):
			push_error("PartDatabase: duplicate part id '%s'" % part.id)
			continue
		_parts[part.id] = part
		if not _by_slot.has(part.slot):
			_by_slot[part.slot] = []
		_by_slot[part.slot].append(part)

	for slot in _by_slot:
		_by_slot[slot].sort_custom(func(a, b): return a.price < b.price)
	print("PartDatabase: loaded %d parts" % _parts.size())


func get_part(id: String) -> PartSpec:
	return _parts.get(id)


func for_slot(slot: String) -> Array:
	return _by_slot.get(slot, [])


## Parts in a slot that will actually fit this car and are unlocked at the
## player's level. The garage never shows a part that cannot be bolted on.
func available_for(slot: String, stats: VehicleStats, max_tier: int = 99) -> Array[PartSpec]:
	var out: Array[PartSpec] = []
	for part in for_slot(slot):
		if part.tier <= max_tier and part.fits(stats):
			out.append(part)
	return out


func slots() -> Array:
	return PartSpec.SLOTS
