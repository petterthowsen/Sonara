# A saved device: the serialized device tree plus the metadata the browser shows.
#
# Built on DeviceInstance.to_json() with instance ids and the root's context fields (name, channel
# binding, slot settings, aux return links) removed. Containers keep their whole subtree. CLAP
# state travels as the opaque `plugin_state` blob, fetched fresh at capture time.
# See docs/device-presets-plan.md.
class_name DevicePreset extends RefCounted

const FORMAT := "sonara.device_preset"
const VERSION := 1
const FILE_SETTINGS: Array[String] = ["assets/samples/paths", "assets/sfz/paths"]
## Channel fields that point at the project or the source channel, not at the return itself.
const RETURN_CONTEXT_KEYS: Array[String] = ["id", "parent_channel_id", "output_channel_id",
		"child_channel_ids", "send_channels", "solo", "order", "device_output_id",
		"midi_input_device", "record_armed", "aux_bus_index", "aux_pad_note"]

## Set by tests: setting key -> Array of root directories, instead of the real settings.
static var roots_override: Dictionary = {}

static var logger := Log.make("DevicePreset")

var name: String = ""
var author: String = ""
var tags: PackedStringArray = []
var device_id: String = ""
var device_name: String = ""
var plugin: Dictionary = {}
var created: String = ""
var modified: String = ""
## Serialized root device (DeviceInstance.to_json() with ids stripped).
var device: Dictionary = {}
## Return channels behind separate outputs: {owner: [child index path], index, channel}.
var returns: Array = []
## Lookup table of referenced files: {path, root_setting, root, rel}.
var files: Array = []
var file_version: int = VERSION
## File the preset was read from (set by PresetLibrary).
var path: String = ""
## Set by capture(): false when a CLAP plugin didn't return its state in time (its last known
## state was used instead).
var state_complete: bool = true

## Filled by instantiate().
var missing_files: PackedStringArray = []
var warnings: PackedStringArray = []


## Trimmed, lower-cased, de-duplicated tags from a comma-separated string or an array.
static func normalize_tags(raw: Variant) -> PackedStringArray:
	var parts: Array = []
	if raw is String:
		parts = raw.split(",")
	elif raw is Array or raw is PackedStringArray:
		parts = Array(raw)
	var out := PackedStringArray()
	for part in parts:
		var tag := str(part).strip_edges().to_lower()
		if not tag.is_empty() and not out.has(tag):
			out.append(tag)
	return out


## Snapshot `inst` (and its subtree) as a preset. Refreshes CLAP plugin states first.
static func capture(inst: DeviceInstance, preset_name: String = "", preset_author: String = "", preset_tags: Variant = []) -> DevicePreset:
	var roots: Array = [inst]
	for ret in _return_channels(inst):
		roots.append_array(ret.channel.devices)
	var complete: bool = await DeviceInstance.refresh_plugin_states(roots)
	var preset := capture_now(inst, preset_name, preset_author, preset_tags)
	preset.state_complete = complete
	return preset


## Same as capture() without waiting for plugin states (they keep their last saved state).
static func capture_now(inst: DeviceInstance, preset_name: String = "", preset_author: String = "", preset_tags: Variant = []) -> DevicePreset:
	var preset := DevicePreset.new()
	preset.name = preset_name if not preset_name.is_empty() else inst.get_display_name()
	preset.author = preset_author
	preset.tags = normalize_tags(preset_tags)
	preset.device_id = inst.device.id
	preset.device_name = inst.device.name
	var now := Time.get_datetime_string_from_system(true) + "Z"
	preset.created = now
	preset.modified = now
	var data := inst.to_json()
	DeviceInstance.refresh_ids_in_json(data, 0)
	for key in ["name", "position", "slot_volume", "slot_mute", "slot_solo", "slot_note",
			"choke_targets", "slot_note_map", "slot_separate_out", "preset_name", "preset_path"]:
		data.erase(key)
	_strip_open_slots(data)
	preset.device = data
	if inst.device.is_plugin():
		preset.plugin = {"vendor": inst.device.author, "version": inst.device.version}
	preset.returns = _capture_returns(inst)
	var file_roots: Array = [data]
	for entry in preset.returns:
		file_roots.append_array(entry["channel"].get("devices", []))
	preset.files = _build_files_table(file_roots)
	return preset


