# test_scale_ui.gd
# Scale picker, clip editor scale toggles and the Conform button (REQ-002, 011, 013, 021).
# Run: godot --headless --path Godot -s tests/test_scale_ui.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Scale UI"


func run_tests() -> void:
	_test_picker()
	await _test_clip_editor()


func _test_picker() -> void:
	var picker: HBoxContainer = load("res://editor/ScalePicker.gd").new()
	root.add_child(picker)
	var root_opt: OptionButton = picker.get_child(0)
	var type_opt: OptionButton = picker.get_child(1)
	_assert(picker.display_text() == "No scale", "REQ-002: picker starts at No scale")
	_assert(root_opt.disabled, "root is disabled while there is no scale")
	var picks := []
	picker.scale_picked.connect(func(r, t): picks.append([r, t]))
	picker.set_scale_display(2, "dorian")
	_assert(picker.display_text() == "D Dorian", "REQ-002: picker reads D Dorian")
	_assert(picks.is_empty(), "set_scale_display does not emit")
	_assert(root_opt.selected == 2 and type_opt.get_item_text(type_opt.selected) == "Dorian", "dropdowns follow the display")
	_assert(not root_opt.disabled, "root is enabled with a scale")
	_assert(root_opt.item_count == 12 and type_opt.get_item_text(0) == "No scale", "12 roots, No scale first")
	type_opt.select(0)
	type_opt.item_selected.emit(0)
	_assert(picks.size() == 1 and picks[0] == [2, "none"], "picking a type emits scale_picked")
	_assert(root_opt.disabled, "picking No scale disables the root")
	picker.set_scale_display(0, "none")
	_assert(picker.display_text() == "No scale", "none reads No scale")
	picker.queue_free()


func _test_clip_editor() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	var rig = load("res://tests/value_lane_rig.gd").new(self)
	await rig.build([0, 960], [0.5, 0.5], [], [61, 62])
	var ce = rig.editor
	var me = rig.midi_editor
	var project = rig.project
	ce._bind_project_scale(project)
	var fold: Button = ce.fold_to_scale_toggle
	var snap: Button = ce.scale_snap_toggle
	var conform: Button = ce.tools_group.find_child("ConformToScale", true, false)
	_assert(fold.disabled and snap.disabled, "REQ-011: toggles disabled with no scale")
	_assert(not fold.button_pressed and not snap.button_pressed, "toggles default off")

	me.get_active_note_editor().selection_manager.select_all(me.get_active_note_editor().get_all_visual_notes())
	ce._sync_selection_tools()
	_assert(conform.disabled, "REQ-021: Conform disabled with no scale")

	project.set_scale(2, "dorian")
	_assert(not fold.disabled and not snap.disabled, "REQ-011: toggles enabled once a scale is set")
	_assert(me.scale_context.scale.display_name() == "D Dorian", "scale pushed into the MIDI editor context")
	_assert(not conform.disabled, "REQ-021: Conform enabled with scale and selection")

	snap.button_pressed = true
	_assert(project.get_clip_editor_view("scale_snap"), "pressing snap sets the project flag")
	_assert(me.scale_context.snap_enabled, "snap_enabled reaches the context")
	fold.button_pressed = true
	_assert(project.get_clip_editor_view("fold_to_scale") and me.scale_context.fold_enabled, "fold flag set and pushed")
	project.set_clip_editor_view("scale_snap", false)
	_assert(not snap.button_pressed and not me.scale_context.snap_enabled, "project flag change updates the toggle")

	me.drum_view = true
	_assert(fold.disabled and snap.disabled, "REQ-013: toggles disabled in Drum View")
	_assert(conform.disabled, "Conform stays disabled in Drum View")
	me.drum_view = false
	_assert(not fold.disabled and not snap.disabled, "toggles return after Drum View")

	project.set_scale(0, "none")
	_assert(fold.disabled and snap.disabled and conform.disabled, "scale none disables toggles and Conform again")

	# Rebinding to another project disconnects the old one.
	var other = load("res://data/Project.gd").new()
	ce._bind_project_scale(other)
	_assert(not project.scale_changed.is_connected(ce._on_project_scale_changed), "old project disconnected")
	other.set_scale(5, "blues")
	_assert(me.scale_context.scale.display_name() == "F Blues", "new project drives the context")
	await rig.cleanup()
