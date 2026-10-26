# AutomationLanePresets.gd
# The user's automation lane presets (spec 055): named, ordered lists of automation targets, kept
# in ONE JSON file `<presets root>/automation_lane_presets.json`. A preset holds no points or
# values. Every call reads the file, so a preset saved in one window shows up in another
# (REQ-028). `PresetLibrary.dir_override` redirects the file for tests.
#
#   {"version": 1, "presets": [{"name": "Strings", "entries": [{"target", "device_id", "label"}]}]}
#
# `device_id` is set only for device and modulator parameter entries. `label` is the lane's
# display name when it was saved, used only to tell the user which entries a load skipped.
class_name AutomationLanePresets extends RefCounted

const FILE_NAME := "automation_lane_presets.json"
const VERSION := 1

static var logger := Log.make("AutomationLanePresets")


static func file_path() -> String:
	return PresetLibrary.root_dir().path_join(FILE_NAME)


## Preset names in file order.
static func names() -> Array[String]:
	var out: Array[String] = []
	for preset in _read():
		out.append(str(preset["name"]))
	return out


static func exists(preset_name: String) -> bool:
	return not get_preset(preset_name).is_empty()


## `{"name", "entries"}` of the preset called `preset_name`, or {} when there is none.
static func get_preset(preset_name: String) -> Dictionary:
	for preset in _read():
		if preset["name"] == preset_name:
			return preset
	return {}


## Store `entries` under `preset_name` (surrounding whitespace dropped). An existing preset is
## replaced in place only when `overwrite` is true. Returns false when the name is empty, the
## name is taken and `overwrite` is false, or the file can't be written.
static func save(preset_name: String, entries: Array, overwrite := false) -> bool:
	var clean := preset_name.strip_edges()
	if clean.is_empty():
		logger.warn("save: refusing a preset with no name")
		return false
	var presets := _read()
	var index := -1
	for i in range(presets.size()):
		if presets[i]["name"] == clean:
			index = i
			break
	if index >= 0 and not overwrite:
		return false
	var preset := {"name": clean, "entries": entries.duplicate(true)}
	if index >= 0:
		presets[index] = preset
	else:
		presets.append(preset)
	return _write(presets)


## Remove `preset_name`. Returns false when it doesn't exist or the file can't be written.
static func delete(preset_name: String) -> bool:
	var presets := _read()
	for i in range(presets.size()):
		if presets[i]["name"] == preset_name:
			presets.remove_at(i)
			return _write(presets)
	return false


## Preset entries for `lanes` of `track`, in the given order.
static func entries_for(track: Object, lanes: Array) -> Array:
	var channel: Object = track.get_linked_channel() if track != null else null
	var out: Array = []
	for lane in lanes:
		if lane == null or lane.target == null:
			continue
		var target: AutomationTarget = lane.target
		var device_id := ""
		var instance: Object = target.resolve(channel)
		if instance != null and instance.device != null:
			device_id = str(instance.device.device_id)
		out.append({"target": str(target), "device_id": device_id, "label": target.display_name(channel)})
	return out


## The target `entry` means on `channel`, or null when it can't be resolved (REQ-025, REQ-026).
## Channel-level targets (volume, pan, MIDI CC, stage) always resolve; a send needs its index.
## A device entry resolves at its saved position when the device there has the saved type, else
## on the first device of that type, searched depth-first. Parameters that aren't automation-safe
## are rejected.
static func resolve_entry(entry: Dictionary, channel: Object) -> AutomationTarget:
	if channel == null:
		return null
	var target := AutomationTarget.parse(str(entry.get("target", "")))
	if target == null:
		return null
	match target.kind:
		AutomationTarget.Kind.CHANNEL_VOLUME, AutomationTarget.Kind.CHANNEL_PAN, \
		AutomationTarget.Kind.MIDI_CC, AutomationTarget.Kind.STAGE_PARAM:
			return target
		AutomationTarget.Kind.SEND_AMOUNT:
			return target if target.is_resolvable(channel) else null
	var device_id := str(entry.get("device_id", ""))
	if device_id.is_empty():
		return null
	var at_saved: Object = target.resolve(channel)
	if at_saved != null and _device_type(at_saved) == device_id and _is_safe(target, channel):
		return target
	for found in _walk(channel.devices, []):
		if _device_type(found["instance"]) != device_id:
			continue
		var moved := _retarget(target, found["path"])
		return moved if _is_safe(moved, channel) else null
	return null


static func _device_type(instance: Object) -> String:
	return str(instance.device.device_id) if instance != null and instance.device != null else ""


## A copy of the device-parameter `target` pointed at the device at `path`.
static func _retarget(target: AutomationTarget, path: Array) -> AutomationTarget:
	if target.kind == AutomationTarget.Kind.DEVICE_MODULATOR_PARAM:
		return AutomationTarget.device_modulator_param(path, target.mod_id, target.param_id)
	return AutomationTarget.device_param(path, target.param_id)


## Resolvable on `channel`, and the parameter is automation-safe.
static func _is_safe(target: AutomationTarget, channel: Object) -> bool:
	if not target.is_resolvable(channel):
		return false
	var instance: Object = target.resolve(channel)
	if target.kind == AutomationTarget.Kind.DEVICE_MODULATOR_PARAM:
		return instance.get_modulator(target.mod_id).get_parameter(target.param_id).is_automation_safe
	return instance.get_parameter(target.param_id).is_automation_safe


## Depth-first walk of a device chain: `[{"path": [..], "instance": DeviceInstance}]`.
static func _walk(devices: Array, prefix: Array) -> Array:
	var out: Array = []
	for i in range(devices.size()):
		var instance: Object = devices[i]
		if instance == null:
			continue
		var path := prefix + [i]
		out.append({"path": path, "instance": instance})
		out.append_array(_walk(instance.children, path))
	return out


# ---------------------------------------------------------------------------
# File
# ---------------------------------------------------------------------------

## Valid presets from the file. A missing file is no presets; an unreadable one is logged.
static func _read() -> Array:
	var path := file_path()
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not (parsed.get("presets") is Array):
		logger.warn("unreadable lane preset file: %s" % path)
		return []
	var out: Array = []
	for preset in parsed["presets"]:
		if preset is Dictionary and preset.get("name") is String and preset.get("entries") is Array:
			out.append(preset)
	return out


static func _write(presets: Array) -> bool:
	var path := file_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		logger.warn("could not write %s" % path)
		return false
	file.store_string(JSON.stringify({"version": VERSION, "presets": presets}, "\t"))
	return true
