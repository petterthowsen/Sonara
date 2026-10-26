# test_automation_lane_presets.gd
# Automation lane presets (spec 055 T-013 to T-015): the store, target resolution, save / load /
# delete with undo for both lane views, and the save dialog's empty-name refusal.
#
# Run: godot --headless --path Godot -s tests/test_automation_lane_presets.gd -- --test
extends TestBase

var _store: GDScript
var _actions: GDScript
var _history: GDScript
var _project_script: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _param_script: GDScript
var _lane_script: GDScript
var _scratch := ""


func suite_name() -> String:
	return "Automation lane presets"


func run_tests() -> void:
	_store = load("res://data/AutomationLanePresets.gd")
	_actions = load("res://history/AutomationLanePresetActions.gd")
	_history = load("res://history/HistoryUtil.gd")
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_scratch = OS.get_temp_dir().path_join("sonara_lane_presets_test_%d" % Time.get_ticks_usec())
	var library: GDScript = load("res://data/PresetLibrary.gd")
	library.dir_override = _scratch
	_test_store_round_trip()
	_test_store_refusals()
	_test_resolution()
	for kind in ["arranger", "clip_editor"]:
		_test_save(_make_view(kind), kind)
		_test_load_and_undo(_make_view(kind), kind)
		_test_load_skips_and_noop(_make_view(kind), kind)
		_test_delete_keeps_lanes(_make_view(kind), kind)
	await _test_dialog_refuses_empty_name()
	library.dir_override = ""
	DirAccess.remove_absolute(_scratch.path_join(_store.FILE_NAME))
	DirAccess.remove_absolute(_scratch)


func _make_view(kind: String) -> Object:
	if kind == "arranger":
		return load("res://arranger/tracklist/ArrangerLaneView.gd").new()
	return load("res://clip_editor/automation/ClipEditorLaneView.gd").new()


func _reset_store() -> void:
	for preset_name in _store.names():
		_store.delete(preset_name)


## A device registered under `device_id` with one automation-safe parameter (id 0) per name.
func _device_instance(channel: Object, device_id: String, param_names: Array) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id.get_extension(), DawEnums.CATEGORY_EFFECT, DawEnums.DEVICE_BUILTIN)
		for i in range(param_names.size()):
			device.add_parameter(_param_script.new(i, param_names[i]))
		registry._devices[device_id] = device
	var instance: Object = _instance_script.new(device, channel.id, channel.devices.size())
	instance.name = device_id
	channel.add_device(instance)
	return instance


func _track() -> Object:
	var project: Object = _project_script.new()
	return project.create_instrument_track("Preset Track").track


func _add_lane(track: Object, lane_id: String, target: AutomationTarget) -> Object:
	var lane: Object = _lane_script.new(lane_id, target)
	track.add_automation_lane(lane)
	return lane


func _targets(lanes: Array) -> Array:
	var out: Array = []
	for lane in lanes:
		out.append(str(lane.target))
	return out


# ---------------------------------------------------------------------------
# T-013 store and resolution
# ---------------------------------------------------------------------------

func _test_store_round_trip() -> void:
	_assert(_store.names().is_empty(), "no file reads as no presets")
	var entries := [{"target": "channel/cc/1", "device_id": ""}, {"target": "channel/cc/11", "device_id": ""}]
	_assert(_store.save("Strings", entries), "a preset saves")
	_assert(_store.save("Brass", [{"target": "channel/volume", "device_id": ""}]), "a second preset saves")
	_assert(FileAccess.file_exists(_scratch.path_join("automation_lane_presets.json")), "the file lives under the presets root")
	# Everything is read from the file, so a fresh script instance sees the same presets.
	var again: GDScript = load("res://data/AutomationLanePresets.gd")
	_assert(str(again.names()) == str(["Strings", "Brass"]), "names come back in file order: %s" % str(again.names()))
	var back: Dictionary = again.get_preset("Strings")
	_assert(back["entries"].size() == 2 and back["entries"][1]["target"] == "channel/cc/11", "entries round-trip in order")
	_assert(again.get_preset("Nope").is_empty(), "an unknown name gives an empty preset")
	_assert(_store.delete("Brass") and not _store.exists("Brass"), "delete removes a preset")
	_assert(not _store.delete("Brass"), "deleting a missing preset reports false")
	_reset_store()


