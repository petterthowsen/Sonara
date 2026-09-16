# DeviceDrag.gd
# Payload for dragging a device (from a DevicePanel, CompactDevicePanel or drum pad). Nothing moves
# until the drop; see DeviceDropTarget.
class_name DeviceDrag

## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
signal drag_completed(data: DeviceDrag)

var source: Control = null
var device: DeviceInstance = null
var preview: Control = null

## True after a drop changed something.
var did_commit: bool = false


## Bind the preview's lifetime to this drag payload.
func _init(_source: Control, _device: DeviceInstance, _preview: Control) -> void:
	source = _source
	device = _device
	preview = _preview
	if preview:
		preview.tree_exiting.connect(_on_tree_exiting)


## Undim the source (if a drop didn't free it) and notify listeners.
func _on_tree_exiting() -> void:
	if is_instance_valid(source):
		source.modulate.a = 1.0
	drag_completed.emit(self)


## Start dragging `inst` from `source`: set the preview and dim the source in place.
## Call from `_get_drag_data`.
static func start(source: Control, inst: DeviceInstance) -> DeviceDrag:
	if source == null or inst == null:
		return null
	var ghost := make_preview(inst)
	var drag := DeviceDrag.new(source, inst, ghost)
	source.set_drag_preview(ghost)
	source.modulate.a = 0.5
	return drag


## The dragged DeviceInstance for a DeviceDrag, otherwise `data` unchanged (assets etc.).
static func unwrap(data: Variant) -> Variant:
	if data is DeviceDrag:
		return (data as DeviceDrag).device
	return data


## Ghost label that follows the cursor.
static func make_preview(inst: DeviceInstance) -> Control:
	var ghost := PanelContainer.new()
	var label_node := Label.new()
	label_node.text = inst.get_display_name() if inst else "Device"
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
