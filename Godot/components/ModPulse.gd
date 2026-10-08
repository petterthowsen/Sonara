@tool
## Redraws its parent control every frame so the bound-modulator overlay can pulse
## (`ModDisplay.pulse_alpha`). Added and removed by `ModDisplay.set_pulsing`, so the control's own
## `_process` stays free for its other work.
extends Node


func _process(_delta: float) -> void:
	var parent := get_parent() as CanvasItem
	if parent:
		parent.queue_redraw()
