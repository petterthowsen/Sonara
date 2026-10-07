@tool
## A row of exclusive toggle buttons (Clean | Glue | Punch | Opto) in the app's colours. The
## selected segment is filled with the theme accent. `Simple View` and the compressor view
## share it.
class_name SegmentedControl extends HBoxContainer

signal selected_changed(index: int)

@export var font_size := 11:
	set(v):
		font_size = v
		for btn in _buttons:
			btn.add_theme_font_size_override("font_size", v)
## Trim labels to the width the control is given (for tight cells). Off: each segment is as wide
## as its label.
@export var clip_labels := false:
	set(v):
		clip_labels = v
		for btn in _buttons:
			btn.clip_text = v
var _tc := ThemedColors.new(self, &"SegmentedControl")
var selected_color: Color:
	get:
		return _tc.get_color(&"selected")
	set(c):
		_tc.set_color(&"selected", c)
var idle_color: Color:
	get:
		return _tc.get_color(&"idle")
	set(c):
		_tc.set_color(&"idle", c)
var hover_color: Color:
	get:
		return _tc.get_color(&"hover")
	set(c):
		_tc.set_color(&"hover", c)

## The segment labels. Set in the scene to see them in the editor; `set_items` does the same.
@export var items := PackedStringArray():
	set(v):
		items = v
		_rebuild()

## Index of the selected segment, -1 for none. Setting it emits `selected_changed` on a change.
var selected: int:
	get:
		return _selected
	set(i):
		var old := _selected
		set_selected_no_signal(i)
		if _selected != old:
			selected_changed.emit(_selected)

var _selected := -1
var _buttons: Array[Button] = []
var _group := ButtonGroup.new()


func _init() -> void:
	add_theme_constant_override("separation", 1)


## Replace the segments. Nothing is selected afterwards.
func set_items(labels: PackedStringArray) -> void:
	items = labels


func _rebuild() -> void:
	var labels := items
	for btn in _buttons:
		btn.queue_free()
		remove_child(btn)
	_buttons.clear()
	_group = ButtonGroup.new()
	_selected = -1
	for i in labels.size():
		var btn := Button.new()
		btn.text = labels[i]
		btn.tooltip_text = labels[i]
		btn.clip_text = clip_labels
		btn.toggle_mode = true
		btn.button_group = _group
		btn.focus_mode = Control.FOCUS_NONE
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", font_size)
		_style(btn, i, labels.size())
		btn.pressed.connect(_on_pressed.bind(i))
		add_child(btn)
		_buttons.append(btn)


func item_count() -> int:
	return _buttons.size()


func set_selected_no_signal(index: int) -> void:
	_selected = index if index >= 0 and index < _buttons.size() else -1
	for i in _buttons.size():
		_buttons[i].set_pressed_no_signal(i == _selected)


func _on_pressed(index: int) -> void:
	if index == _selected:
		_buttons[index].set_pressed_no_signal(true)
		return
	selected = index


func _style(btn: Button, index: int, count: int) -> void:
	var radius_left := 3 if index == 0 else 0
	var radius_right := 3 if index == count - 1 else 0
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var box := StyleBoxFlat.new()
		match state:
			"normal", "disabled":
				box.bg_color = idle_color
			"hover":
				box.bg_color = hover_color
			_:
				box.bg_color = selected_color
		box.corner_radius_top_left = radius_left
		box.corner_radius_bottom_left = radius_left
		box.corner_radius_top_right = radius_right
		box.corner_radius_bottom_right = radius_right
		box.content_margin_left = 6
		box.content_margin_right = 6
		box.content_margin_top = 3
		box.content_margin_bottom = 3
		btn.add_theme_stylebox_override(state, box)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
