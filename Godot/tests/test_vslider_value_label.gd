# test_vslider_value_label.gd
# VolumeSlider shows its value readout only on hover/drag, vertically centered, and moves it
# above or below the handle when the handle is near the center.
# Run: godot --headless --path Godot -s tests/test_vslider_value_label.gd -- --test
extends TestBase


func suite_name() -> String:
	return "VolumeSlider value label"


func run_tests() -> void:
	root.size = Vector2i(400, 400)
	var holder := Control.new()
	holder.size = Vector2(200, 300)
	root.add_child(holder)
	var slider: VolumeSlider = load("res://components/VSlider.gd").new()
	var edit: SmartLineEdit = (load("res://components/SmartLineEdit.tscn") as PackedScene).instantiate()
	edit.name = "SmartLineEdit"
	slider.add_child(edit)
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.size = Vector2(30, 200)
	holder.add_child(slider)
	await process_frame
	await process_frame
	holder.position = Vector2(40, 40)
	slider.size = Vector2(60, 200)  # narrow strip width
	await process_frame
	var tip: ValueTooltip = null

	_assert(slider._value_tooltip == null or not slider._value_tooltip.visible, "no readout when not hovered")
	_assert(not slider.smart_line_edit.visible, "the permanent label is gone")
	slider._on_mouse_entered()
	tip = slider._value_tooltip
	_assert(tip != null and tip.visible, "tooltip shows on hover")

	var win: Rect2 = Rect2(Vector2.ZERO, root.get_visible_rect().size)
	for v in [5.0, 10.0, 30.0, 45.0, 48.0, 50.0, 52.0, 55.0, 70.0, 95.0]:
		slider.value = v
		var tip_rect: Rect2 = Rect2(tip.global_position, tip.size)
		var handle_y: float = slider.get_global_rect().position.y + slider.size.y * (1.0 - v / 100.0)
		var handle: Rect2 = Rect2(slider.get_global_rect().position.x, handle_y - slider.handle_height * 0.5, slider.size.x, slider.handle_height)
		_assert(not tip_rect.intersects(handle), "value %s: tooltip does not cover the handle (%s vs %s)" % [v, tip_rect, handle])
		_assert(win.encloses(tip_rect), "value %s: tooltip inside the window" % v)
	slider.value = 10.0
	var centered := slider.get_global_rect().get_center().y
	_assert(absf(tip.global_position.y + tip.size.y * 0.5 - centered) < 1.0, "centered when the handle is far from center")

	slider._on_mouse_exited()
	_assert(not tip.visible, "hidden after the pointer leaves")
	slider._dragging = true
	slider._layout_value_label()
	_assert(tip.visible, "shown while dragging")
	slider._dragging = false
	slider._layout_value_label()
	_assert(not tip.visible, "hidden after the drag ends")
	holder.free()
