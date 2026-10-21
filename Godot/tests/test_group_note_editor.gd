# test_group_note_editor.gd
# Note Editor follow-ups to MIDI clips on group tracks (spec 049): the track-mode track list shows
# groups that hold clips or note/instrument devices, Transfer Notes and Split Voices accept groups,
# and Split Into Child Tracks spreads a group clip's voices over the group's child tracks.
# Run: godot --headless --path Godot -s tests/test_group_note_editor.gd -- --test
extends TestBase

const BAR := 3840
const SEND_ID := "sonara.builtin.midi_send"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _list_scene: PackedScene
var _recorded: Array = []


func suite_name() -> String:
	return "Group tracks in the Note Editor"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_list_scene = load("res://clip_editor/tracklist/ClipEditorTrackList.tscn")
	_test_qualifies()
	await _test_list()
	await _test_transfer_and_split()
	await _test_split_into_children()


func _device(category: int) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(SEND_ID)
	if device == null:
		device = _device_script.new(SEND_ID, SEND_ID, category, _device_script.DeviceType.BuiltIn)
		registry._devices[SEND_ID] = device
	return device


func _add_send(group: Dictionary) -> Object:
	var send: Object = _device_instance_script.new(_device(_device_script.DeviceCategory.NoteEffect), group.channel.id, -1)
	group.channel.add_device(send)
	return send


func _group(project: Object, group_name: String) -> Dictionary:
	var made: Dictionary = project.create_group_track(group_name)
	return {"track": made.track, "channel": made.channel}


func _clip_on(project: Object, track: Object, notes: Array, bars: int = 4) -> Object:
	var clip: Object = project.create_clip("C")
	project.add_clip(clip)
	for t: Array in notes:
		clip.add_midi_note(project.allocate_note_id(), t[0], 0.8, t[1], t[2])
	return track.create_clip_instance(clip, 0, bars * BAR)


func _test_qualifies() -> void:
	var project: Object = _project_script.new()
	var g: Dictionary = _group(project, "G")
	var inst: Object = project.create_instrument_track("I").track
	var folder: Object = project.create_folder_track("F").track
	_assert(inst.is_note_editor_track(), "an instrument track qualifies")
	_assert(not folder.is_note_editor_track(), "a folder never qualifies")
	_assert(not g.track.is_note_editor_track(), "an empty group without devices does not qualify")
	_clip_on(project, g.track, [[60, 0, 480]])
	_assert(g.track.is_note_editor_track(), "a group with a clip qualifies")
	var g2: Dictionary = _group(project, "G2")
	_add_send(g2)
	_assert(g2.track.is_note_editor_track(), "a group with a note effect qualifies")


func _test_list() -> void:
	var project: Object = _project_script.new()
	project.create_instrument_track("I")
	var folder: Object = project.create_folder_track("F").track
	var g: Dictionary = _group(project, "G")
	var list: Node = _list_scene.instantiate()
	root.add_child(list)
	list.set_anchors_preset(Control.PRESET_TOP_LEFT)
	list.size = Vector2(300, 600)
	list.set_project(project)
	await process_frame
	await process_frame
	_assert(list.listed_tracks().size() == 1 and not list.listed_tracks().has(g.track) and not list.listed_tracks().has(folder),
			"folder and empty group stay out")
	var inst := _clip_on(project, g.track, [[60, 0, 480]])
	await process_frame
	await process_frame
	_assert(list.listed_tracks().has(g.track), "adding a clip lists the group")
	g.track.remove_clip_instance(inst)
	await process_frame
	await process_frame
	_assert(not list.listed_tracks().has(g.track), "removing the last clip unlists it again")
	var send := _add_send(g)
	await process_frame
	await process_frame
	_assert(list.listed_tracks().has(g.track), "adding a note effect lists the group")
	g.channel.remove_device_instance(send)
	await process_frame
	await process_frame
	_assert(not list.listed_tracks().has(g.track), "removing the device unlists it")
	list.queue_free()


