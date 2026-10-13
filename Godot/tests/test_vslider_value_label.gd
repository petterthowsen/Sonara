# test_vslider_value_label.gd
# VolumeSlider shows its value readout only on hover/drag, vertically centered, and moves it
# above or below the handle when the handle is near the center.
# Run: godot --headless --path Godot -s tests/test_vslider_value_label.gd -- --test
extends TestBase


func suite_name() -> String:
	return "VolumeSlider value label"


func run_tests() -> void:
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
	var label := slider.smart_line_edit
	var h := label.size.y

	_assert(not label.visible, "hidden when not hovered")
	slider._on_mouse_entered()
	_assert(label.visible, "shown on hover")
	slider.value = 10.0  # handle near the bottom
	_assert(is_equal_approx(label.position.y, (200.0 - label.size.y) * 0.5), "centered when the handle is far from center (%s)" % label.position.y)

	slider.value = 52.0  # handle just above center
	var handle_center := 200.0 * (1.0 - 0.52)
	_assert(label.position.y >= handle_center, "handle in upper half: label sits below it (%s vs %s)" % [label.position.y, handle_center])
	slider.value = 48.0  # handle just below center
	handle_center = 200.0 * (1.0 - 0.48)
	_assert(label.position.y + label.size.y <= handle_center, "handle in lower half: label sits above it (%s)" % label.position.y)
	_assert(label.position.y >= 0.0 and label.position.y + h <= 200.0, "label stays inside the slider")

	slider._on_mouse_exited()
	_assert(not label.visible, "hidden again after the pointer leaves")
	slider._dragging = true
	slider._layout_value_label()
	_assert(label.visible, "shown while dragging")
	slider._dragging = false
	slider._layout_value_label()
	_assert(not label.visible, "hidden after the drag ends")
	holder.free()
