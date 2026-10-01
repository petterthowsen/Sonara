## ChevronScrollContainer - a ScrollContainer without scrollbars.
##
## Chevron buttons sit on the edges of each scrollable axis (top/bottom, left/right). Pressing one
## animates the scroll to reveal the next item(s). A button only shows while there is more content
## in its direction. The usual ScrollContainer API
## (scroll_vertical, get_v_scroll_bar(), ...) keeps working.
## The mouse wheel steps like the buttons, one item edge per notch, so it never parks an item
## half in view (which `fade_hidden_items` would hide). Shift+wheel scrolls horizontally.
##
## Items are the children of the content's first branching node (e.g. the FlowContainer inside a
## panel), so a press lands on an item edge. Without such items it pages by `page_fraction`.
## Enable an axis through the usual horizontal_scroll_mode / vertical_scroll_mode; the
## scrollbars themselves are always hidden.
##
## With `reserve_button_space` the buttons get their own strips instead of covering the content.
## The space is only taken while the content overflows, so content that fits uses the whole area.
## A reserved button that can't scroll further stays in place, dimmed and disabled.
##
## With `fade_hidden_items`, items not wholly inside the view fade to `hidden_item_alpha`, so
## the view never shows a half-cut item.
class_name ChevronScrollContainer extends ScrollContainer

const ICON_UP: Texture2D = preload("res://assets/icons/chevron-up.svg")
const ICON_DOWN: Texture2D = preload("res://assets/icons/chevron-down.svg")
const ICON_LEFT: Texture2D = preload("res://assets/icons/chevron-left.svg")
const ICON_RIGHT: Texture2D = preload("res://assets/icons/chevron-right.svg")

## Thickness of the button strips along the edge.
@export var button_thickness := 16.0:
	set(value):
		button_thickness = value
		_update_buttons()
## Keep the button strips clear of content instead of overlaying it (while overflowing).
@export var reserve_button_space := false:
	set(value):
		reserve_button_space = value
		_update_buttons()
## Seconds a press takes to scroll.
@export var animation_duration := 0.18
## Scroll to item edges. When off, a press scrolls by `page_fraction` of the view.
@export var snap_to_items := true
## Fraction of the view scrolled per press when there are no items to snap to.
@export_range(0.1, 1.0) var page_fraction := 0.75
## Fade items that are not wholly inside the view.
@export var fade_hidden_items := false:
	set(value):
		fade_hidden_items = value
		_update_item_fades()
## Opacity of items not wholly in view.
@export_range(0.0, 1.0) var hidden_item_alpha := 0.0
## Seconds an item takes to fade in or out.
@export var fade_duration := 0.12
@export var button_color := Color(0.1, 0.1, 0.1, 0.8)
@export var button_hover_color := Color(0.25, 0.25, 0.25, 0.9)

var _button_up: Button
var _button_down: Button
var _button_left: Button
var _button_right: Button
var _tween: Tween
## Where the running scroll animation is headed, so quick presses or wheel notches queue up
## from there instead of re-targeting the same item edge.
var _tween_target := 0.0
var _tween_vertical := true
## Holds the buttons. ScrollContainer lays out every Control child (internal ones too) as
## content, so the buttons live under a Node2D, which it leaves alone.
var _button_layer: Node2D
## The theme's own panel style, and the copy whose margins make room for reserved buttons.
var _base_panel: StyleBox
var _reserve_panel: StyleBox


func _ready() -> void:
	_button_layer = Node2D.new()
	# BACK: drawn after the content and picked first, so content in the strips can't take clicks.
	add_child(_button_layer, false, Node.INTERNAL_MODE_BACK)
	_button_up = _make_button(ICON_UP, true, -1)
	_button_down = _make_button(ICON_DOWN, true, 1)
	_button_left = _make_button(ICON_LEFT, false, -1)
	_button_right = _make_button(ICON_RIGHT, false, 1)

	_hide_scrollbars()
	_base_panel = get_theme_stylebox("panel")
	_reserve_panel = _base_panel.duplicate() if _base_panel else StyleBoxEmpty.new()
	add_theme_stylebox_override("panel", _reserve_panel)
	resized.connect(_update_buttons)
	sort_children.connect(_update_buttons)
	gui_input.connect(_on_gui_input)
	for bar in [get_v_scroll_bar(), get_h_scroll_bar()]:
		bar.changed.connect(_update_buttons)
		bar.value_changed.connect(_update_buttons.unbind(1))
		bar.value_changed.connect(_update_item_fades.unbind(1))
	sort_children.connect(_update_item_fades)
	_update_buttons.call_deferred()


