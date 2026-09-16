# test_track_folding.gd
# Headless tests for folding folder/group children in the arranger: AutomationRowOrder leaves out
# folded-away rows, TrackFoldAnimation slides the subtree top-down with the same heights for both
# columns, Project.reveal_track unfolds ancestors, and the fold state survives save/load.
#
# Project and the arranger helpers reference autoloads, so they are loaded with load().
# Run: godot --headless --path Godot -s tests/test_track_folding.gd -- --test
extends TestBase

var _project_script: GDScript
var _row_order: GDScript
var _fold_anim: GDScript


func suite_name() -> String:
	return "Track folding tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_row_order = load("res://arranger/AutomationRowOrder.gd")
	_fold_anim = load("res://arranger/TrackFoldAnimation.gd")
	_test_collapsed_rows_left_out()
	_test_nested_collapse()
	await _test_slide_heights()
	_test_reveal_track()
	_test_fold_state_persists()


## Folder with two children (60 px each) plus a root track after it.
func _make_project() -> Dictionary:
	var project: Object = _project_script.new()
	var folder: Object = project.create_folder_track("Folder").track
	var a: Object = project.create_instrument_track("A").track
	var b: Object = project.create_instrument_track("B").track
	var after: Object = project.create_instrument_track("After").track
	project.place_track(a, folder.id, null)
	project.place_track(b, folder.id, a)
	project.place_track(after, -1, folder)
	for t in [folder, a, b, after]:
		t.height = 60
	return {"project": project, "folder": folder, "a": a, "b": b, "after": after}


func _row_tracks(rows: Array) -> Array:
	var names: Array = []
	for row in rows:
		names.append(row["track"].name)
	return names


func _test_collapsed_rows_left_out() -> void:
	var p := _make_project()
	_assert(_row_tracks(_row_order.build(p.project)) == ["Folder", "A", "B", "After"], "expanded shows all rows")
	p.folder.set("_is_folder_expanded", false)
	_assert(_row_tracks(_row_order.build(p.project)) == ["Folder", "After"], "collapsed hides children: %s" % str(_row_tracks(_row_order.build(p.project))))
	_assert(p.project.is_track_folded_away(p.a), "child reports folded away")
	_assert(not p.project.is_track_folded_away(p.after), "sibling after the folder is not folded")


func _test_nested_collapse() -> void:
	var p := _make_project()
	var inner: Object = p.project.create_folder_track("Inner").track
	var c: Object = p.project.create_instrument_track("C").track
	p.project.place_track(inner, p.folder.id, p.b)
	p.project.place_track(c, inner.id, null)
	inner.set("_is_folder_expanded", false)
	_assert(_row_tracks(_row_order.build(p.project)) == ["Folder", "A", "B", "Inner", "After"], "inner fold hides only its child")
	# Outer animating open while the inner folder stays collapsed: C stays hidden.
	p.folder.set("_is_folder_expanded", false)
	p.folder.is_folder_expanded = true
	var anim: Object = _fold_anim.start(p.folder)
	_assert(not _row_tracks(_row_order.build(p.project)).has("C"), "outer unfold keeps inner child hidden")
	_fold_anim.finish_all()


func _test_slide_heights() -> void:
	var p := _make_project()
	p.folder.is_folder_expanded = false
	var anim: Object = _fold_anim.start(p.folder)
	_assert(anim != null and _fold_anim.for_track(p.folder) == anim, "collapse starts an animation")
	_assert(_fold_anim.start(p.folder) == anim, "second column's start() reuses it")
	var rows: Array = _row_order.build(p.project)
	_assert(_row_tracks(rows) == ["Folder", "A", "B", "After"], "children stay in rows while sliding")

	anim.reveal = 0.75  # 90 of 120 px: A full, B cut to 30 px -> below the row floor, hidden
	var heights: Array = _row_order.fold_heights(p.project, rows)
	_assert(heights == [60.0, 60.0, 0.0, 60.0], "reveal 0.75 heights: %s" % str(heights))
	anim.reveal = 0.875  # 105 px: B shows 45
	heights = _row_order.fold_heights(p.project, rows)
	_assert(heights == [60.0, 60.0, 45.0, 60.0], "reveal 0.875 heights: %s" % str(heights))
	anim.reveal = 0.25  # 30 px: nothing reaches the floor
	heights = _row_order.fold_heights(p.project, rows)
	_assert(heights == [60.0, 0.0, 0.0, 60.0], "reveal 0.25 heights: %s" % str(heights))

	var done := [false]
	anim.finished.connect(func(): done[0] = true)
	for i in 60:
		if done[0]:
			break
		await process_frame
	_assert(done[0], "animation finishes on its own")
	_assert(_fold_anim.for_track(p.folder) == null, "finished animation is unregistered")
	_assert(_row_tracks(_row_order.build(p.project)) == ["Folder", "After"], "children dropped after the slide")

	# Reversing mid-slide reuses the animation from its current reveal.
	p.folder.is_folder_expanded = true
	var opening: Object = _fold_anim.start(p.folder)
	opening.reveal = 0.5
	p.folder.is_folder_expanded = false
	_assert(_fold_anim.start(p.folder) == opening, "reverse reuses the running animation")
	_assert(is_equal_approx(opening.reveal, 0.5), "reverse starts from the current reveal")
	_fold_anim.finish_all()
	_assert(opening.reveal == 0.0, "finish_all jumps to the target")


func _test_reveal_track() -> void:
	var p := _make_project()
	var inner: Object = p.project.create_folder_track("Inner").track
	var c: Object = p.project.create_instrument_track("C").track
	p.project.place_track(inner, p.folder.id, null)
	p.project.place_track(c, inner.id, null)
	inner.set("_is_folder_expanded", false)
	p.folder.set("_is_folder_expanded", false)
	var events: Array = []
	p.folder.folder_expanded_changed.connect(func(e): events.append(e))
	p.project.reveal_track(c)
	_assert(p.folder.is_folder_expanded and inner.is_folder_expanded, "reveal expands every ancestor")
	_assert(events == [true], "reveal emits folder_expanded_changed")
	_fold_anim.finish_all()


func _test_fold_state_persists() -> void:
	var p := _make_project()
	p.folder.set("_is_folder_expanded", false)
	var loaded: Object = _project_script.from_json(p.project.to_json())
	var folder: Object = loaded.get_track_by_id(p.folder.id)
	_assert(folder != null and not folder.is_folder_expanded, "collapsed state saved and loaded")
	_assert(_row_tracks(_row_order.build(loaded)) == ["Folder", "After"], "loaded project starts folded")
