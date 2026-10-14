## The Modulators pane of the DevicePanel (spec 018, rebuilt in 033): a column-major grid of square
## modulator panels, each in its own `Modulator.cell`, with `+` placeholders in every empty cell
## (gaps and the trailing ones), and the selected modulator's settings on the right. The device
## lane's horizontal scroll is the only scrolling surface — the pane widens one column per growth
## step.
##
## The detail column shows the selected modulator's options: one scene per kind in `options/`
## (`OPTIONS_SCENES`), laid out in the editor from `ModParamSlot`s. A kind without a scene gets
## `GenericOptions` (a generated row, or "No settings" for velocity, keytrack, random, release).
class_name ModulatorsPane extends HBoxContainer

## Options scene per modulator kind; any other kind gets `GENERIC_OPTIONS`.
const OPTIONS_SCENES := {
	"lfo": "res://devices/modulators/options/LfoOptions.tscn",
	"adsr": "res://devices/modulators/options/EnvelopeOptions.tscn",
	"ad": "res://devices/modulators/options/EnvelopeOptions.tscn",
	"knob": "res://devices/modulators/options/KnobOptions.tscn",
	"cc": "res://devices/modulators/options/CcOptions.tscn",
	"sidechain": "res://devices/modulators/options/SidechainOptions.tscn",
}
## An XY pad pair's options (both slots on one slider).
const XY_PAD_OPTIONS := "res://devices/modulators/options/XYPadOptions.tscn"
const GENERIC_OPTIONS := "res://devices/modulators/options/GenericOptions.tscn"
const PLACEHOLDER_SCENE := "res://devices/modulators/ModulatorPlaceholder.tscn"

## Grid geometry: `ROWS`-cell columns of square cells (`SEP` apart), filling the pane's height; the column width follows so cells stay square.
const ROWS := 3
const SEP := 2
## Width of a column holding only `+` placeholders: narrow rectangles, not squares.
const PLACEHOLDER_COLUMN_WIDTH := 40

## Selected modulator per device instance id, remembered while the session lives.
static var _remembered: Dictionary = {}

var device: DeviceInstance = null

var _grid: HBoxContainer = null
var _kind_menu: PopupMenu = null
var _detail: VBoxContainer = null
var _tiles: Array[ModulatorPanel] = []
var _placeholders: Array[Button] = []
## Placeholder-only column appended while a drag is in progress, so a panel can be dropped past
## the last one; null otherwise.
var _drag_column: VBoxContainer = null
## Grid cell of the placeholder whose `+` menu is open (the add lands there).
var _add_cell := -1
## Square cell side applied to every cell; 0 until the first layout.
var _side := 0
## Times `_layout_panel_size` actually applied a side (stays put when the height didn't change).
var _layout_count := 0
## Swap drag in progress (started by a panel, resolved and committed here in `_input`).
var _drag: ModulatorDrag = null
var _indicator: DropIndicator = null
var _selected_mod_id := -1
var _detail_title: Label = null
## The selected modulator's options scene, or null.
var _options: ModulatorOptions = null
## Modulator the detail column was built for; -1 when it holds no controls to update in place.
var _detail_mod_id := -1
## Pair the detail column shows (an XY pad); null otherwise.
var _detail_pad: XYPad = null


func _ready() -> void:
	add_theme_constant_override("separation", 8)


## Bind to `dev` and show its modulators. Safe to call before the node is ready.
func bind_to_device(dev) -> void:
	unbind()
	device = dev
	if not is_node_ready():
		await ready
	if _grid == null:
		_build_structure()
	_refresh_kinds()
	device.modulator_added.connect(_on_modulator_added)
	device.modulator_removed.connect(_on_modulator_removed)
	device.modulator_changed.connect(_on_modulator_changed)
	device.modulators_reordered.connect(_on_modulators_reordered)
	device.route_changed.connect(_on_route_changed)
	device.name_changed.connect(_on_device_name_changed)
	_rebuild_grid()