func _test_store_refusals() -> void:
	var entries := [{"target": "channel/volume", "device_id": ""}]
	_assert(not _store.save("   ", entries), "a whitespace-only name is refused")
	_assert(_store.names().is_empty(), "nothing was written")
	_store.save("Keep", entries)
	_assert(not _store.save("Keep", [{"target": "channel/pan", "device_id": ""}]), "an existing name is refused without overwrite")
	_assert(_store.get_preset("Keep")["entries"][0]["target"] == "channel/volume", "the old preset stays")
	_assert(_store.save("Keep", [{"target": "channel/pan", "device_id": ""}], true), "overwrite replaces it")
	_assert(_store.get_preset("Keep")["entries"][0]["target"] == "channel/pan", "the new entries are stored")
	_reset_store()


func _test_resolution() -> void:
	var track := _track()
	var channel: Object = track.get_linked_channel()
	_device_instance(channel, "test.lp_other", ["Level"])
	var filter: Object = _device_instance(channel, "test.lp_filter", ["Freq", "Res"])
	var saved := {"target": str(AutomationTarget.device_param([1], 0)), "device_id": "test.lp_filter"}
	var target: AutomationTarget = _store.resolve_entry(saved, channel)
	_assert(target != null and str(target) == "device/1/param/0", "a Filter resolves at its saved position")
	# Move the Filter to the front: it is found by type.
	channel.devices.erase(filter)
	channel.devices.insert(0, filter)
	target = _store.resolve_entry(saved, channel)
	_assert(target != null and str(target) == "device/0/param/0", "a moved Filter resolves at its new position: %s" % str(target))
	channel.devices.erase(filter)
	_assert(_store.resolve_entry(saved, channel) == null, "a missing Filter resolves to null")
	var unsafe := {"target": str(AutomationTarget.device_param([0], 7)), "device_id": "test.lp_other"}
	_assert(_store.resolve_entry(unsafe, channel) == null, "a parameter the device lacks is rejected")
	for spelling in ["channel/cc/1", "channel/volume", "channel/pan", "channel/stage/x"]:
		_assert(_store.resolve_entry({"target": spelling, "device_id": ""}, channel) != null, "%s always resolves" % spelling)
	_assert(_store.resolve_entry({"target": "channel/send/3", "device_id": ""}, channel) == null, "a send the channel lacks is rejected")
	_assert(_store.resolve_entry({"target": "garbage", "device_id": ""}, channel) == null, "an unparseable target is rejected")
	var entries: Array = _store.entries_for(track, [_lane_script.new("a", AutomationTarget.device_param([0], 0))])
	_assert(entries[0]["device_id"] == "test.lp_other" and entries[0]["target"] == "device/0/param/0", "entries_for records the device type")


# ---------------------------------------------------------------------------
# T-014 actions
# ---------------------------------------------------------------------------

func _test_save(view: Object, kind: String) -> void:
	_reset_store()
	var track := _track()
	var cc1 := _add_lane(track, "lane0", AutomationTarget.midi_cc(1))
	var cc11 := _add_lane(track, "lane1", AutomationTarget.midi_cc(11))
	_add_lane(track, "lane2", AutomationTarget.channel_pan())
	view.apply_shown(track, [cc11, cc1])
	_assert(not _actions.save(view, track, "", false), "%s: an empty name saves nothing" % kind)
	_assert(_store.names().is_empty(), "%s: store untouched" % kind)
	_assert(_actions.save(view, track, "Strings", false), "%s: save with two lanes shown" % kind)
	var targets: Array = []
	for entry in _store.get_preset("Strings")["entries"]:
		targets.append(entry["target"])
	var expected: Array = _targets(view.shown_lanes(track))
	_assert(targets == expected and targets.size() == 2, "%s: shown lanes saved in shown order: %s" % [kind, str(targets)])
	if kind == "clip_editor":
		_assert(targets == ["channel/cc/11", "channel/cc/1"], "clip editor order is the pane order")
	_assert(not _actions.save(view, track, "Strings", false), "%s: an existing name needs overwrite" % kind)
	_assert(_actions.save(view, track, "Strings", true), "%s: overwrite replaces it" % kind)
	view.apply_shown(track, [])
	_assert(not _actions.save(view, track, "Empty", true), "%s: nothing shown, nothing saved" % kind)
	_reset_store()


