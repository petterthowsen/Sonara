# The user's device presets: one .sonpreset JSON file per preset under
# `<presets root>/<Device name>/`. Users may add their own subfolders anywhere; the browser
# builds its tree from the folders. Only read and written on an explicit load, save or scan.
class_name PresetLibrary extends RefCounted

const EXTENSION := ".sonpreset"

## Set by tests to use a scratch directory instead of the `presets/path` setting.
static var dir_override: String = ""

static var logger := Log.make("PresetLibrary")


## The presets root. Not created until something is saved.
static func root_dir() -> String:
	if not dir_override.is_empty():
		return dir_override
	return Utils.expand_path(str(Settings.get_value("presets/path")))


## Filename-safe form of a name. Keeps case and spaces (users browse these folders) and strips
## only characters that are illegal or special in paths.
static func slug_for(name_value: String) -> String:
	var out := ""
	for c in name_value.strip_edges():
		if not "/\\:*?\"<>|".contains(c):
			out += c
	out = out.strip_edges().lstrip(".")
	return out if not out.is_empty() else "Preset"


static func folder_for(device_name: String) -> String:
	return root_dir().path_join(slug_for(device_name))


static func path_for(device_name: String, preset_name: String) -> String:
	return folder_for(device_name).path_join(slug_for(preset_name) + EXTENSION)


static func exists(device_name: String, preset_name: String) -> bool:
	return FileAccess.file_exists(path_for(device_name, preset_name))


## Write `preset` to `<root>/<device name>/<name>.sonpreset`. Returns the path, or "" when the
## name is empty or taken and `overwrite` is false, or the file can't be written. Overwriting keeps
## the original creation time.
static func save(preset: DevicePreset, overwrite := false) -> String:
	if preset == null or preset.name.strip_edges().is_empty():
		logger.warn("save: refusing to save a preset with no name")
		return ""
	var path := path_for(preset.device_name, preset.name)
	if FileAccess.file_exists(path):
		if not overwrite:
			return ""
		var old := DevicePreset.read_header(path)
		if old != null and not old.created.is_empty():
			preset.created = old.created
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		logger.error("save: cannot write %s (%d)" % [path, FileAccess.get_open_error()])
		return ""
	file.store_string(JSON.stringify(preset.to_json(), "\t"))
	file.close()
	logger.info("saved preset '%s' to %s" % [preset.name, path])
	AssetService.rescan_presets()
	return path


## Fully load one preset file, or null when it is missing or not a preset.
static func load_preset(path: String) -> DevicePreset:
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var preset: DevicePreset = null
	if parsed is Dictionary:
		preset = DevicePreset.from_json(parsed)
	if preset == null:
		logger.warn("not a device preset: %s" % path)
		return null
	preset.path = path
	return preset


static func delete_preset(path: String) -> bool:
	return FileAccess.file_exists(path) and DirAccess.remove_absolute(path) == OK


## Headers of the presets for `device_id`, sorted by name. Each result's `path` is set.
## Scans the device's own folder first and the rest of the root only when `device_name` is empty
## or nothing was found there (a preset may sit in a user subfolder or have been moved).
static func list_for_device(device_id: String, device_name: String = "") -> Array[DevicePreset]:
	var found: Array[DevicePreset] = []
	var dirs: Array[String] = []
	if not device_name.is_empty():
		dirs.append(folder_for(device_name))
	for pass_index in 2:
		for dir in dirs:
			_scan(dir, device_id, found)
		if not found.is_empty() or pass_index == 1:
			break
		dirs = [root_dir()]
	found.sort_custom(func(a: DevicePreset, b: DevicePreset) -> bool:
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return found


static func _scan(dir: String, device_id: String, out: Array[DevicePreset]) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file_name in DirAccess.get_files_at(dir):
		if not file_name.ends_with(EXTENSION):
			continue
		var header := DevicePreset.read_header(dir.path_join(file_name))
		if header != null and header.device_id == device_id:
			header.path = dir.path_join(file_name)
			out.append(header)
	for sub in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(sub), device_id, out)
