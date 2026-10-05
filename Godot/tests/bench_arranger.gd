# bench_arranger.gd
# Arranger timeline benchmark: idle, scroll and zoom frames with many tracks and clips.
# Not a test_*.gd script, so tests/run_all.sh skips it. Timings are headless: they cover
# layout, script and scene-tree cost (including _draw callbacks), not GPU work.
#
# Run: godot --headless --path Godot -s tests/bench_arranger.gd -- --test [--tracks=100] [--notes=500] [--clips=4]
#      [--hide-tracklist | --hide-timeline] to attribute cost to one column
# Only the BENCH lines matter: godot ... 2>&1 | grep BENCH
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const CLIP_BARS := 8
const PITCH_MIN := 36
const PITCH_MAX := 96

var _tracks := 100
var _notes_per_track := 500
var _clips_per_track := 4


func suite_name() -> String:
	return "Arranger timeline benchmark"


func run_tests() -> void:
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


## Project with `_tracks` instrument tracks, each with `_clips_per_track` clips back to back
## and `_notes_per_track` random notes spread over them.
func _build_project() -> Object:
	var project: Object = load("res://data/Project.gd").new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var clip_len: int = CLIP_BARS * project.ppq * 4
	for t in _tracks:
		var track: Object = project.create_instrument_track("T%d" % t).track
		for c in _clips_per_track:
			var clip: Object = project.create_clip("T%d C%d" % [t, c])
			project.add_clip(clip)
			track.create_clip_instance(clip, c * clip_len, clip_len)
			@warning_ignore("integer_division")
			for n in _notes_per_track / _clips_per_track:
				var length := rng.randi_range(1, 8) * 120
				@warning_ignore("integer_division")
				var start := rng.randi_range(0, (clip_len - length) / 120) * 120
				clip.midi_notes.append(_note(project, rng.randi_range(PITCH_MIN, PITCH_MAX), start, length))
	return project


func _note(project: Object, pitch: int, start: int, length: int) -> Object:
	var n: Object = load("res://data/MidiNote.gd").new()
	n.id = project.allocate_note_id()
	n.note = pitch
	n.velocity = MidiNoteData.from_midi_velocity(100)
	n.start_tick = start
	n.duration_ticks = length
	return n


## Milliseconds from calling `work` until the next frame has started, so deferred layout
## and redraws queued by `work` are included.
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
	var project := _build_project()
	_report_value("tracks", _tracks)
	_report_value("clips per track", _clips_per_track)
	_report_value("notes per track", _notes_per_track)

	# Headless windows are 64x64; the timeline culls clip drawing to what is on screen.
	get_root().size = Vector2i(1600, 900)
	var root := Control.new()
	root.size = Vector2(1600, 900)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame

	var t_bind := Time.get_ticks_usec()
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame
	_report("1. bind project", (Time.get_ticks_usec() - t_bind) / 1000.0)
	for i in 5:
		await process_frame

	for arg in OS.get_cmdline_user_args():
		if arg == "--hide-tracklist":
			arranger.tracks_panel.visible = false
		elif arg == "--hide-timeline":
			arranger.timeline.visible = false
	await process_frame
	var idle: Array = []
	for i in 20:
		idle.append(await _time_with_frame(func(): pass))
	_report("2. idle frame (median of 20)", _median(idle))

	# Pan the way Arranger._process applies it: the scroll container and the grid together.
	var h_scroll: ScrollContainer = arranger.h_scroll
	var grid: Resource = arranger.grid_helper
	var scroll_times: Array = []
	for i in 30:
		var x := 200 + 40 * i
		scroll_times.append(await _time_with_frame(func():
			arranger.target_scroll_horizontal = x
			h_scroll.scroll_horizontal = x
			grid.scroll_position = x))
	_report("3. h-scroll step (median of 30)", _median(scroll_times))

	var v_scroll: ScrollContainer = arranger.v_scroll
	var v_times: Array = []
	for i in 30:
		var y := 40 * (i + 1)
		v_times.append(await _time_with_frame(func():
			arranger.target_scroll_vertical = y
			v_scroll.scroll_vertical = y))
	_report("4. v-scroll step (median of 30)", _median(v_times))

	var zoom_times: Array = []
	for i in 10:
		var factor: float = arranger.zoom_sensitivity_h if i % 2 == 0 else 1.0 / arranger.zoom_sensitivity_h
		var ppb: float = grid.pixels_per_beat * factor
		zoom_times.append(await _time_with_frame(func():
			arranger.target_pixels_per_beat = ppb
			arranger.timeline.set_zoom(ppb)))
	_report("5. zoom step (median of 10)", _median(zoom_times))

	root.free()
	editor.free()
	await process_frame
