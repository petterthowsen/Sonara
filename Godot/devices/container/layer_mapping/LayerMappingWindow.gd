## Layer mapping window (docs/specs/006-layer-note-mapping): edits each Layer slot's note map.
##
## Layout: slot list | [input piano][connections][output piano] in one scroll area (shared
## LaneLayout, so both pianos scroll and zoom together) | toolbar and status below.
##
## Selecting inputs: click a key (plain = select it, Shift = range, Ctrl = toggle), or drag across
## keys. Connecting: drag from the input piano and release over an output key; the selected inputs
## map one to one onto consecutive outputs from that key. Delete disconnects, Up/Down shift by a
## semitone (Shift: an octave). Clicks audition: input keys through the whole Layer, output keys
## on the selected slot only (REQ-013).
##
## Every edit replaces one slot's map through DeviceInstance.set_slot_note_map, wrapped in a
## PropertyCommand (one undo step); Resolve/Distribute batch theirs in one MacroCommand.
class_name LayerMappingWindow extends Window

const MIN_ROW_HEIGHT := 8.0
const MAX_ROW_HEIGHT := 40.0
const AUDITION_VELOCITY := 100

## Open windows by Layer instance id (one per Layer, REQ-008).
static var _open: Dictionary = {}

var layer: DeviceInstance = null
var _channel: Channel = null
var _project: Project = null
var _selected_slot := 0
var _selection := PackedInt32Array()
var _anchor := -1

var _layout: LaneLayout = LaneLayout.chromatic(14.0)
var _slot_list: ItemList
var _scroll: ScrollContainer
var _input_piano: VPiano
var _output_piano: VPiano
var _canvas: LayerMappingCanvas
var _status: Label
var _bound_slots: Array[DeviceInstance] = []

## Input-piano press state: "select" (drag extends the selection) or "connect" (drag a selection
## onto the output piano), and the input key the press started on.
var _drag_mode := ""
var _drag_start := -1
var _audition_input := -1
var _audition_output := -1
var _audition_slot: DeviceInstance = null


## Open (or focus) the mapping window for `p_layer`.
static func open_for(p_layer: DeviceInstance) -> LayerMappingWindow:
	if p_layer == null:
		return null
	var existing: LayerMappingWindow = _open.get(p_layer.id)
	if is_instance_valid(existing):
		existing.grab_focus()
		return existing
	var window := LayerMappingWindow.new()
	window.layer = p_layer
	var host: Node = Sonara.editor if Sonara.editor else Engine.get_main_loop().root
	host.add_child(window)
	window.popup_centered()
	return window


func _ready() -> void:
	Hotkeys.set_context(self, "layer_mapping")
	title = "Layer Mapping — %s" % layer.get_display_name()
	size = Vector2i(640, 640)
	min_size = Vector2i(480, 360)
	exclusive = false
	transient = false
	unresizable = false
	close_requested.connect(_close)
	_open[layer.id] = self
	_build_ui()
	_bind_model()
	_rebuild_slots()
	_scroll_to_note.call_deferred(60)


func _exit_tree() -> void:
	_stop_auditions()
	_unbind_model()
	if _open.get(layer.id) == self:
		_open.erase(layer.id)


func _close() -> void:
	_stop_auditions()
	queue_free()


