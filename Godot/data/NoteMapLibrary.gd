# The user's library of named note maps: one JSON file per map under
# ~/.config/sonara/note_maps/.
#
# The library is only ever read and written on an explicit load or save, never on
# a clip-editor frame path. A channel stores its own copy of an assigned map
# (REQ-011, REQ-026), so nothing here is consulted while a project is open.
class_name NoteMapLibrary extends RefCounted

const DIR_NAME := "note_maps"
const EXTENSION := ".json"

## Set by tests to point the library at a scratch directory instead of the real
## user config, the way ConversationStore.scratch_dir_override does.
static var dir_override: String = ""

static var _logger := Log.make("NoteMapLibrary")


## Directory holding the library files. Not created until something is saved.
static func library_dir() -> String:
	if not dir_override.is_empty():
		return dir_override
	return Sonara.get_config_dir().path_join(DIR_NAME)


## Filename-safe form of a map name. Two names that differ only in case or
## punctuation share a slug, which is what makes `exists()` catch collisions.
static func slug_for(name_value: String) -> String:
	var out := ""
	for c in name_value.strip_edges().to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif c == " " or c == "-" or c == "_":
			if not out.ends_with("_"):
				out += "_"
	out = out.strip_edges().trim_prefix("_").trim_suffix("_")
	return out if not out.is_empty() else "map"


static func path_for(name_value: String) -> String:
	return library_dir().path_join(slug_for(name_value) + EXTENSION)


static func exists(name_value: String) -> bool:
	return FileAccess.file_exists(path_for(name_value))


## Every map in the library, sorted by category then name. Each map is fully
## loaded — the files are small and there are only ever a handful.
static func list() -> Array[NoteMap]:
	var maps: Array[NoteMap] = []
	var dir := library_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return maps
	var names := DirAccess.get_files_at(dir)
	names.sort()
	for file_name in names:
		if not file_name.ends_with(EXTENSION):
			continue
		var map := _read(dir.path_join(file_name))
		if map == null:
			continue
		if map.map_name.is_empty():
			# Fall back to the filename so a hand-edited file still shows up.
			map.map_name = file_name.trim_suffix(EXTENSION)
		maps.append(map)
	maps.sort_custom(func(a: NoteMap, b: NoteMap) -> bool:
		if a.category != b.category:
			return a.category.naturalnocasecmp_to(b.category) < 0
		return a.map_name.naturalnocasecmp_to(b.map_name) < 0)
	return maps


## Load one map by name, or null when it isn't in the library.
static func load_map(name_value: String) -> NoteMap:
	return _read(path_for(name_value))


## Write a map to the library. Returns false without touching anything when the
## name is already taken and `overwrite` is false (REQ-009).
static func save_map(map: NoteMap, overwrite := false) -> bool:
	if map == null or map.map_name.strip_edges().is_empty():
		_logger.warn("save_map: refusing to save a map with no name")
		return false
	if not overwrite and exists(map.map_name):
		return false
	var dir := library_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := path_for(map.map_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_logger.error("save_map: cannot write %s (%d)" % [path, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(map.to_json(), "\t"))
	file.close()
	_logger.info("saved note map '%s' to %s" % [map.map_name, path])
	return true


## Remove a map from the library. Returns true when a file was deleted.
static func delete_map(name_value: String) -> bool:
	var path := path_for(name_value)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


static func _read(path: String) -> NoteMap:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_logger.warn("note map file is not a JSON object: %s" % path)
		return null
	return NoteMap.from_json(parsed)