## Every return channel behind `inst`'s separate outputs as {owner, index, channel}. `owner` is the
## child index path from `inst` (a Drum Machine pad or Layer slot), `[]` for a multi-out plugin.
static func _return_channels(inst: DeviceInstance) -> Array:
	var out: Array = []
	var channel := inst.get_channel()
	var project := channel.get_project() if channel else null
	if project == null or inst.get_parent_device() != null:
		return out
	var per_child := AuxReturnSync.is_drum_machine(inst) or AuxReturnSync.is_layer(inst)
	for i in AuxReturnSync.extra_out_count(inst):
		var ch := AuxReturnSync.get_return_channel(project, inst, i)
		if ch != null:
			out.append({"owner": [i] if per_child else [], "index": i, "channel": ch})
	return out


## Stripped Channel.to_json() of each return: mixer settings and effect chain only. Sends, routing,
## track link and ids point at project channels and are dropped.
static func _capture_returns(inst: DeviceInstance) -> Array:
	var out: Array = []
	for ret in _return_channels(inst):
		var data: Dictionary = ret.channel.to_json()
		for key in RETURN_CONTEXT_KEYS:
			data.erase(key)
		for dev in data.get("devices", []):
			DeviceInstance.refresh_ids_in_json(dev, 0)
			_strip_open_slots(dev)
		out.append({"owner": ret.owner, "index": ret.index, "channel": data})
	return out


## Slot open/collapsed state is UI state, not part of a preset.
static func _strip_open_slots(data: Dictionary) -> void:
	var slots: Variant = data.get("slots")
	if slots is Dictionary:
		slots.erase("open")
	for child in data.get("children", []):
		if child is Dictionary:
			_strip_open_slots(child)


## A fresh DeviceInstance on `channel_id`, or null when the device is unknown. Sets `missing_files`
## and `warnings` for the caller to show. The instance is named after the preset.
##
## Return channels need ids from `project`; they wait on the instance's `detached_returns` so
## AuxReturnSync adopts them when the device is added to the channel's root chain. Without a
## project the returns are skipped.
func instantiate(channel_id: int, project: Project = null) -> DeviceInstance:
	missing_files = PackedStringArray()
	warnings = PackedStringArray()
	if file_version > VERSION:
		warnings.append("Preset '%s' was saved by a newer version of Sonara" % name)
	var data: Dictionary = device.duplicate(true)
	DeviceInstance.refresh_ids_in_json(data, channel_id)
	_resolve_files(data)
	data["name"] = name
	data["position"] = -1
	data["preset_name"] = name
	data["preset_path"] = path
	var inst := DeviceInstance.from_json(data)
	if inst == null:
		warnings.append("Device '%s' is not available" % device_id)
		return null
	if not plugin.is_empty() and inst.device != null and str(plugin.get("version", "")) != inst.device.version:
		logger.info("preset '%s' was saved with plugin version %s, installed is %s"
				% [name, plugin.get("version", ""), inst.device.version])
	if not returns.is_empty():
		if project == null:
			warnings.append("Separate outputs of '%s' were not restored" % name)
		else:
			_attach_returns(inst, channel_id, project)
	return inst


## Build fresh Channels from `returns` and park them on their owners the way a removed device
## parks its returns (AuxReturnSync.on_device_added adopts them): a Drum Machine keeps every pad
## return, a Layer slot and a multi-out plugin keep their own.
func _attach_returns(inst: DeviceInstance, channel_id: int, project: Project) -> void:
	var drum := AuxReturnSync.is_drum_machine(inst)
	var layer := AuxReturnSync.is_layer(inst)
	for entry in returns:
		if not entry is Dictionary or not entry.get("channel") is Dictionary:
			continue
		var owner: DeviceInstance = inst
		var index := int(entry.get("index", 0))
		for step in entry.get("owner", []):
			owner = owner.children[int(step)] if owner and int(step) < owner.children.size() else null
		if owner == null or (index < 0) or ((drum or layer) and owner == inst):
			warnings.append("A separate output of '%s' has no matching device" % name)
			continue
		var data: Dictionary = (entry["channel"] as Dictionary).duplicate(true)
		var new_id := project.next_channel_id
		project.next_channel_id += 1
		data["id"] = new_id
		for dev in data.get("devices", []):
			DeviceInstance.refresh_ids_in_json(dev, new_id)
			_resolve_files(dev)
		var ch := Channel.from_json(data)
		if drum:
			inst.detached_returns[new_id] = ch
			owner.return_channel_id = new_id
		elif layer:
			owner.detached_returns[new_id] = ch
			owner.return_channel_id = new_id
		else:
			inst.detached_returns[new_id] = ch
			while inst.return_channel_ids.size() <= index:
				inst.return_channel_ids.append(-1)
			inst.return_channel_ids[index] = new_id


