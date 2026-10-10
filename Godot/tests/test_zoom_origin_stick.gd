# test_zoom_origin_stick.gd
# Headless tests for the zoom origin-stick rule shared by the Arranger timeline and the
# MIDI editor: at scroll position 0 the view only stays pinned to the origin when the
# cursor is in the left third of the view; beyond that the zoom anchors around the cursor
# and the scroll may move away from 0.
#
# The Arranger's _zoom_horizontally takes the cursor X explicitly. The MidiEditor derives
# it from h_scroll.get_local_mouse_position(), which is (0, 0) headless — so the
# beyond-left-third cases shift the whole editor left, which puts the cursor right of the
# viewport's left third without needing a real mouse.
#
# Run: godot --headless --path Godot -s tests/test_zoom_origin_stick.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const CLIP_EDITOR_SCENE := "res://clip_editor/ClipEditor.tscn"
const CONTENT_BARS := 92
## Allowed drift of the anchored beat, in pixels: the scroll is rounded to whole pixels.
const TOLERANCE := 1.0

var _arranger: Control
var _editor: Node
var _root: Control
var _clip_editor: Control
var _midi: Object


func suite_name() -> String:
	return "Zoom origin stick (left third rule)"


func run_tests() -> void:
	await _setup_arranger()
	await _test_arranger_stick_left_third()
	await _test_arranger_anchor_beyond_left_third()
	await _teardown_arranger()
	await _setup_midi()
	await _test_midi_stick_left_third()
	await _test_midi_anchor_beyond_left_third()
	await _test_midi_instant_left_third()
	await _test_midi_instant_beyond_left_third()
	await _teardown_midi()


# ---------------------------------------------------------------- Arranger

func _setup_arranger() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var bar_ticks: int = project.ppq * 4
	for t in 8:
		var track: Object = project.create_instrument_track("T%d" % t).track
		for c in CONTENT_BARS / 4:
			var clip: Object = project.create_clip("T%d C%d" % [t, c])
			project.add_clip(clip)
			track.create_clip_instance(clip, c * 4 * bar_ticks, 4 * bar_ticks)

	get_root().size = Vector2i(1600, 900)
	_root = Control.new()
	_root.size = Vector2(1600, 900)
	get_root().add_child(_root)
	# Arranger and Playhead reach Sonara.editor; a bare Editor script instance (kept out of the
	# tree so its scene-bound _ready never runs) is enough for them to resolve.
	_arranger = load(ARRANGER_SCENE).instantiate()
	_editor = load(EDITOR_SCRIPT).new()
	_editor.arranger = _arranger
	get_root().get_node("Sonara").editor = _editor
	_root.add_child(_arranger)
	_arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	_editor.project = project
	_editor.project_activated.emit(project)
	for i in 60:
		await process_frame


func _teardown_arranger() -> void:
	_root.queue_free()
	await process_frame
	get_root().get_node("Sonara").editor = null
	_editor.free()
	_arranger = null


func _arranger_zoom(steps: String, cursor_x: float) -> void:
	for step in steps:
		_arranger._zoom_horizontally(step == "u", cursor_x)
		for i in 2:
			await process_frame
	while _arranger._zoom_anchor_active:
		await process_frame


func _test_arranger_stick_left_third() -> void:
	var h: ScrollContainer = _arranger.h_scroll
	# Reset to origin.
	_arranger.target_pixels_per_beat = 64.0
	_arranger.target_scroll_horizontal = 0
	for i in 60:
		await process_frame
	_assert(h.scroll_horizontal == 0, "arranger setup: scroll at 0")
	await _arranger_zoom("uuuu", 40.0)
	_assert(h.scroll_horizontal == 0,
		"arranger: cursor in left third keeps scroll at 0 (got %d)" % h.scroll_horizontal)


func _test_arranger_anchor_beyond_left_third() -> void:
	var h: ScrollContainer = _arranger.h_scroll
	var grid: Resource = _arranger.grid_helper
	_arranger.target_pixels_per_beat = 64.0
	_arranger.target_scroll_horizontal = 0
	for i in 60:
		await process_frame
	_assert(h.scroll_horizontal == 0, "arranger setup: scroll at 0")
	var cursor_x := 900.0
	_assert(cursor_x > h.size.x / 3.0, "arranger setup: cursor beyond the left third")
	var anchor_beat: float = (h.scroll_horizontal + cursor_x) / grid.pixels_per_beat
	await _arranger_zoom("uuuu", cursor_x)
	_assert(h.scroll_horizontal > 0,
		"arranger: cursor beyond left third scrolls away from 0 (got %d)" % h.scroll_horizontal)
	var drift := absf(anchor_beat * grid.pixels_per_beat - h.scroll_horizontal - cursor_x)
	_assert(drift <= TOLERANCE, "arranger: beat under the cursor stays put (drift %.1f px)" % drift)


