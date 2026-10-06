# ShortcutControl.gd
# Settings control for one "shortcuts/<action id>" setting: a primary and a secondary binding
# button with key capture, a reset button, conflict warnings and a read-only line per double
# tap. Implements the custom control interface documented in SettingRow.gd.
#
# Click a binding to capture: the next non-modifier key press becomes the chord. Escape
# cancels (and can't be bound). Right-click clears a slot.
extends VBoxContainer

signal value_edited(value)

const DIM_COLOR := Color(1, 1, 1, 0.5)
const WARNING_COLOR := Color(1.0, 0.72, 0.3)

var _setting
var _value: Array = []
var _action_id := ""
var _physical := false
var _buttons: Array[Button] = []
var _reset_button: Button
var _warnings: VBoxContainer
var _double_taps: VBoxContainer
## Slot being captured, -1 when idle.
var _capture_slot := -1


func setup(setting, value) -> void:
	_setting = setting
	_action_id = setting.key.trim_prefix(Settings.SHORTCUT_PREFIX)
	_physical = HotkeyActions.get_action(_action_id).get("physical", false)
	_value = _clean(value)
	_build()
	Settings.setting_changed.connect(_on_setting_changed)
	_refresh()


func set_value(value) -> void:
	_value = _clean(value)
	_refresh()


func get_value():
	return _value.duplicate()


func _exit_tree() -> void:
	_end_capture()
	if Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.disconnect(_on_setting_changed)


func _build() -> void:
	custom_minimum_size.x = 320
	var line := HBoxContainer.new()
	add_child(line)
	for slot in Settings.MAX_CHORDS:
		var b := Button.new()
		b.custom_minimum_size.x = 120
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.tooltip_text = "Click to rebind, right-click to clear"
		b.pressed.connect(_begin_capture.bind(slot))
		b.gui_input.connect(_on_button_gui_input.bind(slot))
		b.focus_exited.connect(_on_button_focus_exited.bind(slot))
		line.add_child(b)
		_buttons.append(b)
	_reset_button = Button.new()
	_reset_button.text = "↺"
	_reset_button.tooltip_text = "Reset to default"
	_reset_button.pressed.connect(_on_reset_pressed)
	line.add_child(_reset_button)
	_warnings = VBoxContainer.new()
	add_child(_warnings)
	_double_taps = VBoxContainer.new()
	add_child(_double_taps)


func _clean(value) -> Array:
	var result: Array = []
	if value is Array:
		for c in value:
			result.append(str(c))
	return result


func _default_value() -> Array:
	return _clean(_setting.default)


# ---------------------------------------------------------------------------
# DISPLAY
# ---------------------------------------------------------------------------

func _refresh() -> void:
	for slot in _buttons.size():
		if slot == _capture_slot:
			continue
		var b := _buttons[slot]
		if slot < _value.size():
			b.text = KeyChord.display(_value[slot], _physical)
			b.modulate = Color.WHITE
		else:
			b.text = "—"
			b.modulate = DIM_COLOR
	_reset_button.disabled = _value == _default_value()
	_refresh_warnings()
	_refresh_double_taps()


func _refresh_warnings() -> void:
	for child in _warnings.get_children():
		_warnings.remove_child(child)
		child.queue_free()
	var seen: Dictionary = {}
	for chord in _value:
		for other in Hotkeys.find_conflicts(_action_id, chord):
			if seen.has(other):
				continue
			seen[other] = true
			_add_warning(other)


func _add_warning(other_id: String) -> void:
	var def := HotkeyActions.get_action(other_id)
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Also used by %s (%s)" % [def.label,
			HotkeyActions.CONTEXT_LABELS.get(def.context, def.context)]
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", WARNING_COLOR)
	row.add_child(label)
	var link := LinkButton.new()
	link.text = "Unbind there"
	link.add_theme_font_size_override("font_size", 12)
	link.pressed.connect(_unbind_other.bind(other_id))
	row.add_child(link)
	_warnings.add_child(row)


