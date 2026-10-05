# test_clip_editor_performance.gd
# Phase 1 of docs/clip-editor-performance-plan.md: scrolling leaves notes alone, the note
# editors share one width that grows in chunks, notes share styleboxes, and track-mode
# lookups by note id go through the index.
# Run: godot --headless --path Godot -s tests/test_clip_editor_performance.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Clip editor performance (Phase 1) tests"


var _project_script: GDScript
var _track_script: GDScript
var _instance_script: GDScript
var _clip_editor_scene: PackedScene


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	await _test_scroll_does_not_reposition_notes()
	await _test_shared_width_grows_in_chunks()
	await _test_notes_share_styleboxes()
	await _test_note_id_index()


func _typed_tracks(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


## A ClipEditor in track mode over two instrument tracks, each with one 4-bar clip at tick 0
## holding notes at pitches 60 (velocity 100) and 64 (velocity 100), plus 67 (velocity 20)
## on the first. Every track visible and editable, the first active.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var tracks: Array = []
	var clips: Array = []
	for i in 2:
		var track: Object = project.create_instrument_track("T%d" % i).track
		var clip: Object = project.create_clip("C%d" % i)
		project.add_clip(clip)
		clips.append(clip)
		track.create_clip_instance(clip, 0, 4 * 3840)
		clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
		clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 960, 480)
		if i == 0:
			clip.add_midi_note(project.allocate_note_id(), 67, MidiNoteData.from_midi_velocity(20), 1920, 480)
		tracks.append(track)
	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	clip_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip_editor.size = Vector2(1200, 700)
	await process_frame
	var midi: Object = clip_editor.midi_editor
	var typed := _typed_tracks(tracks)
	var edited := _typed_instances(tracks[0].clip_instances)
	midi.set_track_views(typed, edited)
	midi.editable_tracks = typed
	midi.current_track = tracks[0]
	await process_frame
	await process_frame
	return {"project": project, "tracks": tracks, "clips": clips, "clip_editor": clip_editor, "midi": midi}


func _reposition_calls(midi: Object) -> int:
	var n := 0
	for e in midi.note_editors:
		n += e.reposition_calls
	return n


func _test_scroll_does_not_reposition_notes() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var before := _reposition_calls(midi)
	for i in 5:
		var x := 100.0 * (i + 1)
		midi.target_scroll_horizontal = x
		midi.h_scroll.scroll_horizontal = int(x)
		midi.grid_helper.scroll_position = midi.h_scroll.scroll_horizontal
		await process_frame
	_assert(midi.grid_helper.scroll_position > 0.0, "the view actually scrolled")
	_assert(_reposition_calls(midi) == before, "scrolling repositions no notes (%d calls)" % (_reposition_calls(midi) - before))

	var note: VisualNote = midi.get_active_note_editor().get_all_visual_notes()[0]
	var x_before := note.position.x
	midi.set_horizontal_zoom(midi.grid_helper.pixels_per_beat * 2.0)
	_assert(_reposition_calls(midi) > before, "zooming does reposition notes")
	_assert(is_equal_approx(note.position.x, x_before * 2.0), "a zoomed note moves with the scale")
	ctx.clip_editor.queue_free()
	await process_frame


func _test_shared_width_grows_in_chunks() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var editors: Array = [midi.note_editors[0], midi.context_layer]
	var w: float = editors[0].custom_minimum_size.x
	var same := true
	for e in editors:
		same = same and e.custom_minimum_size.x == w
	_assert(editors.size() == 2 and same, "the note editor and the context layer get the same width")
	_assert(w >= midi.h_scroll.size.x * 2.0, "the note area is at least two viewports wide: %.0f" % w)

	# One small scroll step far from the end doesn't change the width.
	midi.h_scroll.scroll_horizontal = 10
	midi.grid_helper.scroll_position = 10
	await process_frame
	_assert(editors[0].custom_minimum_size.x == w, "a small scroll doesn't resize the note area")

	# Scrolling to the end grows it by at least one chunk, the same for every editor.
	var max_scroll: float = w - midi.h_scroll.size.x
	midi.target_scroll_horizontal = max_scroll
	midi.h_scroll.scroll_horizontal = int(max_scroll)
	midi.grid_helper.scroll_position = midi.h_scroll.scroll_horizontal
	await process_frame
	await process_frame
	var chunk_px: float = midi.grid_helper.ticks_to_pixels(midi.scroll_growth_bars * midi.grid_helper.get_ticks_per_bar())
	var grown: float = editors[0].custom_minimum_size.x
	_assert(grown >= w + chunk_px - 1.0, "scrolling near the end grows the area by a chunk (%.0f -> %.0f)" % [w, grown])
	_assert(editors[1].custom_minimum_size.x == grown, "the growth applies to the layer too")

	# Moving an instance far right widens the area to cover it (next frame, batched).
	var inst: Object = ctx.tracks[1].clip_instances[0]
	inst.set_position(400 * 3840)
	await process_frame
	var far_px: float = midi.grid_helper.ticks_to_pixels(inst.get_end_ticks())
	_assert(editors[0].custom_minimum_size.x >= far_px, "the width covers the furthest instance")
	ctx.clip_editor.queue_free()
	await process_frame


func _test_notes_share_styleboxes() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.midi.get_active_note_editor()
	var by_pitch := {}
	for vn in editor.get_all_visual_notes():
		by_pitch[vn.midi_note_data.note] = vn
	var a: VisualNote = by_pitch[60]
	var b: VisualNote = by_pitch[64]
	var quiet: VisualNote = by_pitch[67]
	_assert(a.get_theme_stylebox("panel") == b.get_theme_stylebox("panel"), "same colour and velocity share one stylebox")
	_assert(a.get_theme_stylebox("panel") != quiet.get_theme_stylebox("panel"), "a different velocity uses another stylebox")
	_assert(a.label.label_settings == b.label.label_settings, "labels of one text colour share LabelSettings")

	# Selecting one note must not recolour the other through the shared box.
	var colour_b: Color = (b.get_theme_stylebox("panel") as StyleBoxFlat).bg_color
	a.set_selected(true)
	_assert((b.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colour_b, "selecting a note leaves the others' colour alone")
	_assert((a.get_theme_stylebox("panel") as StyleBoxFlat).bg_color != colour_b, "the selected note is drawn brighter")
	ctx.clip_editor.queue_free()
	await process_frame


func _test_note_id_index() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.midi.get_active_note_editor()
	var clip: Object = ctx.clips[0]
	var nd: Object = clip.add_midi_note(ctx.project.allocate_note_id(), 72, MidiNoteData.from_midi_velocity(100), 2880, 480)
	var vn: VisualNote = editor.get_visual_note(nd.id)
	_assert(vn != null and vn.midi_note_data == nd, "a reactively added note is found by id")
	_assert(editor.get_clip_instance_for_note(nd.id) == ctx.tracks[0].clip_instances[0], "its clip instance is found by id")

	nd.start_tick = 3840
	clip.update_midi_note(nd)
	_assert(is_equal_approx(vn.position.x, editor.ticks_to_pixels(3840)), "a changed note is repositioned")

	editor.selection_manager._set_selected_notes([vn] as Array[VisualNote])
	clip.remove_midi_note(nd)
	_assert(editor.get_visual_note(nd.id) == null, "a removed note is no longer found by id")
	_assert(editor.selection_manager.selected_notes.is_empty(), "a removed note leaves the selection")
	ctx.clip_editor.queue_free()
	await process_frame
