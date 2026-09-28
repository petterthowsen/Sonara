## SimpleView.gd
## The Panel view generated from a device's parameters (REQ-001, REQ-009). Loads (or generates)
## the device's `SimpleLayout` through `SimpleLayoutStore`, lays out one `SimpleControl` per
## layout control on a grid of fixed-size cells, and shows page tabs when there is more than one
## page. The view never scrolls: its root is a VBoxContainer (tabs above the grid) whose minimum
## size is the tabs plus the current page, so it grows and shrinks as pages are switched.
## Edit mode (move/resize/rename/add/remove controls) is Phase 4 (T-014/T-015), not implemented here.

class_name SimpleView extends DeviceView

const SimpleControlScene := preload("res://devices/simple_view/SimpleControl.tscn")

## Pixel size of one grid cell, including the margin below.
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

@onready var _page_tabs: TabBar = $PageTabs
@onready var _grid: Control = $Grid

var layout: SimpleLayout = null
var _current_page: int = 0
var _controls: Array[SimpleControl] = []
var _group_boxes: Array[Control] = []
## Pixel y of each grid row on the current page (plus one entry for the bottom edge), shifted
## down by the group title strips above it. Grid cells stay square in the layout model; only
## the pixel placement makes room for group titles.
var _row_y: PackedFloat32Array = []
## Group id → `{rect, box}` on the current page: the group's saved cell rect and the cell rect
## its box is drawn over after growing into the free space to its right and below.
var _group_fit := {}


func _ready() -> void:
	if not _page_tabs.tab_changed.is_connected(_on_tab_changed):
		_page_tabs.tab_changed.connect(_on_tab_changed)


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
	_reload()


func _on_view_hidden() -> void:
	if device and device.parameters_updated.is_connected(_on_parameters_updated):
		device.parameters_updated.disconnect(_on_parameters_updated)


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
	_build_page_tabs()
	_build_page(_current_page)


func _on_tab_changed(index: int) -> void:
	_build_page(index)


## ============================================================================
## BUILD
## ============================================================================

func _build_page_tabs() -> void:
	_page_tabs.tab_changed.disconnect(_on_tab_changed)
	_page_tabs.clear_tabs()
	for page in layout.pages:
		_page_tabs.add_tab(String(page.get("title", "")))
	_page_tabs.visible = layout.pages.size() > 1
	if layout.pages.size() > 0:
		_page_tabs.current_tab = _current_page
	_page_tabs.tab_changed.connect(_on_tab_changed)


func _build_page(index: int) -> void:
	_current_page = index
	_clear_page()
	if layout == null or index < 0 or index >= layout.pages.size():
		return
	var page: Dictionary = layout.pages[index]
	_compute_row_y(page)
	var page_columns := _page_columns(page)
	_group_fit = fit_groups(page, page_columns, _used_rows(page))
	# Only as big as this page, so a sparse page doesn't leave a wide empty area (the devices
	# beside this one move over when pages are switched). The view (a VBoxContainer) takes its
	# minimum size from this, so the DevicePanel grows and shrinks to fit instead of scrolling;
	# pages split content that doesn't fit. The page tabs clip and scroll with arrow buttons, so
	# they only need room for one tab plus the arrows.
	_grid.custom_minimum_size = Vector2(page_columns * cell_size.x, _row_y[_used_rows(page)])
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
	control.bind(device, data)
	_controls.append(control)


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
func _compute_row_y(page: Dictionary) -> void:
	var header_rows := {}
	for group in page.get("groups", []):
		if not String(group.get("title", "")).is_empty():
			header_rows[GridPacker.rect_from_array(group.rect).position.y] = true
	_row_y.resize(layout.rows + 1)
	var y := 0.0
	for row in range(layout.rows + 1):
		if header_rows.has(row):
			y += group_header_height
		_row_y[row] = y
		y += cell_size.y


## Pixel rect of a grid rect on the current page (excluding any header strip above it).
func _pixel_rect(rect: Rect2i) -> Rect2:
	var top: float = _row_y[clampi(rect.position.y, 0, layout.rows)]
	var bottom: float = _row_y[clampi(rect.end.y - 1, 0, layout.rows)] + cell_size.y
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
