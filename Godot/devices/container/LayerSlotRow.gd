## One Layer slot: device light, name, and a volume knob, with the slot color along the left edge.
## Clicking the row (not the light or knob) shows or hides the slot; an open slot is highlighted.
class_name LayerSlotRow extends PanelContainer

## Width of the slot color bar on the left edge, in pixels.
const COLOR_BAR := 4

signal activated
## Right-click: the slot chain's context menu.
signal context_requested

var container: DeviceInstance = null
var instance: DeviceInstance = null

var _light: DeviceLightButton = null
var _name: Label = null
var _knob: RotaryKnob = null
var _idle_style: StyleBoxFlat = null
var _open_style: StyleBoxFlat = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_idle_style = _make_style(Color(0.12, 0.12, 0.12, 0.6))
	_open_style = _make_style(Color(0.2, 0.2, 0.2, 0.95))
	add_theme_stylebox_override("panel", _idle_style)
	custom_minimum_size = Vector2(160, 32)
	_build()


## Bind this row to child `inst` of Layer `p_container`.
func setup(p_container: DeviceInstance, inst: DeviceInstance) -> void:
	container = p_container
	instance = inst
	if not is_node_ready():
		await ready
	refresh_slot()
	_light.bind_to_device_instance(inst)
	_name.text = inst.get_display_name()
	if not inst.name_changed.is_connected(_on_instance_name_changed):
		inst.name_changed.connect(_on_instance_name_changed)
	_knob.set_block_signals(true)
	_knob.value = inst.slot_volume
	_knob.set_block_signals(false)
	if not inst.slot_changed.is_connected(_on_slot_changed):
		inst.slot_changed.connect(_on_slot_changed)


## Keep the slot label in sync with instance renames.
func _on_instance_name_changed(new_name: String) -> void:
	if _name:
		_name.text = new_name


## Follow the slot's color and open state.
func refresh_slot() -> void:
	if container == null or instance == null or _idle_style == null:
		return
	var key := container.slot_key_for(instance)
	var color := container.slot_color(key)
	var open := container.is_slot_open(key)
	_idle_style.border_color = color.darkened(0.3)
	_open_style.border_color = color
	add_theme_stylebox_override("panel", _open_style if open else _idle_style)
	tooltip_text = ("Hide %s" if open else "Show %s") % instance.get_display_name()


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
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			context_requested.emit()
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
	style.border_width_left = COLOR_BAR
	style.content_margin_left = 4 + COLOR_BAR
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style