## Scroll one step toward the end (`direction` 1) or start (-1) of an axis, animated.
func scroll_step(vertical: bool, direction: int) -> void:
	var target := _step_target(vertical, direction)
	_animate_to(vertical, target)


## Animate the scroll to the nearest line start, so no line is cut off at the near edge.
func snap_scroll(vertical: bool) -> void:
	var current := _current(vertical)
	var max_scroll := _max_scroll(vertical)
	var best := current
	var best_distance := INF
	for line in _line_edges(vertical):
		var start := minf(line.x, max_scroll)
		if absf(start - current) < best_distance:
			best_distance = absf(start - current)
			best = start
	if absf(best - current) >= 1.0:
		_animate_to(vertical, best)


## The outer length (height if `vertical`) nearest to `length` that shows a whole number of
## lines while overflowing, counting the panel margins and any reserved button space. Returns
## `length` unchanged when everything already fits, or when there are no items.
func snap_length(vertical: bool, length: float) -> float:
	var lines := _line_edges(vertical)
	if lines.is_empty():
		return length
	var base := _base_margin(vertical)
	if length - base >= lines[-1].y - lines[0].x:
		return length
	var overhead := base + (2.0 * button_thickness if reserve_button_space else 0.0)
	var view := length - overhead
	var best := lines[0].y - lines[0].x
	for line in lines:
		var span := line.y - lines[0].x
		if absf(span - view) < absf(best - view):
			best = span
	# Showing every line means nothing overflows, so no button space is reserved.
	if is_equal_approx(best, lines[-1].y - lines[0].x):
		return best + base
	return best + overhead


func _make_button(icon: Texture2D, vertical: bool, direction: int) -> Button:
	var button := Button.new()
	button.icon = icon
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_constant_override("icon_max_width", 12)
	var normal := StyleBoxFlat.new()
	normal.bg_color = button_color
	var hover := StyleBoxFlat.new()
	hover.bg_color = button_hover_color
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("disabled", normal)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.2))
	button.pressed.connect(scroll_step.bind(vertical, direction))
	button.visible = false
	_button_layer.add_child(button)
	return button


## Scrollbars are replaced by the buttons. Disabled axes stay disabled.
func _hide_scrollbars() -> void:
	if horizontal_scroll_mode != SCROLL_MODE_DISABLED:
		horizontal_scroll_mode = SCROLL_MODE_SHOW_NEVER
	if vertical_scroll_mode != SCROLL_MODE_DISABLED:
		vertical_scroll_mode = SCROLL_MODE_SHOW_NEVER


## Show each button only while its direction has more to reveal, and keep it on its edge.
## Reserved buttons stay while the axis overflows, disabled at the end they can't pass.
func _update_buttons() -> void:
	if _button_up == null:
		return
	var v_bar := get_v_scroll_bar()
	var h_bar := get_h_scroll_bar()
	var v_over := _overflows(true)
	var h_over := _overflows(false)
	_update_reserve(v_over, h_over)

	var v_max := _max_scroll(true)
	var h_max := _max_scroll(false)
	_set_button_state(_button_up, v_over, v_bar.value > 0.5)
	_set_button_state(_button_down, v_over, v_bar.value < v_max - 0.5)
	_set_button_state(_button_left, h_over, h_bar.value > 0.5)
	_set_button_state(_button_right, h_over, h_bar.value < h_max - 0.5)

	var t := button_thickness
	_button_up.position = Vector2.ZERO
	_button_up.size = Vector2(size.x, t)
	_button_down.position = Vector2(0.0, size.y - t)
	_button_down.size = Vector2(size.x, t)
	_button_left.position = Vector2.ZERO
	_button_left.size = Vector2(t, size.y)
	_button_right.position = Vector2(size.x - t, 0.0)
	_button_right.size = Vector2(t, size.y)


