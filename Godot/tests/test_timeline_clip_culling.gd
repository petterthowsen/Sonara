# test_timeline_clip_culling.gd
# Headless tests for arranger clip culling: Timeline gives each clip on an on-screen row the
# part of it that is visible (MidiclipRenderer.show_px_range), and clips off screen, vertically
# or horizontally, draw no notes.
#
# Run: godot --headless --path Godot -s tests/test_timeline_clip_culling.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const TRACKS := 30
const LONG_CLIP_BARS := 256


func suite_name() -> String:
	return "Timeline clip culling"


func run_tests() -> void:
	var f := await _make_fixture()
	await _test_initial_windows(f)
	await _test_horizontal_scroll(f)
	await _test_vertical_scroll(f)
	await _free(f)


## Arranger over TRACKS instrument tracks. The first holds a long clip from 0 and a short one far
## to the right; the last holds a short clip at 0.
func _make_fixture() -> Dictionary:
	# Headless windows are 64x64; the timeline culls clip drawing to what is on screen.
	get_root().size = Vector2i(1200, 600)
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame

	var project: Object = load("res://data/Project.gd").new()
	var bar: int = project.ppq * 4
	var tracks: Array = []
	for i in TRACKS:
		tracks.append(project.create_instrument_track("T%d" % i).track)
	var long_inst: Object = _add_clip(project, tracks[0], 0, LONG_CLIP_BARS * bar)
	var far_inst: Object = _add_clip(project, tracks[0], (LONG_CLIP_BARS + 400) * bar, 4 * bar)
	var bottom_inst: Object = _add_clip(project, tracks[TRACKS - 1], 0, 4 * bar)
	editor.project = project
	editor.project_activated.emit(project)
	for i in 4:
		await process_frame
	return {"root": root, "arranger": arranger, "editor": editor, "project": project,
		"long": long_inst, "far": far_inst, "bottom": bottom_inst}


## A MIDI clip with one note every beat, so every part of it has something to draw.
func _add_clip(project: Object, track: Object, start: int, length: int) -> Object:
	var clip: Object = project.create_clip("C")
	project.add_clip(clip)
	var beat: int = project.ppq
	for i in length / beat:
		clip.add_midi_note(project.allocate_note_id(), 60 + i % 12, MidiNoteData.from_midi_velocity(100), i * beat, beat / 2)
	return track.create_clip_instance(clip, start, length)


func _free(f: Dictionary) -> void:
	f.root.free()
	f.editor.free()
	await process_frame


func _renderer(f: Dictionary, inst: Object) -> Control:
	for row in f.arranger.timeline.timeline_tracks:
		for clip_ui in row.clip_instances:
			if clip_ui.clip_instance == inst:
				return clip_ui.clip_renderer
	return null


func _window(f: Dictionary, inst: Object) -> Vector2i:
	return _renderer(f, inst)._window


## Instance-local ticks at the left and right edge of the timeline viewport.
func _visible_ticks(f: Dictionary) -> Vector2i:
	var grid: Resource = f.arranger.grid_helper
	var h_scroll: ScrollContainer = f.arranger.h_scroll
	return Vector2i(grid.pixels_to_ticks(h_scroll.scroll_horizontal),
		grid.pixels_to_ticks(h_scroll.scroll_horizontal + h_scroll.size.x))


func _scroll_to(f: Dictionary, x: int, y: int) -> void:
	f.arranger.target_scroll_horizontal = x
	f.arranger.target_scroll_vertical = y
	f.arranger.h_scroll.scroll_horizontal = x
	f.arranger.v_scroll.scroll_vertical = y
	f.arranger.grid_helper.scroll_position = x
	for i in 3:
		await process_frame


func _test_initial_windows(f: Dictionary) -> void:
	await _scroll_to(f, 0, 0)
	var long_window := _window(f, f.long)
	var shown := _visible_ticks(f)
	_assert(long_window.y > long_window.x, "the on-screen clip draws a window (got %s)" % long_window)
	_assert(long_window.x <= shown.x and long_window.y >= shown.y,
		"the window covers the visible part (window %s, visible %s)" % [long_window, shown])
	_assert(long_window.y < f.long.duration_ticks,
		"a long clip draws only part of itself (window %s of %d)" % [long_window, f.long.duration_ticks])
	var far := _window(f, f.far)
	_assert(far.y <= far.x, "a clip right of the viewport draws nothing (got %s)" % far)
	var bottom := _window(f, f.bottom)
	_assert(bottom.y <= bottom.x, "a clip on a row below the viewport draws nothing (got %s)" % bottom)


func _test_horizontal_scroll(f: Dictionary) -> void:
	var grid: Resource = f.arranger.grid_helper
	var before := _window(f, f.long)
	# Well past the drawn window.
	var x := int(grid.ticks_to_pixels(before.y)) + 2000
	await _scroll_to(f, x, 0)
	var after := _window(f, f.long)
	var shown := _visible_ticks(f)
	_assert(after.x <= shown.x and after.y >= shown.y,
		"scrolling past the window redraws around the new visible part (window %s, visible %s)" % [after, shown])
	_assert(after.x > before.x, "the window moved right (before %s, after %s)" % [before, after])

	# A small step inside the margin keeps the window (no redraw).
	await _scroll_to(f, x + 20, 0)
	_assert(_window(f, f.long) == after, "a small scroll inside the margin keeps the window")


func _test_vertical_scroll(f: Dictionary) -> void:
	var v_bar: ScrollBar = f.arranger.v_scroll.get_v_scroll_bar()
	await _scroll_to(f, 0, int(v_bar.max_value))
	var bottom := _window(f, f.bottom)
	_assert(bottom.y > bottom.x, "scrolling the bottom row into view gives its clip a window (got %s)" % bottom)
	var long_window := _window(f, f.long)
	_assert(long_window.y <= long_window.x, "the top row's clip, now off screen, drops its window (got %s)" % long_window)
