## Slide-out pane that hosts a container's child DevicePanels.
## Chain shows every child; Layer can focus a single child.
class_name ContainerFolder extends Control

const NestedDeviceListScene = preload("res://devices/container/NestedDeviceList.tscn")
const SLIDE_SEC := 0.18
const MIN_OPEN_WIDTH := 280.0

var list: NestedDeviceList = null
var _open: bool = false
var _tween: Tween = null


func _ready() -> void:
	clip_contents = true
	visible = false
	custom_minimum_size = Vector2(0, 150)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	list = NestedDeviceListScene.instantiate()
	list.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(list)


## Bind the nested list to `container` (or unbind when null).
func bind_to_container(container: DeviceInstance) -> void:
	if list == null:
		return
	list.bind_to_container(container)


## Restrict the list to `child`, or show every child when `child` is null.
func set_focus_child(child: DeviceInstance) -> void:
	if list:
		list.set_focus_child(child)


## Slide the folder open or closed.
func set_open(open: bool, animate: bool = true) -> void:
	if _open == open and visible == open:
		if open and list:
			list.refresh()
		return
	_open = open
	if _tween:
		_tween.kill()
		_tween = null
	var target_w := _open_width() if open else 0.0
	if open:
		visible = true
	if not animate or not is_inside_tree():
		custom_minimum_size.x = target_w
		if not open:
			visible = false
		return
	_tween = create_tween()
	_tween.tween_property(self, "custom_minimum_size:x", target_w, SLIDE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if not open:
		_tween.tween_callback(func() -> void:
			visible = false
		)


## True when the folder is expanded.
func is_open() -> bool:
	return _open


func _open_width() -> float:
	if list == null:
		return MIN_OPEN_WIDTH
	var min_size := list.get_combined_minimum_size()
	return maxf(MIN_OPEN_WIDTH, min_size.x)
