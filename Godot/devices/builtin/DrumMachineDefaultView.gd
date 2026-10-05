## Drum Machine panel: 4x4 pad grid paged in steps of 16. Clicking a pad, empty or not, opens its
## slot in the device lane (one at a time); the pager's hide button closes it.
class_name DrumMachineDefaultView extends DeviceView

const ICON_HIDE_SLOT: Texture2D = preload("res://assets/icons/chevron-left.svg")

const PAD_MENU_SCENE: PackedScene = preload("res://devices/container/DrumPadContextMenu.tscn")
const PAGE_SIZE := 16
const COLS := 4
const FIRST_NOTE := 36

@onready var _page_label: Label = $Pager/PageLabel
@onready var _grid: GridContainer = $Body/Grid
@onready var _strip: DrumPadStrip = $Body/PadStrip
@onready var _prev_button: Button = $Pager/Prev
@onready var _next_button: Button = $Pager/Next

var _pads: Array[DrumPad] = []
var _pad_menu: DrumPadContextMenu = null
var _base_note: int = FIRST_NOTE
## Hides the open pad slot; visible while one is open.
var _hide_slot_button: Button = null
var _sounding_notes: Dictionary = {}
## Pad selection (view state, not persisted). The primary pad is the one whose slot is open.
var _selected_notes: Array[int] = []
var _primary_note: int = -1
## Notes that held a pad at the last rebuild, to tell a removed pad from an empty selected one.
var _occupied: Dictionary = {}
## True while a group move runs, so the intermediate rebuilds keep the (already shifted) selection.
var _moving: bool = false
## Children whose slot_changed/loading_state_changed are connected. Kept so a child
## removed from the machine gets disconnected instead of dangling (see _sync_child_signals).
var _tracked_children: Array[DeviceInstance] = []


## Keep the pad grid and the pad strip usable beside the parameter list.
func _get_minimum_size() -> Vector2:
	return Vector2(300, 220)


## Wire pager buttons and collect the scene pads.
func _ready() -> void:
	_prev_button.pressed.connect(_on_page.bind(-PAGE_SIZE))
	_next_button.pressed.connect(_on_page.bind(PAGE_SIZE))
	_hide_slot_button = Button.new()
	_hide_slot_button.icon = ICON_HIDE_SLOT
	_hide_slot_button.flat = true
	_hide_slot_button.tooltip_text = "Hide the pad's devices"
	_hide_slot_button.visible = false
	_hide_slot_button.pressed.connect(_on_hide_slot_pressed)
	$Pager.add_child(_hide_slot_button)
	for child in _grid.get_children():
		var pad := child as DrumPad
		if pad == null:
			continue
		pad.activated.connect(_on_pad_activated)
		pad.triggered.connect(_on_pad_triggered)
		pad.released.connect(_on_pad_released)
		pad.drop_requested.connect(_on_pad_drop)
		pad.context_requested.connect(_on_pad_context)
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
		if not device.slots_changed.is_connected(_on_children_changed):
			device.slots_changed.connect(_on_children_changed)
	_rebuild()


## Disconnect the child-list signals connected in _on_bind().
func _on_unbind() -> void:
	if device.child_added.is_connected(_on_children_changed):
		device.child_added.disconnect(_on_children_changed)
	if device.child_removed.is_connected(_on_children_changed):
		device.child_removed.disconnect(_on_children_changed)
	if device.child_moved.is_connected(_on_children_changed):
		device.child_moved.disconnect(_on_children_changed)
	if device.slots_changed.is_connected(_on_children_changed):
		device.slots_changed.disconnect(_on_children_changed)
	for child in _tracked_children:
		if child.slot_changed.is_connected(_on_children_changed):
			child.slot_changed.disconnect(_on_children_changed)
		if child.loading_state_changed.is_connected(_on_children_changed):
			child.loading_state_changed.disconnect(_on_children_changed)
		if child.choke_targets_changed.is_connected(_on_children_changed):
			child.choke_targets_changed.disconnect(_on_children_changed)
	_tracked_children.clear()
	if _strip:
		_strip.unbind()


