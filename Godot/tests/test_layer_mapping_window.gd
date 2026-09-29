# test_layer_mapping_window.gd
# Headless smoke tests for the Layer mapping window (docs/specs/006-layer-note-mapping):
# one window per Layer (REQ-008), piano tints / canvas state from the slot maps (REQ-010),
# edits going through undo (REQ-011, REQ-012, REQ-015), and closing when the Layer is removed.
# Pointer gestures and audio are checked live.
#
# Project and DeviceInstance reference autoloads by bare name, so they're load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_layer_mapping_window.gd -- --test
extends TestBase

const LAYER_ID := "sonara.builtin.layer"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _window_script: GDScript


func suite_name() -> String:
	return "Layer mapping window tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_window_script = load("res://devices/container/layer_mapping/LayerMappingWindow.gd")
	await _test_one_window_per_layer()
	await _test_state_and_edits()
	await _test_closes_when_layer_removed()
	await _test_slot_row_out_toggle()
	await _test_slot_row_rename()
	await _test_slot_row_knob_follows_out()
	await _test_slot_row_name_width()
	await _test_out_resets_slot_volume()


func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


func _layer(names: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var layer := _device(ch, LAYER_ID, "Layer")
	ch.add_device(layer)
	var slots: Array = []
	for n in names:
		var slot := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		slot.name = n
		ch.add_device(slot, -1, layer)
		slots.append(slot)
	return {"project": project, "channel": ch, "layer": layer, "slots": slots}


func _map(pairs: Dictionary) -> PackedByteArray:
	var map := LayerNoteMap.empty()
	for input in pairs:
		map[input] = pairs[input]
	return map


func _test_one_window_per_layer() -> void:
	var d := _layer(["Kick"])
	var w1: Window = _window_script.open_for(d.layer)
	await process_frame
	var w2: Window = _window_script.open_for(d.layer)
	_assert(w1 != null and w1 == w2, "REQ-008: opening twice returns the same window")
	w1.queue_free()
	await process_frame
	var w3: Window = _window_script.open_for(d.layer)
	_assert(w3 != null and w3 != w1, "a closed window is replaced by a new one")
	w3.queue_free()
	await process_frame


func _test_state_and_edits() -> void:
	var d := _layer(["Kick", "Snare", "Pad"])
	d.slots[0].set_slot_note_map(_map({36: 36}))
	d.slots[1].set_slot_note_map(_map({36: 38, 37: 40}))
	var w: Window = _window_script.open_for(d.layer)
	await process_frame
	w._slot_list.select(1)
	w._on_slot_selected(1)

	var input_map: NoteMap = w._input_piano.note_map
	_assert(input_map.get_name(36) == "Kick + Snare", "REQ-010: overlapping input names both slots (got '%s')" % input_map.get_name(36))
	_assert(input_map.get_name(37) == "Snare", "REQ-010: input 37 belongs to Snare")
	_assert(not input_map.has_entry(60), "full-map Pad adds no input entries")
	var output_map: NoteMap = w._output_piano.note_map
	_assert(output_map.has_entry(38) and output_map.has_entry(40) and not output_map.has_entry(36), "REQ-009: output piano highlights the selected slot's outputs")
	var canvas_slots: Array = w._canvas.slots
	_assert(canvas_slots.size() == 3 and canvas_slots[1].selected and not canvas_slots[0].selected, "canvas marks the selected slot")

	# Connect a range from the selection (REQ-011). Headless there's no editor history, so the
	# window's edits apply directly; model-level undo is covered in test_layer_note_map.gd.
	w._on_slot_selected(2)  # Pad, full map
	w._set_selection(PackedInt32Array([48, 49, 50]))
	w._apply(d.slots[2], LayerNoteMap.connect_range(d.slots[2].slot_note_map, w._selection, 60), "Connect Notes")
	var pairs := {}
	for input in LayerNoteMap.inputs(d.slots[2].slot_note_map):
		pairs[input] = d.slots[2].slot_note_map[input]
	_assert(pairs == {48: 60, 49: 61, 50: 62}, "REQ-011: range connect on a full map zones it (got %s)" % pairs)

	# Shift the selection up an octave.
	w._shift_selection(12)
	_assert(LayerNoteMap.output_of(d.slots[2].slot_note_map, 60) == 60 and LayerNoteMap.output_of(d.slots[2].slot_note_map, 48) == -1, "shift moves inputs and keeps outputs")
	_assert(w._selection == PackedInt32Array([60, 61, 62]), "selection follows the shift")

	# Distribute is one undo step (REQ-015): one command per changed slot, run as a macro.
	var result: Dictionary = LayerNoteMap.distribute(w._maps())
	var cmds: Array = w._commands_for(result.maps, "Distribute Layers")
	_assert(cmds.size() == 2, "Distribute changes Snare and Pad only (got %d commands)" % cmds.size())
	var hist: Object = load("res://history/CommandHistory.gd").new()
	var typed: Array[Command] = []
	typed.assign(cmds)
	hist.execute(load("res://history/commands/MacroCommand.gd").new("Distribute Layers", typed))
	_assert(LayerNoteMap.output_of(d.slots[0].slot_note_map, 36) == 36, "kick at 36")
	_assert(LayerNoteMap.output_of(d.slots[1].slot_note_map, 37) == 38 and LayerNoteMap.output_of(d.slots[1].slot_note_map, 38) == 40, "snare at 37–38")
	_assert(LayerNoteMap.output_of(d.slots[2].slot_note_map, 39) == 60, "pad at 39–41")
	hist.undo()
	_assert(LayerNoteMap.output_of(d.slots[1].slot_note_map, 36) == 38 and LayerNoteMap.output_of(d.slots[2].slot_note_map, 60) == 60, "REQ-015: one undo reverts every slot")
	w._on_distribute()
	_assert(LayerNoteMap.output_of(d.slots[2].slot_note_map, 39) == 60, "the Distribute button applies the same result")

	# Clear / Reset (REQ-012).
	w._on_slot_selected(0)
	w._on_clear()
	_assert(LayerNoteMap.inputs(d.slots[0].slot_note_map).is_empty(), "REQ-012: clear empties the slot")
	w._on_reset()
	_assert(LayerNoteMap.is_full(d.slots[0].slot_note_map), "REQ-012: reset restores the full map")
	w.queue_free()
	await process_frame


func _test_closes_when_layer_removed() -> void:
	var d := _layer(["Kick"])
	var w: Window = _window_script.open_for(d.layer)
	await process_frame
	d.channel.remove_device_instance(d.layer)
	await process_frame
	_assert(not is_instance_valid(w) or w.is_queued_for_deletion(), "REQ-008: removing the Layer closes its window")
	await process_frame


func _test_slot_row_out_toggle() -> void:
	var d := _layer(["Kick"])
	var row: Control = load("res://devices/container/LayerSlotRow.gd").new()
	root.add_child(row)
	row.setup(d.layer, d.slots[0])
	await process_frame
	_assert(not row._out.disabled, "REQ-007: OUT enabled while the Layer is first on the channel")
	var fx := _device(d.channel, "sonara.builtin.delay", "Delay")
	d.channel.add_device(fx, 0)
	_assert(row._out.disabled and row._out.tooltip_text.contains("first device"), "REQ-007: OUT disabled with a tooltip when a device sits before the Layer")
	d.channel.move_device(1, 0)
	_assert(not row._out.disabled, "REQ-007: moving the Layer to the front re-enables OUT")
	row._out.button_pressed = true
	_assert(d.slots[0].slot_separate_out, "toggling OUT turns the slot's separate output on")
	_assert(d.project.get_channel_children(d.channel).size() == 1, "and creates its return")
	row.queue_free()
	await process_frame


func _test_slot_row_rename() -> void:
	var d := _layer(["PolySynth"])
	var row: Control = load("res://devices/container/LayerSlotRow.gd").new()
	root.add_child(row)
	row.setup(d.layer, d.slots[0])
	await process_frame
	_assert(row._name.get_value() == "PolySynth", "row shows the slot name")
	row._on_name_edited("Snare")
	_assert(d.slots[0].name == "Snare" and row._name.get_value() == "Snare", "REQ-017: inline rename renames the slot")
	d.slots[0].set_name("Rim")
	_assert(row._name.get_value() == "Rim", "row follows renames from elsewhere")
	row.queue_free()
	await process_frame


func _test_slot_row_knob_follows_out() -> void:
	var d := _layer(["Snare"])
	var row: Control = load("res://devices/container/LayerSlotRow.gd").new()
	root.add_child(row)
	row.setup(d.layer, d.slots[0])
	await process_frame
	_assert(is_equal_approx(row._knob.max_value, 1.0), "knob drives the slot volume while OUT is off")
	d.slots[0].set_slot_separate_out(true)
	var ret: Object = d.project.get_channel_by_id(d.slots[0].return_channel_id)
	_assert(row._return == ret and is_equal_approx(row._knob.value, ret.volume), "knob shows the return channel volume while OUT is on")
	row._knob.value = -6.0  # emits value_changed like a drag
	_assert(is_equal_approx(ret.volume, -6.0), "turning the knob sets the channel volume (got %s)" % ret.volume)
	_assert(is_equal_approx(d.slots[0].slot_volume, 0.5), "slot volume untouched")
	ret.set_volume(-12.0)
	_assert(is_equal_approx(row._knob.value, -12.0), "knob follows the mixer fader")
	d.slots[0].set_slot_separate_out(false)
	_assert(row._return == null and is_equal_approx(row._knob.value, 0.5), "OUT off: knob back on the slot volume")
	row.queue_free()
	await process_frame


func _test_slot_row_name_width() -> void:
	var d := _layer(["Kick"])
	var row: Control = load("res://devices/container/LayerSlotRow.gd").new()
	root.add_child(row)
	row.setup(d.layer, d.slots[0])
	await process_frame
	var short_width: float = row._name.custom_minimum_size.x
	d.slots[0].set_name("Orchestral Bass Drum Long Name")
	await process_frame
	_assert(row._name.custom_minimum_size.x > short_width + 50.0, "name widens for long names (%s → %s)" % [short_width, row._name.custom_minimum_size.x])
	_assert(row.get_combined_minimum_size().x > row._name.custom_minimum_size.x, "row grows to fit name + controls")
	row.queue_free()
	await process_frame


func _test_out_resets_slot_volume() -> void:
	var d := _layer(["Snare"])
	var row: Control = load("res://devices/container/LayerSlotRow.gd").new()
	root.add_child(row)
	row.setup(d.layer, d.slots[0])
	await process_frame
	d.slots[0].set_slot_volume(0.3)
	row._out.button_pressed = true
	_assert(d.slots[0].slot_separate_out and is_equal_approx(d.slots[0].slot_volume, 0.5), "OUT on resets the slot volume to unity (got %s)" % d.slots[0].slot_volume)
	row._out.button_pressed = false
	_assert(not d.slots[0].slot_separate_out and is_equal_approx(d.slots[0].slot_volume, 0.5), "OUT off leaves the slot volume at unity")
	row.queue_free()
	await process_frame
