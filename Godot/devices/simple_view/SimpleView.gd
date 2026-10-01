## SimpleView.gd
## The Panel view generated from a device's parameters (REQ-001, REQ-009). Loads (or generates)
## the device's `SimpleLayout` through `SimpleLayoutStore`, lays out one `SimpleControl` per
## layout control on a grid of cells, and hands its page titles to the DevicePanel header
## (`get_header_tabs`) when there is more than one page. The root is an HBoxContainer: the
## modulation sources in a scrolling two-column grid on the left, then the page grid. The view is
## as wide as the current page, and fits the panel's fixed height by shrinking rows; only the
## source column scrolls.
## Edit mode (move/resize/rename/add/remove controls) is Phase 4 (T-014/T-015), not implemented here.

class_name SimpleView extends DeviceView

const SimpleControlScene := preload("res://devices/simple_view/SimpleControl.tscn")

## Side of a (square) modulation source button.
const MOD_BUTTON_SIZE := 50.0
## Font size of a source button's name and route count.
const MOD_BUTTON_FONT_SIZE := 10
## Rows never get shorter than this, however little height the panel leaves.
const MIN_ROW_HEIGHT := 32.0

## Pixel size of one grid cell, including the margin below. Rows shrink below `cell_size.y` when
## the page doesn't fit the view's height; cells never grow past it.
@export var cell_size := Vector2(76, 68)
## Gap between adjacent cells.
@export var cell_margin := 6.0
## Height of the title strip inserted above every row where a titled group starts.
@export var group_header_height := 18.0
## Font size of group titles.
@export var group_title_font_size := 12
## Color of group titles.
@export var group_title_color := Color.WHITE
## Space kept clear around each group box, so neighbouring groups are separated by twice this.
@export var group_margin := 2.0

static var logger := Log.make("SimpleView")

## Source column for a device that offers modulation; hidden for devices without.
@onready var _mods: ScrollContainer = $Mods
@onready var _mod_grid: GridContainer = $Mods/Buttons
@onready var _grid: Control = $Grid

var layout: SimpleLayout = null
var _current_page: int = 0
var _controls: Array[SimpleControl] = []
var _group_boxes: Array[Control] = []
## Pixel y of each grid row on the current page (plus one entry for the bottom edge), shifted
## down by the group title strips above it. Grid cells stay square in the layout model; only
## the pixel placement makes room for group titles.
var _row_y: PackedFloat32Array = []
## Pixel height of one row on the current page: `cell_size.y`, or less when the page's rows and
## title strips don't fit the grid's height.
var _row_height := 68.0
## Grid height the current page was placed for; a different height rebuilds it.
var _built_height := -1.0
## Group id → `{rect, box}` on the current page: the group's saved cell rect and the cell rect
## its box is drawn over after growing into the free space to its right and below.
var _group_fit := {}
## Source id → its toggle button.
var _mod_buttons := {}
## The source in assign mode ("" when none): dragging a modulatable control sets its amount.
var _assign_source := ""


func _ready() -> void:
	_grid.gui_input.connect(_on_grid_gui_input)
	_grid.resized.connect(_on_grid_resized)


## Load (or generate) the layout and build the current page.
func _on_bind() -> void:
	if not is_node_ready():
		await ready
	_reload()


## Subscribe to parameter list changes so a plugin/SFZ device that advertises its parameters
## after this view was built gets its layout reconciled and redrawn.
func _on_view_shown() -> void:
	if device and not device.parameters_updated.is_connected(_on_parameters_updated):
		device.parameters_updated.connect(_on_parameters_updated)
	if device and not device.mod_route_changed.is_connected(_on_mod_route_changed):
		device.mod_route_changed.connect(_on_mod_route_changed)
	_reload()


func _on_view_hidden() -> void:
	if device and device.parameters_updated.is_connected(_on_parameters_updated):
		device.parameters_updated.disconnect(_on_parameters_updated)
	if device and device.mod_route_changed.is_connected(_on_mod_route_changed):
		device.mod_route_changed.disconnect(_on_mod_route_changed)
	set_assign_source("")


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	for control in _controls:
		if control.handles_param(param_id):
			control.refresh()


func _on_parameters_updated() -> void:
	_reload()


