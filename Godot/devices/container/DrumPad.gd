## One drum-machine pad: note label, child name, click-to-play, click-to-focus, drag-to-move, and file/device drops.
class_name DrumPad extends PanelContainer

## MIDI velocity is 1 at this fraction of pad height from the bottom, 127 at the high fraction.
const VELOCITY_Y_LOW := 0.20
const VELOCITY_Y_HIGH := 0.80

## `modifiers` is the click's key mask (KEY_MASK_CTRL / KEY_MASK_SHIFT); the view decides what it means.
signal activated(note: int, modifiers: int)
signal triggered(note: int, velocity: int)
signal released(note: int)
signal drop_requested(note: int, data: Variant)
## Right-click on an occupied pad: its slot chain's context menu.
signal context_requested(note: int)

var note: int = 36
var child: DeviceInstance = null
var container: DeviceInstance = null

@onready var _note_label: Label = $VBox/Note
@onready var _name_label: Label = $VBox/Name
## Pad chrome: dark gray fill, 1 px light gray border; selection uses DevicePanel's border color.
const FILL_EMPTY := Color(0.10, 0.10, 0.11)
const FILL_FILLED := Color(0.17, 0.17, 0.18)
const FILL_HIT := Color(0.34, 0.34, 0.36)
const BORDER_IDLE := Color(0.55, 0.55, 0.57)
const CORNER_RADIUS := 2
## Border width of a selected pad.
const SELECTED_BORDER_WIDTH := 2
const COLOR_STRIP_HEIGHT := 3.0

var _idle_style: StyleBoxFlat = null
var _filled_style: StyleBoxFlat = null
var _selected_style: StyleBoxFlat = null
var _hit_style: StyleBoxFlat = null
var _selected: bool = false
var _strip: Control = null
var _strip_color := Color.TRANSPARENT
var _pressed: bool = false
var _sounding: bool = false
var _drag_started: bool = false
var _primary: bool = false
var _primary_style: StyleBoxFlat = null
var _press_modifiers: int = 0
## Pads of the selection this pad drags along with when it is part of it (set by the view).
var co_selected: Array[DeviceInstance] = []


## Neutral selection border colour, shared with the device cards (theme role `border_selected`).
func _selection_color() -> Color:
	return ThemeDB.get_project_theme().get_color(&"border_selected", &"Sonara")


## Apply pad chrome once the scene labels are ready.
func _ready() -> void:
	_idle_style = _make_style(FILL_EMPTY)
	_filled_style = _make_style(FILL_FILLED)
	_selected_style = _make_style(FILL_FILLED, _selection_color(), SELECTED_BORDER_WIDTH)
	_hit_style = _make_style(FILL_HIT)
	_primary_style = _make_style(FILL_FILLED, Color.WHITE, SELECTED_BORDER_WIDTH)
	# The color strip is an overlay child so it draws above the panel stylebox.
	_strip = Control.new()
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.draw.connect(_draw_strip)
	add_child(_strip)
	add_theme_stylebox_override("panel", _idle_style)
	# Pads take device drops themselves; the device lane shows no insert target over them.
	add_to_group(DeviceDropTarget.OWN_DROPS_GROUP)
	_refresh()


## Bind this pad to MIDI `p_note`, optional occupied `p_child`, and the drum machine.
func setup(p_note: int, p_child: DeviceInstance, p_container: DeviceInstance = null) -> void:
	if _sounding and (p_note != note or p_child != child):
		_stop_preview()
	note = p_note
	child = p_child
	container = p_container
	if is_node_ready():
		_refresh()


## Selected pads get the light border; the primary pad (the one whose slot is open) a white one.
func set_selected(on: bool, primary := false) -> void:
	_selected = on
	_primary = on and primary
	_apply_style()


## Slot color shown as a thin strip along the top edge (alpha 0 = none).
func set_color_strip(color: Color) -> void:
	_strip_color = color
	if _strip:
		_strip.queue_redraw()


func _draw_strip() -> void:
	if _strip_color.a > 0.0:
		_strip.draw_rect(Rect2(1, 1, _strip.size.x - 2, COLOR_STRIP_HEIGHT), _strip_color)


