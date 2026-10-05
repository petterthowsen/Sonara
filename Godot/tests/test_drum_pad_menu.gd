# test_drum_pad_menu.gd
# Headless tests for the Drum Machine pad context menu (spec 020 phase 4).
# Run: godot --headless --path Godot -s tests/test_drum_pad_menu.gd -- --test
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
	return "Drum pad menu"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_drag_script = load("res://devices/DeviceDrag.gd")
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	await _test_menu()


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


func _test_menu() -> void:
	var s: Dictionary = await _setup([36, 38, 40])
	var drum: Object = s.drum
	var pads: Dictionary = s.pads
	var menu: Node = (load("res://devices/container/DrumPadContextMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await process_frame
	menu.bind_to_pad(drum, pads[36])
	var others: Array = menu.other_pads()
	_assert(others.size() == 2 and others[0] == pads[38] and others[1] == pads[40], "lists only the other occupied pads, by note")
	_assert(menu.pad_label(pads[38]).begins_with(Midi.midi_to_note_name(38) + " · "), "entries read 'note · name'")
	# Choke targets: ticking an entry writes to this pad.
	var targets_popup: PopupMenu = menu._targets_button.get_popup()
	menu._fill_menu(menu._targets_button, true)
	_assert(targets_popup.item_count == 2 and not targets_popup.is_item_checked(0), "targets list starts unchecked")
	menu._on_item_pressed(0, true)
	_assert(pads[36].choke_targets.has(pads[38].id), "a targets toggle writes this pad's targets")
	menu._fill_menu(menu._targets_button, true)
	_assert(targets_popup.is_item_checked(0), "the targets list shows the stored target")
	# Choked by: ticking an entry writes to the other pad.
	var by_popup: PopupMenu = menu._choked_by_button.get_popup()
	menu._fill_menu(menu._choked_by_button, false)
	_assert(not by_popup.is_item_checked(0), "pad 38 does not choke 36 yet")
	menu._on_item_pressed(1, false)
	_assert(pads[40].choke_targets.has(pads[36].id) and not pads[36].choke_targets.has(pads[40].id), "a choked-by toggle writes the other pad's targets")
	menu._fill_menu(menu._choked_by_button, false)
	_assert(by_popup.is_item_checked(1), "choked-by shows the derived relation")
	# Rename and color reach the model.
	menu._on_label_changed("Boom")
	_assert(pads[36].get_display_name() == "Boom", "rename reaches the pad")
	var color := Color(0.2, 0.4, 0.6)
	menu._on_color_changed(color)
	_assert(drum.slot_color(_device_instance_script.pad_slot_key(36)).is_equal_approx(color), "color reaches the slot color")
	menu.queue_free()
	s.view.queue_free()