func _set_button_state(button: Button, overflowing: bool, can_scroll: bool) -> void:
	if reserve_button_space:
		button.visible = overflowing
		button.disabled = not can_scroll
	else:
		button.visible = overflowing and can_scroll
		button.disabled = false


## True when the axis is enabled and the content is longer than the area (without reserve).
func _overflows(vertical: bool) -> bool:
	if (vertical_scroll_mode if vertical else horizontal_scroll_mode) == SCROLL_MODE_DISABLED:
		return false
	var content := _content()
	if content == null:
		return false
	var content_size := content.get_combined_minimum_size()
	if vertical:
		return content_size.y > size.y - _base_margin(true) + 0.5
	return content_size.x > size.x - _base_margin(false) + 0.5


## Panel margins along an axis, before any reserved button space.
func _base_margin(vertical: bool) -> float:
	if _base_panel == null:
		return 0.0
	if vertical:
		return _base_panel.get_margin(SIDE_TOP) + _base_panel.get_margin(SIDE_BOTTOM)
	return _base_panel.get_margin(SIDE_LEFT) + _base_panel.get_margin(SIDE_RIGHT)


## Grow the panel margins by the button strips on overflowing axes. Only writes on change,
## since a margin change re-sorts the container and lands back here.
func _update_reserve(v_over: bool, h_over: bool) -> void:
	if _reserve_panel == null:
		return
	var v_extra := button_thickness if reserve_button_space and v_over else 0.0
	var h_extra := button_thickness if reserve_button_space and h_over else 0.0
	var margins := {
		SIDE_TOP: v_extra, SIDE_BOTTOM: v_extra, SIDE_LEFT: h_extra, SIDE_RIGHT: h_extra,
	}
	for side: Side in margins:
		var base := _base_panel.get_margin(side) if _base_panel else 0.0
		var want: float = base + margins[side]
		if not is_equal_approx(_reserve_panel.get_content_margin(side), want):
			_reserve_panel.set_content_margin(side, want)


func _max_scroll(vertical: bool) -> float:
	var bar := _bar(vertical)
	return maxf(bar.max_value - bar.page, 0.0)


func _bar(vertical: bool) -> ScrollBar:
	if vertical:
		return get_v_scroll_bar()
	return get_h_scroll_bar()


func _current(vertical: bool) -> float:
	return float(scroll_vertical if vertical else scroll_horizontal)


## Where a press from the current position should end up.
func _step_target(vertical: bool, direction: int) -> float:
	var current := _current(vertical)
	if _tween and _tween.is_valid() and _tween_vertical == vertical:
		current = _tween_target
	var max_scroll := _max_scroll(vertical)
	var page := _bar(vertical).page
	var edges: Array[Vector2] = _item_edges(vertical) if snap_to_items else []

	if edges.is_empty():
		return clampf(current + direction * page * page_fraction, 0.0, max_scroll)

	var target := max_scroll if direction > 0 else 0.0
	if direction > 0:
		# First item cut off at the far edge: bring its end into view.
		for edge: Vector2 in edges:
			if edge.y > current + page + 0.5:
				target = minf(edge.y - page, max_scroll)
				break
	else:
		# Last item cut off at the near edge: bring its start into view.
		for i in range(edges.size() - 1, -1, -1):
			if edges[i].x < current - 0.5:
				target = maxf(edges[i].x, 0.0)
				break
	return target


## The visible items: children of the content's first node with more than one child.
func _items() -> Array[Control]:
	var items: Array[Control] = []
	var content := _content()
	if content == null:
		return items
	var root: Control = content
	while root.get_child_count() == 1 and root.get_child(0) is Control:
		root = root.get_child(0)
	for child in root.get_children():
		var item := child as Control
		if item and item.visible:
			items.append(item)
	return items