## Release any pads still held when the view is hidden.
func _on_view_hidden() -> void:
	for pad in _pads:
		pad.cancel_preview()
	_release_all_sounding()


## Note of the pad whose slot is open in the device lane (occupied or empty), or -1.
func _open_note() -> int:
	if device == null:
		return -1
	var keys: PackedStringArray = device.open_slot_keys()
	return DeviceInstance.pad_slot_note(keys[0]) if not keys.is_empty() else -1


func _on_hide_slot_pressed() -> void:
	var note := _open_note()
	if note >= 0:
		device.set_slot_open(DeviceInstance.pad_slot_key(note), false)


## Rebuild pads when children are added, removed, or reordered.
func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


## Page the 4x4 grid by 16 notes.
func _on_page(delta: int) -> void:
	_base_note = clampi(_base_note + delta, 0, 127 - PAGE_SIZE + 1)
	_rebuild()


## Bind each scene pad to the MIDI note and child for the current page.
func _rebuild() -> void:
	_sync_child_signals()
	if _pads.is_empty():
		return
	var by_note := {}
	if device:
		for child in device.children:
			by_note[child.slot_note] = child
	var open_note := _open_note()
	if not _moving:
		_reconcile_selection(open_note, by_note)
	if _hide_slot_button:
		_hide_slot_button.visible = open_note >= 0
	var end_note := mini(_base_note + PAGE_SIZE - 1, 127)
	if _page_label:
		_page_label.text = "%s – %s" % [Midi.midi_to_note_name(_base_note), Midi.midi_to_note_name(end_note)]
	for i in range(PAGE_SIZE):
		var row := int(i / COLS)
		var col := i % COLS
		var from_bottom := (COLS - 1) - row
		var note := _base_note + from_bottom * COLS + col
		var child: DeviceInstance = by_note.get(note, null)
		_pads[i].setup(note, child, device)
		_pads[i].set_selected(_selected_notes.has(note), note == _primary_note)
		_pads[i].co_selected = _selected_children(by_note)
		_pads[i].tooltip_text = _pad_tooltip(child)
		_pads[i].set_color_strip(device.slot_color(DeviceInstance.pad_slot_key(note)) if child else Color.TRANSPARENT)
	_strip.bind_pad(device, by_note.get(_primary_note, null))


## The open slot is the primary pad: follow it when it changes outside this view, and drop
## selected pads whose device was removed.
func _reconcile_selection(open_note: int, by_note: Dictionary) -> void:
	if open_note >= 0 and not _selected_notes.has(open_note):
		_selected_notes = [open_note]
	if open_note >= 0:
		_primary_note = open_note
	elif _primary_note >= 0 and not _selected_notes.has(_primary_note):
		_primary_note = -1
	var kept: Array[int] = []
	for n in _selected_notes:
		if n == _primary_note or not _occupied.has(n) or by_note.has(n):
			kept.append(n)
	_selected_notes = kept
	if _primary_note >= 0 and not _selected_notes.has(_primary_note):
		_primary_note = -1
	_occupied = by_note.duplicate()


## Devices on the selected pads.
func _selected_children(by_note: Dictionary) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	for n in _selected_notes:
		if by_note.has(n):
			out.append(by_note[n])
	return out


## Notes of the current selection (primary last-clicked).
func selected_notes() -> Array[int]:
	return _selected_notes.duplicate()


func primary_note() -> int:
	return _primary_note


## Keep slot/loading subscriptions exactly on the machine's current children, so a
## child that is removed (or whose instance is replaced) stops driving this view.
func _sync_child_signals() -> void:
	var current: Array[DeviceInstance] = device.children if device else []
	for child in _tracked_children:
		if child in current:
			continue
		if is_instance_valid(child):
			if child.slot_changed.is_connected(_on_children_changed):
				child.slot_changed.disconnect(_on_children_changed)
			if child.loading_state_changed.is_connected(_on_children_changed):
				child.loading_state_changed.disconnect(_on_children_changed)
			if child.choke_targets_changed.is_connected(_on_children_changed):
				child.choke_targets_changed.disconnect(_on_children_changed)
	_tracked_children.clear()
	for child in current:
		_tracked_children.append(child)
		if not child.slot_changed.is_connected(_on_children_changed):
			child.slot_changed.connect(_on_children_changed)
		if not child.loading_state_changed.is_connected(_on_children_changed):
			child.loading_state_changed.connect(_on_children_changed)
		if not child.choke_targets_changed.is_connected(_on_children_changed):
			child.choke_targets_changed.connect(_on_children_changed)


