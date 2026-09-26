# test_arranger_layout.gd
# Headless test for the Arranger's pinned bottom row: the TracksPanelFooter (add track/folder)
# and the TimelineScrollBar live below the vertical scroll, so they stay visible and don't move
# when the track content scrolls, and their columns line up with the panels above.
#
# Run: godot --headless --path Godot -s tests/test_arranger_layout.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Arranger pinned bottom row"


func run_tests() -> void:
	await _test_bottom_row_pinned_and_aligned()


func _test_bottom_row_pinned_and_aligned() -> void:
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)

	# Arranger and Playhead reach Sonara.editor; a bare Editor script instance (kept out of the
	# tree so its scene-bound _ready never runs) is enough for them to resolve.
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await process_frame

	var v_scroll: ScrollContainer = arranger.v_scroll
	var footer: Control = arranger.tracks_panel_footer
	var bar: Control = arranger.timeline_scroll_bar

	_assert(not v_scroll.is_ancestor_of(footer), "TracksPanelFooter is outside the vertical scroll")
	_assert(not v_scroll.is_ancestor_of(bar), "TimelineScrollBar is outside the vertical scroll")

	var v_rect := v_scroll.get_global_rect()
	_assert(footer.get_global_rect().position.y >= v_rect.end.y - 0.5, "footer sits below the scroll viewport")
	_assert(bar.get_global_rect().position.y >= v_rect.end.y - 0.5, "scrollbar sits below the scroll viewport")
	_assert(arranger.add_track_button.is_visible_in_tree(), "add track button visible")

	# Make the content taller than the viewport and scroll it: the bottom row must not move.
	arranger.h_split.custom_minimum_size.y = 3000
	await process_frame
	await process_frame
	var footer_y := footer.global_position.y
	var bar_y := bar.global_position.y
	v_scroll.scroll_vertical = 1000
	await process_frame
	_assert(v_scroll.scroll_vertical > 0, "content scrolled (%d)" % v_scroll.scroll_vertical)
	_assert(is_equal_approx(footer.global_position.y, footer_y), "footer stays put while scrolling")
	_assert(is_equal_approx(bar.global_position.y, bar_y), "scrollbar stays put while scrolling")

	# Columns line up with the panels above, including after dragging the split.
	_assert_columns_aligned(arranger, "initial")
	arranger.h_split.split_offset = 320
	await process_frame
	await process_frame
	_assert_columns_aligned(arranger, "after split change")

	root.queue_free()
	await process_frame
	get_root().get_node("Sonara").editor = null
	editor.free()


func _assert_columns_aligned(arranger: Control, label: String) -> void:
	var tracks_rect: Rect2 = arranger.tracks_panel.get_global_rect()
	var timeline_rect: Rect2 = arranger.timeline_panel.get_global_rect()
	var footer_rect: Rect2 = arranger.tracks_panel_footer.get_global_rect()
	var bar_rect: Rect2 = arranger.timeline_scroll_bar.get_global_rect()
	_assert(absf(footer_rect.size.x - tracks_rect.size.x) < 1.0,
		"%s: footer width %.0f matches tracks panel %.0f" % [label, footer_rect.size.x, tracks_rect.size.x])
	_assert(absf(bar_rect.position.x - timeline_rect.position.x) < 1.0,
		"%s: scrollbar x %.0f matches timeline x %.0f" % [label, bar_rect.position.x, timeline_rect.position.x])
	_assert(absf(bar_rect.end.x - timeline_rect.end.x) < 1.0,
		"%s: scrollbar right %.0f matches timeline right %.0f" % [label, bar_rect.end.x, timeline_rect.end.x])
