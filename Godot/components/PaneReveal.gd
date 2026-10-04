## PaneReveal - a clipping container that reveals its child horizontally.
##
## The child is always laid out at the full size; the container reports its minimum width as
## the child's minimum times `reveal` and clips, so tweening `reveal` between 0 and 1 slides
## the child in and out of the surrounding layout (the parent container resizes smoothly too).
## With `reveal` at 1 the layout behaves as if the child sat in it directly.
class_name PaneReveal extends Container

## 0 = fully hidden (no width in the layout), 1 = fully shown.
@export var reveal := 1.0:
	set(value):
		reveal = clampf(value, 0.0, 1.0)
		update_minimum_size()
		queue_sort()


func _get_minimum_size() -> Vector2:
	var min_size := Vector2()
	for child in get_children():
		if child is Control and child.visible and not child.is_queued_for_deletion():
			min_size = min_size.max((child as Control).get_combined_minimum_size())
	return Vector2(min_size.x * reveal, min_size.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		for child in get_children():
			if child is Control and child.visible:
				fit_child_in_rect(child, Rect2(Vector2.ZERO, size))
