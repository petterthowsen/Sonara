# Channel pan state: setters, mode transitions, undo snapshots and persistence (pan-modes spec).
extends TestBase

# Channel references autoloads by bare name, so it is load()ed rather than named (see test_note_map.gd).
var _ch: GDScript


func suite_name() -> String:
	return "Channel pan"


func run_tests() -> void:
	_ch = load("res://data/Channel.gd")
	_test_defaults()
	_test_setters()
	_test_transitions()
	_test_dual_round_trip()
	_test_undo()
	_test_json_round_trip()
	_test_migration()
	_test_stage_item()


func _test_defaults() -> void:
	var c = _ch.new(2)
	_assert(c.pan_mode == _ch.PanMode.STEREO_BALANCE, "default mode is balance")
	_assert(c.pan == 0.0 and c.pan_width == 1.0, "default position 0, width 1")


func _test_setters() -> void:
	var c = _ch.new(2)
	var emitted := [0]
	c.pan_changed.connect(func(_l, _r): emitted[0] += 1)
	c.set_pan(0.5)
	_assert(c.pan == 0.5, "set_pan stores position in balance")
	c.set_pan(3.0)
	_assert(c.pan == 1.0, "set_pan clamps")
	c.set_pan_width(-2.0)
	_assert(c.pan_width == -1.0, "set_pan_width clamps to -1")
	c.set_pan_dual(-0.5, 0.25)
	_assert(c.pan_left == -0.5 and c.pan_right == 0.25, "set_pan_dual stores handles")
	_assert(emitted[0] == 4, "each setter emits pan_changed")


func _test_transitions() -> void:
	var c = _ch.new(2)
	c.set_pan(0.5)
	c.set_pan_mode(_ch.PanMode.STEREO_COMBINED)
	_assert(c.pan == 0.5, "balance -> combined keeps position")
	c.set_pan_width(0.25)
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	_assert(is_equal_approx(c.pan_left, 0.25) and is_equal_approx(c.pan_right, 0.75), "combined -> dual uses pos -/+ width")
	c.set_pan_mode(_ch.PanMode.STEREO_BALANCE)
	_assert(is_equal_approx(c.pan, 0.5), "dual -> balance takes midpoint")
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	_assert(is_equal_approx(c.pan_left, -0.5) and is_equal_approx(c.pan_right, 1.0), "balance -> dual assumes width 1, clamped")
	c.set_pan_mode(_ch.PanMode.MONO)
	_assert(is_equal_approx(c.pan, 0.25), "dual -> mono takes midpoint")


func _test_dual_round_trip() -> void:
	var c = _ch.new(2)
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	c.set_pan_dual(-1.0, 0.2)
	c.set_pan_mode(_ch.PanMode.STEREO_COMBINED)
	_assert(is_equal_approx(c.pan, -0.4) and is_equal_approx(c.pan_width, 0.6), "dual -1/+0.2 -> combined -0.4 / w0.6")
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	_assert(is_equal_approx(c.pan_left, -1.0) and is_equal_approx(c.pan_right, 0.2), "round trip back to dual")


func _test_undo() -> void:
	var c = _ch.new(2)
	c.set_pan_dual(-1.0, 0.2)
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	var before = c.get_pan_state()
	var mode_cmd := PropertyCommand.new("Pan Mode", c, "set_pan_state", before,
		_ch.convert_pan_state(before, _ch.PanMode.STEREO_COMBINED))
	mode_cmd.do()
	_assert(c.pan_mode == _ch.PanMode.STEREO_COMBINED, "mode change applied")
	mode_cmd.undo()
	_assert(c.get_pan_state() == before, "undo restores mode and values exactly")
	mode_cmd.do()
	_assert(c.pan_mode == _ch.PanMode.STEREO_COMBINED, "redo re-applies")

	var drag := PropertyCommand.new("Set Pan", c, "set_pan_state", c.get_pan_state(), c.get_pan_state())
	drag.set_mergeable(true)
	_assert(not mode_cmd.can_merge(drag) and not drag.can_merge(mode_cmd), "drag and mode change never merge")


func _test_json_round_trip() -> void:
	for mode in _ch.PanMode.values():
		var c = _ch.new(2)
		c.pan_mode = mode
		c.pan = -0.3
		c.pan_width = 0.6
		c.pan_left = -0.9
		c.pan_right = 0.1
		var r = _ch.from_json(c.to_json())
		_assert(r.get_pan_state() == c.get_pan_state(), "round trip in %s" % _ch.PanMode.keys()[mode])