func unbind() -> void:
	if device == null:
		return
	if ModAssign.active_owner() == device:
		ModAssign.end()
	if device.modulator_added.is_connected(_on_modulator_added):
		device.modulator_added.disconnect(_on_modulator_added)
	if device.modulator_removed.is_connected(_on_modulator_removed):
		device.modulator_removed.disconnect(_on_modulator_removed)
	if device.modulator_changed.is_connected(_on_modulator_changed):
		device.modulator_changed.disconnect(_on_modulator_changed)
	if device.modulators_reordered.is_connected(_on_modulators_reordered):
		device.modulators_reordered.disconnect(_on_modulators_reordered)
	if device.route_changed.is_connected(_on_route_changed):
		device.route_changed.disconnect(_on_route_changed)
	if device.name_changed.is_connected(_on_device_name_changed):
		device.name_changed.disconnect(_on_device_name_changed)
	device = null
	_clear_grid()
	_clear_detail()


# ============================================================================
# STRUCTURE
# ============================================================================

func _build_structure() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# No minimum width: the columns set the grid's width, so no gap opens before the options.
	var left := VBoxContainer.new()
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", SEP)
	add_child(left)

	# The tab button already names the pane; no title row — the grid gets the full height.

	# Column-major grid: an HBox of 3-cell columns, so cell `i` sits in column `i / 3`, row `i % 3`.
	# No scrolling here — the device lane scrolls the pane horizontally.
	_grid = HBoxContainer.new()
	_grid.add_theme_constant_override("separation", SEP)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_grid)

	# The shared `+` menu: every placeholder opens it filled with the registry's kinds.
	_kind_menu = PopupMenu.new()
	_kind_menu.theme_type_variation = &"ContextMenuList"
	_kind_menu.id_pressed.connect(_on_add_kind)
	add_child(_kind_menu)

	# The options column: no ScrollContainer, ever. The device panel's height is fixed, so an
	# options scene lays its controls out sideways and the device lane scrolls a wide pane.
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 6)
	_detail.custom_minimum_size.x = 140
	add_child(_detail)

	# The pane's own `resized` fires before its children are re-fitted, so reading the grid's
	# parent height there sees the previous layout and the final size is never observed (the
	# pane settles and never resizes again — blank displays after a reveal until something
	# else resizes it). The parent's `resized` fires once its height is final.
	left.resized.connect(_layout_panel_size)


## Advertised kinds in the placeholder's `+` menu (refreshed when the registry re-announces them).
## The XY pad is one entry (spec 036 D6): `xyy` is hidden, `xyx` lists as "XY Pad", and picking
## it adds the whole pair through `DeviceInstance.add_xy_pad`.
func _refresh_kinds() -> void:
	if _kind_menu == null:
		return
	_kind_menu.clear()
	var registry = _registry()
	var kinds: Array = registry.get_modulator_kinds() if registry != null else []
	for kind in kinds:
		var kind_id := String(kind.get("id", ""))
		if kind_id == "xyy":
			continue
		var label := String(kind.get("name", kind_id))
		if kind_id == "xyx":
			label = "XY Pad"
		_kind_menu.add_item(label, _kind_menu.item_count)
		_kind_menu.set_item_metadata(_kind_menu.item_count - 1, kind_id)


func _registry():
	var tree := get_tree()
	if tree == null:
		return null
	var service = tree.root.get_node_or_null("AssetService")
	return service.device_registry if service != null else null


# ============================================================================
# GRID (panels and placeholder cells)
# ============================================================================