func to_json() -> Dictionary:
	var data := {
		"format": FORMAT,
		"version": file_version,
		"name": name,
		"author": author,
		"tags": Array(tags),
		"device_id": device_id,
		"device_name": device_name,
		"created": created,
		"modified": modified,
		"device": device,
		"returns": returns,
		"files": files,
	}
	if not plugin.is_empty():
		data["plugin"] = plugin
	return data


static func from_json(data: Dictionary) -> DevicePreset:
	if str(data.get("format", "")) != FORMAT or not data.get("device") is Dictionary:
		return null
	var preset := DevicePreset.new()
	_read_header(data, preset)
	preset.file_version = int(data.get("version", 1))
	preset.plugin = data.get("plugin", {}) if data.get("plugin") is Dictionary else {}
	preset.device = data["device"]
	preset.returns = data.get("returns", []) if data.get("returns") is Array else []
	preset.files = data.get("files", []) if data.get("files") is Array else []
	return preset


## Name, author, tags and device only; `device`, `returns` and `files` stay empty.
static func read_header(path: String) -> DevicePreset:
	if not FileAccess.file_exists(path):
		return null
	# JSON.new().parse (not parse_string) so a broken file logs a warning, not an engine error, per scan.
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(FileAccess.get_file_as_string(path)) == OK else null
	if not parsed is Dictionary or str(parsed.get("format", "")) != FORMAT:
		logger.warn("not a device preset: %s" % path)
		return null
	var preset := DevicePreset.new()
	_read_header(parsed, preset)
	preset.file_version = int(parsed.get("version", 1))
	if preset.name.is_empty():
		preset.name = path.get_file().get_basename()
	return preset


static func _read_header(data: Dictionary, preset: DevicePreset) -> void:
	preset.name = str(data.get("name", ""))
	preset.author = str(data.get("author", ""))
	preset.tags = normalize_tags(data.get("tags", []))
	preset.device_id = str(data.get("device_id", ""))
	preset.device_name = str(data.get("device_name", ""))
	preset.created = str(data.get("created", ""))
	preset.modified = str(data.get("modified", ""))


# ============================================================================
# FILE REFERENCES
# ============================================================================

static func _roots_for(setting: String) -> Array:
	var raw: Array = []
	if roots_override.has(setting):
		raw = roots_override[setting]
	else:
		raw = Settings.get_value(setting)
	var out: Array = []
	for r in raw:
		var expanded := Utils.expand_path(str(r)).trim_suffix("/")
		if not expanded.is_empty():
			out.append(expanded)
	return out


## One entry per distinct file referenced by the tree, with the asset root it sits under.
static func _build_files_table(device_trees: Array) -> Array:
	var paths: Array[String] = []
	for tree in device_trees:
		_collect_paths(tree, paths)
	var table: Array = []
	for path in paths:
		var entry := {"path": path, "root_setting": "", "root": "", "rel": ""}
		var best_len := -1
		for setting in FILE_SETTINGS:
			for root: String in _roots_for(setting):
				if path.begins_with(root + "/") and root.length() > best_len:
					best_len = root.length()
					entry["root_setting"] = setting
					entry["root"] = root
					entry["rel"] = path.substr(root.length() + 1)
		table.append(entry)
	return table


static func _collect_paths(data: Dictionary, out: Array[String]) -> void:
	var path := str(data.get("loaded_file_path", ""))
	if not path.is_empty() and not out.has(path):
		out.append(path)
	for child in data.get("children", []):
		if child is Dictionary:
			_collect_paths(child, out)


## Point every `loaded_file_path` at an existing file: as stored, or the preset's relative path
## under the current roots. Files that can't be found keep their stored path and are reported.
func _resolve_files(data: Dictionary) -> void:
	var path := str(data.get("loaded_file_path", ""))
	if not path.is_empty() and not FileAccess.file_exists(path):
		var resolved := _resolve_path(path)
		if resolved.is_empty():
			if not missing_files.has(path):
				missing_files.append(path)
		else:
			data["loaded_file_path"] = resolved
	for child in data.get("children", []):
		if child is Dictionary:
			_resolve_files(child)


func _resolve_path(path: String) -> String:
	for entry in files:
		if not entry is Dictionary or str(entry.get("path", "")) != path:
			continue
		var rel := str(entry.get("rel", ""))
		if rel.is_empty():
			return ""
		var settings: Array = [str(entry.get("root_setting", ""))]
		for s in FILE_SETTINGS:
			if not settings.has(s):
				settings.append(s)
		for setting in settings:
			if setting.is_empty():
				continue
			for root: String in DevicePreset._roots_for(setting):
				var candidate := root + "/" + rel
				if FileAccess.file_exists(candidate):
					return candidate
	return ""
