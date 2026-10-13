# bench_arranger_zoom.gd
# Arranger horizontal zoom benchmark over a real project file. Not a test_*.gd script, so
# tests/run_all.sh skips it. Timings are headless: they cover script, layout and _draw
# command recording, not GPU work.
#
# Run: godot --headless --path Godot -s tests/bench_arranger_zoom.gd -- --test --project=/path/to/x.sonara
# Only the BENCH lines matter: godot ... 2>&1 | grep BENCH
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const FRAMES := 120

var _path := ""


func suite_name() -> String:
	return "Arranger zoom benchmark"


func run_tests() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--project="):
			_path = arg.get_slice("=", 1)
	OS.low_processor_usage_mode_sleep_usec = 0
	if _path.is_empty():
		_assert(false, "pass --project=<file.sonara>")
		return
	get_root().size = Vector2i(1920, 1080)
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame

	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_path))
	var project: Object = load("res://data/Project.gd").from_json(data)
	editor.project = project
	editor.project_activated.emit(project)
	for i in 10:
		await process_frame
	print("BENCH nodes %d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT))

	# Idle frames for a baseline.
	await _run_frames("idle", func(_i): pass)
	# Zoom out then in, like a held shift+wheel, through the arranger's own path.
	# A wheel notch every 3 frames: zoom out for half the run, then back in.
	var perf: Node = get_root().get_node("PerfRecorder")
	perf.start()
	await _zoom(arranger, "zoom")
	for line in perf.stop().split("\n"):
		if "._" in line and not line.begins_with(" ") and not line.begins_with("#"):
			print("BENCH   ", line)
	await _run_frames("scroll", func(i):
		arranger.target_scroll_horizontal = i * 20)
	# Hide one more part per run: what each part costs is the drop between two runs.
	var tl: Control = arranger.timeline
	for row in tl.timeline_tracks:
		for c in row.clip_instances:
			c.clip_renderer.visible = false
	await _zoom(arranger, "noRender")
	for row in tl.timeline_tracks:
		for c in row.clip_instances:
			c.visible = false
	await _zoom(arranger, "noClips")
	for lr in tl._lane_rows.values():
		lr.visible = false
	await _zoom(arranger, "noLanes")
	tl.visible = false
	await _zoom(arranger, "noTL")
	_assert(true, "ran")


## A wheel notch every 3 frames: zoom out for half the run, then back in. Only frames where the
## zoom actually moved count.
func _zoom(arranger: Control, label: String) -> void:
	var times: Array[float] = []
	for i in FRAMES:
		if i % 3 == 0:
			arranger._zoom_horizontally(i >= FRAMES / 2, 600.0)
		var before: float = arranger.grid_helper.pixels_per_beat
		var t0 := Time.get_ticks_usec()
		await process_frame
		if arranger.grid_helper.pixels_per_beat != before:
			times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	var total := 0.0
	for t in times:
		total += t
	print("BENCH %-8s %d active frames, mean %6.2f ms  p50 %6.2f  p95 %6.2f" % [label, times.size(),
		total / maxi(1, times.size()), times[times.size() / 2], times[int(times.size() * 0.95)]])


func _run_frames(label: String, step: Callable) -> void:
	var times: Array[float] = []
	for i in FRAMES:
		var t0 := Time.get_ticks_usec()
		step.call(i)
		await process_frame
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	var total := 0.0
	for t in times:
		total += t
	print("BENCH %-8s mean %7.2f ms  p50 %7.2f  p95 %7.2f  max %7.2f" % [label,
		total / times.size(), times[times.size() / 2], times[int(times.size() * 0.95)], times[-1]])