## Rebuild the column-major grid: tile `t` sits in cell `t.cell` (column `cell / 3`, row
## `cell % 3`); every other cell is a placeholder. `C = (last + 1) / 3 + 1` columns, `last` being
## the highest occupied cell, so at least one placeholder trails the last panel (a whole column
## of them when its column is full). Rebuilt on add/remove/reorder; the selection is kept by
## `mod_id`. While a drag runs, `_add_drag_column` adds one more column.
##
## Pair-aware (spec 036): an adjacent `xyx`+`xyy` becomes ONE tile (`setup_pair`); an orphan
## `xyx`/`xyy` (a hand-edited save) degrades to a plain tile.
func _rebuild_grid() -> void:
	_clear_grid()
	if device == null:
		return
	var by_cell: Dictionary = {}
	var last := -1
	var i := 0
	while i < device.modulators.size():
		var mod: Modulator = device.modulators[i]
		var entry: Variant = mod
		if mod.kind == "xyx" and i + 1 < device.modulators.size() \
				and device.modulators[i + 1].kind == "xyy":
			var pad := XYPad.new()
			pad.x = mod
			pad.y = device.modulators[i + 1]
			entry = pad
			i += 2
		else:
			i += 1
		by_cell[mod.cell] = entry
		last = maxi(last, mod.cell)
	var columns := (last + 1) / ROWS + 1
	for c in columns:
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", SEP)
		column.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_grid.add_child(column)
		for r in ROWS:
			var k: int = c * ROWS + r
			if by_cell.has(k):
				_add_panel(column, by_cell[k])
			else:
				_add_placeholder(column, k)
	if _drag != null:
		_add_drag_column()
	if _side > 0:
		_apply_side()
	else:
		# First layout: the parent's height isn't final yet (a `resized` may have fired before the
		# structure existed), so size the cells after this frame's layout pass.
		_layout_panel_size.call_deferred()
	_sync_placeholders()
	if _selected_mod_id < 0 or device.get_modulator(_selected_mod_id) == null:
		_selected_mod_id = int(_remembered.get(device.id, device.modulators[0].mod_id if not device.modulators.is_empty() else -1))
	_refresh_selection()


## At the capacity limit every placeholder is disabled: REQ-002 keeps placeholders non-zero
## without offering an add `add_modulator` would refuse. A drop on one still moves a panel there.
func _sync_placeholders() -> void:
	var full := device.modulators.size() >= device.MAX_MODULATORS
	for placeholder in _placeholders:
		placeholder.disabled = full
		placeholder.tooltip_text = ("Maximum of %d modulators" % device.MAX_MODULATORS) if full else "Add modulator"


## During a drag: one more placeholder column after the last, unless that one already holds
## only placeholders — so a panel can always be dropped into a fresh column.
func _add_drag_column() -> void:
	if _drag_column != null or _grid.get_child_count() == 0:
		return
	var last_column := _grid.get_child(_grid.get_child_count() - 1)
	if not last_column.get_children().any(func(cell): return cell is ModulatorPanel):
		return
	_drag_column = VBoxContainer.new()
	_drag_column.add_theme_constant_override("separation", SEP)
	_drag_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.add_child(_drag_column)
	var first: int = (_grid.get_child_count() - 1) * ROWS
	for r in ROWS:
		_add_placeholder(_drag_column, first + r)
	if _side > 0:
		_apply_side()
	_sync_placeholders()


func _remove_drag_column() -> void:
	if _drag_column == null:
		return
	for cell in _drag_column.get_children():
		_placeholders.erase(cell)
	_grid.remove_child(_drag_column)
	_drag_column.queue_free()
	_drag_column = null


func _add_panel(column: VBoxContainer, entry: Variant) -> void:
	var panel := ModulatorPanel.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(panel)
	if entry is XYPad:
		panel.setup_pair(entry)
	else:
		panel.setup(entry)
	panel.selected.connect(_on_panel_clicked)
	panel.drag_started.connect(_on_panel_drag_started)
	_tiles.append(panel)


