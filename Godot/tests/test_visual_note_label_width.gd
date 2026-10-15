# test_visual_note_label_width.gd
# A note's pitch label is hidden when the note is narrower than the label needs.
# Run: godot --headless --path Godot -s tests/test_visual_note_label_width.gd -- --test
extends TestBase


func suite_name() -> String:
	return "VisualNote label width tests"


func run_tests() -> void:
	await _test_threshold()
	await _test_drum_mode_stays_hidden()
	await _test_row_height_still_hides()
	await _test_small_note_has_no_resize_handle()


func _make_note() -> VisualNote:
	var vn: VisualNote = load("res://clip_editor/VisualNote.tscn").instantiate()
	root.add_child(vn)
	var nd := MidiNoteData.new()
	nd.note = 61
	vn.bind_to_note(nd)
	return vn


func _test_threshold() -> void:
	var vn := _make_note()
	await process_frame
	vn.size = Vector2(200, 20)
	vn.update_label_visibility(20.0)
	_assert(vn.label.visible, "wide note shows its label")
	var need := vn.label.get_minimum_size().x + VisualNote.LABEL_PADDING
	vn.size = Vector2(need - 1.0, 20)
	vn.update_label_visibility(20.0)
	_assert(not vn.label.visible, "narrow note hides its label")
	vn.size = Vector2(need, 20)
	vn.update_label_visibility(20.0)
	_assert(vn.label.visible, "label returns once the note is wide enough")
	vn.queue_free()


func _test_drum_mode_stays_hidden() -> void:
	var vn := _make_note()
	await process_frame
	vn.set_drum_mode(true)
	vn.size = Vector2(200, 20)
	vn.update_label_visibility(20.0)
	_assert(not vn.label.visible, "drum mode keeps labels hidden")
	vn.queue_free()


func _test_row_height_still_hides() -> void:
	var vn := _make_note()
	await process_frame
	vn.size = Vector2(200, 4)
	vn.update_label_visibility(4.0)
	_assert(not vn.label.visible, "short row hides the label")
	vn.size = Vector2(200, 20)
	vn.update_label_visibility(20.0)
	_assert(vn.label.visible, "label shows again at full row height")
	vn.queue_free()


func _test_small_note_has_no_resize_handle() -> void:
	var vn := _make_note()
	await process_frame
	vn.size = Vector2(VisualNote.MIN_RESIZABLE_WIDTH - 1.0, 20)
	_assert(not vn._is_over_resize_handle(Vector2(vn.size.x - 1.0, 10)), "narrow note has no resize handle")
	vn.size = Vector2(VisualNote.MIN_RESIZABLE_WIDTH, 20)
	_assert(vn._is_over_resize_handle(Vector2(vn.size.x - 1.0, 10)), "wide enough note keeps its resize handle")
	vn.queue_free()
