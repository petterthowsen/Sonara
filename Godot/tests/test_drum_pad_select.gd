# test_drum_pad_select.gd
# Headless tests for Drum Machine pad selection (spec 020 phase 2): click, ctrl-click and
# shift-click across pages, and the group move that follows (see test_drum_pad_move.gd).
# Run: godot --headless --path Godot -s tests/test_drum_pad_select.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"
const CTRL := KEY_MASK_CTRL
const SHIFT := KEY_MASK_SHIFT

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript
var _history_util: GDScript
var _drag_script: GDScript


func suite_name() -> String:
	return "Drum pad select"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_drag_script = load("res://devices/DeviceDrag.gd")
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	await _test_selection()
	await _test_group_move()


func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _pad(ch: Object, drum: Object, note: int) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx.%d" % note, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	var cmd: Object = _add_cmd.new(ch, inst, -1, drum)
	cmd.do()
	return cmd.device_instance


## A Drum Machine with pads on `notes` and its view in the tree.
func _setup(notes: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	var pads: Dictionary = {}
	for n in notes:
		pads[n] = _pad(ch, drum, n)
	var view: Control = (load("res://devices/builtin/DrumMachineDefaultView.tscn") as PackedScene).instantiate()
	root.add_child(view)
	view.bind_to_device(drum)
	await process_frame
	return {"ch": ch, "drum": drum, "pads": pads, "view": view}


func _test_selection() -> void:
	var s: Dictionary = await _setup([36, 37, 38, 39, 60])
	var view: Object = s.view
	view._on_pad_activated(36, 0)
	_assert(view.selected_notes() == [36] and view.primary_note() == 36, "click selects only that pad")
	_assert(s.drum.is_slot_open(_device_instance_script.pad_slot_key(36)), "click opens the slot")
	view._on_pad_activated(38, CTRL)
	_assert(view.selected_notes() == [36, 38] and view.primary_note() == 38, "ctrl-click adds the pad and makes it primary")
	_assert(s.drum.is_slot_open(_device_instance_script.pad_slot_key(38)), "the ctrl-clicked pad's slot opens")
	view._on_pad_activated(36, CTRL)
	_assert(view.selected_notes() == [38], "ctrl-click on a selected pad removes it")
	view._on_pad_activated(36, 0)
	view._on_pad_activated(39, SHIFT)
	_assert(view.selected_notes() == [36, 37, 38, 39] and view.primary_note() == 36, "shift-click selects the range from the primary")
	# Range across pages: the grid shows 36-51, so page up to reach 60.
	view._on_page(16)
	view._on_page(16)
	view._on_pad_activated(60, SHIFT)
	_assert(view.selected_notes().size() == 25 and view.selected_notes().has(60), "shift-click ranges span pages (got %d)" % view.selected_notes().size())
	_assert(view.primary_note() == 36, "shift-click keeps the primary pad")
	view._on_page(-16)
	_assert(view.selected_notes().size() == 25, "paging keeps the selection")
	view.queue_free()


func _test_group_move() -> void:
	var s: Dictionary = await _setup([36, 37, 38, 40])
	var view: Object = s.view
	var drum: Object = s.drum
	var util: GDScript = load("res://devices/DeviceDropUtil.gd")
	var pads: Dictionary = s.pads
	view._on_pad_activated(36, 0)
	view._on_pad_activated(37, CTRL)
	view._on_pad_activated(38, CTRL)
	var group: Array = [pads[36], pads[37], pads[38]]
	var drag: Object = _drag_script.new(null, pads[36], null, group)
	_assert(util.can_drop_on_drum_pad(drag, null, s.ch, drum, 44), "a group may move up a row")
	var recorded: Array = []
	_history_util.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)
	view._on_pad_drop(40 + 4, drag) # delta +8: 36->44, 37->45, 38->46
	_assert(recorded.size() == 1, "the group move is one history entry (got %d)" % recorded.size())
	_assert(pads[36].slot_note == 44 and pads[37].slot_note == 45 and pads[38].slot_note == 46, "the group keeps its spacing")
	_assert(view.selected_notes() == [44, 45, 46] and view.primary_note() == 46, "the selection follows the moved pads")
	# Refusals.
	var group2: Array = [pads[36], pads[37], pads[38]]
	var drag2: Object = _drag_script.new(null, pads[36], null, group2)
	_assert(not util.can_drop_on_drum_pad(drag2, null, s.ch, drum, 40), "a destination held by an unselected pad refuses the move")
	_assert(not util.can_drop_on_drum_pad(drag2, null, s.ch, drum, 126), "a destination past 127 refuses the move")
	_assert(not util.can_drop_on_drum_pad(drag2, null, s.ch, drum, 44), "no shift refuses the move")
	var before: Array = [pads[36].slot_note, pads[37].slot_note, pads[38].slot_note]
	view._on_pad_drop(126, drag2)
	_assert([pads[36].slot_note, pads[37].slot_note, pads[38].slot_note] == before, "a refused drop moves nothing")
	# One undo restores all.
	recorded[0].undo()
	_history_util.test_recorder = Callable()
	_assert(pads[36].slot_note == 36 and pads[37].slot_note == 37 and pads[38].slot_note == 38, "one undo restores every note")
	view.queue_free()