# ============================================================================
# UI
# ============================================================================

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	vbox.add_child(body)

	_slot_list = ItemList.new()
	_slot_list.custom_minimum_size = Vector2(140, 0)
	_slot_list.focus_mode = Control.FOCUS_NONE
	_slot_list.item_selected.connect(_on_slot_selected)
	body.add_child(_slot_list)

	var pianos := VBoxContainer.new()
	pianos.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(pianos)

	var headers := HBoxContainer.new()
	pianos.add_child(headers)
	for text in ["Input (what you play)", "", "Output (what the layer gets)"]:
		var l := Label.new()
		l.text = text
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 11)
		headers.add_child(l)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pianos.add_child(_scroll)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 0)
	_scroll.add_child(row)

	_input_piano = VPiano.new()
	_input_piano.layout = _layout
	_input_piano.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_piano.key_pressed.connect(_on_input_pressed)
	_input_piano.key_released.connect(_on_input_released)
	row.add_child(_input_piano)

	_canvas = LayerMappingCanvas.new()
	_canvas.layout = _layout
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_canvas)

	_output_piano = VPiano.new()
	_output_piano.layout = _layout
	_output_piano.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output_piano.key_pressed.connect(_on_output_pressed)
	_output_piano.key_released.connect(_on_output_released)
	row.add_child(_output_piano)

	var toolbar := HFlowContainer.new()
	toolbar.add_theme_constant_override("h_separation", 4)
	vbox.add_child(toolbar)
	_add_button(toolbar, "Clear", "Map no notes to this layer", _on_clear)
	_add_button(toolbar, "Reset", "Play every note unchanged (full map)", _on_reset)
	_add_button(toolbar, "▲", "Shift the selected inputs up a semitone (Shift+Up: an octave)", _shift_selection.bind(1))
	_add_button(toolbar, "▼", "Shift the selected inputs down a semitone (Shift+Down: an octave)", _shift_selection.bind(-1))
	_add_button(toolbar, "Disconnect", "Unmap the selected inputs (Delete)", _disconnect_selection)
	toolbar.add_child(VSeparator.new())
	_add_button(toolbar, "Resolve overlaps", "Shift zoned layers so no input note plays two of them", _on_resolve)
	_add_button(toolbar, "Distribute", "Lay zoned layers out one after another from C1", _on_distribute)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_status)


