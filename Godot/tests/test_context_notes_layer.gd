# test_context_notes_layer.gd
# Phase 2 of docs/clip-editor-performance-plan.md: the visible tracks other than the active
# one are drawn (and hit-tested) from data by ContextNotesLayer, with no node per note.
# Run: godot --headless --path Godot -s tests/test_context_notes_layer.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Context notes layer (Phase 2) tests"


var _project_script: GDScript
var _track_script: GDScript
var _instance_script: GDScript
var _layer_script: GDScript
var _layout_script: GDScript
var _grid_script: GDScript
var _placement_script: GDScript
var _clip_editor_scene: PackedScene


func run_tests() -> void:
	# Loaded at run time: naming these classes would compile them before the autoloads exist.
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_layer_script = load("res://clip_editor/note_editor/ContextNotesLayer.gd")
	_layout_script = load("res://clip_editor/LaneLayout.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_placement_script = load("res://clip_editor/note_editor/NotePlacement.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	_test_placement()
	_test_note_at()
	_test_played_window_and_offset()
	_test_drum_view_markers()
	_test_index_invalidation()
	_test_unsorted_clip_and_long_note()
	await _test_one_editor_for_many_tracks()


func _typed_tracks(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


## Two instrument tracks A and B. A: one clip instance at tick 0 (4 bars) with notes at pitch 60
## (tick 0, 480 long) and 64 (tick 960). B: an instance at tick 3840 with a note at pitch 72.
func _make_project() -> Dictionary:
	var project: Object = _project_script.new()
	var a: Object = project.create_instrument_track("A").track
	var b: Object = project.create_instrument_track("B").track
	var clip_a: Object = project.create_clip("Ca")
	project.add_clip(clip_a)
	clip_a.add_midi_note(project.allocate_note_id(), 60, 100, 0, 480)
	clip_a.add_midi_note(project.allocate_note_id(), 64, 20, 960, 480)
	var ci_a: Object = a.create_clip_instance(clip_a, 0, 3840)
	var clip_b: Object = project.create_clip("Cb")
	project.add_clip(clip_b)
	clip_b.add_midi_note(project.allocate_note_id(), 72, 100, 0, 480)
	var ci_b: Object = b.create_clip_instance(clip_b, 3840, 3840)
	return {"project": project, "a": a, "b": b, "clip_a": clip_a, "clip_b": clip_b, "ci_a": ci_a, "ci_b": ci_b}


## A layer over `tracks`, all editable, with a chromatic layout at 20 px rows and a grid
## helper at its defaults.
func _make_layer(tracks: Array, editable: Array = []) -> Dictionary:
	var layer: Control = _layer_script.new()
	var layout: Object = _layout_script.chromatic(20.0)
	var grid: Object = _grid_script.new()
	layer.layout = layout
	layer.grid_helper = grid
	layer.set_tracks(_typed_tracks(tracks), _typed_tracks(tracks if editable.is_empty() else editable))
	return {"layer": layer, "layout": layout, "grid": grid}


func _center(parts: Dictionary, nd: Object, ci: Object) -> Vector2:
	return _placement_script.note_rect(nd, ci.content_origin_ticks(), parts.layout, parts.grid).get_center()


func _test_placement() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b])
	var nd: Object = p.clip_a.midi_notes[0]
	var rect: Rect2 = _placement_script.note_rect(nd, 0, parts.layout, parts.grid)
	_assert(is_equal_approx(rect.position.x, parts.grid.ticks_to_pixels(0)), "note x is its start tick")
	_assert(is_equal_approx(rect.position.y, parts.layout.pitch_to_y(60)), "note y is its pitch row")
	_assert(is_equal_approx(rect.size.x, parts.grid.ticks_to_pixels(480)), "note width is its duration")
	_assert(is_equal_approx(rect.size.y, 20.0), "note height is a row")

	var shifted: Rect2 = _placement_script.note_rect(nd, 960, parts.layout, parts.grid)
	_assert(is_equal_approx(shifted.position.x, parts.grid.ticks_to_pixels(960)), "the instance origin shifts the note")
	parts.layer.free()


