extends Node
## Local, per-player save files.
##
## Saves live on the machine the game is played on, one file per profile, so
## four players sharing a couch each keep their own career. Nothing here talks
## to a server; the online mode reads a profile that was already loaded
## locally.
##
## Writes go to a temp file first and are only then renamed over the real one,
## so a crash mid-save cannot leave a player with a corrupt career.

const SAVE_DIR := "user://profiles"
const SAVE_EXT := ".rmsave"
const SAVE_VERSION := 1

var _cache: Dictionary = {}   # profile_id -> PlayerProfile


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func _path_for(profile_id: String) -> String:
	return "%s/%s%s" % [SAVE_DIR, profile_id, SAVE_EXT]


## Profile ids present on this machine, for the seat-select screen.
func list_profiles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.ends_with(SAVE_EXT):
			var id := name.trim_suffix(SAVE_EXT)
			var profile := load_profile(id)
			if profile != null:
				out.append({
					"id": id,
					"name": profile.display_name,
					"avatar_id": profile.avatar_id,
					"level": profile.level,
					"money": profile.money,
					"rating": profile.rating,
					"cars": profile.garage.size(),
					"last_played": profile.last_played_unix,
				})
		name = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return a["last_played"] > b["last_played"])
	return out


func has_profile(profile_id: String) -> bool:
	return FileAccess.file_exists(_path_for(profile_id))


func load_profile(profile_id: String) -> PlayerProfile:
	if _cache.has(profile_id):
		return _cache[profile_id]
	var path := _path_for(profile_id)
	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SaveSystem: cannot read %s (%d)" % [path, FileAccess.get_open_error()])
		return null
	var text := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_error("SaveSystem: %s is corrupt, ignoring" % path)
		return null

	var version := int(parsed.get("version", 1))
	if version > SAVE_VERSION:
		push_error("SaveSystem: %s was written by a newer build (v%d)" % [path, version])
		return null
	parsed = _migrate(parsed, version)

	var profile := PlayerProfile.from_dict(parsed)
	_cache[profile_id] = profile
	return profile


func create_profile(
	display_name: String,
	starter: CarSpec = null,
	avatar_id: int = 0
) -> PlayerProfile:
	var id := _make_profile_id(display_name)
	var profile := PlayerProfile.create_new(id, display_name, starter, avatar_id)
	_cache[id] = profile
	save_profile(profile)
	return profile


func get_or_create(profile_id: String, display_name: String) -> PlayerProfile:
	var existing := load_profile(profile_id)
	if existing != null:
		return existing
	var profile := PlayerProfile.create_new(profile_id, display_name)
	_cache[profile_id] = profile
	save_profile(profile)
	return profile


func save_profile(profile: PlayerProfile) -> bool:
	if profile == null or profile.profile_id.is_empty():
		return false
	profile.last_played_unix = int(Time.get_unix_time_from_system())

	var path := _path_for(profile.profile_id)
	var temp := path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		push_error("SaveSystem: cannot write %s (%d)" % [temp, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(profile.to_dict(), "\t"))
	file.close()

	# Rename is the atomic step: either the old save or the new one exists,
	# never a half-written file.
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return false
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	var err := dir.rename(temp.get_file(), path.get_file())
	if err != OK:
		push_error("SaveSystem: rename failed for %s (%d)" % [path, err])
		return false
	return true


func save_all() -> void:
	for id in _cache:
		save_profile(_cache[id])


func delete_profile(profile_id: String) -> void:
	_cache.erase(profile_id)
	var dir := DirAccess.open(SAVE_DIR)
	if dir != null:
		dir.remove(_path_for(profile_id).get_file())


func _make_profile_id(display_name: String) -> String:
	var base := display_name.to_lower().strip_edges()
	var cleaned := ""
	for c in base:
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			cleaned += c
		elif c == " " or c == "_" or c == "-":
			cleaned += "_"
	if cleaned.is_empty():
		cleaned = "driver"
	var candidate := cleaned
	var n := 2
	while has_profile(candidate):
		candidate = "%s_%d" % [cleaned, n]
		n += 1
	return candidate


## Save migrations. Each step upgrades one version to the next, so a save from
## any past build walks forward through them in order.
func _migrate(data: Dictionary, from_version: int) -> Dictionary:
	var version := from_version
	while version < SAVE_VERSION:
		match version:
			_:
				pass
		version += 1
	data["version"] = SAVE_VERSION
	return data