## Re-fetch the layout (which reconciles against the instance's current parameters, REQ-016)
## and rebuild the current page.
func _reload() -> void:
	if device == null or device.device == null:
		return
	layout = SimpleLayoutStore.load_or_generate(device.device, device.get_parameters())
	_current_page = clampi(_current_page, 0, maxi(layout.pages.size() - 1, 0))
	_build_mod_buttons()
	_build_page(_current_page)
	header_tabs_changed.emit()


## ============================================================================
## HEADER TABS (pages)
## ============================================================================

## Page titles, shown as tabs in the DevicePanel header; none for a single page.
func get_header_tabs() -> PackedStringArray:
	var titles := PackedStringArray()
	if layout != null and layout.pages.size() > 1:
		for page in layout.pages:
			titles.append(String(page.get("title", "")))
	return titles


func get_header_tab() -> int:
	return _current_page


func select_header_tab(index: int) -> void:
	if index != _current_page:
		_build_page(index)


## ============================================================================
## BUILD
## ============================================================================

## The panel's height reached the grid (or changed): place the page for it.
func _on_grid_resized() -> void:
	if layout != null and not is_equal_approx(_grid.size.y, _built_height):
		_build_page(_current_page)


func _build_page(index: int) -> void:
	_current_page = index
	_clear_page()
	if layout == null or index < 0 or index >= layout.pages.size():
		return
	var page: Dictionary = layout.pages[index]
	_built_height = _grid.size.y
	_compute_row_y(page)
	var page_columns := _page_columns(page)
	_group_fit = fit_groups(page, page_columns, _used_rows(page))
	# Only as wide as this page, so a sparse page doesn't leave a wide empty area (the devices
	# beside this one move over when pages are switched). The view takes its minimum width from
	# this, so the DevicePanel grows and shrinks to fit instead of scrolling; pages split content
	# that doesn't fit. No minimum height: the panel's height is fixed, and rows shrink to fit it.
	_grid.custom_minimum_size = Vector2(page_columns * cell_size.x, 0)
	for group in page.get("groups", []):
		_add_group_box(group)
	for control_data in page.get("controls", []):
		_add_control(control_data)


func _clear_page() -> void:
	for control in _controls:
		control.queue_free()
	_controls.clear()
	for box in _group_boxes:
		box.queue_free()
	_group_boxes.clear()


func _add_control(data: Dictionary) -> void:
	var control := SimpleControlScene.instantiate() as SimpleControl
	_grid.add_child(control)
	var pixel_rect := _control_pixel_rect(GridPacker.rect_from_array(data.rect), String(data.get("group", "")))
	control.position = pixel_rect.position + Vector2(cell_margin, cell_margin) * 0.5
	control.size = pixel_rect.size - Vector2(cell_margin, cell_margin)
	control.bind(device, _decorated(data))
	_controls.append(control)
	if not _assign_source.is_empty():
		control.set_mod_assign(_assign_source, _source_color(_assign_source))


## The layout control with the strategy's annotations (e.g. a Time knob's Sync sibling), resolved
## here so the saved layout stays free of display-only keys.
func _decorated(data: Dictionary) -> Dictionary:
	if layout == null or device == null:
		return data
	return SimpleLayoutGenerator.strategy_for(layout.kind).decorate_control(data, device.get_parameters())


## Columns `page` occupies (the right edge of its rightmost control or group), at least 1.
static func _page_columns(page: Dictionary) -> int:
	var right := 1
	for entry in page.get("controls", []) + page.get("groups", []):
		right = maxi(right, GridPacker.rect_from_array(entry.rect).end.x)
	return right


## Group id → `{rect, box}` for `page` (see `_group_fit`): each group box grows down, then
## right (down first, since generated pages are packed in columns), until it meets another group, an ungrouped control, or the page edge (`columns` ×
## `rows`). Its controls are then spread evenly over the box, so a column of groups lines up
## instead of leaving gaps beside the narrow ones.
static func fit_groups(page: Dictionary, columns: int, rows: int) -> Dictionary:
	var fit := {}
	var obstacles: Array[Rect2i] = []
	for control in page.get("controls", []):
		if String(control.get("group", "")).is_empty():
			obstacles.append(GridPacker.rect_from_array(control.rect))
	for group in page.get("groups", []):
		var rect := GridPacker.rect_from_array(group.rect)
		fit[group.id] = {"rect": rect, "box": rect}
	for id in fit:
		var box: Rect2i = fit[id].box
		var bottom := rows
		for other in _other_boxes(fit, id, obstacles):
			if other.position.x < box.end.x and other.end.x > box.position.x and other.position.y >= box.end.y:
				bottom = mini(bottom, other.position.y)
		box.size.y = maxi(box.size.y, bottom - box.position.y)
		fit[id].box = box
	for id in fit:
		var box: Rect2i = fit[id].box
		var right := columns
		for other in _other_boxes(fit, id, obstacles):
			if other.position.y < box.end.y and other.end.y > box.position.y and other.position.x >= box.end.x:
				right = mini(right, other.position.x)
		box.size.x = maxi(box.size.x, right - box.position.x)
		fit[id].box = box
	return fit


