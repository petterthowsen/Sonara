# test_group_record_arm.gd
# Headless tests for the group record-arm options and the mixer arm-follow setting:
#   arranger/group_arm_without_targets, arranger/group_arm_with_targets,
#   mixer/record_arm_follows_channel_selection (default on).
# Drives the real Editor: arranger selection through focus_track(), mixer selection through
# the Mixer's selection_changed signal. Not covered: real mouse clicks on headers and strips.
# Run: godot --headless --path Godot -s tests/test_group_record_arm.gd -- --test
extends TestBase

const K_EMPTY := "arranger/group_arm_without_targets"
const K_FULL := "arranger/group_arm_with_targets"
const K_MIXER := "mixer/record_arm_follows_channel_selection"
const K_ACTIVE := "arranger/record_arm_follows_active_track"
const GROUP := "Record arm the group"
const FIRST := "Record arm the first valid child"
const LAST := "Record arm the last armed valid child"
const IF_NOTES := "Record arm the group if it has a note device"

var _settings
var _project_script: GDScript
var _policy: GDScript
var _channel_script: GDScript


func suite_name() -> String:
	return "Group record arm"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_project_script = load("res://data/Project.gd")
	_policy = load("res://editor/RecordArmPolicy.gd")
	_channel_script = load("res://data/Channel.gd")
	_test_defaults()
	await _test_group_with_targets()
	await _test_group_without_targets()
	await _test_mixer_setting()
	await _test_group_if_notes()
	_settings.set_value(K_EMPTY, _settings.get_setting(K_EMPTY).default)
	_settings.set_value(K_FULL, _settings.get_setting(K_FULL).default)
	_settings.set_value(K_MIXER, true)
	_settings.set_value(K_ACTIVE, true)


func _test_defaults() -> void:
	for k in [K_EMPTY, K_FULL]:
		var s = _settings.get_setting(k)
		_assert(s != null and s.type == _settings.Type.CHOICE, "%s is a registered choice" % k)
		_assert(s.options.size() == 4 and s.options.has(s.default) and s.options.has(IF_NOTES), "%s has four options incl. its default and the note-device one" % k)
	_assert(_settings.get_setting(K_EMPTY).default == GROUP, "empty-group default arms the group")
	_assert(_settings.get_setting(K_FULL).default == LAST, "non-empty-group default arms the last armed child")
	_assert(_settings.get_setting(K_MIXER).type == _settings.Type.BOOL, "mixer setting is a bool")
	_assert(_settings.get_value(K_MIXER) == true, "mixer setting defaults to on")


## Project: instrument Top, group G { I1, I2 (audio), subgroup S { I3 } }, empty group E.
func _setup() -> Dictionary:
	var editor: Control = load("res://editor/Editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	var project: Object = _project_script.new()
	var top: Object = project.create_instrument_track("Top").track
	var g: Object = project.create_group_track("G").track
	var i1: Object = project.create_instrument_track("I1").track
	var i2: Object = project.create_audio_track("I2").track
	var s: Object = project.create_group_track("S").track
	var i3: Object = project.create_instrument_track("I3").track
	var e: Object = project.create_group_track("E").track
	for pair in [[i1, g], [i2, g], [s, g], [i3, s]]:
		pair[0].parent_track_id = pair[1].id
		pair[1].child_track_ids.append(pair[0].id)
	editor.open_project(project)
	await process_frame
	top.set_armed(true)
	return {"editor": editor, "project": project, "top": top, "g": g, "i1": i1, "i2": i2, "s": s, "i3": i3, "e": e}


func _free(fx: Dictionary) -> void:
	fx.editor.close_project()
	fx.editor.queue_free()
	await process_frame


func _select(fx: Dictionary, t: Object) -> void:
	fx.editor.focus_track(t)


func _armed_names(fx: Dictionary) -> Array:
	var out := []
	for t in fx.project.tracks:
		var ch: Object = fx.project.get_channel_by_id(t.default_channel_id)
		if t.armed and (ch == null or ch.record_armed):
			out.append(t.name)
	return out


func _test_group_with_targets() -> void:
	_settings.set_value(K_ACTIVE, true)
	var fx := await _setup()
	var g: Object = fx.g
	var project: Object = fx.project
	_assert(_policy.valid_children(project, g).size() == 3, "valid children are searched recursively (I1, I2, I3), not the subgroup")

	_settings.set_value(K_FULL, GROUP)
	_select(fx, g)
	_assert(_armed_names(fx) == ["G"], "Group option arms the group and disarms the rest: %s" % [_armed_names(fx)])

	_settings.set_value(K_FULL, FIRST)
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["I1"], "First option arms the first valid child: %s" % [_armed_names(fx)])

	# Last option with no history falls back to the first child.
	_settings.set_value(K_FULL, LAST)
	fx.i1.set_armed(false)
	g.last_armed_child_id = -1
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["I1"], "Last option with no history arms the first valid child: %s" % [_armed_names(fx)])

	# Arming a nested child is remembered by every ancestor group.
	fx.i3.set_armed(true)
	_assert(g.last_armed_child_id == fx.i3.id and fx.s.last_armed_child_id == fx.i3.id, "arming a nested child updates its ancestors")
	_select(fx, fx.top)
	_assert(_armed_names(fx) == ["Top"], "selecting a plain track arms it alone: %s" % [_armed_names(fx)])
	_select(fx, g)
	_assert(_armed_names(fx) == ["I3"], "Last option arms the last armed child (nested): %s" % [_armed_names(fx)])

	fx.i2.set_armed(true)
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["I2"], "Last option follows the most recent arm: %s" % [_armed_names(fx)])

	# A remembered child that no longer exists falls back to the first valid child.
	g.last_armed_child_id = 99999
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["I1"], "Last option with a stale id falls back to the first child: %s" % [_armed_names(fx)])

	# Follow-active off: group selection leaves arms alone.
	_settings.set_value(K_ACTIVE, false)
	_select(fx, fx.top)
	var before := _armed_names(fx)
	_select(fx, g)
	_assert(_armed_names(fx) == before, "with Record Arm Follows Active Track off nothing changes")
	_settings.set_value(K_ACTIVE, true)
	await _free(fx)


