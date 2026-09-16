# test_drum_view.gd
# Headless smoke test for the Drum View wiring in the real ClipEditor scene
# (docs/specs/002-note-maps): the scene loads, the shared LaneLayout reaches every
# view, switching modes folds and unfolds the layout, rows follow the map and the
# clip's notes, and the note editor's pitch math walks rows rather than semitones.
#
# The visual acceptance checks in requirements.md still need a live pass; this is
# the part that can be caught without eyes on the screen.
# Run: godot --headless --path Godot -s tests/test_drum_view.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _aux: GDScript

var _editor: Control = null


func suite_name() -> String:
	return "Drum View wiring tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_aux = load("res://data/AuxReturnSync.gd")

	await _test_scene_loads()
	await _test_drum_view_rows()
	await _test_row_stepping()
	await _test_mode_switch_keeps_selection()
	await _test_empty_drum_view()
	await _test_hit_markers_do_not_overlap()
	await _test_adjacent_hits_never_overlap()

	if _editor:
		_editor.queue_free()
		await process_frame


# --- setup -----------------------------------------------------------------

func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## A project with a Drum Machine channel whose track holds one clip with notes on
## `note_pitches`. Returns {project, track, channel, clip_instance}.
func _drum_project(pad_notes: Array, note_pitches: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Drums")
	var track: Object = pair.track
	var ch: Object = pair.channel

	var drum := _device(ch, _aux.DRUM_MACHINE_ID, "Drum Machine")
	ch.add_device(drum)
	for i in pad_notes.size():
		var pad := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		pad.name = "Pad %d" % i
		ch.add_device(pad, -1, drum)
		pad.set_slot_note(int(pad_notes[i]))

	var clip: Object = project.create_clip("Beat")
	var ci: Object = track.create_clip_instance(clip, 0, 3840)
	var note_id := 1
	for p in note_pitches:
		clip.add_midi_note(note_id, int(p), 100, 0, 240)
		note_id += 1
	return {"project": project, "track": track, "channel": ch, "clip_instance": ci}


## Instantiate the real ClipEditor scene once and keep it around.
func _get_editor() -> Control:
	if _editor == null:
		var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
		_editor = scene.instantiate()
		root.add_child(_editor)
	return _editor


# --- tests -----------------------------------------------------------------

func _test_scene_loads() -> void:
	var editor := _get_editor()
	await process_frame
	await process_frame
	_assert(editor != null, "ClipEditor.tscn instantiates")

	var midi = editor.midi_editor
	_assert(midi != null, "MidiEditor is present")
	_assert(midi.drum_row_header != null, "DrumRowHeader is in the scene")
	_assert(midi.v_piano.layout == midi.lane_layout, "VPiano shares the editor's LaneLayout")
	_assert(midi.note_lanes.layout == midi.lane_layout, "NoteLanes shares it")
	_assert(midi.drum_row_header.layout == midi.lane_layout, "DrumRowHeader shares it")
	_assert(midi.note_editor.layout == midi.lane_layout, "the NoteEditor shares it")
	_assert(not midi.lane_layout.is_folded(), "the editor starts in the piano roll")
	_assert(midi.v_piano.visible and not midi.drum_row_header.visible,
		"the piano keys show and the drum rows don't")

	# The toolbar exists and is wired.
	_assert(editor.mode_switch != null and editor.note_map_button != null, "the note map toolbar is present")


func _test_drum_view_rows() -> void:
	var editor := _get_editor()
	var setup := _drum_project([36, 38], [38, 50])
	editor.midi_editor.bind_to_clip_instance(setup.clip_instance)
	await process_frame
	await process_frame

	var midi = editor.midi_editor
	_assert(midi.get_active_channel() == setup.channel, "the active channel resolves from the bound clip")
	_assert(midi.note_map.pitches() == PackedInt32Array([36, 38]),
		"REQ-002: the effective map comes from the pads: %s" % str(midi.note_map.pitches()))
	_assert(midi.wants_drum_view(), "REQ-028: a Drum Machine channel wants Drum View")

	midi.drum_view = true
	await process_frame
	_assert(midi.lane_layout.is_folded(), "REQ-015: switching folds the layout")
	_assert(midi.drum_row_header.visible and not midi.v_piano.visible,
		"REQ-018: the drum rows replace the piano keys")
	# Mapped {36, 38} plus the clip's notes on 38 and 50.
	_assert(midi.lane_layout.rows() == PackedInt32Array([36, 38, 50]),
		"REQ-016: rows are mapped union used: %s" % str(midi.lane_layout.rows()))
	_assert(not midi.drum_view_is_empty(), "REQ-023: this view is not empty")

	midi.drum_view = false
	await process_frame
	_assert(not midi.lane_layout.is_folded(), "REQ-015: switching back restores the piano roll")
	_assert(midi.lane_layout.row_count() == 128, "the piano roll has all 128 lanes again")
	_assert(midi.v_piano.visible and not midi.drum_row_header.visible, "and the piano keys come back")


func _test_row_stepping() -> void:
	var editor := _get_editor()
	var setup := _drum_project([36, 38, 42], [])
	editor.midi_editor.bind_to_clip_instance(setup.clip_instance)
	await process_frame
	await process_frame

	var midi = editor.midi_editor
	midi.drum_view = true
	await process_frame
	_assert(midi.lane_layout.rows() == PackedInt32Array([36, 38, 42]),
		"rows come from the three pads: %s" % str(midi.lane_layout.rows()))

	# REQ-020: the note editor's pitch math walks rows, not semitones.
	var ne = midi.note_editor
	_assert(ne.step_note(38, 1) == 42, "REQ-020: stepping up one row goes 38 -> 42")
	_assert(ne.step_note(38, -1) == 36, "REQ-020: stepping down one row goes 38 -> 36")

	# REQ-019: a new note is one grid step long, not the remembered length.
	ne.default_note_length_ticks = 1920
	var snap: int = ne.get_snap_interval()
	var placed = ne._place_note_at_position(Vector2(0, midi.lane_layout.pitch_to_y_center(38)))
	await process_frame
	_assert(placed != null and placed.midi_note_data != null, "a note is placed in Drum View")
	if placed and placed.midi_note_data:
		_assert(placed.midi_note_data.note == 38,
			"REQ-019: the note lands on the clicked row (got %d)" % placed.midi_note_data.note)
		_assert(placed.midi_note_data.duration_ticks == snap,
			"REQ-019: its length is one grid step (%d, want %d)" % [placed.midi_note_data.duration_ticks, snap])

	midi.drum_view = false
	await process_frame


func _test_mode_switch_keeps_selection() -> void:
	var editor := _get_editor()
	var setup := _drum_project([36, 38], [])
	editor.midi_editor.bind_to_clip_instance(setup.clip_instance)
	for _i in 4:
		await process_frame

	var midi = editor.midi_editor
	var ne = midi.note_editor

	# Notes are placed through the editor rather than seeded into the clip:
	# NoteContainer._load_notes_from_single_clip needs Sonara.editor.project,
	# which does not exist headless, so pre-seeded notes get no visuals here.
	ne.default_note_length_ticks = 240
	var notes: Array = []
	for pitch in [36, 38]:
		var vn = ne._place_note_at_position(Vector2(0, midi.lane_layout.pitch_to_y_center(pitch)))
		await process_frame
		if vn:
			notes.append(vn)
	_assert(notes.size() == 2, "two notes placed in the piano roll (got %d)" % notes.size())
	if notes.size() < 2:
		return
	_assert(not notes[0].drum_mode, "REQ-022: the piano roll draws bars")

	ne.selection_manager.clear_selection()
	for vn in notes:
		ne.selection_manager.toggle_note_selection(vn)
	var before: int = ne.selection_manager.selected_notes.size()
	_assert(before == 2, "both notes are selected (got %d)" % before)

	midi.drum_view = true
	for _i in 3:
		await process_frame
	_assert(ne.selection_manager.selected_notes.size() == before,
		"REQ-015: switching to Drum View keeps the selection (%d -> %d)" % [before, ne.selection_manager.selected_notes.size()])
	for vn in notes:
		_assert(vn.drum_mode, "REQ-022: notes render as hit markers")
		_assert(vn.midi_note_data.duration_ticks == 240,
			"REQ-022: the stored length is unchanged (got %d)" % vn.midi_note_data.duration_ticks)
		_assert(not vn._is_over_resize_handle(Vector2(vn.size.x - 1.0, 2.0)),
			"REQ-022: a hit marker has no resize handle")

	midi.drum_view = false
	for _i in 3:
		await process_frame
	_assert(ne.selection_manager.selected_notes.size() == before,
		"REQ-015: switching back keeps it too")
	for vn in notes:
		_assert(not vn.drum_mode, "REQ-022: the piano roll draws bars again")
		_assert(vn.midi_note_data.duration_ticks == 240, "REQ-022: and lengths survived the round trip")


## REQ-023: an Auto channel with no map source and an empty clip has no rows, and
## Drum View says so rather than silently falling back to 128 chromatic lanes.
func _test_empty_drum_view() -> void:
	var editor := _get_editor()
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var track: Object = pair.track
	var ch: Object = pair.channel
	ch.add_device(_device(ch, "sonara.builtin.polysynth", "PolySynth"))
	var clip: Object = project.create_clip("Empty")
	var ci: Object = track.create_clip_instance(clip, 0, 3840)

	var midi = editor.midi_editor
	midi.bind_to_clip_instance(ci)
	for _i in 4:
		await process_frame

	_assert(midi.get_active_channel() == ch, "the synth channel is active")
	_assert(midi.note_map.is_empty(), "REQ-003: an Auto channel with no Drum Machine has an empty map")
	_assert(not midi.wants_drum_view(), "REQ-028: it opens in the piano roll")

	midi.drum_view = true
	for _i in 2:
		await process_frame
	_assert(midi.lane_layout.is_folded(), "REQ-023: it stays folded with no rows")
	_assert(midi.lane_layout.row_count() == 0, "REQ-023: and really has none (got %d)" % midi.lane_layout.row_count())
	_assert(midi.drum_view_is_empty(), "REQ-023: the editor reports an empty Drum View")
	_assert(midi.note_editor._place_note_at_position(Vector2(0, 0)) == null,
		"REQ-023: a click in an empty Drum View places nothing")

	midi.drum_view = false
	await process_frame


## Hit markers have a fixed width that vertical zoom never touches, and it must
## stay within one grid step: a wider marker makes hits a sixteenth apart run
## together and a tight kit read as one long legato note.
func _test_hit_markers_do_not_overlap() -> void:
	var editor := _get_editor()
	var setup := _drum_project([36, 38], [])
	var midi = editor.midi_editor
	midi.bind_to_clip_instance(setup.clip_instance)
	for _i in 4:
		await process_frame

	midi.drum_view = true
	for _i in 2:
		await process_frame

	var ne = midi.note_editor
	var step_px: float = ne.ticks_to_pixels(ne.get_snap_interval())
	_assert(step_px > 0.0, "the grid step has a pixel width (%f)" % step_px)

	# Zoom vertically to the maximum: this is where the old row-height-derived
	# marker was far wider than a sixteenth and the overlap showed up.
	midi.note_height = midi.note_height_max
	for _i in 2:
		await process_frame

	var marker: Vector2 = ne.drum_marker_size()
	_assert(marker.y > step_px,
		"the tall row really is taller than a grid step (%f vs %f), so this is the overlapping case"
			% [marker.y, step_px])
	_assert(marker.x <= step_px,
		"a hit marker is never wider than one grid step (%f > %f)" % [marker.x, step_px])
	_assert(marker.x >= 3.0, "but is still wide enough to see (%f)" % marker.x)

	# Vertical zoom changes the row height only: the marker keeps its width.
	midi.note_height = midi.note_height_min
	for _i in 2:
		await process_frame
	var small: Vector2 = ne.drum_marker_size()
	_assert(is_equal_approx(small.x, marker.x),
		"vertical zoom does not change the marker width (%f vs %f)" % [small.x, marker.x])
	_assert(small.y < marker.y, "only the height follows the row (%f vs %f)" % [small.y, marker.y])

	midi.drum_view = false
	midi.note_height = 20
	await process_frame


## Markers for adjacent notes must never overlap at any zoom. The snap interval
## grows as you zoom out (sixteenths -> beats -> bars), so capping the marker at
## one grid step is not enough on its own: sixteenth-note hits drawn at bar-wide
## snap used to run into each other. Notes on one pitch never overlap in the data,
## so the marker is capped at the note's own length too.
func _test_adjacent_hits_never_overlap() -> void:
	var editor := _get_editor()
	var setup := _drum_project([36, 38], [])
	var clip: Object = setup.clip_instance.clip
	# Four back-to-back sixteenths on one pad, the tightest legal packing.
	for i in 4:
		clip.add_midi_note(i + 1, 36, 100, i * 240, 240)

	var midi = editor.midi_editor
	midi.bind_to_clip_instance(setup.clip_instance)
	for _i in 4:
		await process_frame

	midi.drum_view = true
	midi.note_height = midi.note_height_max
	for _i in 2:
		await process_frame

	var ne = midi.note_editor
	for ppb in [8.0, 16.0, 32.0, 64.0, 128.0, 256.0]:
		ne.grid_helper.pixels_per_beat = ppb
		for _i in 2:
			await process_frame

		var rects: Array = []
		for child in ne.get_children():
			if child is VisualNote and child.visible and child.midi_note_data.note == 36:
				rects.append(Rect2(child.position, child.size))
		_assert(rects.size() == 4, "all four hits are drawn at %f px/beat (got %d)" % [ppb, rects.size()])
		rects.sort_custom(func(a, b): return a.position.x < b.position.x)
		for i in rects.size() - 1:
			var left: Rect2 = rects[i]
			var right: Rect2 = rects[i + 1]
			_assert(left.end.x <= right.position.x,
				"at %f px/beat hit %d ends at %f, before hit %d starts at %f"
					% [ppb, i, left.end.x, i + 1, right.position.x])
			_assert(left.size.x >= 1.0, "and is still at least a pixel wide (%f)" % left.size.x)

	ne.grid_helper.pixels_per_beat = 64.0
	midi.drum_view = false
	midi.note_height = 20
	await process_frame