static func _other_boxes(fit: Dictionary, id: Variant, obstacles: Array[Rect2i]) -> Array[Rect2i]:
	var out := obstacles.duplicate()
	for other_id in fit:
		if other_id != id:
			out.append(fit[other_id].box)
	return out


## Pixel rect of a control: its grid cell, spread out inside its group's grown box so the gaps
## between (and around) its columns and rows are equal.
func _control_pixel_rect(rect: Rect2i, group_id: String) -> Rect2:
	var pixels := _pixel_rect(rect)
	var fit: Dictionary = _group_fit.get(group_id, {})
	if fit.is_empty():
		return pixels
	var saved: Rect2i = fit.rect
	var saved_pixels := _pixel_rect(saved)
	var box_pixels := _pixel_rect(fit.box)
	var gap := (box_pixels.size - saved_pixels.size) / Vector2(saved.size.x + 1, saved.size.y + 1)
	var cell := rect.position - saved.position
	return Rect2(pixels.position + gap * Vector2(cell.x + 1, cell.y + 1),
		pixels.size + gap * Vector2(rect.size.x - 1, rect.size.y - 1))


## Number of grid rows `page` occupies (the bottom edge of its lowest control or group), at least 1.
func _used_rows(page: Dictionary) -> int:
	var bottom := 1
	for entry in page.get("controls", []) + page.get("groups", []):
		bottom = maxi(bottom, GridPacker.rect_from_array(entry.rect).end.y)
	return mini(bottom, layout.rows)


## Fill `_row_y` for `page`: every row where a titled group starts gets a header strip above it.
## Rows are `cell_size.y` tall, or shorter when the used rows and their strips don't fit the
## grid's height (a grid with no height yet, as in a test, keeps full-size rows).
func _compute_row_y(page: Dictionary) -> void:
	var used_rows := _used_rows(page)
	var header_rows := {}
	for group in page.get("groups", []):
		if not String(group.get("title", "")).is_empty():
			header_rows[GridPacker.rect_from_array(group.rect).position.y] = true
	_row_height = cell_size.y
	if _grid.size.y > 0.0:
		var strips := 0
		for row in header_rows:
			if row < used_rows:
				strips += 1
		var fit := (_grid.size.y - strips * group_header_height) / used_rows
		_row_height = clampf(fit, MIN_ROW_HEIGHT, cell_size.y)
	_row_y.resize(layout.rows + 1)
	var y := 0.0
	for row in range(layout.rows + 1):
		if header_rows.has(row):
			y += group_header_height
		_row_y[row] = y
		y += _row_height


## Pixel rect of a grid rect on the current page (excluding any header strip above it).
func _pixel_rect(rect: Rect2i) -> Rect2:
	var top: float = _row_y[clampi(rect.position.y, 0, layout.rows)]
	var bottom: float = _row_y[clampi(rect.end.y - 1, 0, layout.rows)] + _row_height
	return Rect2(rect.position.x * cell_size.x, top, rect.size.x * cell_size.x, bottom - top)


## A background panel with a title strip on top, covering a group's controls.
func _add_group_box(group: Dictionary) -> void:
	var cells: Rect2i = _group_fit[group.id].box if _group_fit.has(group.id) else GridPacker.rect_from_array(group.rect)
	var pixel_rect := _pixel_rect(cells)
	var title_text := String(group.get("title", ""))
	var header := 0.0 if title_text.is_empty() else group_header_height
	var box := Panel.new()
	box.position = pixel_rect.position - Vector2(0, header) + Vector2(group_margin, group_margin)
	box.size = pixel_rect.size + Vector2(0, header) - Vector2(group_margin, group_margin) * 2.0
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.03)
	style.set_corner_radius_all(4)
	box.add_theme_stylebox_override("panel", style)
	_grid.add_child(box)
	_grid.move_child(box, 0)
	if header > 0.0:
		var title := Label.new()
		title.text = title_text
		title.add_theme_font_size_override("font_size", group_title_font_size)
		title.add_theme_color_override("font_color", group_title_color)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.position = Vector2(cell_margin, -1)
		title.size = Vector2(box.size.x - cell_margin * 2.0, header)
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(title)
	_group_boxes.append(box)


