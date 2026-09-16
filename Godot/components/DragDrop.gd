# DragDrop.gd
# Small helpers shared by the drop resolvers (mixer strips, tracks, device chains): the drag in
# progress, what part of a control is actually on screen, and forwarding drops from child controls.
class_name DragDrop extends RefCounted


## Data of the GUI drag in progress under `node`'s viewport, or null.
static func current_drag(node: Node) -> Variant:
	if node == null or not node.is_inside_tree():
		return null
	var viewport := node.get_viewport()
	if viewport == null or not viewport.gui_is_dragging():
		return null
	return viewport.gui_get_drag_data()


## Global rect of `control` clipped by every clipping ancestor (scroll containers etc.), so
## scrolled-out content can't catch drops.
static func visible_rect(control: Control) -> Rect2:
	if control == null or not control.is_visible_in_tree():
		return Rect2()
	var rect := control.get_global_rect()
	var node := control.get_parent()
	while node:
		if node is Control:
			var c := node as Control
			if c.clip_contents:
				rect = rect.intersection(c.get_global_rect())
			if c.top_level:
				break
		elif node is Viewport or node is CanvasLayer:
			break
		node = node.get_parent()
	return rect


## True when `point` is on a visible part of `control`.
static func is_point_visible(control: Control, point: Vector2) -> bool:
	var rect := visible_rect(control)
	return rect.has_area() and rect.has_point(point)


## Forward drops from every mouse-stopping control under `root` that has no drop handlers of its
## own, so buttons, knobs and labels don't swallow a drop the owner would accept. Subtrees in
## `skip_group` handle their own drops and are left alone.
static func forward_drops(root: Node, can: Callable, drop: Callable, skip_group: StringName = &"") -> void:
	for child in root.get_children():
		if skip_group != &"" and child.is_in_group(skip_group):
			continue
		if child is Control:
			var c := child as Control
			if c.mouse_filter == Control.MOUSE_FILTER_STOP and not _handles_drops(c):
				c.set_drag_forwarding(Callable(), can, drop)
		forward_drops(child, can, drop, skip_group)


## True when a script on `node` defines its own `_can_drop_data`.
static func _handles_drops(node: Node) -> bool:
	var script := node.get_script() as Script
	if script == null:
		return false
	for method in script.get_script_method_list():
		if method.name == "_can_drop_data":
			return true
	return false