func _test_note_at() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b], [p.b])
	var layer: Control = parts.layer
	var note_b: Object = p.clip_b.midi_notes[0]
	var hit: Dictionary = layer.note_at(_center(parts, note_b, p.ci_b))
	_assert(hit.get("track") == p.b and hit.get("instance") == p.ci_b and hit.get("data") == note_b,
		"an editable track's note is found as track, instance and data")

	var note_a: Object = p.clip_a.midi_notes[0]
	_assert(layer.note_at(_center(parts, note_a, p.ci_a)).is_empty(), "a view-only track's note is not hit")
	layer.set_tracks(_typed_tracks([p.a, p.b]), _typed_tracks([p.a, p.b]))
	_assert(layer.note_at(_center(parts, note_a, p.ci_a)).get("data") == note_a, "it is hit once the track is editable")

	layer.excluded_track = p.a
	_assert(layer.note_at(_center(parts, note_a, p.ci_a)).is_empty(), "the excluded (active) track is left to its editor")
	layer.excluded_track = null

	var empty := Vector2(_center(parts, note_b, p.ci_b).x, parts.layout.pitch_to_y(30) + 5.0)
	_assert(layer.note_at(empty).is_empty(), "empty space hits nothing")
	_assert(layer.note_at(Vector2(-50, 10)).is_empty(), "left of the content hits nothing")
	_assert(layer.note_at(Vector2(10, -5)).is_empty(), "above the rows hits nothing")
	_assert(layer.alpha_for(p.a) == layer.ALPHA_EDITABLE, "editable tracks draw at 0.85")
	layer.set_tracks(_typed_tracks([p.a, p.b]), _typed_tracks([p.b]))
	_assert(layer.alpha_for(p.a) == layer.ALPHA_VIEW_ONLY, "view-only tracks draw at 0.5")

	# Overlapping notes on two editable tracks: the earlier track in list order wins.
	var twin: Object = p.b.create_clip_instance(p.clip_a, 0, 3840)
	layer.set_tracks(_typed_tracks([p.a, p.b]), _typed_tracks([p.a, p.b]))
	var both: Dictionary = layer.note_at(_center(parts, note_a, p.ci_a))
	_assert(both.get("track") == p.a, "of overlapping notes the earlier track wins: %s" % [both.get("track")])
	p.b.remove_clip_instance(twin)
	parts.layer.free()


func _test_played_window_and_offset() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b])
	var layer: Control = parts.layer
	# Trim A's instance so it only plays the second note; clip_offset shifts the content origin.
	var ci: Object = p.ci_a
	ci.clip_offset = 960
	ci.duration_ticks = 1920
	var first: Object = p.clip_a.midi_notes[0]
	var second: Object = p.clip_a.midi_notes[1]
	_assert(layer.note_at(_center(parts, first, ci)).is_empty(), "a note outside the played window is not hit")
	var hit: Dictionary = layer.note_at(_center(parts, second, ci))
	_assert(hit.get("data") == second, "a note inside the window is hit where the instance plays it")
	var rect: Rect2 = _placement_script.note_rect(second, ci.content_origin_ticks(), parts.layout, parts.grid)
	_assert(is_equal_approx(rect.position.x, parts.grid.ticks_to_pixels(ci.start_ticks)),
		"the first played note starts at the instance start (origin = start - clip_offset)")
	parts.layer.free()


func _test_drum_view_markers() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b])
	var layer: Control = parts.layer
	var note_b: Object = p.clip_b.midi_notes[0]
	var note_a: Object = p.clip_a.midi_notes[0]
	parts.layout.set_rows(PackedInt32Array([60, 72]))
	var rect: Rect2 = _placement_script.note_rect(note_b, p.ci_b.content_origin_ticks(), parts.layout, parts.grid)
	_assert(is_equal_approx(rect.size.x, minf(12.0, parts.grid.ticks_to_pixels(480) - 1.0)) or rect.size.x <= 12.0,
		"a Drum View note is a hit marker, not a bar")
	_assert(rect.size.y < 20.0 and rect.size.y >= 3.0, "the marker fits inside its row")
	_assert(layer.note_at(rect.get_center()).get("data") == note_b, "a marker is hit where it is drawn")
	_assert(layer.note_at(_placement_script.note_rect(note_a, 0, parts.layout, parts.grid).get_center()).get("data") == note_a,
		"pitches with a row are hit")

	var unrowed: Object = p.clip_a.midi_notes[1]  # pitch 64: no row in this layout
	_assert(not _placement_script.note_rect(unrowed, 0, parts.layout, parts.grid).has_area(), "a pitch without a row has no rect")
	_assert(layer.note_at(Vector2(parts.grid.ticks_to_pixels(960) + 1.0, 5.0)).is_empty(), "and can't be hit")
	parts.layer.free()


