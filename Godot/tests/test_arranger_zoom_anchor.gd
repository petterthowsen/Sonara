# test_arranger_zoom_anchor.gd
# Headless test for the Arranger's shift+wheel horizontal zoom: the beat under the cursor
# stays under the cursor on every frame of the smoothed zoom. Zooming in near the end of
# the content used to clamp the scroll to the ScrollContainer's stale range on some
# frames, so the view jumped back and forth by hundreds of pixels.
#
# Run: godot --headless --path Godot -s tests/test_arranger_zoom_anchor.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const CONTENT_BARS := 92
## Allowed drift of the anchored beat, in pixels: the scroll is rounded to whole pixels.
const TOLERANCE := 1.0

var _arranger: Control
var _editor: Node
var _root: Control


func suite_name() -> String:
	return "Arranger horizontal zoom anchor"


func run_tests() -> void:
	await _setup()
	# Viewing the last bars of the song: the timeline is barely wider than the view.
	await _check_zoom("zoom in near content end, cursor mid", 6000, 22.0, 500.0, "uuuuuu")
	await _check_zoom("zoom in near content end, cursor right", 7000, 22.0, 1300.0, "uuuuuuuuuu")
	await _check_zoom("zoom out far right", 18000, 64.0, 700.0, "dddddd")
	await _check_zoom("zoom in and out", 6000, 22.0, 900.0, "uudduuddd")
	await _teardown()


func _setup() -> void:
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
	await _settle()


func _teardown() -> void:
	_root.queue_free()
	await process_frame
	get_root().get_node("Sonara").editor = null
	_editor.free()


func _settle() -> void:
	for i in 60:
		await process_frame


## Start at `scroll` / `ppb`, then send one shift+wheel step per `steps` character
## ("u" in, "d" out) at `cursor_x`, two frames apart, and follow the zoom until it settles.
func _check_zoom(label: String, scroll: int, ppb: float, cursor_x: float, steps: String) -> void:
	_arranger.target_pixels_per_beat = ppb
	await _settle()
	_arranger.target_scroll_horizontal = scroll
	await _settle()

	var h: ScrollContainer = _arranger.h_scroll
	var grid: Resource = _arranger.grid_helper
	var anchor_beat: float = (h.scroll_horizontal + cursor_x) / grid.pixels_per_beat
	var worst := 0.0
	var frames := 0
	for step in steps:
		_arranger._zoom_horizontally(step == "u", cursor_x)
		for i in 2:
			await process_frame
			worst = maxf(worst, absf(anchor_beat * grid.pixels_per_beat - h.scroll_horizontal - cursor_x))
			frames += 1
	while _arranger._zoom_anchor_active and frames < 200:
		await process_frame
		worst = maxf(worst, absf(anchor_beat * grid.pixels_per_beat - h.scroll_horizontal - cursor_x))
		frames += 1

	_assert(not _arranger._zoom_anchor_active, "%s: zoom settles" % label)
	_assert(worst <= TOLERANCE, "%s: beat under the cursor stays put (worst drift %.1f px over %d frames)" % [label, worst, frames])