## Click selects the pad and opens its slot (an empty pad's slot takes drops onto its note).
## Ctrl-click toggles it in the selection; shift-click selects the range from the primary pad.
func _on_pad_activated(note: int, modifiers: int = 0) -> void:
	if device == null:
		return
	var ctrl := (modifiers & (KEY_MASK_CTRL | KEY_MASK_META)) != 0
	var shift := (modifiers & KEY_MASK_SHIFT) != 0
	if shift and _primary_note >= 0:
		_selected_notes.clear()
		for n in range(mini(_primary_note, note), maxi(_primary_note, note) + 1):
			_selected_notes.append(n)
		_rebuild()
		return
	if ctrl:
		if _selected_notes.has(note):
			_selected_notes.erase(note)
			if note == _primary_note:
				_primary_note = _selected_notes.back() if not _selected_notes.is_empty() else -1
				if _primary_note >= 0:
					device.set_slot_open(DeviceInstance.pad_slot_key(_primary_note), true)
			_rebuild()
			return
		_selected_notes.append(note)
	else:
		_selected_notes = [note]
	_primary_note = note
	device.set_slot_open(DeviceInstance.pad_slot_key(note), true)
	# Opening an already-open slot emits nothing, so refresh the borders ourselves.
	_rebuild()


func _on_pad_context(note: int) -> void:
	var child := _child_for_note(note)
	if child == null:
		return
	# A right-click outside the selection selects that pad first.
	if not _selected_notes.has(note):
		_on_pad_activated(note, 0)
	if _pad_menu == null:
		_pad_menu = PAD_MENU_SCENE.instantiate()
		add_child(_pad_menu)
	_pad_menu.bind_to_pad(device, child)
	_pad_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i(_pad_menu.get_contents_minimum_size())))


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
	if DeviceDropUtil.is_group_drag(device, data):
		var drag := data as DeviceDrag
		var delta := note - drag.device.slot_note
		if DeviceDropUtil.group_move_plan(device, drag.devices, delta).is_empty():
			return
		# The selection follows the moved pads; set it first, as the move rebuilds this view.
		_moving = true
		var shifted: Array[int] = []
		for n in _selected_notes:
			shifted.append(n + delta)
		_selected_notes = shifted
		if _primary_note >= 0:
			_primary_note += delta
		_occupied.clear()
		DeviceDropUtil.drop_on_drum_pad(device.get_channel(), device, note, data)
		_moving = false
		_rebuild()
		return
	DeviceDropUtil.drop_on_drum_pad(device.get_channel(), device, note, data)
	var child := _child_for_note(note)
	if child:
		device.reveal_child(child)
	_rebuild()


## Find the drum-machine child occupying `note`, if any.
func _child_for_note(note: int) -> DeviceInstance:
	if device == null:
		return null
	for child in device.children:
		if child.slot_note == note:
			return child
	return null


## Pad tooltip: the device name and, when set, the pads it chokes and the pads that choke it.
func _pad_tooltip(child: DeviceInstance) -> String:
	if child == null:
		return ""
	var text := child.get_display_name()
	var names := func(pads: Array[DeviceInstance]) -> String:
		return ", ".join(pads.map(func(p): return p.get_display_name()))
	var chokes := device.choke_target_pads(child)
	if not chokes.is_empty():
		text += "\nChokes: " + names.call(chokes)
	var choked_by := device.choked_by(child)
	if not choked_by.is_empty():
		text += "\nChoked by: " + names.call(choked_by)
	return text
