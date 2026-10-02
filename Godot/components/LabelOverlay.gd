@tool
## Shows a trimmed Label's full text on top of everything, centered on the label, while the
## label or any of its hover sources (e.g. the knob it captions) is hovered. Top-level and
## click-through, so it never affects layout. Nothing shows when the text fits.
##
##     LabelOverlay.attach(caption, [knob])
class_name LabelOverlay extends PanelContainer

var _target: Label
var _text_label: Label
var _hovered := {}  # hover source → true


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true
	z_index = 127
	visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.94)
	style.set_corner_radius_all(3)
	style.content_margin_left = 4
	style.content_margin_right = 4
	add_theme_stylebox_override("panel", style)
	_text_label = Label.new()
	_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_text_label)


## Attach an overlay to `label`. The label itself always counts as a hover source; its
## mouse_filter becomes PASS so it can be hovered.
static func attach(label: Label, hover_sources: Array[Control] = []) -> LabelOverlay:
	var overlay := LabelOverlay.new()
	overlay._target = label
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_child(overlay, false, Node.INTERNAL_MODE_BACK)
	overlay.add_hover_source(label)
	for source in hover_sources:
		overlay.add_hover_source(source)
	label.visibility_changed.connect(overlay._on_target_visibility_changed)
	return overlay


func add_hover_source(source: Control) -> void:
	source.mouse_entered.connect(_set_hovered.bind(source, true))
	source.mouse_exited.connect(_set_hovered.bind(source, false))
	source.tree_exiting.connect(_set_hovered.bind(source, false))


## True when the label's text doesn't fit and shows an ellipsis.
func is_truncated() -> bool:
	if _target == null or _target.text.is_empty():
		return false
	var font := _target.get_theme_font("font")
	var font_size := _target.get_theme_font_size("font_size")
	return font.get_string_size(_target.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > _target.size.x


func _set_hovered(source: Control, hovered: bool) -> void:
	if hovered:
		_hovered[source] = true
	else:
		_hovered.erase(source)
	refresh()


func _on_target_visibility_changed() -> void:
	if not _target.is_visible_in_tree():
		_hovered.clear()
	refresh()


## Show or hide the overlay for the current hover state and text.
func refresh() -> void:
	var wanted := not _hovered.is_empty() and _target.is_node_ready() and _target.is_visible_in_tree() \
		and is_truncated()
	if not wanted:
		visible = false
		return
	_text_label.text = _target.text
	_text_label.modulate = _target.modulate
	_text_label.add_theme_font_size_override("font_size", _target.get_theme_font_size("font_size"))
	visible = true
	var overlay_size := get_combined_minimum_size()
	size = overlay_size
	var pos := _target.get_global_rect().get_center() - overlay_size * 0.5
	var view_width := get_viewport_rect().size.x
	pos.x = clampf(pos.x, 0.0, maxf(view_width - overlay_size.x, 0.0))
	global_position = pos
