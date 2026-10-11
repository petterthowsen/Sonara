# test_key_change_track.gd
# Spec 034 G-005: the key change lane. Adds land on bar lines with the key in effect there,
# drags snap to bar lines and clamp between neighbours (bar 2 earliest), every edit is exactly
# one undo step recorded on release, deletes work, the base-scale chip follows the project scale
# (including through Editor.set_project_scale undo/redo), and the lane redraws when bar lines
# move under the tick-anchored tabs.
#
# Everything stays untyped on purpose: the suite script compiles before the autoloads exist, so
# static references to Project/track classes there would fail to compile (see TestBase._init).
#
# Run: godot --headless --path Godot -s tests/test_key_change_track.gd -- --test
extends TestBase

var _recorded: Array = []
var _last_undone = null


func suite_name() -> String:
	return "Key change track"


func run_tests() -> void:
	var sink := _recorded
	load("res://history/HistoryUtil.gd").test_recorder = func(cmd): sink.append(cmd)
	await _test_lane_model()
	await _test_bar_snapping_and_clamping()
	load("res://history/HistoryUtil.gd").test_recorder = Callable()


func _rig() -> Dictionary:
	var track = load("res://arranger/ruler/KeyChangeTrack.gd").new()
	var grid = load("res://components/GridHelper.gd").new()
	grid.min_line_spacing = 10.0
	grid.pixels_per_beat = 100.0
	var project = load("res://data/Project.gd").new()
	project.set_scale(0, "major")
	get_root().add_child(track)
	track.set_grid_helper(grid)
	track.bind_project(project)
	return {"track": track, "grid": grid, "project": project}


func _teardown(rig: Dictionary) -> void:
	rig["track"].queue_free()
	await process_frame


func _history_count() -> int:
	return _recorded.size()


func _undo_last() -> void:
	_last_undone = _recorded.pop_back()
	_last_undone.undo()


func _redo_last() -> void:
	_last_undone.do()


func _test_lane_model() -> void:
	var rig := _rig()
	var track = rig["track"]
	var project = rig["project"]
	var grid = rig["grid"]

	# Add at bar 5: lands on the bar line, initial value = the key in effect there (base C major).
	var id: int = track.add_change_at_bar(5)
	_assert(project.key_change_map.changes.size() == 1, "add creates one change")
	_assert(project.key_change_map.changes[0]["tick"] == 3840 * 4, "bar 5 lands on its bar-line tick")
	var c: Dictionary = project.key_change_map.changes[0]
	_assert(c["root"] == 0 and c["type_id"] == "major", "initial value is the scale in effect there")
	_assert(track.items().size() == 1, "lane holds one item per change")

	# The item sits at the tick's pixel position and follows scroll.
	var item = track.items()[0]
	await process_frame
	_assert(is_equal_approx(item.position.x, grid.ticks_to_pixels(3840 * 4)),
		"item x is the tick in pixels (no scroll)")
	grid.scroll_position = 100.0
	await process_frame
	_assert(is_equal_approx(item.position.x, grid.ticks_to_pixels(3840 * 4) - 100.0),
		"item follows scroll")
	grid.scroll_position = 0.0

	# Editing the key through the dropdown path: one undo step.
	var before_count := _history_count()
	track.open_dropdown(id, Vector2.ZERO)
	track._on_picker_scale_picked(2, "dorian")
	_assert(project.get_scale_at_tick(3840 * 4).type_id == "dorian", "picker updates the change")
	_assert(_history_count() == before_count + 1, "an edit is exactly one undo step")
	_undo_last()
	_assert(project.get_scale_at_tick(3840 * 4).type_id == "major", "undo restores the key")
	_redo_last()
	_assert(project.get_scale_at_tick(3840 * 4).type_id == "dorian", "redo reapplies it")

	# Move and delete, each one step.
	before_count = _history_count()
	track.move_change(id, 8)
	_assert(project.key_change_map.changes[0]["tick"] == 3840 * 7, "move_change snaps to the bar line")
	_assert(_history_count() == before_count + 1, "move is one undo step")
	_undo_last()
	_assert(project.key_change_map.changes[0]["tick"] == 3840 * 4, "undo restores the position")

	before_count = _history_count()
	track.delete_change(id)
	_assert(project.key_change_map.is_empty(), "delete removes the change")
	_assert(_history_count() == before_count + 1, "delete is one undo step")
	_undo_last()
	_assert(project.key_change_map.changes.size() == 1, "undo restores the deleted change")
	track.delete_change(project.key_change_map.changes[0]["id"])

	# The chip shows the base scale and its dropdown drives Editor.set_project_scale.
	var editor = load("res://editor/Editor.gd").new()
	var sonara: Node = get_root().get_node("Sonara")
	sonara.editor = editor
	editor.project = project
	project.set_scale(0, "major")
	track._rebuild_items()
	var chip = track.chip()
	_assert(chip != null and chip.visible, "start-key chip exists")
	_assert(chip.text == "C Major", "chip shows the base scale")
	track.open_dropdown(0, Vector2.ZERO)
	track._on_picker_scale_picked(9, "natural_minor")
	_assert(project.scale_root == 9 and project.scale_type == "natural_minor",
		"chip picker calls Editor.set_project_scale")
	_assert(chip.text == "A Natural Minor", "chip follows the base scale")
	# Undo of the base key (a PropertyCommand) updates the chip too.
	var undo_ok: bool = editor.undo()
	_assert(undo_ok and project.scale_root == 0 and chip.text == "C Major", "chip follows undo of the base key")
	var base_cmds := _history_count() - before_count
	_assert(base_cmds >= 1, "the base key change was recorded: %d" % base_cmds)
	sonara.editor = null
	editor.free()

	# A time-signature edit moves bar lines under the tick-anchored tab (Gotcha 16): the tab
	# keeps its tick and is not re-snapped, while the bar line it used to sit on moves away.
	var id2: int = track.add_change_at_bar(5)
	var bar5_before: int = project.time_signature_map.tick_of_bar(5, project.time_numerator, project.time_denominator, project.ppq)
	_assert(is_equal_approx(track.items()[0].position.x, grid.ticks_to_pixels(bar5_before)),
		"the tab starts on its bar line")
	var sig: int = project.time_signature_map.add_change(3, 7, 8)
	await process_frame
	var bar5_after: int = project.time_signature_map.tick_of_bar(5, project.time_numerator, project.time_denominator, project.ppq)
	_assert(bar5_after != bar5_before, "the 7/8 change moves bar 5")
	_assert(is_equal_approx(track.items()[0].position.x, grid.ticks_to_pixels(project.key_change_map.changes[0]["tick"])),
		"the tab keeps its tick (bar lines move under it, Gotcha 16)")
	project.time_signature_map.remove_change(sig)
	track.delete_change(id2)
	await _teardown(rig)


