# The note map editor: a scrolled piano keyboard covering all 128 pitches, with a
# name field, a reset button and a colour picker for the selected key
# (REQ-006, REQ-007).
#
# Clicking a key selects and auditions it (REQ-008); auditioning is delegated
# upwards through `audition_started` / `audition_stopped` so it reuses
# MidiEditor's existing preview-note path rather than talking to the engine here.
#
# Every edit goes through HistoryUtil.execute_property on Channel.set_note_map, so
# each one undoes as a single step and only ever touches the channel's own copy of
# the map (REQ-026). An Auto map is shown read-only (REQ-005); "Save as…" is the
# one action that stays available on it (REQ-027).
class_name NoteMapEditorDialog extends Window

## The dialog wants the given pitch previewed on the edited channel.
signal audition_started(note: int, velocity: int)
signal audition_stopped(note: int)

## The user asked to store the current map in the library ("Save as…" on an Auto
## map, or "Save" on a named one). ClipEditor opens the save dialog.
signal save_requested(map: NoteMap)

## The channel's map changed, so the clip editor should refresh.
signal map_edited

## Taller than the clip editor's default: this view is a list of named entries,
## not a place to read chords, so the labels need the room.
const KEY_HEIGHT := 26.0

var channel: Channel = null

var _piano: VPiano
var _scroll: ScrollContainer
var _selected_pitch := 60
var _name_edit: LineEdit
var _reset_button: Button
var _color_button: ColorPickerButton
var _save_button: Button
var _save_as_button: Button
var _selection_label: Label
var _readonly_hint: Label

var _logger := Log.make("NoteMapEditorDialog")


func _ready() -> void:
	title = "Note Map"
	size = Vector2i(420, 560)
	min_size = Vector2i(320, 360)
	# The ColorPickerButton opens a nested Window; staying non-exclusive and
	# non-transient keeps this dialog alive while it is open
	# (see TrackItemContextMenu.gd:18).
	exclusive = false
	transient = false
	unresizable = false
	close_requested.connect(_on_close_requested)
	_build_ui()
	hide()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_selection_label = Label.new()
	_selection_label.text = "C3"
	vbox.add_child(_selection_label)

	# Name + reset + colour row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vbox.add_child(row)

	# A plain LineEdit, not SmartLineEdit: this is a form field in a dialog, and
	# SmartLineEdit renders as a bare centred label until it is double-clicked,
	# which reads as static text rather than something you can type into.
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Name for this pitch"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, 28)
	row.add_child(_name_edit)
	_name_edit.text_submitted.connect(_on_name_changed)
	_name_edit.focus_exited.connect(func(): _on_name_changed(_name_edit.text))

	_reset_button = Button.new()
	_reset_button.text = "X"
	_reset_button.tooltip_text = "Remove this pitch's entry"
	_reset_button.pressed.connect(_on_reset_pressed)
	row.add_child(_reset_button)

	_color_button = ColorPickerButton.new()
	_color_button.custom_minimum_size = Vector2(48, 26)
	_color_button.edit_alpha = false
	_color_button.color_changed.connect(_on_color_changed)
	row.add_child(_color_button)

	_readonly_hint = Label.new()
	_readonly_hint.text = "This map comes from the Drum Machine. Use Save as… to make it editable."
	_readonly_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readonly_hint.modulate = Color(1, 1, 1, 0.6)
	_readonly_hint.visible = false
	vbox.add_child(_readonly_hint)

	# The keyboard.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	_piano = VPiano.new()
	_piano.key_height = KEY_HEIGHT
	_piano.minimum_width = 160.0
	# Same palette as the clip editor's keyboard (ClipEditor.tscn): inverted, so
	# the naturals are dark and the accidentals light, instead of a bright white
	# slab in a dark dialog.
	_piano.key_color_white = Color(0.69921875, 0.69921875, 0.69921875)
	_piano.key_color_black = Color(0.16015625, 0.16015625, 0.16015625)
	_piano.invert_colors = true
	_piano.key_color_border = Color(0.08235294, 0.08235294, 0.08235294)
	_piano.border_width = 3.0
	_piano.border_color = Color(0.33333334, 0.33333334, 0.33333334)
	_piano.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_piano.key_pressed.connect(_on_key_pressed)
	_piano.key_released.connect(_on_key_released)
	_scroll.add_child(_piano)

	# Buttons.
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 4)
	vbox.add_child(buttons)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.tooltip_text = "Save this map to the library"
	_save_button.pressed.connect(func(): save_requested.emit(_current_map()))
	buttons.add_child(_save_button)

	_save_as_button = Button.new()
	_save_as_button.text = "Save as…"
	_save_as_button.tooltip_text = "Save this map to the library under a new name"
	_save_as_button.pressed.connect(func(): save_requested.emit(_current_map()))
	buttons.add_child(_save_as_button)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(_on_close_requested)
	buttons.add_child(close_button)


