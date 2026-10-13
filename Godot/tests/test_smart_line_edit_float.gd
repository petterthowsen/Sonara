# test_smart_line_edit_float.gd
# While editing, SmartLineEdit's LineEdit escapes ancestor clipping (top_level) and draws above
# later siblings (absolute z_index), so renaming a channel inside a mixer group isn't clipped.
# Run: godot --headless --path Godot -s tests/test_smart_line_edit_float.gd -- --test
extends TestBase


func suite_name() -> String:
	return "SmartLineEdit floating editor"


func run_tests() -> void:
	var clip := Control.new()
	clip.clip_contents = true
	clip.position = Vector2(50, 50)
	clip.size = Vector2(120, 100)
	root.add_child(clip)
	var edit: SmartLineEdit = (load("res://components/SmartLineEdit.tscn") as PackedScene).instantiate()
	edit.value_type = SmartLineEdit.ValueType.STRING
	edit.position = Vector2(60, 10)
	edit.size = Vector2(50, 24)
	clip.add_child(edit)
	var sibling := Control.new()
	clip.add_child(sibling)
	await process_frame
	await process_frame
	edit.set_value("Layer")

	var before_anchor_right := edit.line_edit.anchor_right
	edit.start_editing()
	await process_frame
	var le := edit.line_edit
	_assert(edit.is_editing, "editing started")
	_assert(le.top_level, "line edit is top_level while editing (escapes ancestor clip)")
	_assert(not le.z_as_relative and le.z_index > 100, "absolute high z_index (above later siblings)")
	_assert(le.get_global_rect().position.x == edit.get_global_rect().position.x, "aligned with the label horizontally")
	_assert(le.size.x >= edit.size.x - 0.5, "at least as wide as the control (%s)" % le.size)
	var vis := le.get_global_rect().intersection(edit.get_global_rect())
	_assert(vis.size.y > 0.0, "overlaps the label rect")

	edit.cancel_editing()
	await process_frame
	_assert(not le.top_level, "docked again after editing")
	_assert(le.z_as_relative and le.z_index == 0, "z restored")
	_assert(is_equal_approx(le.anchor_right, before_anchor_right), "anchors restored")
	_assert(not le.visible and edit.label.visible, "label shown again")

	# Second edit cycle works and commits.
	edit.start_editing()
	await process_frame
	le.text = "Renamed"
	edit.stop_editing()
	_assert(edit.get_value() == "Renamed", "commit applies value")
	_assert(not le.top_level, "docked after commit")
