# test_track_device_drop.gd
# Headless tests for device drops on the arranger tracklist (TrackDeviceDropTarget): the middle of a
# track header adds the device to that track's channel, a gap between rows (or a folder header)
# creates a new track there (one undo step), instruments don't fit audio tracks, a device dropped
# back on its own track does nothing, and nothing changes until commit.
# Run: godot --headless --path Godot -s tests/test_track_device_drop.gd -- --test
#
# TrackList, the project and drop classes reference autoloads, so they are loaded with load().
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _device_drag: GDScript
var _drop_target: GDScript
var _list: Control
var _project: Object


func suite_name() -> String:
	return "Tracklist device drop tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_device_drag = load("res://devices/DeviceDrag.gd")
	_drop_target = load("res://arranger/tracklist/TrackDeviceDropTarget.gd")
	await _test_effect_onto_track()
	await _test_instrument_in_gap_creates_track()
	await _test_new_track_macro_undo()
	await _test_folder_header_nests_new_track()
	await _test_instrument_onto_audio_track_inserts()
	await _test_device_drag_between_tracks()


## Fresh project + TrackList: Folder holding A and B (instrument tracks), then audio track C.
func _setup() -> Dictionary:
	if _list:
		_list.free()
	_project = _project_script.new()
	var folder: Object = _project.create_folder_track("Folder").track
	var a: Object = _project.create_instrument_track("A").track
	var b: Object = _project.create_instrument_track("B").track
	var c: Object = _project.create_audio_track("C").track
	_project.place_track(a, folder.id, null)
	_project.place_track(b, folder.id, a)
	_project.place_track(c, -1, folder)
	for t in [folder, a, b, c]:
		t.height = 60
	_list = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	_list.size = Vector2(320, 800)
	root.add_child(_list)
	_list._on_project_activated(_project)
	await process_frame
	await process_frame
	return {"folder": folder, "a": a, "b": b, "c": c}


## Registered fake device `device_id`.
func _device(device_id: String, category: int) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return device


