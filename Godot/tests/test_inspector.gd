# test_inspector.gd
# Headless tests for the Inspector: sections follow the selection, mixed values read "—", and
# edits go through the model setters as one undo step.
#
# Scripts under test use autoloads, so they are loaded at run time (see test_clip_reverse.gd).
#
# Run: godot --headless --path Godot -s tests/test_inspector.gd -- --test
extends TestBase

var _project: Object
var _recorded: Array = []


func suite_name() -> String:
	return "Inspector"


func run_tests() -> void:
	var project_script: GDScript = load("res://data/Project.gd")
	_project = project_script.new()
	_install_recorder()
	await _test_sections_follow_selection()
	await _test_mixed_values()
	await _test_rename_and_undo()
	await _test_position_edit_and_undo()
	await _test_length_and_offset_clamp()
	await _test_loop_and_mute()
	_test_bbt_round_trip()
	_test_color_override_reset()
	load("res://history/HistoryUtil.gd").test_recorder = Callable()


func _install_recorder() -> void:
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _make_instance(clip_name: String, start: int = 0, duration: int = 3840, shared_clip = null):
	var clip = shared_clip
	if clip == null:
		clip = load("res://data/Clip.gd").new()
		clip.name = clip_name
	var inst = load("res://data/ClipInstance.gd").new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = duration
	return inst


func _typed(instances: Array) -> Array:
	return instances


func _panel():
	var panel = load("res://editor/inspector/InspectorPanel.tscn").instantiate()
	panel.project = _project
	root.add_child(panel)
	await process_frame
	return panel


func _section(panel):
	return panel.get_visible_sections()[0] if not panel.get_visible_sections().is_empty() else null


func _field(section, member: String) -> LineEdit:
	return section.get(member)


func _submit(edit: LineEdit, text: String) -> void:
	edit.text = text
	edit.text_submitted.emit(text)


func _test_sections_follow_selection() -> void:
	var panel = await _panel()
	_assert(panel.get_visible_sections().is_empty(), "no section with nothing selected")
	_assert(panel.get_node("%EmptyLabel").visible, "empty state shows with nothing selected")
	var a = _make_instance("A")
	panel.set_selection([a])
	var sections = panel.get_visible_sections()
	_assert(sections.size() == 1 and sections[0].get_script() == load("res://editor/inspector/ClipInspector.gd"), "ClipInspector shows for a clip")
	_assert(not panel.get_node("%EmptyLabel").visible, "empty state hides while a section shows")
	var first = sections[0]
	panel.set_selection([])
	_assert(panel.get_visible_sections().is_empty() and not first.visible, "section hides when the selection clears")
	panel.set_selection([a])
	_assert(panel.get_visible_sections()[0] == first, "the section instance is reused")
	panel.set_selection(["not a clip"])
	_assert(panel.get_visible_sections().is_empty(), "no section handles unknown objects")
	panel.queue_free()


func _test_mixed_values() -> void:
	var panel = await _panel()
	var a = _make_instance("Kick", 0)
	var b = _make_instance("Snare", 960)
	panel.set_selection([a, b])
	var s = _section(panel)
	_assert(s._name_edit.text == "" and s._name_edit.placeholder_text == "—", "different names show the dash")
	_assert(s._position_edit.text == "" and s._position_edit.placeholder_text == "—", "different positions show the dash")
	_assert(s._length_edit.text == "1.0.000", "equal lengths show a value")
	b.set_position(0)
	_assert(s._position_edit.text == "1.1.000", "refreshes from the model signal, got '%s'" % s._position_edit.text)
	a.muted = false
	b.set_muted(true)
	_assert(s._mute_toggle.text == "—", "mixed mute shows the dash")
	b.set_muted(false)
	_assert(s._mute_toggle.text == "Off", "equal mute shows Off")
	panel.queue_free()


func _test_rename_and_undo() -> void:
	var panel = await _panel()
	var shared = load("res://data/Clip.gd").new()
	shared.name = "Loop"
	var a = _make_instance("", 0, 3840, shared)
	var b = _make_instance("", 3840, 3840, shared)
	var other = _make_instance("Other")
	panel.set_selection([a, b, other])
	var s = _section(panel)
	_recorded.clear()
	_submit(s._name_edit, "Renamed")
	_assert(shared.name == "Renamed" and other.clip.name == "Renamed", "rename applies to every selected clip")
	_assert(_recorded.size() == 1, "rename is one history entry, got %d" % _recorded.size())
	_recorded[0].undo()
	_assert(shared.name == "Loop" and other.clip.name == "Other", "undo restores every name")
	_assert(s._name_edit.text == "", "field refreshes after undo (names differ again)")
	panel.queue_free()