## ============================================================================
## MODULATION
## ============================================================================

## Leave assign mode on Esc.
func _unhandled_input(event: InputEvent) -> void:
	if not _assign_source.is_empty() and is_visible_in_tree() and event.is_action_pressed("ui_cancel"):
		set_assign_source("")
		get_viewport().set_input_as_handled()


## A click on empty grid space leaves assign mode (controls consume their own clicks).
func _on_grid_gui_input(event: InputEvent) -> void:
	if not _assign_source.is_empty() and event is InputEventMouseButton and event.pressed:
		set_assign_source("")


func _on_mod_route_changed(_source: String, param_id: int, _amount: float) -> void:
	for control in _controls:
		if control.handles_param(param_id):
			control.refresh_mod()
	_update_mod_button_labels()


## One square toggle button per modulation source, in the source's color, with its name and route
## count, two to a row in the scrolling column left of the page.
func _build_mod_buttons() -> void:
	for child in _mod_grid.get_children():
		_mod_grid.remove_child(child)
		child.queue_free()
	_mod_buttons.clear()
	var sources := device.get_mod_sources() if device else ([] as Array[Dictionary])
	_mods.visible = not sources.is_empty()
	for i in sources.size():
		var id: String = sources[i]["id"]
		var color := ModDisplay.source_color(i)
		var button := Button.new()
		button.name = id.validate_node_name()
		button.custom_minimum_size = Vector2(MOD_BUTTON_SIZE, MOD_BUTTON_SIZE)
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = "Modulate with %s: click, then drag a control" % sources[i]["name"]
		# The name wraps (e.g. "Filter" over "Env") so it fits the square.
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.clip_text = true
		button.add_theme_font_size_override("font_size", MOD_BUTTON_FONT_SIZE)
		button.add_theme_color_override("font_color", color)
		button.add_theme_color_override("font_hover_color", color)
		button.add_theme_color_override("font_pressed_color", Color.BLACK)
		button.add_theme_color_override("font_hover_pressed_color", Color.BLACK)
		button.add_theme_stylebox_override("normal", _source_style(color, false))
		button.add_theme_stylebox_override("hover", _source_style(color, false))
		button.add_theme_stylebox_override("pressed", _source_style(color, true))
		button.add_theme_stylebox_override("hover_pressed", _source_style(color, true))
		button.toggled.connect(func(pressed): set_assign_source(id if pressed else ""))
		button.mouse_entered.connect(_highlight_targets.bind(id, color))
		button.mouse_exited.connect(_highlight_targets.bind("", color))
		_mod_grid.add_child(button)
		_mod_buttons[id] = button
	_update_mod_button_labels()


static func _source_style(color: Color, filled: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color if filled else Color(color, 0.12)
	style.border_color = color
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.set_content_margin_all(2)
	return style


## Each button's label: the source's name, with its route count on a line below once it has routes.
func _update_mod_button_labels() -> void:
	if device == null:
		return
	for source in device.get_mod_sources():
		var button: Button = _mod_buttons.get(source["id"])
		if button == null:
			continue
		var count := device.get_route_count_for_source(source["id"])
		button.text = source["name"] if count == 0 else "%s\n%d" % [source["name"], count]


func _source_color(source: String) -> Color:
	var sources := device.get_mod_sources() if device else ([] as Array[Dictionary])
	for i in sources.size():
		if sources[i]["id"] == source:
			return ModDisplay.source_color(i)
	return Color.WHITE


## Enter assign mode for `source`, or leave it with "".
func set_assign_source(source: String) -> void:
	_assign_source = source
	var color := _source_color(source)
	for id in _mod_buttons:
		(_mod_buttons[id] as Button).set_pressed_no_signal(id == source)
	for control in _controls:
		control.set_mod_assign(source, color)


## Dim the controls that `source` doesn't modulate, while its button is hovered.
func _highlight_targets(source: String, color: Color) -> void:
	for control in _controls:
		if control.is_modulatable():
			control.set_mod_highlight(source, color)