func _test_bar_snapping_and_clamping() -> void:
	var rig := _rig()
	var track = rig["track"]
	var project = rig["project"]
	var grid = rig["grid"]
	var id_a: int = track.add_change_at_bar(5)
	var id_b: int = track.add_change_at_bar(9)
	var adds := _history_count()  # 2, one per add_change_at_bar

	# Drag simulation: pressed records the snapshot, dragged applies, released records one step.
	# The changes sit at bar 5 (tick 15360) and bar 9 (tick 30720); 4/4 bars are 3840 ticks.
	track._on_item_pressed(id_b)
	# Onto the earlier change's own bar line: clamps to the tick just after it.
	track._on_item_dragged(id_b, grid.ticks_to_pixels(3840 * 4))
	var b_index: int = project.key_change_map.index_of(id_b)
	_assert(b_index >= 0 and project.key_change_map.changes[b_index]["tick"] == 3840 * 4 + 1,
		"dragging onto the earlier change's bar clamps just after it (order never flips)")
	# Far left of both: still stops at the earlier neighbour.
	track._on_item_dragged(id_b, grid.ticks_to_pixels(3840 * 2))
	b_index = project.key_change_map.index_of(id_b)
	_assert(project.key_change_map.changes[b_index]["tick"] == 3840 * 4 + 1,
		"dragging to bar 1/2 clamps at the neighbour (bar 2 earliest overall)")
	track._on_item_released(id_b)
	_assert(_history_count() == adds + 1, "a whole drag is exactly one history entry: %d" % _history_count())
	_undo_last()  # put the neighbour back on bar 9 before the next drag

	# A second change between neighbours clamps both ways. This time the *earlier* change (at
	# bar 5) is dragged onto the later change's bar line (bar 9): stops just before it.
	track._on_item_pressed(id_a)
	track._on_item_dragged(id_a, grid.ticks_to_pixels(3840 * 8))
	track._on_item_released(id_a)
	var a_index: int = project.key_change_map.index_of(id_a)
	_assert(project.key_change_map.changes[a_index]["tick"] == 3840 * 8 - 1,
		"moving past the next change stops just before it")
	_undo_last()

	# Dragging to bar 2 when nothing is left of it: earliest allowed spot (tick_of_bar(1)).
	var first_id: int = project.key_change_map.changes[0]["id"]
	track.delete_change(first_id)
	track.delete_change(project.key_change_map.changes[0]["id"])
	await process_frame
	_assert(project.key_change_map.is_empty(), "last change deleted")
	var solo: int = track.add_change_at_bar(6)
	track._on_item_pressed(solo)
	track._on_item_dragged(solo, grid.ticks_to_pixels(0))
	_assert(project.key_change_map.changes[0]["tick"] == 3840, "with no neighbours, bar 2 (tick 3840) is earliest")
	track._on_item_released(solo)
	await _teardown(rig)