func _test_index_invalidation() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b])
	var layer: Control = parts.layer
	var changed_count := [0]
	layer.notes_changed.connect(func(): changed_count[0] += 1)
	var note_a: Object = p.clip_a.midi_notes[0]
	var spot := _center(parts, note_a, p.ci_a)
	_assert(layer.note_at(spot).get("data") == note_a, "the note is found")
	var builds: int = layer.index_builds
	layer.note_at(spot)
	_assert(layer.index_builds == builds, "searching again reuses the index")

	# Added
	var added: Object = p.clip_a.add_midi_note(p.project.allocate_note_id(), 67, 100, 480, 240)
	_assert(changed_count[0] == 1, "adding a note signals notes_changed")
	_assert(layer.note_at(_center(parts, added, p.ci_a)).get("data") == added, "an added note is found")
	# Changed
	added.start_tick = 1920
	p.clip_a.update_midi_note(added)
	_assert(layer.note_at(_center(parts, added, p.ci_a)).get("data") == added, "a moved note is found where it now is")
	_assert(layer.note_at(Vector2(parts.grid.ticks_to_pixels(600), parts.layout.pitch_to_y(67) + 5.0)).is_empty(),
		"and no longer where it was")
	# Removed
	p.clip_a.remove_midi_note(added)
	_assert(layer.note_at(_center(parts, added, p.ci_a)).is_empty(), "a removed note is not found")
	_assert(changed_count[0] == 3, "every note change signals notes_changed")
	parts.layer.free()


func _test_unsorted_clip_and_long_note() -> void:
	var p := _make_project()
	var parts := _make_layer([p.a, p.b])
	var layer: Control = parts.layer
	# Notes added out of order, one long one starting far left of the rest.
	var late: Object = p.clip_b.add_midi_note(p.project.allocate_note_id(), 50, 100, 3000, 240)
	var long_note: Object = p.clip_b.add_midi_note(p.project.allocate_note_id(), 55, 100, 100, 2800)
	var early: Object = p.clip_b.add_midi_note(p.project.allocate_note_id(), 45, 100, 10, 240)
	for nd in [late, long_note, early]:
		_assert(layer.note_at(_center(parts, nd, p.ci_b)).get("data") == nd, "note at pitch %d is found in an unsorted clip" % nd.note)
	# Far right end of the long note: found although it starts thousands of ticks earlier.
	var far := Vector2(parts.grid.ticks_to_pixels(3800 + 2800 - 100), parts.layout.pitch_to_y(55) + 5.0)
	_assert(layer.note_at(far).get("data") == long_note, "the end of a long note is found (search reaches back by the longest note)")
	parts.layer.free()


## The point of Phase 2: one NoteEditor whose node count follows the active track only.
func _test_one_editor_for_many_tracks() -> void:
	var project: Object = _project_script.new()
	var tracks: Array = []
	var edited: Array = []
	for i in 12:
		var track: Object = project.create_instrument_track("T%d" % i).track
		var clip: Object = project.create_clip("C%d" % i)
		project.add_clip(clip)
		edited.append(track.create_clip_instance(clip, 0, 4 * 3840))
		for n in 20:
			clip.add_midi_note(project.allocate_note_id(), 40 + n, 100, n * 480, 240)
		tracks.append(track)
	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	clip_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip_editor.size = Vector2(1200, 700)
	await process_frame
	var midi: Object = clip_editor.midi_editor
	var typed := _typed_tracks(tracks)
	midi.set_track_views(typed, _typed_instances(edited))
	midi.editable_tracks = typed
	midi.current_track = tracks[0]
	await process_frame
	await process_frame

	_assert(midi.note_editors.size() == 1, "one note editor for 12 visible tracks")
	var editor: Object = midi.note_editors[0]
	_assert(editor.get_child_count() == 20, "its nodes are the active track's 20 notes: %d" % editor.get_child_count())
	_assert(midi.context_layer.track_count() == 12 and midi.context_layer.excluded_track == tracks[0],
		"the layer holds the tracks and skips the active one")
	_assert(midi.context_layer.get_child_count() == 0, "the layer has no note nodes")

	# Switching tracks rebinds the same editor; the old notes are gone at once.
	midi.current_track = tracks[5]
	_assert(midi.note_editors[0] == editor and midi._editor_track(editor) == tracks[5], "switching rebinds the editor")
	_assert(editor.get_child_count() == 20 and editor.get_all_visual_notes().size() == 20,
		"only the new track's notes have nodes: %d children" % editor.get_child_count())
	_assert(midi.context_layer.excluded_track == tracks[5], "and the layer skips the new active track")

	# Editing the active track's note moves it in the editor; a context track's edit redraws.
	var context_clip: Object = edited[7].clip
	context_clip.add_midi_note(project.allocate_note_id(), 90, 100, 0, 240)
	var hit: Dictionary = midi.context_layer.note_at(_placement_script.note_rect(context_clip.midi_notes[-1],
			edited[7].content_origin_ticks(), midi.lane_layout, midi.grid_helper).get_center())
	_assert(hit.get("track") == tracks[7], "a note added to a context track can be hit at once")

	# The width covers a far-away instance on a context track.
	edited[3].set_position(300 * 3840)
	await process_frame
	var far_px: float = midi.grid_helper.ticks_to_pixels(edited[3].get_end_ticks())
	_assert(midi.context_layer.custom_minimum_size.x >= far_px and editor.custom_minimum_size.x >= far_px,
		"the width covers a context track's furthest instance")
	clip_editor.queue_free()
	await process_frame
