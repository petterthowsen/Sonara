## One drum-machine pad: note label, child name, click-to-focus, and file/device drops.
class_name DrumPad extends PanelContainer

signal activated(note: int)
signal drop_requested(note: int, data: Variant)

var note: int = 36
var child: DeviceInstance = null

var _note_label: Label = null
var _name_label: Label = null
var _idle_style: StyleBoxFlat = null
var _filled_style: StyleBoxFlat = null
var _selected_style: StyleBoxFlat = null
var _selected: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(56, 48)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_idle_style = _make_style(Color(0.14, 0.14, 0.16, 0.95))
	_filled_style = _make_style(Color(0.2, 0.24, 0.3, 0.98))
	_selected_style = _make_style(Color(0.32, 0.42, 0.55, 1.0))
	add_theme_stylebox_override("panel", _idle_style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_note_label = Label.new()
	_note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note_label.add_theme_font_size_override("font_size", 11)
	_note_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_note_label)
	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 10)
	_name_label.modulate = Color(0.85, 0.85, 0.9, 0.9)
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_name_label)
	_refresh()


## Bind this pad to MIDI `p_note` and optional occupied `p_child`.
func setup(p_note: int, p_child: DeviceInstance) -> void:
	note = p_note
	child = p_child
	if is_node_ready():
		_refresh()


## Highlight when this pad's child is shown in the folder.
func set_selected(on: bool) -> void:
	_selected = on
	_apply_style()


func _refresh() -> void:
	if _note_label:
		_note_label.text = Midi.midi_to_note_name(note)
	if _name_label:
		if child:
			var label := child.get_display_name()
			if not child.loaded_file_path.is_empty():
				label = child.loaded_file_path.get_file().get_basename()
			_name_label.text = label
		else:
			_name_label.text = ""
	_apply_style()


func _apply_style() -> void:
	var style := _idle_style
	if _selected:
		style = _selected_style
	elif child:
		style = _filled_style
	if style:
		add_theme_stylebox_override("panel", style)


func _make_style(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(4)
	box.set_content_margin_all(4)
	return box


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			activated.emit(note)
			accept_event()


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return DeviceDropUtil.can_drop_on_drum_pad(data, child)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	drop_requested.emit(note, data)
