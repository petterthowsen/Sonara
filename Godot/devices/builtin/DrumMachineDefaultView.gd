## Drum Machine panel: 4x4 pad grid paged in steps of 16, focusing one child at a time.
class_name DrumMachineDefaultView extends DeviceView

const PAGE_SIZE := 16
const COLS := 4
const FIRST_NOTE := 36

@onready var _page_label: Label = $Pager/PageLabel
@onready var _grid: GridContainer = $Grid
@onready var _prev_button: Button = $Pager/Prev
@onready var _next_button: Button = $Pager/Next

var _pads: Array[DrumPad] = []
var _base_note: int = FIRST_NOTE
var _selected: DeviceInstance = null
var _sounding_notes: Dictionary = {}


## Keep the pad grid usable beside the parameter list.
func _get_minimum_size() -> Vector2:
	return Vector2(240, 220)


## Wire pager buttons and collect the scene pads.
func _ready() -> void:
	_prev_button.pressed.connect(_on_page.bind(-PAGE_SIZE))
	_next_button.pressed.connect(_on_page.bind(PAGE_SIZE))
	for child in _grid.get_children():
		var pad := child as DrumPad
		if pad == null:
			continue
		pad.activated.connect(_on_pad_activated)
		pad.triggered.connect(_on_pad_triggered)
		pad.released.connect(_on_pad_released)
		pad.drop_requested.connect(_on_pad_drop)
		_pads.append(pad)


## Wire child-list signals and rebuild the current page of pads.
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


## Release any pads still held when the view is hidden.
func _on_view_hidden() -> void:
	for pad in _pads:
		pad.cancel_preview()
	_release_all_sounding()


## Highlight the pad whose child is shown in the folder.
func set_focused_child(child: DeviceInstance) -> void:
	_selected = child
	_rebuild()


## Rebuild pads when children are added, removed, or reordered.
func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


## Page the 4x4 grid by 16 notes.
func _on_page(delta: int) -> void:
	_base_note = clampi(_base_note + delta, 0, 127 - PAGE_SIZE + 1)
	_rebuild()


## Bind each scene pad to the MIDI note and child for the current page.
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
		_pads[i].setup(note, child, device)
		_pads[i].set_selected(child != null and child == _selected)


## Focus the occupied pad and open its child in the device folder.
func _on_pad_activated(note: int) -> void:
	var child := _child_for_note(note)
	if child == null:
		return
	_selected = child
	set_focused_child(child)
	container_child_requested.emit(child)


## Send a note-on to this drum machine's channel at the pad's click velocity.
func _on_pad_triggered(note: int, velocity: int) -> void:
	if _child_for_note(note) == null:
		return
	_sounding_notes[note] = true
	MidiManager.send_note_to_channel(channel_id, note, velocity, true)


## Send a note-off for a pad that was previewed.
func _on_pad_released(note: int) -> void:
	if not _sounding_notes.has(note):
		return
	_sounding_notes.erase(note)
	MidiManager.send_note_to_channel(channel_id, note, 0, false)


## Note-off every pad still held from this view.
func _release_all_sounding() -> void:
	for note in _sounding_notes.keys():
		MidiManager.send_note_to_channel(channel_id, note, 0, false)
	_sounding_notes.clear()


## Load a dropped sample or device onto the pad's MIDI note.
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


## Find the drum-machine child occupying `note`, if any.
func _child_for_note(note: int) -> DeviceInstance:
	if device == null:
		return null
	for child in device.children:
		if child.slot_note == note:
			return child
	return null


## Channel that owns this drum machine.
func _channel() -> Channel:
	if device == null or Sonara.editor == null or Sonara.editor.project == null:
		return null
	return Sonara.editor.project.get_channel_by_id(device.channel_id)
