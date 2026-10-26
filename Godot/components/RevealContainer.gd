## RevealContainer - shows its children cut to an animatable height.
##
## With `reveal_height` at -1 it works like a plain container: children fill it, and its minimum
## size is the largest child minimum. Given a height, that height becomes its minimum height,
## and the children stay at least `content_height` (and their own minimum) tall, anchored to
## the top and clipped. A parent can then slide a panel open or shut below what its content
## would otherwise allow, without the content re-flowing on the way.
class_name RevealContainer extends Container

## The height shown, or -1 to show everything.
var reveal_height := -1.0:
	set(value):
		reveal_height = value
		update_minimum_size()
		queue_sort()
## The height the children keep while `reveal_height` is set, usually the open height.
var content_height := 0.0:
	set(value):
		content_height = value
		queue_sort()


func _init() -> void:
	clip_contents = true


func _get_minimum_size() -> Vector2:
	var min_size := Vector2.ZERO
	for child in _layout_children():
		min_size = min_size.max(child.get_combined_minimum_size())
	if reveal_height >= 0.0:
		min_size.y = reveal_height
	return min_size


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	for child in _layout_children():
		var height := size.y
		if reveal_height >= 0.0:
			height = maxf(maxf(height, content_height), child.get_combined_minimum_size().y)
		fit_child_in_rect(child, Rect2(0.0, 0.0, size.x, height))


func _layout_children() -> Array[Control]:
	var children: Array[Control] = []
	for child in get_children():
		var control := child as Control
		if control and control.visible and not control.top_level:
			children.append(control)
	return children