func _test_migration() -> void:
	var old = _ch.from_json({"id": 2, "pan_mode": "STEREO_COMBINED", "pan": 0.3})
	_assert(old.pan_mode == _ch.PanMode.STEREO_BALANCE and is_equal_approx(old.pan, 0.3), "old combined -> balance")
	var dual = _ch.from_json({"id": 2, "pan_mode": "STEREO_DUAL", "pan_left": -1.0, "pan_right": 0.2})
	_assert(dual.pan_mode == _ch.PanMode.STEREO_DUAL and is_equal_approx(dual.pan_right, 0.2), "old dual stays dual")


## A PanControl (load()ed: it needs the autoloads) built like the one in MixerChannel.tscn.
func _make_pan() -> Control:
	var pan := PanelContainer.new()
	var single := HorSlider.new()
	single.name = "HSlider"
	pan.add_child(single)
	var dual := HDualSlider.new()
	dual.name = "DualPanSlider"
	pan.add_child(dual)
	var popup := PopupMenu.new()
	popup.name = "PanModePopup"
	for i in 4:
		popup.add_check_item("mode", i)
	pan.add_child(popup)
	var stage_button := Button.new()
	stage_button.name = "StageButton"
	pan.add_child(stage_button)
	var stage_menu := PopupMenu.new()
	stage_menu.name = "StageMenu"
	pan.add_child(stage_menu)
	pan.set_script(load("res://mixer/PanControl.gd"))
	root.add_child(pan)
	return pan


## The Stage item is in the pan mode menu only for instrument, audio and group channels; in Stage mode the
## sliders give way to the Stage button, and the menu change is one undo step.
func _test_stage_item() -> void:
	var project = load("res://data/Project.gd").new()
	var pan = _make_pan()
	var inst = project.create_channel("Inst", _ch.ChannelType.INSTRUMENT)
	pan.bind_to_channel(inst)
	_assert(pan.offers_stage(), "instrument channel offers Stage")
	var bus = project.create_channel("Bus", _ch.ChannelType.BUS)
	pan.bind_to_channel(bus)
	_assert(not pan.offers_stage(), "bus channel hides Stage")
	var group = project.create_channel("Group", _ch.ChannelType.GROUP)
	pan.bind_to_channel(group)
	_assert(pan.offers_stage(), "group channel offers Stage")
	pan.bind_to_channel(inst)
	_assert(pan.offers_stage(), "Stage item comes back for an instrument channel")
	var button: Button = pan.get_node("StageButton")
	_assert(not button.visible, "no Stage button outside Stage mode")
	var recorded: Array = []
	var history_util = load("res://history/HistoryUtil.gd")  # references an autoload: load()ed
	history_util.set("test_recorder", func(cmd): recorded.append(cmd))
	pan.get_node("PanModePopup").id_pressed.emit(_ch.PanMode.STAGE)
	_assert(recorded.size() == 1, "the mode change is one command")
	_assert(inst.pan_mode == _ch.PanMode.STAGE, "choosing Stage makes the channel a stage source")
	_assert(button.visible and not pan.get_node("HSlider").visible, "Stage mode shows the button, not the slider")
	recorded[0].undo()
	_assert(inst.pan_mode == _ch.PanMode.STEREO_BALANCE and not button.visible, "undo leaves Stage")
	recorded[0].do()
	_assert(inst.pan_mode == _ch.PanMode.STAGE, "redo re-enters Stage")
	pan.get_node("PanModePopup").id_pressed.emit(_ch.PanMode.MONO)
	_assert(inst.pan_mode == _ch.PanMode.MONO, "leaving Stage to Mono")
	# Right-click menu on the Stage button: Leave Stage is one undoable command.
	inst.set_pan_mode(_ch.PanMode.STAGE)
	recorded.clear()
	pan.get_node("StageMenu").id_pressed.emit(pan.STAGE_MENU_LEAVE)
	_assert(recorded.size() == 1 and inst.pan_mode == _ch.PanMode.MONO, "Leave Stage restores the previous mode in one command")
	recorded[0].undo()
	_assert(inst.pan_mode == _ch.PanMode.STAGE, "undo returns to Stage")
	history_util.set("test_recorder", Callable())
	button.pressed.emit()  # harmless while the Stage view doesn't exist
	pan.queue_free()