## Show the editor for `p_channel`, optionally starting on a given pitch.
func open_for(p_channel: Channel, pitch := -1) -> void:
	channel = p_channel
	if pitch >= 0:
		_selected_pitch = pitch
	refresh()
	popup_centered()
	call_deferred("_scroll_to_selected")


## Re-read the channel's map. Called on open and whenever the map changes under us.
func refresh() -> void:
	var map := _current_map()
	_piano.note_map = map
	_piano.hovered_note = _selected_pitch

	var editable := is_editable()
	_name_edit.editable = editable
	_reset_button.disabled = not editable
	_color_button.disabled = not editable
	_readonly_hint.visible = not editable
	# Saving a named map under its own name is the explicit library write (REQ-026);
	# an Auto map can only be saved as something new (REQ-027).
	_save_button.visible = editable

	_selection_label.text = "%s  (%d)" % [Midi.midi_to_note_name(_selected_pitch), _selected_pitch]
	_name_edit.text = map.get_name(_selected_pitch)
	var color := map.get_color(_selected_pitch)
	_color_button.color = color if color.a > 0.0 else Color.WHITE


## An Auto map's names come from the pad devices and its colours from the return
## channels, so nothing here may edit it (REQ-005).
func is_editable() -> bool:
	return channel != null and channel.note_map_mode != Channel.NoteMapMode.AUTO


func _current_map() -> NoteMap:
	return NoteMapResolver.effective_map(channel)


func _scroll_to_selected() -> void:
	if _piano == null or _scroll == null:
		return
	var y := _piano.note_to_y(_selected_pitch)
	_scroll.scroll_vertical = int(maxf(0.0, y - _scroll.size.y * 0.5))


# --- editing ---------------------------------------------------------------

func _on_key_pressed(note: int, velocity: int) -> void:
	_selected_pitch = note
	refresh()
	audition_started.emit(note, velocity)


func _on_key_released(note: int) -> void:
	audition_stopped.emit(note)


func _on_name_changed(value: String) -> void:
	if not is_editable():
		return
	var text := value.strip_edges()
	var map := _current_map()
	if map.get_name(_selected_pitch) == text:
		return
	var edited := map.duplicate_map()
	if text.is_empty():
		# An entry with no name and no colour is just an unmapped pitch.
		if not edited.has_entry(_selected_pitch):
			return
		edited.set_entry(_selected_pitch, "", map.get_color(_selected_pitch))
	else:
		var color := map.get_color(_selected_pitch)
		edited.set_entry(_selected_pitch, text, color if color.a > 0.0 else _color_button.color)
	_apply("Rename Note Map Entry", edited)


func _on_color_changed(color: Color) -> void:
	if not is_editable():
		return
	var map := _current_map()
	if map.get_color(_selected_pitch).is_equal_approx(color):
		return
	var edited := map.duplicate_map()
	edited.set_entry(_selected_pitch, map.get_name(_selected_pitch), color)
	_apply("Recolor Note Map Entry", edited)


func _on_reset_pressed() -> void:
	if not is_editable():
		return
	var map := _current_map()
	if not map.has_entry(_selected_pitch):
		return
	var edited := map.duplicate_map()
	edited.erase_entry(_selected_pitch)
	_apply("Clear Note Map Entry", edited)


## Push one undoable edit onto the channel's own copy of the map (REQ-026).
##
## set_note_map() switches the channel to NAMED as a side effect, and undoing with
## a null old map would land it on Auto rather than back on None. So when the
## channel starts on None, the mode change is recorded alongside the map as one
## macro and undo restores both.
func _apply(label: String, edited: NoteMap) -> void:
	if channel == null:
		return
	var old_map: NoteMap = channel.note_map.duplicate_map() if channel.note_map else null
	var old_mode: Channel.NoteMapMode = channel.note_map_mode
	var cmds: Array[Command] = []
	# The mode goes first so it is undone *last*: set_note_map(null) on undo would
	# otherwise leave the channel on Auto after the mode had already been restored.
	if old_mode != Channel.NoteMapMode.NAMED:
		cmds.append(PropertyCommand.new(label, channel, "set_note_map_mode", old_mode, Channel.NoteMapMode.NAMED))
	cmds.append(PropertyCommand.new(label, channel, "set_note_map", old_map, edited))
	HistoryUtil.execute_many(label, cmds)
	refresh()
	map_edited.emit()


func _on_close_requested() -> void:
	audition_stopped.emit(_selected_pitch)
	hide()
