## SplitOverdrag - notices a SplitContainer divider dragged on past where it can go.
##
## Godot clamps split_offset while dragging, so the overshoot is read from the pointer instead:
## the dragger gets the drag's input in its own coordinates, which move with the divider, so
## how far the pointer ends up from where it grabbed the divider is how far it went past it.
class_name SplitOverdrag


## Call `on_overdrag` when a drag of `split`'s divider is let go more than `threshold.call()`
## px past where the divider stopped, toward the second child (down, or right). Connected to
## the dragger's gui_input, which runs before the split's own drag_ended.
static func watch(split: SplitContainer, threshold: Callable, on_overdrag: Callable) -> void:
	var dragger: Control = null
	for child in split.get_children(true):
		if child.get_class() == "SplitContainerDragger":
			dragger = child
			break
	if dragger == null:
		push_warning("SplitOverdrag: %s has no dragger" % split.name)
		return
	var state := {"grab": 0.0, "pressed": false}
	dragger.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var along := mb.position.y if split.vertical else mb.position.x
		if mb.pressed:
			state.grab = along
			state.pressed = true
		elif state.pressed:
			state.pressed = false
			if along - float(state.grab) > float(threshold.call()):
				on_overdrag.call())