## Flat `+` cell (`ModulatorPlaceholder.tscn`, its icon centered at its own size) for empty grid
## cell `cell` (its `cell` meta): opens the shared kind menu, and the add lands in that cell.
func _add_placeholder(column: VBoxContainer, cell: int) -> void:
	var button: Button = load(PLACEHOLDER_SCENE).instantiate()
	button.set_meta(&"cell", cell)
	button.pressed.connect(_on_placeholder_pressed.bind(button))
	_placeholders.append(button)
	column.add_child(button)


func _clear_grid() -> void:
	# Detach before queue_free so the grid's child count is correct immediately (queued deletions
	# land at the end of the frame, but a rebuild can happen several times within one). Freeing a
	# column frees its cells; the panel/placeholder lists are tracked separately.
	for column in _grid.get_children():
		_grid.remove_child(column)
		column.queue_free()
	_drag_column = null
	_tiles.clear()
	_placeholders.clear()


## Square sizing: cells fill the pane's height (no fixed sizes); only the column width is set,
## to the resulting cell height, so cells stay square. Applied only when the side changes.
func _layout_panel_size() -> void:
	if _grid == null:
		return
	var parent := _grid.get_parent() as Control
	var side := maxi(0, int(floor((parent.size.y - (ROWS - 1) * SEP) / ROWS)))
	if side == _side:
		return
	_side = side
	_layout_count += 1
	_apply_side()


## Apply the current side as each column's width; a column of only placeholders stays narrow.
func _apply_side() -> void:
	for column in _grid.get_children():
		var has_panel := column.get_children().any(func(cell): return cell is ModulatorPanel)
		column.custom_minimum_size.x = _side if has_panel else mini(_side, PLACEHOLDER_COLUMN_WIDTH)


func _refresh_selection() -> void:
	for tile in _tiles:
		if tile.modulator != null:
			tile.set_selected(tile.modulator.mod_id == _selected_mod_id)
			tile.refresh()
	_refresh_detail()


## A panel click: selects it, or deselects it when it already was (which hides the settings).
func _on_panel_clicked(mod_id: int) -> void:
	_select(-1 if mod_id == _selected_mod_id else mod_id)


func _select(mod_id: int) -> void:
	_selected_mod_id = mod_id
	if device != null:
		_remembered[device.id] = mod_id
	_refresh_selection()


func _on_placeholder_pressed(button: Button) -> void:
	if device == null or button.disabled:
		return
	_add_cell = int(button.get_meta(&"cell", -1))
	ContextMenuPopup.popup_below_control(_kind_menu, button)


func _on_add_kind(id: int) -> void:
	if device == null:
		return
	if id < 0 or id >= _kind_menu.item_count:
		return
	var kind_id := String(_kind_menu.get_item_metadata(id))
	var cell := _add_cell
	_add_cell = -1
	if kind_id == "xyx":
		var pad: XYPad = device.add_xy_pad(cell)
		if pad != null:
			_select(pad.x.mod_id)
		return
	var mod = device.add_modulator(kind_id, cell)
	if mod != null:
		_select(mod.mod_id)


func _on_modulator_added(mod: Modulator) -> void:
	_rebuild_grid()
	_select(mod.mod_id)


func _on_modulator_removed(mod_id: int) -> void:
	if ModAssign.is_active_for(device, mod_id):
		ModAssign.end()
	if _selected_mod_id == mod_id:
		_selected_mod_id = -1
		if device != null:
			_remembered.erase(device.id)
	_rebuild_grid()


## A reorder: rebuild (array order is display order) and recolour every modulated knob on the
## device — arcs take their colour from the array index.
func _on_modulators_reordered() -> void:
	_rebuild_grid()
	ModAssign.notify_changed()


func _on_modulator_changed(mod_id: int) -> void:
	for tile in _tiles:
		if tile.modulator != null and tile.represents(mod_id):
			tile.refresh()
	if _detail_pad != null and _detail_pad.holds(mod_id):
		_options.sync()
	elif mod_id == _selected_mod_id:
		_sync_detail()


func _on_route_changed(_mod_id: int, _target: String, _amount: float) -> void:
	for tile in _tiles:
		if tile.modulator != null:
			tile.refresh()