## Remove from *other_id* every chord this action also uses.
func _unbind_other(other_id: String) -> void:
	var kept: Array = []
	for chord in Hotkeys.get_chords(other_id):
		if chord not in _value:
			kept.append(chord)
	Settings.set_value(Settings.SHORTCUT_PREFIX + other_id, kept)
	_refresh_warnings()


func _refresh_double_taps() -> void:
	for child in _double_taps.get_children():
		_double_taps.remove_child(child)
		child.queue_free()
	for id in Hotkeys.get_double_taps(_action_id):
		var display := Hotkeys.get_display(id)
		if display.is_empty():
			continue
		var label := Label.new()
		label.text = "%s · %s" % [display, HotkeyActions.get_action(id).label]
		label.add_theme_font_size_override("font_size", 12)
		label.modulate = DIM_COLOR
		_double_taps.add_child(label)


## Another action's binding changed (Unbind there, Cancel, Reset all): follow Settings.
func _on_setting_changed(key: String, value) -> void:
	if not key.begins_with(Settings.SHORTCUT_PREFIX) or _capture_slot >= 0:
		return
	if key == _setting.key:
		_value = _clean(value)
	_refresh()


# ---------------------------------------------------------------------------
# EDITING
# ---------------------------------------------------------------------------

func _begin_capture(slot: int) -> void:
	_end_capture()
	_buttons[slot].grab_focus()
	_capture_slot = slot
	Hotkeys.capturing = true
	_buttons[slot].text = "Press keys…"
	_buttons[slot].modulate = Color.WHITE


## Leave capture mode and restore the button labels. Safe to call when idle.
func _end_capture() -> void:
	if _capture_slot < 0:
		return
	_capture_slot = -1
	Hotkeys.capturing = false
	if is_inside_tree():
		_refresh()


func _on_button_focus_exited(slot: int) -> void:
	if _capture_slot == slot:
		_end_capture()


func _on_button_gui_input(event: InputEvent, slot: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_end_capture()
		_set_slot(slot, "")
		_buttons[slot].accept_event()


func _input(event: InputEvent) -> void:
	if _capture_slot < 0:
		return
	if event is InputEventMouseButton and event.pressed:
		# A click on the capturing button itself is handled by the button; elsewhere cancels.
		var b := _buttons[_capture_slot]
		if not b.get_global_rect().has_point(event.global_position):
			_end_capture()
		return
	if not event is InputEventKey or not event.pressed or event.is_echo():
		return
	get_viewport().set_input_as_handled()
	if event.keycode == KEY_ESCAPE:
		_end_capture()
		return
	var chord := KeyChord.from_event(event, _physical)
	if chord.is_empty():
		_buttons[_capture_slot].text = _modifier_label(event)
		return
	var slot := _capture_slot
	_end_capture()
	_set_slot(slot, chord)


static func _modifier_label(event: InputEventKey) -> String:
	var text := ""
	if event.ctrl_pressed: text += "Ctrl+"
	if event.shift_pressed: text += "Shift+"
	if event.alt_pressed: text += "Alt+"
	if event.meta_pressed: text += "Meta+"
	return text + "…" if not text.is_empty() else "Press keys…"


## Put *chord* in *slot* ("" clears it). A chord already in the other slot moves, and the
## list is kept compact, so an unbound primary promotes the secondary.
func _set_slot(slot: int, chord: String) -> void:
	var result := _value.duplicate()
	if chord.is_empty():
		if slot < result.size():
			result.remove_at(slot)
	else:
		if slot < result.size():
			result[slot] = chord
		else:
			result.append(chord)
		var seen: Array = []
		for c in result:
			if c == chord and c in seen:
				continue
			seen.append(c)
		result = seen
	if result == _value:
		return
	_value = result
	value_edited.emit(_value.duplicate())
	_refresh()


func _on_reset_pressed() -> void:
	_end_capture()
	_value = _default_value()
	value_edited.emit(_value.duplicate())
	_refresh()