func _editor(_project: Object, source: Object, inst: Object) -> Node:
	var ed = load("res://clip_editor/note_editor/NoteEditor.gd").new()
	ed.set_grid_helper(load("res://components/GridHelper.gd").new())
	root.add_child(ed)
	ed.bind_to_clips(Array([inst], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd")), source)
	await process_frame
	return ed


func _song_notes(track: Object) -> Array:
	var out := []
	for inst in track.clip_instances:
		for n: MidiNoteData in inst.clip.midi_notes:
			out.append("%d@%d" % [n.note, inst.clip_to_song_ticks(n.start_tick)])
	out.sort()
	return out


func _test_transfer_and_split() -> void:
	var project: Object = _project_script.new()
	var inst_track: Object = project.create_instrument_track("I").track
	var g: Dictionary = _group(project, "G")
	_add_send(g)
	var src_inst := _clip_on(project, inst_track, [[60, 0, 480], [64, 0, 480]])
	var ed := await _editor(project, inst_track, src_inst)
	_assert(ed.is_transfer_target(g.track), "a qualifying group is a transfer target")
	_assert(ed.split_target_tracks([g.track, inst_track]) == [inst_track, g.track], "a group is a split target in track order")
	_assert(ed.has_split_targets([g.track]), "the group alone makes Split Voices available")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_assert(ed.transfer_selection(g.track) == 2 and _song_notes(g.track).size() == 2, "notes transfer onto the group")
	ed.queue_free()

	# A group as the source transfers to an instrument track.
	var empty_group: Dictionary = _group(project, "Empty")
	_assert(not ed.is_transfer_target(empty_group.track), "an empty, deviceless group is no target")
	var g_inst: Object = g.track.clip_instances[0]
	var ed2 := await _editor(project, g.track, g_inst)
	ed2.selection_manager.select_all(ed2.get_all_visual_notes())
	_assert(ed2.is_transfer_target(inst_track) and ed2.can_transfer(), "a group source can transfer to an instrument track")
	_assert(ed2.transfer_selection(inst_track) == 2 and g_inst.clip.midi_notes.is_empty(), "the notes left the group")
	ed2.queue_free()


func _test_split_into_children() -> void:
	var project: Object = _project_script.new()
	var g: Dictionary = _group(project, "Choir")
	var b: Dictionary = project.create_instrument_track("B")
	var c: Dictionary = project.create_instrument_track("C")
	var d: Object = project.create_instrument_track("D").track
	project.nest_channel(b.channel, g.channel)
	project.nest_channel(c.channel, g.channel, b.channel)
	var chord := [[48, 0, 960], [55, 0, 960], [64, 0, 960], [72, 0, 960]]
	var inst := _clip_on(project, g.track, chord)
	var ed := await _editor(project, g.track, inst)
	var kids: Array = ed.child_split_targets()
	_assert(kids == [b.track, c.track], "child tracks of the group in order (got %d)" % kids.size())
	_assert(ed.can_split_into_children(), "Split Into Child Tracks is available")
	var h = load("res://history/HistoryUtil.gd")
	h.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	var moved: int = ed.split_voices_into_children()
	h.test_recorder = Callable()
	_assert(moved == 2, "voices 1 and 2 moved to the children (got %d)" % moved)
	_assert(_song_notes(b.track) == ["72@0"] and _song_notes(c.track) == ["64@0"], "voice 1 to the first child, voice 2 to the second")
	_assert(inst.clip.midi_notes.size() == 2, "voices 3 and 4 stay on the group")
	_assert(_song_notes(d).is_empty(), "other tracks are untouched")
	_assert(_recorded.size() == 1, "one undo step")
	ed.queue_free()

	var plain: Object = project.create_instrument_track("P").track
	var inst2 := _clip_on(project, plain, chord)
	var ed2 := await _editor(project, plain, inst2)
	_assert(ed2.child_split_targets().is_empty() and not ed2.can_split_into_children(), "an instrument source has no child targets")
	ed2.queue_free()
