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


## Parts in a slot that will actually fit this car. The garage never offers a
## part that cannot be bolted on, so a player is never sold something their
## chassis will refuse.
func available_for(slot: String, spec: CarSpec, stats: VehicleStats) -> Array[PartSpec]:
	var out: Array[PartSpec] = []
	for part in for_slot(slot):
		if spec.accepts_part(part) and part.fits(stats):
			out.append(part)
	return out


## Everything in a slot, paired with the reason it will not fit if it will not.
## The garage shows these greyed out rather than hiding them: seeing the parts
## a better chassis would accept is half of why a player wants a better one.
func catalogue_for(slot: String, spec: CarSpec, stats: VehicleStats) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for part in for_slot(slot):
		var reason := spec.part_rejection_reason(part)
		if reason.is_empty() and not part.fits(stats):
			reason = "Does not suit this car"
		out.append({"part": part, "blocked_reason": reason})
	return out


func slots() -> Array:
	return PartSpec.SLOTS
