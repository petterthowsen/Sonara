## SimpleView.gd
## The Panel view generated from a device's parameters (REQ-001, REQ-009). Loads (or generates)
## the device's `SimpleLayout` through `SimpleLayoutStore`, lays out one `SimpleControl` per
## layout control on a fixed-size grid, and shows page tabs when there is more than one page.
## Edit mode (move/resize/rename/add/remove controls) is Phase 4 (T-014/T-015), not implemented here.

class_name SimpleView extends DeviceView

const SimpleControlScene := preload("res://devices/simple_view/SimpleControl.tscn")

## Pixel size of one grid cell, including the margin below.
@export var cell_size := Vector2(60, 60)
## Gap between adjacent cells.
@export var cell_margin := 6.0
## Height of the title strip inserted above every row where a titled group starts.
@export var group_header_height := 14.0

static var logger := Log.make("SimpleView")

@onready var _page_tabs: TabBar = $VBox/PageTabs
@onready var _scroll: ScrollContainer = $VBox/Scroll
@onready var _grid: Control = $VBox/Scroll/Grid

var layout: SimpleLayout = null
var _current_page: int = 0
var _controls: Array[SimpleControl] = []
var _group_boxes: Array[Control] = []
## Pixel y of each grid row on the current page (plus one entry for the bottom edge), shifted
## down by the group title strips above it. Grid cells stay square in the layout model; only
## the pixel placement makes room for group titles.
var _row_y: PackedFloat32Array = []


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
	_grid.custom_minimum_size = Vector2(layout.columns * cell_size.x, _row_y[layout.rows])
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
	var pixel_rect := _pixel_rect(GridPacker.rect_from_array(data.rect))
	control.position = pixel_rect.position + Vector2(cell_margin, cell_margin) * 0.5
	control.size = pixel_rect.size - Vector2(cell_margin, cell_margin)
	control.bind(device, data)
	_controls.append(control)


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
	var pixel_rect := _pixel_rect(GridPacker.rect_from_array(group.rect))
	var title_text := String(group.get("title", ""))
	var header := 0.0 if title_text.is_empty() else group_header_height
	var box := Panel.new()
	box.position = pixel_rect.position - Vector2(0, header)
	box.size = pixel_rect.size + Vector2(0, header)
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
		title.add_theme_font_size_override("font_size", 10)
		title.modulate = Color(1, 1, 1, 0.6)
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.position = Vector2(cell_margin, -1)
		title.size = Vector2(box.size.x - cell_margin * 2.0, header)
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(title)
	_group_boxes.append(box)