func _test_load_and_undo(view: Object, kind: String) -> void:
	_reset_store()
	var track := _track()
	var volume := _add_lane(track, "lane0", AutomationTarget.channel_volume())
	var pan := _add_lane(track, "lane1", AutomationTarget.channel_pan())
	view.apply_shown(track, [pan])
	var before: Variant = view.capture(track)
	var lane_count: int = track.automation_lanes.size()
	_store.save("P", [{"target": "channel/cc/1", "device_id": ""}, {"target": "channel/volume", "device_id": ""}])
	var recorded: Array = []
	_history.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)
	var skipped: Array = _actions.load(view, track, _store.get_preset("P"))
	_history.test_recorder = Callable()
	_assert(skipped.is_empty(), "%s: nothing skipped" % kind)
	_assert(recorded.size() == 1, "%s: one history entry (%d)" % [kind, recorded.size()])
	var cc_lane: Object = track.get_automation_lane_for(AutomationTarget.midi_cc(1))
	_assert(cc_lane != null and track.automation_lanes.size() == lane_count + 1, "%s: the missing CC1 lane is created" % kind)
	_assert(cc_lane != null and cc_lane.points.size() == 1, "%s: the created lane is seeded with a point" % kind)
	var shown: Array = view.shown_lanes(track)
	_assert(shown.has(cc_lane) and shown.has(volume) and not shown.has(pan), "%s: only the preset's lanes are shown" % kind)
	_assert(track.automation_lanes.has(pan), "%s: the hidden lane keeps existing" % kind)
	if kind == "clip_editor":
		_assert(_targets(shown) == ["channel/cc/1", "channel/volume"], "clip editor shows the preset's order")
	else:
		_assert(track.automation_expanded, "the Arranger expands the track's automation")
	if recorded.is_empty():
		return
	recorded[0].undo()
	_assert(track.get_automation_lane_for(AutomationTarget.midi_cc(1)) == null and track.automation_lanes.size() == lane_count,
		"%s: undo removes the created lane" % kind)
	_assert(view.capture(track) == before, "%s: undo restores the shown set" % kind)
	recorded[0].do()
	var redone: Object = track.get_automation_lane_for(AutomationTarget.midi_cc(1))
	_assert(redone != null and view.is_shown(track, redone), "%s: redo re-attaches and shows the created lane" % kind)
	_reset_store()


func _test_load_skips_and_noop(view: Object, kind: String) -> void:
	_reset_store()
	var track := _track()
	var channel: Object = track.get_linked_channel()
	var pan := _add_lane(track, "lane0", AutomationTarget.channel_pan())
	view.apply_shown(track, [pan])
	var preset := {"name": "P", "entries": [
		{"target": "channel/cc/1", "device_id": ""},
		{"target": "device/0/param/0", "device_id": "test.lp_missing", "label": "Filter / Freq"}]}
	var skipped: Array = _actions.load(view, track, preset)
	_assert(skipped.size() == 1 and skipped[0]["label"] == "Filter / Freq", "%s: the unresolved entry is reported" % kind)
	var shown: Array = view.shown_lanes(track)
	_assert(shown.size() == 1 and str(shown[0].target) == "channel/cc/1", "%s: only the CC1 lane is shown" % kind)
	var count: int = track.automation_lanes.size()
	var state: Variant = view.capture(track)
	var recorded: Array = []
	_history.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)
	skipped = _actions.load(view, track, {"name": "None", "entries": [{"target": "channel/send/5", "device_id": ""}]})
	_history.test_recorder = Callable()
	_assert(skipped.size() == 1 and recorded.is_empty(), "%s: a load that resolves nothing records nothing" % kind)
	_assert(track.automation_lanes.size() == count and view.capture(track) == state, "%s: and changes nothing" % kind)
	_assert(channel != null, "%s: track has a channel" % kind)


func _test_delete_keeps_lanes(view: Object, kind: String) -> void:
	_reset_store()
	var track := _track()
	var lane := _add_lane(track, "lane0", AutomationTarget.channel_volume())
	view.apply_shown(track, [lane])
	_actions.save(view, track, "Gone", false)
	_assert(_actions.delete("Gone") and not _store.exists("Gone"), "%s: the preset is deleted" % kind)
	_assert(track.automation_lanes.has(lane) and view.is_shown(track, lane), "%s: the lane is unaffected" % kind)


# ---------------------------------------------------------------------------
# T-015 dialog
# ---------------------------------------------------------------------------

func _test_dialog_refuses_empty_name() -> void:
	var scene: PackedScene = load("res://arranger/tracklist/AutomationLanePresetSaveDialog.tscn")
	var dialog: Window = scene.instantiate()
	root.add_child(dialog)
	await process_frame
	_assert(not dialog.save_named("", true), "the dialog refuses an empty name")
	_assert(not dialog.save_named("   ", true), "and a whitespace-only name")
	dialog.queue_free()
