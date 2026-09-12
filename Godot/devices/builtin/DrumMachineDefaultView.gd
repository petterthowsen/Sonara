## Drum Machine panel: 4x4 pad grid paged in steps of 16, focusing one child at a time.
class_name DrumMachineDefaultView extends DeviceView

const PAGE_SIZE := 16
const COLS := 4
const FIRST_NOTE := 36

var _grid: GridContainer = null
var _page_label: Label = null
var _pads: Array[DrumPad] = []
var _base_note: int = FIRST_NOTE
var _selected: DeviceInstance = null


func _get_minimum_size() -> Vector2:
	return Vector2(240, 220)


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	var pager := HBoxContainer.new()
	pager.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(pager)
	var prev := Button.new()
	prev.text = "◀"
	prev.pressed.connect(_on_page.bind(-PAGE_SIZE))
	pager.add_child(prev)
	_page_label = Label.new()
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pager.add_child(_page_label)
	var next := Button.new()
	next.text = "▶"
	next.pressed.connect(_on_page.bind(PAGE_SIZE))
	pager.add_child(next)
	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	root.add_child(_grid)
	for i in range(PAGE_SIZE):
		var pad := DrumPad.new()
		_grid.add_child(pad)
		pad.activated.connect(_on_pad_activated)
		pad.drop_requested.connect(_on_pad_drop)
		_pads.append(pad)


func _on_bind() -> void:
	if not is_node_ready():
		await ready
	if device:
		if not device.child_added.is_connected(_on_children_changed):
			device.child_added.connect(_on_children_changed)
		if not device.child_removed.is_connected(_on_children_changed):
			device.child_removed.connect(_on_children_changed)
		if not device.child_moved.is_connected(_on_children_changed):
			device.child_moved.connect(_on_children_changed)
	_rebuild()


## Highlight the pad whose child is shown in the folder.
func set_focused_child(child: DeviceInstance) -> void:
	_selected = child
	_rebuild()


func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


func _on_page(delta: int) -> void:
	_base_note = clampi(_base_note + delta, 0, 127 - PAGE_SIZE + 1)
	_rebuild()


func _rebuild() -> void:
	if _pads.is_empty():
		return
	var by_note := {}
	if device:
		for child in device.children:
			by_note[child.slot_note] = child
	var end_note := mini(_base_note + PAGE_SIZE - 1, 127)
	if _page_label:
		_page_label.text = "%s – %s" % [Midi.midi_to_note_name(_base_note), Midi.midi_to_note_name(end_note)]
	for i in range(PAGE_SIZE):
		var row := int(i / COLS)
		var col := i % COLS
		var from_bottom := (COLS - 1) - row
		var note := _base_note + from_bottom * COLS + col
		var child: DeviceInstance = by_note.get(note, null)
		if child and not child.slot_changed.is_connected(_on_children_changed):
			child.slot_changed.connect(_on_children_changed)
		if child and not child.loading_state_changed.is_connected(_on_children_changed):
			child.loading_state_changed.connect(_on_children_changed)
		_pads[i].setup(note, child)
		_pads[i].set_selected(child != null and child == _selected)


func _on_pad_activated(note: int) -> void:
	var child := _child_for_note(note)
	if child == null:
		return
	_selected = child
	set_focused_child(child)
	container_child_requested.emit(child)


func _on_pad_drop(note: int, data: Variant) -> void:
	if device == null:
		return
	var channel := _channel()
	await DeviceDropUtil.drop_on_drum_pad(channel, device, note, data, get_tree())
	var child := _child_for_note(note)
	if child:
		_selected = child
		container_child_requested.emit(child)
	_rebuild()


func _child_for_note(note: int) -> DeviceInstance:
	if device == null:
		return null
	for child in device.children:
		if child.slot_note == note:
			return child
	return null


func _channel() -> Channel:
	if device == null or Sonara.editor == null or Sonara.editor.project == null:
		return null
	return Sonara.editor.project.get_channel_by_id(device.channel_id)