# ---------------------------------------------------------------- MIDI editor

func _setup_midi(shift_x: float = 0.0) -> void:
	var project: Object = load("res://data/Project.gd").new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	pair.track.create_clip_instance(clip, 0, 3840 * CONTENT_BARS)

	get_root().size = Vector2i(1600, 900)
	_clip_editor = load(CLIP_EDITOR_SCENE).instantiate()
	get_root().add_child(_clip_editor)
	_clip_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if shift_x != 0.0:
		_clip_editor.position = Vector2(shift_x, 0)
	_midi = _clip_editor.midi_editor
	await process_frame
	await process_frame
	_midi.target_pixels_per_beat = 64.0
	_midi.grid_helper.pixels_per_beat = 64.0
	_midi.target_scroll_horizontal = 0
	_midi.h_scroll.scroll_horizontal = 0
	for i in 30:
		await process_frame


func _teardown_midi() -> void:
	_clip_editor.queue_free()
	await process_frame
	_clip_editor = null
	_midi = null


## Local cursor X inside the MIDI editor's h_scroll (headless mouse sits at viewport 0,0).
func _midi_cursor_x() -> float:
	var hs: ScrollContainer = _midi.h_scroll
	return -hs.get_global_transform().origin.x


func _midi_settle() -> void:
	while _midi._zoom_anchor_active:
		await process_frame
	for i in 10:
		await process_frame


func _test_midi_stick_left_third() -> void:
	var hs: ScrollContainer = _midi.h_scroll
	_assert(_midi.scroll_smoothing > 0, "midi setup: smoothed zoom path active")
	_assert(_midi_cursor_x() <= hs.size.x / 3.0, "midi setup: cursor in the left third")
	_assert(hs.scroll_horizontal == 0, "midi setup: scroll at 0")
	for i in 5:
		_midi._smooth_horizontal_zoom(2.0)
		await process_frame
	await _midi_settle()
	_assert(hs.scroll_horizontal == 0,
		"midi: cursor in left third keeps scroll at 0 (got %d)" % hs.scroll_horizontal)


func _test_midi_anchor_beyond_left_third() -> void:
	await _teardown_midi()
	await _setup_midi(-900.0)
	var hs: ScrollContainer = _midi.h_scroll
	var grid: Resource = _midi.grid_helper
	var cursor_x := _midi_cursor_x()
	_assert(cursor_x > hs.size.x / 3.0, "midi setup: cursor beyond the left third")
	_assert(hs.scroll_horizontal == 0, "midi setup: scroll at 0")
	var anchor_beat: float = (hs.scroll_horizontal + cursor_x) / grid.pixels_per_beat
	for i in 5:
		_midi._smooth_horizontal_zoom(2.0)
		await process_frame
	await _midi_settle()
	_assert(hs.scroll_horizontal > 0,
		"midi: cursor beyond left third scrolls away from 0 (got %d)" % hs.scroll_horizontal)
	var drift := absf(anchor_beat * grid.pixels_per_beat - hs.scroll_horizontal - cursor_x)
	_assert(drift <= TOLERANCE, "midi: beat under the cursor stays put (drift %.1f px)" % drift)


func _test_midi_instant_left_third() -> void:
	await _teardown_midi()
	await _setup_midi()
	var hs: ScrollContainer = _midi.h_scroll
	_midi.set_horizontal_zoom(128.0)
	await process_frame
	_assert(hs.scroll_horizontal == 0,
		"midi instant zoom: cursor in left third keeps scroll at 0 (got %d)" % hs.scroll_horizontal)


func _test_midi_instant_beyond_left_third() -> void:
	await _teardown_midi()
	await _setup_midi(-900.0)
	var hs: ScrollContainer = _midi.h_scroll
	var cursor_x := _midi_cursor_x()
	var anchor_beat: float = (hs.scroll_horizontal + cursor_x) / _midi.grid_helper.pixels_per_beat
	_midi.set_horizontal_zoom(128.0)
	await process_frame
	_assert(hs.scroll_horizontal > 0,
		"midi instant zoom: cursor beyond left third scrolls away from 0 (got %d)" % hs.scroll_horizontal)
	var drift := absf(anchor_beat * _midi.grid_helper.pixels_per_beat - hs.scroll_horizontal - cursor_x)
	_assert(drift <= 2.0, "midi instant zoom: beat under the cursor stays put (drift %.1f px)" % drift)
