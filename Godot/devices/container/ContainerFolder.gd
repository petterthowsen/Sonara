## Slide-out pane that hosts a container's child DevicePanels.
## Chain shows every child and sizes to fit them; Layer and Drum Machine show one focused child.
class_name ContainerFolder extends Control

const NestedDeviceListScene = preload("res://devices/container/NestedDeviceList.tscn")
const SLIDE_SEC := 0.18
const MIN_OPEN_WIDTH := 280.0

var list: NestedDeviceList = null
var _open: bool = false
var _tween: Tween = null


## Instantiate the nested list and keep folder width in sync with its children.
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
	list.minimum_size_changed.connect(_on_list_minimum_size_changed)
	add_child(list)


## Bind the nested list to `container` (or unbind when null).
func bind_to_container(container: DeviceInstance) -> void:
	if list == null:
		return
	await list.bind_to_container(container)


## Restrict the list to `child`, or show every child when `child` is null.
func set_focus_child(child: DeviceInstance) -> void:
	if list:
		await list.set_focus_child(child)


## Slide the folder open or closed.
func set_open(open: bool, animate: bool = true) -> void:
	if _open == open and visible == open:
		return
	_open = open
	if _tween:
		_tween.kill()
		_tween = null
	if open:
		visible = true
		_slide_to_open_width(animate)
		return
	if not animate or not is_inside_tree():
		custom_minimum_size.x = 0.0
		visible = false
		return
	_tween = create_tween()
	_tween.tween_property(self, "custom_minimum_size:x", 0.0, SLIDE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(func() -> void:
		visible = false
	)


## True when the folder is expanded.
func is_open() -> bool:
	return _open


## Width of the visible children (one for Layer/Drum, all of them for Chain).
func _open_width() -> float:
	if list == null:
		return MIN_OPEN_WIDTH
	list.update_minimum_size()
	var min_size := list.get_combined_minimum_size()
	return maxf(MIN_OPEN_WIDTH, min_size.x)


## Keep an open folder sized to its visible children.
func _sync_open_width() -> void:
	if not _open:
		return
	_slide_to_open_width(false)


## Animate (or snap) to the current children width.
func _slide_to_open_width(animate: bool) -> void:
	var target_w := _open_width()
	if absf(custom_minimum_size.x - target_w) < 0.5:
		return
	if _tween:
		_tween.kill()
		_tween = null
	if animate and is_inside_tree():
		_tween = create_tween()
		_tween.tween_property(self, "custom_minimum_size:x", target_w, SLIDE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		custom_minimum_size.x = target_w


## Grow or shrink after nested DevicePanels finish computing their min size.
func _on_list_minimum_size_changed() -> void:
	if not _open:
		return
	_slide_to_open_width(_tween != null and _tween.is_running())
