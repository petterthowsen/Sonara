# bench_clip_editor.gd
# Clip editor track-mode benchmark (docs/clip-editor-performance-plan.md, Phase 0).
# Not a test_*.gd script, so tests/run_all.sh skips it. Timings are headless: they cover
# layout, script and scene-tree cost, not GPU or drawing.
#
# Run: godot --headless --path Godot -s tests/bench_clip_editor.gd -- --test [--tracks=100] [--notes=500] [--clips=4]
# Only the BENCH lines matter: godot ... 2>&1 | grep BENCH
extends TestBase


func suite_name() -> String:
	return "Clip editor track-mode benchmark"


var _project_script: GDScript
var _instance_script: GDScript
var _track_script: GDScript
var _clip_editor_scene: PackedScene

var _tracks := 100
var _notes_per_track := 500
var _clips_per_track := 4
const CLIP_BARS := 8
const PITCH_MIN := 36
const PITCH_MAX := 96
## A pitch no generated note uses, for hit-tests over empty space.
const EMPTY_PITCH := 120


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_track_script = load("res://data/Track.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	_parse_args()
	# Headless sleeps 6.9 ms every frame (it can't draw); that would swamp the timings.
	OS.low_processor_usage_mode_sleep_usec = 0
	await _run()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tracks="):
			_tracks = int(arg.get_slice("=", 1))
		elif arg.begins_with("--notes="):
			_notes_per_track = int(arg.get_slice("=", 1))
		elif arg.begins_with("--clips="):
			_clips_per_track = maxi(1, int(arg.get_slice("=", 1)))


func _report(label: String, ms: float) -> void:
	print("BENCH %-34s %10.2f ms" % [label, ms])


func _report_value(label: String, value) -> void:
	print("BENCH %-34s %10s" % [label, str(value)])


func _node_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _typed_tracks(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


## Project with `_tracks` instrument tracks, each with `_clips_per_track` clips back to back
## and `_notes_per_track` notes spread over them (random pitch, start and length, no overlaps).
func _build_project() -> Dictionary:
	var project: Object = _project_script.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var bar: int = project.ppq * 4
	var clip_len: int = CLIP_BARS * bar
	var tracks: Array = []
	var total := 0
	for t in _tracks:
		var track: Object = project.create_instrument_track("T%d" % t).track
		tracks.append(track)
		for c in _clips_per_track:
			var clip: Object = project.create_clip("T%d C%d" % [t, c])
			project.add_clip(clip)
			track.create_clip_instance(clip, c * clip_len, clip_len)
			@warning_ignore("integer_division")
			var want: int = _notes_per_track / _clips_per_track + (1 if c < _notes_per_track % _clips_per_track else 0)
			total += _fill_clip(project, clip, want, clip_len, rng)
	return {"project": project, "tracks": tracks, "total_notes": total}


## Adds up to `count` non-overlapping random notes (checked here, so Clip never warns).
func _fill_clip(project: Object, clip: Object, count: int, clip_len: int, rng: RandomNumberGenerator) -> int:
	var by_pitch := {}  # pitch -> Array of [start, end]
	var added := 0
	var attempts := 0
	while added < count and attempts < count * 20:
		attempts += 1
		var pitch := rng.randi_range(PITCH_MIN, PITCH_MAX)
		var length := rng.randi_range(1, 8) * 120
		@warning_ignore("integer_division")
		var start := rng.randi_range(0, (clip_len - length) / 120) * 120
		var spans: Array = by_pitch.get(pitch, [])
		var free := true
		for s in spans:
			if start < s[1] and start + length > s[0]:
				free = false
				break
		if not free:
			continue
		spans.append([start, start + length])
		by_pitch[pitch] = spans
		clip.add_midi_note(project.allocate_note_id(), pitch, rng.randi_range(1, 127), start, length)
		added += 1
	return added


## Milliseconds from calling `work` until the next frame has started, so deferred layout
## (container sorts, queued rebuilds) queued by `work` is included.
func _time_with_frame(work: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	work.call()
	await process_frame
	return (Time.get_ticks_usec() - t0) / 1000.0


func _median(values: Array) -> float:
	var v := values.duplicate()
	v.sort()
	@warning_ignore("integer_division")
	return v[v.size() / 2]


func _run() -> void:
	var t_build := Time.get_ticks_usec()
	var data := _build_project()
	_report("project build (not editor cost)", (Time.get_ticks_usec() - t_build) / 1000.0)
	_report_value("tracks", _tracks)
	_report_value("clips per track", _clips_per_track)
	_report_value("notes total", data.total_notes)

	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	clip_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip_editor.size = Vector2(1600, 900)
	await process_frame
	await process_frame
	var midi: Object = clip_editor.midi_editor
	var tracks: Array = _typed_tracks(data.tracks)
	var first_track: Object = tracks[0]
	var edited: Array = _typed_instances(first_track.clip_instances)
	# Track mode with nothing drawn yet, so the next step times binding alone.
	midi.set_track_views(_typed_tracks([]), edited)
	await process_frame

	# An idle frame before anything is bound, to subtract from the timings below.
	var idle_before: Array = []
	for i in 10:
		idle_before.append(await _time_with_frame(func(): pass))
	_report("idle frame, nothing bound", _median(idle_before))
	var nodes_before := _node_count()

	# 1. Binding: every track visible and editable.
	var bind_ms := await _time_with_frame(func():
		midi.set_track_views(tracks, edited)
		midi.editable_tracks = tracks
		midi.current_track = first_track)
	_report("1. bind all tracks", bind_ms)
	await process_frame
	_report_value("nodes added by binding", _node_count() - nodes_before)
	_assert(midi.note_editors.size() == 1, "one note editor, whatever the track count")

	var idle_after: Array = []
	for i in 10:
		idle_after.append(await _time_with_frame(func(): pass))
	_report("idle frame, all bound", _median(idle_after))

	# 2. Horizontal scroll step, the way panning applies it (scroll, grid and target together).
	var h_scroll: ScrollContainer = midi.h_scroll
	var scroll_times: Array = []
	for i in 20:
		var x := 200.0 + 40.0 * i
		scroll_times.append(await _time_with_frame(func():
			midi.target_scroll_horizontal = x
			h_scroll.scroll_horizontal = int(x)
			midi.grid_helper.scroll_position = h_scroll.scroll_horizontal))
	_report("2. scroll step (median of 20)", _median(scroll_times))

	# 3. Horizontal zoom step, alternating in and out so the zoom stays put.
	var zoom_times: Array = []
	for i in 10:
		var factor: float = midi.zoom_sensitivity_h if i % 2 == 0 else 1.0 / midi.zoom_sensitivity_h
		zoom_times.append(await _time_with_frame(func():
			midi.set_horizontal_zoom(midi.grid_helper.pixels_per_beat * factor)))
	_report("3. zoom step (median of 10)", _median(zoom_times))

	# 4. 100 hit-tests over empty space (a pitch with no notes).
	var active: Object = midi.get_active_note_editor()
	var y: float = midi.lane_layout.pitch_to_y(EMPTY_PITCH) + 1.0
	var points: Array[Vector2] = []
	for i in 100:
		points.append(active.get_global_transform() * Vector2(20.0 + 10.0 * i, y))
	var misses := 0
	var t_hit := Time.get_ticks_usec()
	for p in points:
		if midi._note_hit(p).is_empty():
			misses += 1
	_report("4. 100 empty hit-tests", (Time.get_ticks_usec() - t_hit) / 1000.0)
	_assert(misses == 100, "hit-tests over the empty pitch miss every note")

	# 5. Nudge 50 selected notes of the active track by one snap step.
	var sel: Array[VisualNote] = []
	for vn in active.get_all_visual_notes():
		if sel.size() >= 50:
			break
		sel.append(vn)
	active.selection_manager._set_selected_notes(sel)
	var step: int = active.get_snap_interval()
	var move_ms := await _time_with_frame(func(): active._move_selection_horizontal(step))
	_report("5. nudge 50 notes", move_ms)

	# 6. Hide one track, then show it again.
	var others: Array = _typed_tracks(tracks.slice(0, tracks.size() - 1))
	var hide_ms := await _time_with_frame(func(): midi.set_track_views(others, edited))
	var show_ms := await _time_with_frame(func(): midi.set_track_views(tracks, edited))
	_report("6a. hide one track", hide_ms)
	_report("6b. show it again", show_ms)

	# 7. Switch the active track (rebinds the note editor to it).
	var switch_ms := await _time_with_frame(func(): midi.current_track = tracks[tracks.size() / 2])
	_report("7. switch active track", switch_ms)

	_report_value("node count at end", _node_count())
	clip_editor.queue_free()
	await process_frame
