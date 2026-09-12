## One Layer slot: device light, name, and a volume knob.
## Clicking the row (not the light or knob) asks the parent panel to open that child.
class_name LayerSlotRow extends PanelContainer

signal activated

var instance: DeviceInstance = null

var _light: DeviceLightButton = null
var _name: Label = null
var _knob: RotaryKnob = null
var _selected: bool = false
var _idle_style: StyleBoxFlat = null
var _selected_style: StyleBoxFlat = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_idle_style = _make_style(Color(0.12, 0.12, 0.12, 0.6))
	_selected_style = _make_style(Color(0.22, 0.28, 0.36, 0.95))
	add_theme_stylebox_override("panel", _idle_style)
	custom_minimum_size = Vector2(160, 32)
	_build()


## Bind this row to a Layer child instance.
func setup(inst: DeviceInstance) -> void:
	instance = inst
	if not is_node_ready():
		await ready
	_light.bind_to_device_instance(inst)
	_name.text = inst.get_display_name()
	_knob.set_block_signals(true)
	_knob.value = inst.slot_volume
	_knob.set_block_signals(false)
	if not inst.slot_changed.is_connected(_on_slot_changed):
		inst.slot_changed.connect(_on_slot_changed)


## Highlight this row when its child is shown in the folder.
func set_selected(on: bool) -> void:
	_selected = on
	add_theme_stylebox_override("panel", _selected_style if on else _idle_style)


func _build() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_light = DeviceLightButton.new()
	_light.diameter = 18.0
	_light.custom_minimum_size = Vector2(18, 18)
	_light.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(_light)

	_name = Label.new()
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.mouse_filter = Control.MOUSE_FILTER_STOP
	_name.gui_input.connect(_on_name_gui_input)
	row.add_child(_name)

	_knob = RotaryKnob.new()
	_knob.custom_minimum_size = Vector2(28, 28)
	_knob.min_value = 0.0
	_knob.max_value = 1.0
	_knob.value_default = 0.5
	_knob.mouse_filter = Control.MOUSE_FILTER_STOP
	_knob.value_changed.connect(_on_knob_changed)
	row.add_child(_knob)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			activated.emit()
			accept_event()


func _on_name_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			activated.emit()
			accept_event()


func _on_knob_changed(value: float) -> void:
	if instance:
		instance.set_slot_volume(value)


func _on_slot_changed() -> void:
	if instance == null or _knob == null:
		return
	_knob.set_block_signals(true)
	_knob.value = instance.slot_volume
	_knob.set_block_signals(false)


func _make_style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style