func _add_button(parent: Control, text: String, tip: String, callback: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	parent.add_child(b)


func _scroll_to_note(note: int) -> void:
	_scroll.scroll_vertical = int(_layout.pitch_to_y_center(note) - _scroll.size.y * 0.5)


# ============================================================================
# MODEL BINDING
# ============================================================================

func _bind_model() -> void:
	_channel = layer.get_channel()
	_project = _channel.get_project() if _channel else null
	layer.child_added.connect(_on_children_changed)
	layer.child_removed.connect(_on_children_changed)
	layer.child_moved.connect(_on_children_changed)
	layer.slots_changed.connect(_refresh)
	if _channel:
		_channel.device_removed.connect(_on_something_removed)
	if _project:
		_project.channel_removed.connect(_on_something_removed)
	# A Layer nested in containers also goes away when an ancestor is removed.
	var parent := layer.get_parent_device()
	while parent:
		parent.child_removed.connect(_on_something_removed)
		parent = parent.get_parent_device()


func _unbind_model() -> void:
	for pair in [
		[layer.child_added, _on_children_changed], [layer.child_removed, _on_children_changed],
		[layer.child_moved, _on_children_changed], [layer.slots_changed, _refresh],
	]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	if _channel and _channel.device_removed.is_connected(_on_something_removed):
		_channel.device_removed.disconnect(_on_something_removed)
	if _project and _project.channel_removed.is_connected(_on_something_removed):
		_project.channel_removed.disconnect(_on_something_removed)
	var parent := layer.get_parent_device()
	while parent:
		if parent.child_removed.is_connected(_on_something_removed):
			parent.child_removed.disconnect(_on_something_removed)
		parent = parent.get_parent_device()
	_bind_slots([])


## Keep slot_changed / name_changed connected on exactly the current slots.
func _bind_slots(slots: Array[DeviceInstance]) -> void:
	for slot in _bound_slots:
		if is_instance_valid(slot):
			if slot.slot_changed.is_connected(_refresh):
				slot.slot_changed.disconnect(_refresh)
			if slot.name_changed.is_connected(_on_slot_renamed):
				slot.name_changed.disconnect(_on_slot_renamed)
	_bound_slots = slots.duplicate()
	for slot in _bound_slots:
		slot.slot_changed.connect(_refresh)
		slot.name_changed.connect(_on_slot_renamed)


## True while the Layer still sits on a channel that is in the project (REQ-008).
func _is_attached() -> bool:
	if _channel == null or _project == null or _project.get_channel_by_id(_channel.id) != _channel:
		return false
	var root := layer
	while root.get_parent_device():
		var parent := root.get_parent_device()
		if not parent.children.has(root):
			return false
		root = parent
	return _channel.devices.has(root)


func _on_something_removed(_a = null, _b = null) -> void:
	if not _is_attached():
		_close()


func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild_slots()


func _on_slot_renamed(_name: String) -> void:
	_rebuild_slots()


func _rebuild_slots() -> void:
	_bind_slots(layer.children)
	_slot_list.clear()
	for slot in layer.children:
		var idx := _slot_list.add_item(slot.get_display_name())
		_slot_list.set_item_custom_fg_color(idx, _slot_color(slot).lightened(0.3))
	_selected_slot = clampi(_selected_slot, 0, maxi(layer.children.size() - 1, 0))
	if not layer.children.is_empty():
		_slot_list.select(_selected_slot)
	_refresh()


func _on_slot_selected(index: int) -> void:
	_stop_auditions()
	_selected_slot = index
	_refresh()


func _current_slot() -> DeviceInstance:
	if _selected_slot < 0 or _selected_slot >= layer.children.size():
		return null
	return layer.children[_selected_slot]


func _slot_color(slot: DeviceInstance) -> Color:
	return layer.slot_color(layer.slot_key_for(slot))


# ============================================================================
# DRAWING STATE
# ============================================================================

## Push maps, colours and the selection to the canvas and both pianos (REQ-009, REQ-010).
func _refresh() -> void:
	if _canvas == null:
		return
	var canvas_slots: Array[Dictionary] = []
	var input_map := NoteMap.new()
	var owners := {}  # input -> Array[DeviceInstance] of zoned slots mapping it
	for i in layer.children.size():
		var slot := layer.children[i]
		canvas_slots.append({"map": slot.slot_note_map, "color": _slot_color(slot), "selected": i == _selected_slot})
		if LayerNoteMap.is_full(slot.slot_note_map):
			continue
		for input in LayerNoteMap.inputs(slot.slot_note_map):
			if not owners.has(input):
				owners[input] = []
			owners[input].append(slot)
	for input in owners:
		var slots: Array = owners[input]
		var names := PackedStringArray()
		for s in slots:
			names.append(s.get_display_name())
		# Overlaps read as "Kick + Snare" in red, so they stand out (REQ-010).
		var color := Color(0.9, 0.2, 0.2) if slots.size() > 1 else _slot_color(slots[0])
		input_map.set_entry(input, " + ".join(names), color)
	_input_piano.note_map = input_map

	var output_map := NoteMap.new()
	var slot := _current_slot()
	if slot and not LayerNoteMap.is_full(slot.slot_note_map):
		for input in LayerNoteMap.inputs(slot.slot_note_map):
			var out: int = slot.slot_note_map[input]
			output_map.set_entry(out, Midi.midi_to_note_name(out), _slot_color(slot))
	_output_piano.note_map = output_map

	_canvas.slots = canvas_slots
	_canvas.selected_inputs = _selection
	_update_status()


func _update_status(extra := "") -> void:
	var slot := _current_slot()
	var text := ""
	if slot == null:
		text = "Add devices to the Layer to map them."
	elif LayerNoteMap.is_full(slot.slot_note_map):
		text = "%s plays all notes unchanged. Select inputs and drag them onto an output key to zone it." % slot.get_display_name()
	else:
		text = "%s: %d input notes mapped." % [slot.get_display_name(), LayerNoteMap.inputs(slot.slot_note_map).size()]
	if not extra.is_empty():
		text += "  " + extra
	_status.text = text


# ============================================================================
# INPUT PIANO: selection, connect drag, audition
# ============================================================================

func _on_input_pressed(note: int, velocity: int) -> void:
	_audition_input_note(note, velocity)
	if _drag_start >= 0:
		# Gliding while the button is held.
		if _drag_mode == "select":
			_set_selection(_range(_anchor, note))
		return
	_drag_start = note
	if Input.is_key_pressed(KEY_SHIFT) and _anchor >= 0:
		_drag_mode = "select"
		_set_selection(_range(_anchor, note))
	elif Input.is_key_pressed(KEY_CTRL):
		_drag_mode = "select"
		var sel := _selection.duplicate()
		var idx := sel.find(note)
		if idx >= 0:
			sel.remove_at(idx)
		else:
			sel.append(note)
		_anchor = note
		_set_selection(sel)
	elif _selection.has(note):
		_drag_mode = "connect"
	else:
		_drag_mode = "select"
		_anchor = note
		_set_selection(PackedInt32Array([note]))


func _on_input_released(_note: int) -> void:
	_stop_input_audition()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _drag_start >= 0:
		var y := _canvas.get_local_mouse_position().y
		_canvas.set_drag(_drag_start if _drag_mode == "connect" or _pointer_over(_output_piano) or _pointer_over(_canvas) else -1, y)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _drag_start >= 0:
			_finish_drag()
		elif mb.pressed and mb.ctrl_pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			_layout.row_height = clampf(_layout.row_height + step, MIN_ROW_HEIGHT, MAX_ROW_HEIGHT)
			set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if Hotkeys.pressed(event, "layers_delete"):
			_disconnect_selection()
			set_input_as_handled()
		elif Hotkeys.pressed(event, "layers_shift_octave_up"):
			_shift_selection(12)
			set_input_as_handled()
		elif Hotkeys.pressed(event, "layers_shift_octave_down"):
			_shift_selection(-12)
			set_input_as_handled()
		elif Hotkeys.pressed(event, "layers_shift_up"):
			_shift_selection(1)
			set_input_as_handled()
		elif Hotkeys.pressed(event, "layers_shift_down"):
			_shift_selection(-1)
			set_input_as_handled()


func _pointer_over(control: Control) -> bool:
	return control.get_global_rect().has_point(control.get_global_mouse_position())


## Released after pressing on the input piano: over an output key, connect the selection.
func _finish_drag() -> void:
	_canvas.set_drag(-1, 0.0)
	_drag_start = -1
	_drag_mode = ""
	if not _pointer_over(_output_piano):
		return
	var out := _output_piano.get_note_at_position(_output_piano.get_local_mouse_position())
	if out < 0 or _selection.is_empty():
		return
	var slot := _current_slot()
	if slot == null:
		return
	var map := LayerNoteMap.connect_note(slot.slot_note_map, _selection[0], out) if _selection.size() == 1 \
		else LayerNoteMap.connect_range(slot.slot_note_map, _selection, out)
	_apply(slot, map, "Connect Notes")


func _set_selection(sel: PackedInt32Array) -> void:
	var sorted := sel.duplicate()
	sorted.sort()
	_selection = sorted
	_canvas.selected_inputs = _selection


func _range(a: int, b: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for n in range(mini(a, b), maxi(a, b) + 1):
		out.append(n)
	return out


# ============================================================================
# EDITS (REQ-011, REQ-012, REQ-014, REQ-015)
# ============================================================================

## Replace `slot`'s map as one undo step.
func _apply(slot: DeviceInstance, map: PackedByteArray, label: String) -> void:
	if map == slot.slot_note_map:
		return
	HistoryUtil.execute_property(label, slot, "set_slot_note_map", slot.slot_note_map, map)


func _on_clear() -> void:
	var slot := _current_slot()
	if slot:
		_apply(slot, LayerNoteMap.empty(), "Clear Layer Mapping")


func _on_reset() -> void:
	var slot := _current_slot()
	if slot:
		_apply(slot, LayerNoteMap.full(), "Reset Layer Mapping")


func _disconnect_selection() -> void:
	var slot := _current_slot()
	if slot and not _selection.is_empty():
		_apply(slot, LayerNoteMap.disconnect_notes(slot.slot_note_map, _selection), "Disconnect Notes")


func _shift_selection(delta: int) -> void:
	var slot := _current_slot()
	if slot == null or _selection.is_empty() or LayerNoteMap.is_full(slot.slot_note_map):
		return
	var map := LayerNoteMap.shift(slot.slot_note_map, _selection, delta)
	if map == slot.slot_note_map:
		_update_status("Can't shift past the keyboard's edge.")
		return
	_apply(slot, map, "Shift Notes")
	var moved := PackedInt32Array()
	for n in _selection:
		moved.append(n + delta)
	_anchor = _anchor + delta if _anchor >= 0 else -1
	_set_selection(moved)


func _on_resolve() -> void:
	_apply_all(LayerNoteMap.resolve_overlaps(_maps()), "Resolve Overlaps")


func _on_distribute() -> void:
	_apply_all(LayerNoteMap.distribute(_maps()), "Distribute Layers")


## One set_slot_note_map command per slot whose map differs from `maps`.
func _commands_for(maps: Array, label: String) -> Array[Command]:
	var cmds: Array[Command] = []
	for i in mini(maps.size(), layer.children.size()):
		var slot := layer.children[i]
		if maps[i] != slot.slot_note_map:
			cmds.append(PropertyCommand.new(label, slot, "set_slot_note_map", slot.slot_note_map, maps[i]))
	return cmds


func _maps() -> Array:
	return layer.children.map(func(s: DeviceInstance) -> PackedByteArray: return s.slot_note_map)


## Apply a Resolve/Distribute result as a single undo step and report skipped slots.
func _apply_all(result: Dictionary, label: String) -> void:
	var cmds := _commands_for(result.maps, label)
	if not cmds.is_empty():
		HistoryUtil.execute_many(label, cmds)
	var zoned := layer.children.filter(func(s: DeviceInstance) -> bool: return not LayerNoteMap.is_full(s.slot_note_map))
	var notes := PackedStringArray()
	if zoned.is_empty():
		notes.append("Every layer plays all notes; zone some first (drag inputs onto outputs).")
	var skipped := PackedStringArray()
	for i in result.skipped:
		skipped.append(layer.children[i].get_display_name())
	if not skipped.is_empty():
		notes.append("Couldn't place: %s (not enough free keys)." % ", ".join(skipped))
	_update_status(" ".join(notes))


# ============================================================================
# AUDITION (REQ-013)
# ============================================================================

func _audition_input_note(note: int, velocity: int) -> void:
	_stop_input_audition()
	if _channel == null:
		return
	_audition_input = note
	MidiManager.send_note_to_channel(_channel.id, note, velocity, true)


func _stop_input_audition() -> void:
	if _audition_input >= 0 and _channel:
		MidiManager.send_note_to_channel(_channel.id, _audition_input, 0, false)
	_audition_input = -1


func _on_output_pressed(note: int, velocity: int) -> void:
	_stop_output_audition()
	var slot := _current_slot()
	if slot == null:
		return
	_audition_output = note
	_audition_slot = slot
	slot.audition_slot(note, velocity, true)


func _on_output_released(_note: int) -> void:
	_stop_output_audition()


func _stop_output_audition() -> void:
	if _audition_output >= 0 and is_instance_valid(_audition_slot):
		_audition_slot.audition_slot(_audition_output, 0, false)
	_audition_output = -1
	_audition_slot = null


func _stop_auditions() -> void:
	_stop_input_audition()
	_stop_output_audition()