func _on_device_name_changed(_new_name: String) -> void:
	_refresh_selection()


# ============================================================================
# MOVE DRAG
# ============================================================================

## A panel crossed the drag threshold: own the drag, follow the mouse, commit on release. The
## grid grows a spare placeholder column for the drag's duration.
func _on_panel_drag_started(mod: Modulator) -> void:
	if device == null or _drag != null:
		return
	_drag = ModulatorDrag.start(self, mod)
	if _drag != null:
		_add_drag_column()
		_indicator = DropIndicator.place(self, _indicator, Rect2(), true)
		DropIndicator.hide_indicator(_indicator)


func _input(event: InputEvent) -> void:
	if _drag == null:
		return
	if event is InputEventMouseMotion:
		_drag.preview.global_position = event.global_position + Vector2(-12, -12)
		var target := ModulatorDrag.resolve(self, _drag, event.global_position)
		if target.is_valid():
			DropIndicator.place(self, _indicator, target.indicator_rect, true)
		else:
			DropIndicator.hide_indicator(_indicator)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		var target := ModulatorDrag.resolve(self, _drag, event.global_position)
		target.commit(_drag)
		_end_drag()


## Drop or cancel: free the ghost, hide the indicator, drop the spare column (a commit already
## rebuilt the grid). Nothing needs undoing — nothing moved.
func _end_drag() -> void:
	if _drag != null:
		_drag.preview.queue_free()
		_drag = null
	if _grid != null:
		_remove_drag_column()
	DropIndicator.hide_indicator(_indicator)


func _exit_tree() -> void:
	_end_drag()


# ============================================================================
# DETAIL
# ============================================================================

func _clear_detail() -> void:
	_detail_mod_id = -1
	_detail_pad = null
	_options = null
	_detail_title = null
	if _detail == null:
		return
	# Detach first so an options scene drops its external connections (`_exit_tree`) right away.
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()


## Push the model's values into the existing controls. Rebuilding here would free the control
## being dragged (every edit echoes back as `modulator_changed`), so only rebuild when the detail
## isn't showing the selected modulator.
func _sync_detail() -> void:
	var mod := device.get_modulator(_selected_mod_id) if device != null else null
	if mod == null or _detail_mod_id != mod.mod_id:
		_refresh_detail()
		return
	if _options != null:
		_options.sync()


func _refresh_detail() -> void:
	_clear_detail()
	if _detail == null or device == null:
		return
	var mod := device.get_modulator(_selected_mod_id)
	_detail.visible = mod != null
	if mod == null:
		return
	_detail_mod_id = mod.mod_id
	_detail_title = Label.new()
	_detail_title.text = mod.name
	_detail_title.clip_text = true
	_detail_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_child(_detail_title)

	# A pair's Y slot (or an orphan XY half) shows the generic Position control like any kind.
	var pad := _pair_of(mod)
	var path: String = XY_PAD_OPTIONS if pad != null else OPTIONS_SCENES.get(mod.kind, GENERIC_OPTIONS)
	_options = load(path).instantiate()
	_detail.add_child(_options)
	if pad != null:
		_detail_pad = pad
		(_options as XYPadOptions).setup_pair(pad)
	else:
		_options.setup(mod)


## The pad `mod` heads (an `xyx` immediately followed by its `xyy`), or null.
func _pair_of(mod: Modulator) -> XYPad:
	if mod == null or mod.kind != "xyx":
		return null
	for pad in device.xy_pairs():
		if pad.x == mod:
			return pad
	return null


# ============================================================================
# INPUT
# ============================================================================

## Esc leaves assign mode (the wire button, another modulator or Delete also end it).
func _unhandled_input(event: InputEvent) -> void:
	if ModAssign.is_active() and event.is_action_pressed("ui_cancel"):
		ModAssign.end()
		get_viewport().set_input_as_handled()
