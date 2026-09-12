@tool
class_name SmartLineEdit extends Control

## Value type enum: NUMERIC for float/int values, STRING for text values
enum ValueType { NUMERIC, STRING }

@onready var label: Label = $Label
@onready var line_edit: LineEdit = $LineEdit

## Internal string representation of the value
var _value_string := "0.0"

## Type of value this SmartLineEdit handles
@export var value_type := ValueType.NUMERIC

## Format string for display (e.g. "%0.1f dB", "%s"). Only used for NUMERIC type.
@export var display_format := "%0.1f"

## For NUMERIC values: maximum allowed value
@export var max_value := 12.0

## For NUMERIC values: minimum allowed value
@export var min_value := -60.0

## Optional suffix to display (e.g., " dB", " ms")
@export var suffix := ""

## Whether this control is disabled
@export var disabled := false

## Whether to allow editing via double-click on the label
@export var edit_via_click := true

## Tracks if currently in edit mode
var is_editing := false

## Tracks double-click detection
var _last_click_time := 0.0
var _double_click_threshold := 0.3

## Optional validation callback: func(value: Variant) -> bool
## Returns true if value is valid, false otherwise
var validation_callback: Callable = Callable()

signal value_changed(value)
## Emitted after a Tab/Shift+Tab commit so the owner can continue editing the next control.
signal tab_requested(reverse: bool)

var _owns_label_settings := false


func _ready() -> void:
	label.visible = true
	_update_label_from_value()
	line_edit.visible = false
	line_edit.gui_input.connect(_on_line_edit_gui_input)
	line_edit.focus_exited.connect(_on_line_edit_focus_exited)
	label.gui_input.connect(_on_label_gui_input)


## Steal Tab/Shift+Tab while editing so they commit instead of switching views.
func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not is_editing:
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	if key_event.keycode != KEY_TAB and key_event.physical_keycode != KEY_TAB:
		return
	get_viewport().set_input_as_handled()
	stop_editing()
	tab_requested.emit(key_event.shift_pressed)


## Set label and line-edit font color (used for contrast on colored headers).
func set_font_color(color: Color) -> void:
	if label:
		if label.label_settings:
			if not _owns_label_settings:
				label.label_settings = label.label_settings.duplicate()
				label.label_settings.resource_local_to_scene = true
				_owns_label_settings = true
			label.label_settings.font_color = color
			label.label_settings.shadow_color = Utils.contrasting_shadow_color(color)
		else:
			label.add_theme_color_override("font_color", color)
			label.add_theme_color_override("font_shadow_color", Utils.contrasting_shadow_color(color))
	if line_edit:
		line_edit.add_theme_color_override("font_color", color)
		line_edit.add_theme_color_override("caret_color", color)
		line_edit.add_theme_color_override("font_shadow_color", Utils.contrasting_shadow_color(color))


## Set the value (as string internally, but accepts float/int for NUMERIC type)
func set_value(new_value: Variant) -> void:
	if value_type == ValueType.NUMERIC:
		# Convert numeric value to float and clamp
		var numeric_val = float(new_value)
		numeric_val = clamp(numeric_val, min_value, max_value)
		_value_string = str(numeric_val)
	else:
		# Store string value directly
		_value_string = str(new_value)

	# Validate if callback provided
	if validation_callback.is_valid():
		if not validation_callback.call(_get_typed_value()):
			push_error("Value failed validation: %s" % _value_string)
			return

	_update_label_from_value()


## Get the current value as its appropriate type
func get_value() -> Variant:
	return _get_typed_value()


## Internal: get value in appropriate type (float for NUMERIC, string for STRING)
func _get_typed_value() -> Variant:
	if value_type == ValueType.NUMERIC:
		return float(_value_string)
	else:
		return _value_string


## Internal: update label display based on current value
func _update_label_from_value() -> void:
	if value_type == ValueType.NUMERIC:
		var numeric_val = float(_value_string)
		label.text = display_format % numeric_val
		if suffix:
			label.text += suffix
	else:
		label.text = _value_string


## Set validation callback that will be called before accepting values
func set_validation(callback: Callable) -> void:
	validation_callback = callback


## Start editing: show line edit, populate with current value
func start_editing() -> void:
	if disabled:
		return

	label.visible = false
	line_edit.visible = true
	line_edit.grab_click_focus.call_deferred()
	line_edit.grab_focus.call_deferred()
	line_edit.text = _value_string
	line_edit.select_all()
	is_editing = true


## Cancel editing: revert to label display without applying changes
func cancel_editing() -> void:
	is_editing = false
	line_edit.release_focus()
	release_focus()
	line_edit.visible = false
	label.visible = true


## Stop editing: apply the entered value
func stop_editing() -> void:
	cancel_editing()

	var input_text = line_edit.text.strip_edges()
	if input_text.is_empty():
		return

	if value_type == ValueType.NUMERIC:
		_parse_and_apply_numeric_value(input_text)
	else:
		_parse_and_apply_string_value(input_text)

	value_changed.emit(_get_typed_value())


## Internal: parse numeric input supporting %, integers, and floats
func _parse_and_apply_numeric_value(input: String) -> void:
	var numeric_val: float

	if input.ends_with("%"):
		# Percentage input: convert 0-100% to min-max range
		var percent = input.substr(0, input.length() - 1)
		var percent_val = clamp(float(percent), 0.0, 100.0)
		numeric_val = remap(percent_val, 0, 100, min_value, max_value)
	else:
		# Direct numeric input
		numeric_val = float(input)

	numeric_val = clamp(numeric_val, min_value, max_value)
	set_value(numeric_val)


## Internal: parse and apply string value
func _parse_and_apply_string_value(input: String) -> void:
	set_value(input)


## Internal: handle GUI input in LineEdit
func _on_line_edit_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if is_editing:
			cancel_editing()
			accept_event()
	elif event.is_action_pressed("ui_accept"):
		if is_editing:
			stop_editing()
			accept_event()


## Internal: handle GUI input on Label (double-click detection)
func _on_label_gui_input(event: InputEvent) -> void:
	if not edit_via_click or disabled or is_editing:
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var current_time = Time.get_ticks_msec() / 1000.0
		var time_since_last_click = current_time - _last_click_time

		if time_since_last_click < _double_click_threshold:
			# Double-click detected
			start_editing()
			_last_click_time = 0.0  # Reset to prevent triple-click
			accept_event()
		else:
			_last_click_time = current_time


## Internal: handle LineEdit focus exit
func _on_line_edit_focus_exited() -> void:
	if is_editing:
		cancel_editing()
