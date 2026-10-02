# SfzKeyInfoUtil.gd
# What the assistant is told about a loaded SFZ: its playable key ranges and keyswitches
# (spec 014). The engine reports them after the async load, so there are two ways to get
# them: the load/add tools wait briefly (`wait_for_key_info`), and `compact_device` adds
# them to every later device listing once they have arrived.
class_name SfzKeyInfoUtil extends RefCounted

## How long load_device_file / add_device wait for the engine's `keys/info`.
const WAIT_SECONDS := 2.0


## Key info to merge into a compact device row. Empty for anything but a loaded SFZ.
## `{"key_info": "loading"}` while it hasn't arrived, else playable_ranges and keyswitches.
static func row_fields(inst: DeviceInstance) -> Dictionary:
	if not AuxReturnSync.is_sfz(inst) or inst.loaded_file_path.is_empty():
		return {}
	if not inst.key_info_received:
		return {"key_info": "loading"} if _engine_connected(inst) else {}
	var out := {}
	if not inst.playable_ranges.is_empty():
		var ranges: Array = []
		for r in inst.playable_ranges:
			ranges.append({"from": Midi.midi_to_note_name(r[0]), "to": Midi.midi_to_note_name(r[1])})
		out["playable_ranges"] = ranges
	var switches: Array = []
	for info in inst.key_labels:
		if info.keyswitch:
			switches.append({"key": Midi.midi_to_note_name(info.key), "name": _switch_name(info)})
	if not switches.is_empty():
		out["keyswitches"] = switches
	return out


## One paragraph for a tool's text result, or "" when there is nothing to say.
static func text_for(inst: DeviceInstance, path: String) -> String:
	if not AuxReturnSync.is_sfz(inst) or inst.loaded_file_path.is_empty():
		return ""
	if not inst.key_info_received:
		if not _engine_connected(inst):
			return ""
		return "SFZ key info (playable range, keyswitches) is not available yet: call get_device on \"%s\" in a moment before writing notes for it." % path
	var parts: Array[String] = []
	if not inst.playable_ranges.is_empty():
		var ranges: Array[String] = []
		for r in inst.playable_ranges:
			ranges.append(Midi.midi_to_note_name(r[0]) if r[0] == r[1] else "%s-%s" % [Midi.midi_to_note_name(r[0]), Midi.midi_to_note_name(r[1])])
		parts.append("Playable keys: %s. Notes outside them are silent." % ", ".join(ranges))
	var switches: Array[String] = []
	for info in inst.key_labels:
		if info.keyswitch:
			switches.append("%s %s" % [Midi.midi_to_note_name(info.key), _switch_name(info)])
	if not switches.is_empty():
		parts.append("Keyswitches (not notes: play one briefly before a phrase to pick the articulation): %s." % ", ".join(switches))
	return " ".join(parts)


## Wait up to WAIT_SECONDS for `inst` to receive key info. Connect first, then trigger the
## load, then await this: `var w := SfzKeyInfoUtil.watch(inst)` / `await w.call()`.
## Returns a Callable to await; it resolves immediately when there is nothing to wait for.
static func watch(inst: DeviceInstance) -> Callable:
	if not AuxReturnSync.is_sfz(inst) or not _engine_connected(inst):
		return func() -> void: pass
	var done := [false]
	var on_info := func() -> void: done[0] = true
	inst.key_labels_changed.connect(on_info)
	return func() -> void:
		var tree := Engine.get_main_loop() as SceneTree
		var timer := tree.create_timer(WAIT_SECONDS)
		while not done[0] and timer.time_left > 0.0:
			await tree.process_frame
		if inst.key_labels_changed.is_connected(on_info):
			inst.key_labels_changed.disconnect(on_info)


static func _switch_name(info: Dictionary) -> String:
	var label: String = info.label
	return label if not label.is_empty() else "(unnamed)"


static func _engine_connected(inst: DeviceInstance) -> bool:
	var channel := inst.get_channel()
	return channel != null and channel.is_engine_connected()
