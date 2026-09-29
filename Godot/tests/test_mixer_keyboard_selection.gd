# test_mixer_keyboard_selection.gd
# Headless tests for mixer selection: Shift-click range, arrow-key navigation, fader nudge and
# dragging several selected strips at once.
# MixerChannel is not named here: autoload-dependent classes only compile when loaded at runtime.
# Run: godot --headless --path Godot -s tests/test_mixer_keyboard_selection.gd -- --test
extends TestBase

var _mixer: Object
var _project: Object
var _chs: Array = []


func suite_name() -> String:
	return "Mixer keyboard and multi-selection tests"


func run_tests() -> void:
	await _setup()
	_test_range_select()
	_test_adjacent_select()
	_test_volume_nudge()
	await _test_multi_drag_reorder()


func _setup() -> void:
	_project = (load("res://data/Project.gd") as GDScript).new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	_mixer.size = Vector2(1400, 600)
	root.add_child(_mixer)
	_mixer._on_project_opened(_project)
	for n in ["A", "B", "C", "D"]:
		_chs.append(_project.create_instrument_track(n).channel)
	await process_frame
	await process_frame


func _test_range_select() -> void:
	_mixer.select_channel(_chs[0])
	_mixer.click_select_channel(_chs[2], false, true)
	_assert(_mixer.selection.size() == 3, "shift-click selects A..C: %d" % _mixer.selection.size())
	_assert(_mixer.focused_channel == _chs[0], "anchor stays focused")
	_mixer.click_select_channel(_chs[3], false, true)
	_assert(_mixer.selection.size() == 4, "shift-click re-aims the range")


func _test_adjacent_select() -> void:
	_mixer.select_channel(_chs[1])
	_mixer._select_adjacent(1)
	_assert(_mixer.selection == [_chs[2]], "right selects next")
	_mixer._select_adjacent(-1)
	_mixer._select_adjacent(-1)
	_assert(_mixer.selection == [_chs[0]], "left selects previous")


func _test_volume_nudge() -> void:
	_mixer.select_channel(_chs[0])
	_mixer.select_channel(_chs[1], true)
	var a0: float = _chs[0].volume
	var b0: float = _chs[1].volume
	_mixer._nudge_volume(1.0)
	_assert(is_equal_approx(_chs[0].volume, a0 + 1.0) and is_equal_approx(_chs[1].volume, b0 + 1.0), "nudge moves every selected channel")


func _test_multi_drag_reorder() -> void:
	_mixer.select_channel(_chs[0])
	_mixer.select_channel(_chs[1], true)
	var drag: Object = (load("res://mixer/MixerChannelDrag.gd") as GDScript).new(_mixer.find_mixer_channel_ui_for_channel(_chs[0]), _chs[0], null)
	drag.channels = _mixer.get_strip_drag_channels(_chs[0])
	_assert(drag.channels == [_chs[0], _chs[1]], "drag carries both selected strips")
	var target: Object = (load("res://mixer/MixerChannelDropTarget.gd") as GDScript).new()
	target.kind = target.Kind.REORDER
	target.after_sibling = _chs[3]
	target.commit(_mixer, drag)
	await process_frame
	var order: Array = []
	for child in _mixer.left_channels.get_children():
		if child.is_in_group("mixer_channel") and child.channel:
			order.append(child.channel.name)
	_assert(order == ["C", "D", "A", "B"], "A,B moved after D: %s" % str(order))
