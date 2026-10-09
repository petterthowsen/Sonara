# DeviceDrag.gd
# Payload for dragging a device (from a DevicePanel, CompactDevicePanel or drum pad). Nothing moves
# until the drop; see DeviceDropTarget.
class_name DeviceDrag

## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
signal drag_completed(data: DeviceDrag)

var source: Control = null
var device: DeviceInstance = null
## Every device moving together (the selection the drag started from); `device` is the one under
## the pointer. Defaults to just `device`.
var devices: Array[DeviceInstance] = []
var preview: Control = null

## Ctrl (Cmd on macOS) was held when the drag started: a drop inserts copies and leaves the
## originals where they are.
var copy: bool = false

## True after a drop changed something.
var did_commit: bool = false


## Bind the preview's lifetime to this drag payload.
func _init(
	_source: Control,
	_device: DeviceInstance,
	_preview: Control,
	_devices: Array = []
) -> void:
	source = _source
	device = _device
	if not _devices.is_empty():
		for d in _devices:
			if d != null:
				devices.append(d)
	elif _device != null:
		devices = [_device]
	preview = _preview
	if preview:
		preview.tree_exiting.connect(_on_tree_exiting)


## Undim the source (if a drop didn't free it) and notify listeners.
func _on_tree_exiting() -> void:
	if is_instance_valid(source):
		source.modulate.a = 1.0
	drag_completed.emit(self)


## Start dragging `inst` from `source`: set the preview and dim the source in place. Devices in
## `co_selected` move with it when `inst` is one of them (a DeviceLane selection).
## Call from `_get_drag_data`.
static func start(
	source: Control,
	inst: DeviceInstance,
	co_selected: Array = []
) -> DeviceDrag:
	if source == null or inst == null:
		return null
	var moving: Array[DeviceInstance] = [inst]
	if co_selected.has(inst):
		moving.clear()
		for d in co_selected:
			if d != null:
				moving.append(d)
	var copying := Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	var ghost := make_preview(inst, moving.size() - 1, copying)
	var drag := DeviceDrag.new(source, inst, ghost, moving)
	drag.copy = copying
	source.set_drag_preview(ghost)
	if not copying:
		source.modulate.a = 0.5
	return drag


## The dragged DeviceInstance for a DeviceDrag, otherwise `data` unchanged (assets etc.).
static func unwrap(data: Variant) -> Variant:
	if data is DeviceDrag:
		return (data as DeviceDrag).device
	return data


## Every DeviceInstance of a drag payload moving together, or `data` alone when it is one.
static func unwrap_all(data: Variant) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	if data is DeviceDrag:
		out.append_array((data as DeviceDrag).devices)
	elif data is DeviceInstance:
		out.append(data)
	return out


## True when `data` is a device drag that copies instead of moving.
static func is_copy(data: Variant) -> bool:
	return data is DeviceDrag and (data as DeviceDrag).copy


## Ghost label that follows the cursor. `extra` counts further devices moving with this one;
## `copying` marks a copy drag.
static func make_preview(inst: DeviceInstance, extra := 0, copying := false) -> Control:
	var ghost := PanelContainer.new()
	var label_node := Label.new()
	label_node.text = inst.get_display_name() if inst else "Device"
	if extra > 0:
		label_node.text += "  +%d" % extra
	if copying:
		label_node.text = "Copy: " + label_node.text
	label_node.add_theme_font_size_override("font_size", 12)
	ghost.add_child(label_node)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.24, 0.3, 0.95)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	ghost.add_theme_stylebox_override("panel", style)
	ghost.z_index = 1000
	return ghost