## An item's rect in scrolled-content coordinates.
func _item_rect(item: Control, content: Control) -> Rect2:
	return Rect2(item.global_position - content.global_position, item.size)


## Fade each item toward full opacity when wholly inside the view, else toward
## `hidden_item_alpha`. Only starts a tween when an item's target changes.
func _update_item_fades() -> void:
	var content := _content()
	if content == null:
		return
	var view := Rect2(Vector2(scroll_horizontal, scroll_vertical),
			Vector2(_bar(false).page, _bar(true).page))
	for item in _items():
		var target := 1.0
		if fade_hidden_items:
			var r := _item_rect(item, content)
			var inside := true
			if vertical_scroll_mode != SCROLL_MODE_DISABLED:
				inside = r.position.y >= view.position.y - 0.5 and r.end.y <= view.end.y + 0.5
			if horizontal_scroll_mode != SCROLL_MODE_DISABLED:
				inside = inside and r.position.x >= view.position.x - 0.5 and r.end.x <= view.end.x + 0.5
			target = 1.0 if inside else hidden_item_alpha
		if is_equal_approx(float(item.get_meta(&"_fade_target", 1.0)), target):
			continue
		item.set_meta(&"_fade_target", target)
		if item.has_meta(&"_fade_tween"):
			var old: Tween = item.get_meta(&"_fade_tween")
			if old and old.is_valid():
				old.kill()
		var tween := item.create_tween()
		tween.tween_property(item, "modulate:a", target, fade_duration)
		item.set_meta(&"_fade_tween", tween)


## Start/end (x/y) of each item along the axis, in scrolled-content coordinates.
func _item_edges(vertical: bool) -> Array[Vector2]:
	var edges: Array[Vector2] = []
	var content := _content()
	if content == null:
		return edges
	for item in _items():
		var offset := _item_rect(item, content).position
		if vertical:
			edges.append(Vector2(offset.y, offset.y + item.size.y))
		else:
			edges.append(Vector2(offset.x, offset.x + item.size.x))
	return edges


## Item edges merged into lines (a FlowContainer row is one line), sorted by start.
func _line_edges(vertical: bool) -> Array[Vector2]:
	var edges := _item_edges(vertical)
	edges.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var lines: Array[Vector2] = []
	for edge in edges:
		if not lines.is_empty() and edge.x < lines[-1].y:
			lines[-1].y = maxf(lines[-1].y, edge.y)
		else:
			lines.append(edge)
	return lines


func _content() -> Control:
	for child in get_children():
		if child is Control and child.visible:
			return child
	return null


func _animate_to(vertical: bool, target: float) -> void:
	_kill_tween()
	_tween_target = target
	_tween_vertical = vertical
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scroll_vertical" if vertical else "scroll_horizontal",
			int(round(target)), animation_duration)


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null


## The wheel steps like the buttons. Handled here, from the gui_input signal, the event is
## accepted before ScrollContainer's own pixel scrolling sees it. A notch that can't scroll
## (nothing overflows, or already at the end) is left for the parent, e.g. the mixer's own scroll.
func _on_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var vertical := true
	var direction := 0
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			direction = -1
		MOUSE_BUTTON_WHEEL_DOWN:
			direction = 1
		MOUSE_BUTTON_WHEEL_LEFT:
			direction = -1
			vertical = false
		MOUSE_BUTTON_WHEEL_RIGHT:
			direction = 1
			vertical = false
		_:
			return
	if vertical and (mb.shift_pressed or vertical_scroll_mode == SCROLL_MODE_DISABLED):
		vertical = false
	if not _overflows(vertical):
		return
	var target := _step_target(vertical, direction)
	var from := _tween_target if _tween and _tween.is_valid() and _tween_vertical == vertical \
			else _current(vertical)
	if absf(target - from) < 0.5:
		return
	_animate_to(vertical, target)
	accept_event()