func _asset(category: int, device_id: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Device
	asset.path = _device(device_id, category).device_id
	return asset


func _fx_asset() -> Object:
	return _asset(_device_script.DeviceCategory.Effect, "test.fx.verb")


func _synth_asset() -> Object:
	return _asset(_device_script.DeviceCategory.Instrument, "test.synth")


func _rect(track: Object) -> Rect2:
	return _list._find_track_item(track).get_global_rect()


func _channel(track: Object) -> Object:
	return _project.get_track_mixer_channel(track)


func _child_names(folder: Object) -> Array:
	var names: Array = []
	for t in _project.get_track_children(folder):
		names.append(t.name)
	return names


func _device_ids(ch: Object) -> Array:
	var ids: Array = []
	for d in ch.devices:
		ids.append(d.device.device_id)
	return ids


func _test_effect_onto_track() -> void:
	var t := await _setup()
	var rect := _rect(t.a)
	var track_count: int = _project.tracks.size()
	var target: Object = _drop_target.resolve(_list, _fx_asset(), rect.get_center())
	_assert(target.kind == _drop_target.Kind.ONTO_TRACK, "middle of a header targets the track: %d" % target.kind)
	_assert(target.channel == _channel(t.a), "target is A's channel")
	_assert(target.indicator_rect == rect and target.is_nest(), "glow outlines A's header")
	_assert(_channel(t.a).devices.is_empty(), "resolving adds nothing")
	_assert(target.commit(), "commit adds the effect")
	_assert(_device_ids(_channel(t.a)) == ["test.fx.verb"], "effect on A: %s" % str(_device_ids(_channel(t.a))))
	_assert(_project.tracks.size() == track_count, "no track created")


func _test_instrument_in_gap_creates_track() -> void:
	var t := await _setup()
	var track_count: int = _project.tracks.size()
	var b_rect := _rect(t.b)
	var mouse := Vector2(b_rect.get_center().x, b_rect.position.y + 3.0)
	var target: Object = _drop_target.resolve(_list, _synth_asset(), mouse)
	_assert(target.kind == _drop_target.Kind.NEW_TRACK, "top edge of B inserts a new track: %d" % target.kind)
	_assert(target.parent_id == t.folder.id and target.after_sibling == t.a, "new track goes after A in Folder")
	_assert(not target.is_nest() and target.indicator_rect.size.y <= 4.0, "insert line, not an outline")
	_assert(_project.tracks.size() == track_count, "resolving creates nothing")
	_assert(target.commit(), "commit creates a track")
	_assert(_project.tracks.size() == track_count + 1, "one track created")
	var names := _child_names(t.folder)
	_assert(names.size() == 3 and names[0] == "A" and names[2] == "B", "new track between A and B: %s" % str(names))
	var created: Object = _project.get_track_children(t.folder)[1]
	_assert(_device_ids(_channel(created)) == ["test.synth"], "synth on the new track")


## HistoryUtil only runs do() without an editor, so rebuild create_channel_for's undo step by hand:
## create, then place (TrackReorderCommand). Undo must restore the folder; redo re-place it.
func _test_new_track_macro_undo() -> void:
	var t := await _setup()
	var track_count: int = _project.tracks.size()
	var create: Object = load("res://history/commands/TrackCreateCommand.gd").new(_project, "instrument", "New")
	create.do()
	var reorder_script: GDScript = load("res://history/commands/TrackReorderCommand.gd")
	var before: Dictionary = reorder_script.capture_layout(_project)
	_project.place_track(create.track, t.folder.id, t.a)
	var reorder: Object = reorder_script.new(_project, before, reorder_script.capture_layout(_project))
	var macro: Object = load("res://history/commands/MacroCommand.gd").new("Create", [create, reorder])
	_assert(_child_names(t.folder) == ["A", "New", "B"], "placed between A and B")
	macro.undo()
	_assert(_project.tracks.size() == track_count, "undo removes the track")
	_assert(_child_names(t.folder) == ["A", "B"], "undo restores Folder: %s" % str(_child_names(t.folder)))
	macro.do()
	_assert(_child_names(t.folder) == ["A", "New", "B"], "redo puts it back: %s" % str(_child_names(t.folder)))


func _test_folder_header_nests_new_track() -> void:
	var t := await _setup()
	var rect := _rect(t.folder)
	var target: Object = _drop_target.resolve(_list, _fx_asset(), rect.get_center())
	_assert(target.kind == _drop_target.Kind.NEW_TRACK, "channel-less folder header makes a new track: %d" % target.kind)
	_assert(target.parent_id == t.folder.id and target.after_sibling == t.b, "appended inside Folder")
	_assert(target.indicator_rect == rect and target.is_nest(), "glow outlines the folder header")
	_assert(target.commit(), "commit creates an audio track in the folder")
	var children: Array = _project.get_track_children(t.folder)
	_assert(children.size() == 3, "Folder has 3 children")
	_assert(_channel(children[2]).channel_type == load("res://data/Channel.gd").ChannelType.AUDIO, "effect makes an audio track")


func _test_instrument_onto_audio_track_inserts() -> void:
	var t := await _setup()
	var target: Object = _drop_target.resolve(_list, _synth_asset(), _rect(t.c).get_center())
	_assert(target.kind == _drop_target.Kind.NEW_TRACK, "instrument doesn't fit the audio track, so it inserts: %d" % target.kind)
	_assert(target.parent_id == -1, "at root level next to C")
	var arr: Object = _drop_target.resolve(_list, [_fx_asset(), _synth_asset()], _rect(t.a).get_center())
	_assert(arr.kind == _drop_target.Kind.ONTO_TRACK, "an array that all fits goes onto the track")
	var none: Object = _drop_target.resolve(_list, [_fx_asset(), "nope"], _rect(t.a).get_center())
	_assert(not none.is_valid(), "non-asset items are rejected")


func _test_device_drag_between_tracks() -> void:
	var t := await _setup()
	var inst: Object = _device_instance_script.new(_device("test.fx.verb", _device_script.DeviceCategory.Effect), _channel(t.a).id, -1)
	_channel(t.a).add_device(inst, -1, null)
	var drag: Object = _device_drag.new(null, inst, null)
	var own: Object = _drop_target.resolve(_list, drag, _rect(t.a).get_center())
	_assert(not own.is_valid(), "dropping on its own track does nothing")
	var target: Object = _drop_target.resolve(_list, drag, _rect(t.b).get_center())
	_assert(target.kind == _drop_target.Kind.ONTO_TRACK and target.channel == _channel(t.b), "moves onto B")
	_assert(target.commit(drag), "commit moves the device")
	_assert(inst.get_channel() == _channel(t.b) and _channel(t.a).devices.is_empty(), "device now on B")
	_assert(drag.did_commit, "drag marked committed")