func _test_group_without_targets() -> void:
	_settings.set_value(K_ACTIVE, true)
	var fx := await _setup()
	var e: Object = fx.e
	_assert(_policy.valid_children(fx.project, e).is_empty(), "the empty group has no valid children")
	for opt in [GROUP, FIRST, LAST]:
		_settings.set_value(K_EMPTY, opt)
		_select(fx, fx.top)
		_select(fx, e)
		_assert(_armed_names(fx) == ["E"], "empty group with '%s' arms the group (no child exists): %s" % [opt, _armed_names(fx)])
	# Each case reads its own setting.
	_settings.set_value(K_EMPTY, GROUP)
	_settings.set_value(K_FULL, FIRST)
	_select(fx, fx.g)
	_assert(_armed_names(fx) == ["I1"], "non-empty group uses its own setting: %s" % [_armed_names(fx)])
	_select(fx, e)
	_assert(_armed_names(fx) == ["E"], "empty group uses its own setting: %s" % [_armed_names(fx)])
	# Arming a clip track afterwards disarms the group.
	_select(fx, fx.top)
	_assert(_armed_names(fx) == ["Top"], "selecting a clip track disarms a previously armed group: %s" % [_armed_names(fx)])
	await _free(fx)


func _test_mixer_setting() -> void:
	_settings.set_value(K_ACTIVE, false)  # isolate the mixer path
	var fx := await _setup()
	var mixer = fx.editor.mixer
	var ch_i1: Object = fx.project.get_track_mixer_channel(fx.i1)
	var ch_i2: Object = fx.project.get_track_mixer_channel(fx.i2)
	var ch_g: Object = fx.project.get_track_mixer_channel(fx.g)

	_settings.set_value(K_MIXER, true)
	mixer.selection_changed.emit(_chs(ch_i1))
	_assert(_armed_names(fx) == ["I1"], "mixer selection arms the selected channel's track (on): %s" % [_armed_names(fx)])

	_settings.set_value(K_MIXER, false)
	mixer.selection_changed.emit(_chs(ch_i2))
	_assert(_armed_names(fx) == ["I1"], "mixer selection leaves arms alone (off): %s" % [_armed_names(fx)])

	_settings.set_value(K_MIXER, true)
	_settings.set_value(K_FULL, FIRST)
	mixer.selection_changed.emit(_chs(ch_g))
	_assert(_armed_names(fx) == ["I1"], "mixer selection of a group follows the group option: %s" % [_armed_names(fx)])
	_settings.set_value(K_FULL, GROUP)
	mixer.selection_changed.emit(_chs(ch_i2))
	mixer.selection_changed.emit(_chs(ch_g))
	_assert(_armed_names(fx) == ["G"], "mixer selection of a group can arm the group: %s" % [_armed_names(fx)])
	_settings.set_value(K_ACTIVE, true)
	await _free(fx)


func _chs(ch: Object) -> Array:
	return Array([ch], TYPE_OBJECT, &"RefCounted", _channel_script)


## Registers a fake device `device_id` of `category` in the asset registry.
func _device(device_id: String, category: int) -> Object:
	var device_script: GDScript = load("res://data/Device.gd")
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = device_script.new(device_id, device_id, category, device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return device


## REQ-018: "Record arm the group if it has a note device" arms a group whose own chain holds an
## instrument or note effect, and falls back to the last armed valid child otherwise.
func _test_group_if_notes() -> void:
	_settings.set_value(K_ACTIVE, true)
	var fx := await _setup()
	var project: Object = fx.project
	var g: Object = fx.g
	var device_script: GDScript = load("res://data/Device.gd")
	var instance_script: GDScript = load("res://data/DeviceInstance.gd")
	var group_channel: Object = project.get_track_mixer_channel(g)
	_assert(not _policy.has_note_device(project, g), "an empty group has no note device")

	var reverb: Object = instance_script.new(_device("test.fx.reverb", device_script.DeviceCategory.Effect), group_channel.id, -1)
	group_channel.add_device(reverb)
	_assert(not _policy.has_note_device(project, g), "a group with only an audio effect has no note device")

	_settings.set_value(K_FULL, IF_NOTES)
	fx.i2.set_armed(true)
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["I2"], "a Reverb-only group arms its last armed child: %s" % [_armed_names(fx)])

	var send: Object = instance_script.new(_device("test.note.send", device_script.DeviceCategory.NoteEffect), group_channel.id, -1)
	group_channel.add_device(send)
	_assert(_policy.has_note_device(project, g), "a group with a note effect has a note device")
	_select(fx, fx.top)
	_select(fx, g)
	_assert(_armed_names(fx) == ["G"], "a group with a MIDI Send arms itself: %s" % [_armed_names(fx)])

	# A group without valid children arms itself either way; the empty-group setting accepts the option.
	_settings.set_value(K_EMPTY, IF_NOTES)
	_select(fx, fx.top)
	_select(fx, fx.e)
	_assert(_armed_names(fx) == ["E"], "an empty group arms itself with the new option: %s" % [_armed_names(fx)])
	await _free(fx)