## Update labels and fill style from the bound child.
func _refresh() -> void:
	if _note_label:
		_note_label.text = Midi.midi_to_note_name(note)
	if _name_label:
		if child:
			# The pad's slot chain is named after its first device; a loaded sample says more.
			var label := child.get_display_name()
			var loader := DeviceDropUtil.find_file_loading_descendant(child)
			if loader and not loader.loaded_file_path.is_empty():
				label = loader.loaded_file_path.get_file().get_basename()
			_name_label.text = label
		else:
			_name_label.text = ""
	_apply_style()


## Apply idle, filled, selected, or hit panel style.
func _apply_style() -> void:
	var style := _idle_style
	if _sounding:
		style = _hit_style
	elif _primary:
		style = _primary_style
	elif _selected:
		style = _selected_style
	elif child:
		style = _filled_style
	if style:
		add_theme_stylebox_override("panel", style)


## Build a pad background with a border.
func _make_style(color: Color, border: Color = BORDER_IDLE, border_width := 1) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(CORNER_RADIUS)
	box.set_content_margin_all(4)
	return box


## Map a local click Y to MIDI velocity 1–127. Bottom 20% is quietest, top 20% is loudest.
static func velocity_from_y(local_y: float, height: float) -> int:
	if height <= 0.0:
		return 100
	var y_from_bottom := 1.0 - clampf(local_y / height, 0.0, 1.0)
	var span := VELOCITY_Y_HIGH - VELOCITY_Y_LOW
	var t := clampf((y_from_bottom - VELOCITY_Y_LOW) / span, 0.0, 1.0)
	return clampi(roundi(t * 126.0) + 1, 1, 127)


## Press plays the pad (velocity from Y). Release without a drag also focuses it.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and child:
			context_requested.emit(note)
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_pressed = true
			_drag_started = false
			_press_modifiers = mb.get_modifiers_mask() & (KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_MASK_META)
			_start_preview(mb.position.y)
		else:
			_stop_preview()
			if _pressed and not _drag_started:
				activated.emit(note, _press_modifiers)
			_pressed = false


## Catch mouse-up outside the pad so a held preview always gets a note-off.
func _input(event: InputEvent) -> void:
	if not _sounding:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		if get_global_rect().has_point(mb.global_position):
			return
		_stop_preview()
		_pressed = false


## Emit a trigger for occupied pads using click height as velocity.
func _start_preview(local_y: float) -> void:
	if child == null or _sounding:
		return
	_sounding = true
	_apply_style()
	triggered.emit(note, velocity_from_y(local_y, size.y))


## End a sounding preview so gated samples and nested instruments release.
func _stop_preview() -> void:
	if not _sounding:
		return
	_sounding = false
	_apply_style()
	released.emit(note)


## Stop a held preview without requiring a mouse-up (e.g. the view was hidden).
func cancel_preview() -> void:
	_stop_preview()
	_pressed = false


## Drag this pad's device onto another pad (or a drop zone).
func _get_drag_data(_at_position: Vector2) -> Variant:
	if child == null:
		return null
	_drag_started = true
	_stop_preview()
	var moving: Array[DeviceInstance] = []
	if _selected and co_selected.size() > 1 and co_selected.has(child):
		moving.append_array(co_selected)
	var preview := _make_drag_preview(moving.size() - 1)
	set_drag_preview(preview)
	return DeviceDrag.new(self, child, preview, moving)


## Preview shown while dragging a pad's device.
func _make_drag_preview(extra := 0) -> Control:
	var preview := PanelContainer.new()
	var label := Label.new()
	label.text = child.get_display_name() if child else Midi.midi_to_note_name(note)
	if extra > 0:
		label.text += "  +%d" % extra
	label.add_theme_font_size_override("font_size", 12)
	preview.add_theme_stylebox_override("panel", _make_style(FILL_FILLED))
	preview.add_child(label)
	return preview


## Accept samples, devices, or another pad's device (move or swap).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var inst := container if container else child
	var channel := inst.get_channel() if inst else null
	return DeviceDropUtil.can_drop_on_drum_pad(data, child, channel, container, note)


## Forward the drop to DrumMachineDefaultView, which applies it and focuses the pad.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	drop_requested.emit(note, data)