func _test_position_edit_and_undo() -> void:
	var panel = await _panel()
	var a = _make_instance("A", 0)
	var b = _make_instance("B", 3840)
	panel.set_selection([a])
	var s = _section(panel)
	_assert(s._position_edit.text == "1.1.000", "position of tick 0 reads 1.1.000")
	_recorded.clear()
	_submit(s._position_edit, "3.2.240")
	var expected := 2 * 3840 + 960 + 240
	_assert(a.start_ticks == expected, "typed position moves the clip: %d vs %d" % [a.start_ticks, expected])
	_assert(_recorded.size() == 1, "move is one history entry")
	_assert(s._position_edit.text == "3.2.240", "field shows the new position")
	_recorded[0].undo()
	_assert(a.start_ticks == 0 and s._position_edit.text == "1.1.000", "undo restores position and field")
	_submit(s._position_edit, "garbage")
	_assert(a.start_ticks == 0, "invalid text leaves the clip alone")
	panel.set_selection([a, b])
	_recorded.clear()
	_submit(s._position_edit, "5.1.000")
	_assert(a.start_ticks == 4 * 3840 and b.start_ticks == 4 * 3840, "multi-selection moves all to the typed position")
	_assert(_recorded.size() == 1 and _recorded[0].get_script() == load("res://history/commands/MacroCommand.gd"), "multi-edit is one macro entry")
	_recorded[0].undo()
	_assert(a.start_ticks == 0 and b.start_ticks == 3840, "one undo restores all")
	panel.queue_free()


func _test_length_and_offset_clamp() -> void:
	var panel = await _panel()
	var a = _make_instance("A", 0, 3840)
	a.clip.type = 0  # AUDIO
	a.clip.content_length_ticks = 7680
	panel.set_selection([a])
	var s = _section(panel)
	_assert(s._length_edit.text == "1.0.000", "length of one bar reads 1.0.000, got '%s'" % s._length_edit.text)
	_submit(s._length_edit, "0.2")
	_assert(a.duration_ticks == 1920, "length accepts beats: %d" % a.duration_ticks)
	_submit(s._length_edit, "9")
	_assert(a.duration_ticks == 7680, "audio length is limited to the source: %d" % a.duration_ticks)
	_submit(s._offset_edit, "1.0.000")
	_assert(a.clip_offset == 3840, "offset set")
	_assert(a.duration_ticks == 7680, "setting offset keeps length")
	panel.queue_free()


func _test_loop_and_mute() -> void:
	var panel = await _panel()
	var a = _make_instance("A", 0, 3840)
	panel.set_selection([a])
	var s = _section(panel)
	_assert(not s._loop_start_edit.editable, "loop fields are read-only while looping is off")
	_recorded.clear()
	s._loop_toggle.button_pressed = true
	_assert(a.loop_enabled and _recorded.size() == 1, "loop toggle enables looping as one entry")
	_assert(s._loop_start_edit.editable and s._loop_toggle.text == "On", "loop fields unlock")
	_submit(s._loop_length_edit, "0.2")
	_assert(a.loop_length_ticks == 1920, "loop length edit")
	s._mute_toggle.button_pressed = true
	_assert(a.muted, "mute toggle mutes")
	_recorded.back().undo()
	_assert(not a.muted and s._mute_toggle.text == "Off", "undo unmutes and refreshes")
	panel.queue_free()


func _test_bbt_round_trip() -> void:
	var bbt: GDScript = load("res://editor/inspector/InspectorBbt.gd")
	for t in [0, 240, 960, 3840, 3840 * 7 + 960 * 2 + 17]:
		var text: String = bbt.format_position(_project, t)
		_assert(bbt.parse_position(_project, text) == t, "position %d round-trips via '%s'" % [t, text])
		var d: String = bbt.format_duration(_project, t, 0)
		_assert(bbt.parse_duration(_project, d, 0) == t, "duration %d round-trips via '%s'" % [t, d])
	_assert(bbt.parse_duration(_project, "0.9", 0) == -1, "a beat past the bar is refused in 4/4")
	_assert(bbt.parse_position(_project, "0.1.0") == -1, "bar 0 is refused")


func _test_color_override_reset() -> void:
	var a = _make_instance("A")
	a.color_override = Color.RED
	var changed := [0]
	a.instance_modified.connect(func(): changed[0] += 1)
	a.set_color_override(Color.TRANSPARENT)
	_assert(a.color_override.a == 0.0 and changed[0] == 1, "set_color_override clears and notifies")
	var clip = a.clip
	var fired := [0]
	clip.clip_modified.connect(func(): fired[0] += 1)
	clip.set_color(Color.GREEN)
	clip.set_color(Color.GREEN)
	_assert(clip.color == Color.GREEN and fired[0] == 1, "Clip.set_color notifies once")
