## The Modulators pane of the DevicePanel (spec 018, rebuilt in 033): a column-major grid of square
## modulator panels with trailing `+` placeholder cells, and the selected modulator's settings on
## the right. The device lane's horizontal scroll is the only scrolling surface — the pane widens
## one column per growth step.
##
## The detail column builds its controls from the modulator kind's parameter descriptors with the
## existing component set: `EnvelopeControl` for `adsr` and `ad`, normalized knobs and enum
## selectors for `lfo`. Velocity, keytrack and random have no settings.
class_name ModulatorsPane extends HBoxContainer

## Modulator parameter IDs by envelope stage (the engine's blocks-of-ten convention).
const ENV_STAGE_PARAM := {
	Envelope.Stage.ATTACK: 0,
	Envelope.Stage.DECAY: 10,
	Envelope.Stage.SUSTAIN: 20,
	Envelope.Stage.RELEASE: 30,
}
## LFO parameter display order: Rate, Sync, Shape, Retrigger, Phase.
const LFO_ORDER := [10, 20, 0, 30, 40]
## Knob parameter display order: Value, Polarity (spec 036).
const KNOB_ORDER := [0, 10]
## Sidechain generic parameters in display order; the Source (40) is a custom channel menu.
const SC_ORDER := [0, 10, 20, 30]
const SC_SOURCE_PARAM := 40

## Grid geometry: `ROWS`-cell columns of square cells (`SEP` apart), sized from the pane's height.
const ROWS := 3
const SEP := 2
const PANEL_MIN_SIDE := 56
const PANEL_MAX_SIDE := 110

## Selected modulator per device instance id, remembered while the session lives.
static var _remembered: Dictionary = {}

var device: DeviceInstance = null

var _header: HBoxContainer = null
var _grid: HBoxContainer = null
var _kind_menu: PopupMenu = null
var _detail: VBoxContainer = null
var _detail_scroll: ScrollContainer = null
var _tiles: Array[ModulatorPanel] = []
var _placeholders: Array[Button] = []
## Square cell side applied to every cell; 0 until the first layout.
var _side := 0
## Times `_layout_panel_size` actually applied a side (stays put when the height didn't change).
var _layout_count := 0
## Swap drag in progress (started by a panel, resolved and committed here in `_input`).
var _drag: ModulatorDrag = null
var _indicator: DropIndicator = null
var _selected_mod_id := -1
## Detail controls by parameter id (knobs, dropdowns, toggles), refreshed from the model.
var _controls: Dictionary = {}
var _detail_title: Label = null
## Per-parameter controls (caption + control) and the columns they are flowed into.
var _param_boxes: Array[Control] = []
var _param_columns: HBoxContainer = null
var _laying_out := false
var _envelope: Envelope = null
var _envelope_control: EnvelopeControl = null
## Modulator the detail column was built for; -1 when it holds no controls to update in place.
var _detail_mod_id := -1
## Pair the detail column shows (an XY pad's XY slider); null otherwise.
var _detail_pad: XYPad = null
var _detail_pad_slider: XYSlider = null
## The sidechain Source menu and the project it lists (rebuilt on channel-list changes).
var _source_menu: OptionButton = null
var _source_menu_project = null
var _source_cb_added: Callable = Callable()
var _source_cb_removed: Callable = Callable()


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

	var left := VBoxContainer.new()
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.custom_minimum_size.x = 180
	left.add_theme_constant_override("separation", SEP)
	add_child(left)

	_header = HBoxContainer.new()
	var title := Label.new()
	title.text = "Modulators"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.add_child(title)
	left.add_child(_header)

	# Column-major grid: an HBox of 3-cell columns, so cell `i` sits in column `i / 3`, row `i % 3`.
	# No scrolling here — the device lane scrolls the pane horizontally.
	_grid = HBoxContainer.new()
	_grid.add_theme_constant_override("separation", SEP)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_grid)

	# The shared `+` menu: every placeholder opens it filled with the registry's kinds.
	_kind_menu = PopupMenu.new()
	_kind_menu.theme_type_variation = &"ContextMenuList"
	_kind_menu.id_pressed.connect(_on_add_kind)
	add_child(_kind_menu)

	_detail_scroll = ScrollContainer.new()
	var detail_scroll := _detail_scroll
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.custom_minimum_size.x = 140
	# Width follows the content (horizontal disabled). Height must not: it is the budget the options
	# are flowed into columns against (see _layout_param_columns), so the pane grows wider, not taller.
	# SHOW_NEVER keeps the minimum height at 0 without ever showing a scrollbar.
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	detail_scroll.resized.connect(_layout_param_columns)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 6)
	detail_scroll.add_child(_detail)
	add_child(detail_scroll)

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

## Rebuild the column-major grid: `C = max(1, tiles / 3 + 1)` columns of `ROWS` cells, panels
## first in array order, then `3·C − tiles` placeholder cells (1–3). Cheap at ≤ 8 entries.
## Rebuilt on add/remove/reorder; the selection is kept by `mod_id`.
##
## Pair-aware (spec 036): an adjacent `xyx`+`xyy` becomes ONE tile (`setup_pair`); an orphan
## `xyx`/`xyy` (a hand-edited save) degrades to a plain tile.
func _rebuild_grid() -> void:
	_clear_grid()
	if device == null:
		return
	var tiles: Array = []
	var i := 0
	while i < device.modulators.size():
		var mod: Modulator = device.modulators[i]
		if mod.kind == "xyx" and i + 1 < device.modulators.size() \
				and device.modulators[i + 1].kind == "xyy":
			var pad := XYPad.new()
			pad.x = mod
			pad.y = device.modulators[i + 1]
			tiles.append(pad)
			i += 2
		else:
			tiles.append(mod)
			i += 1
	var n := tiles.size()
	var columns := maxi(1, n / ROWS + 1)
	for c in columns:
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", SEP)
		_grid.add_child(column)
		for r in ROWS:
			var k: int = c * ROWS + r
			if k < n:
				_add_panel(column, tiles[k])
			else:
				_add_placeholder(column)
	if _side > 0:
		_apply_side()
	else:
		# First layout: the parent's height isn't final yet (a `resized` may have fired before the
		# structure existed), so size the cells after this frame's layout pass.
		_layout_panel_size.call_deferred()
	# At the capacity limit the last placeholder (always one at 8) is disabled: REQ-002 keeps
	# placeholders non-zero without offering an add `add_modulator` would refuse.
	var full := device.modulators.size() >= device.MAX_MODULATORS
	for placeholder in _placeholders:
		placeholder.disabled = full
		placeholder.tooltip_text = "Maximum of 8 modulators" if full else "Add modulator"
	if _selected_mod_id < 0 or device.get_modulator(_selected_mod_id) == null:
		_selected_mod_id = int(_remembered.get(device.id, device.modulators[0].mod_id if not device.modulators.is_empty() else -1))
	_refresh_selection()


func _add_panel(column: VBoxContainer, entry: Variant) -> void:
	var panel := ModulatorPanel.new()
	column.add_child(panel)
	if entry is XYPad:
		panel.setup_pair(entry)
	else:
		panel.setup(entry)
	panel.selected.connect(_on_panel_clicked)
	panel.drag_started.connect(_on_panel_drag_started)
	_tiles.append(panel)


## Flat `+` cell: opens the shared kind menu. Sizing (icon at ~40 % of the side) happens in
## `_apply_side`; placement always trails the panels, so an add lands in the first free cell.
func _add_placeholder(column: VBoxContainer) -> void:
	var button := Button.new()
	button.theme_type_variation = &"DeviceCard"
	button.focus_mode = Control.FOCUS_NONE
	var plus := TextureRect.new()
	plus.texture = load("res://assets/icons/plus.svg")
	plus.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	plus.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(plus)
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
	_tiles.clear()
	_placeholders.clear()


## Square sizing: the side is a function of the pane's height only (the device lane's height is
## fixed), so cells stay square and 3·side + 2·SEP ≤ avail_h holds by construction — setting the
## minimum size can't grow the pane and re-fire `resized`.
func _layout_panel_size() -> void:
	if _grid == null:
		return
	var parent := _grid.get_parent() as Control
	var avail := parent.size.y - _header.get_combined_minimum_size().y - SEP
	var side := clampi(int(floor((avail - 2.0 * SEP) / ROWS)), PANEL_MIN_SIDE, PANEL_MAX_SIDE)
	if side == _side:
		return
	_side = side
	_layout_count += 1
	_apply_side()


## Apply the current side to every cell (panels and placeholders), plus the `+` icon at ~40 %.
func _apply_side() -> void:
	var cell := Vector2(_side, _side)
	for tile in _tiles:
		tile.custom_minimum_size = cell
		tile.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		tile.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	for placeholder in _placeholders:
		placeholder.custom_minimum_size = cell
		placeholder.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		placeholder.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		if placeholder.get_child_count() > 0:
			var plus: Control = placeholder.get_child(0)
			var icon := float(_side) * 0.4
			plus.custom_minimum_size = Vector2.ONE * icon
			plus.position = (Vector2.ONE * float(_side) - Vector2.ONE * icon) * 0.5


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
	_kind_menu.position = Vector2i(button.get_screen_position() + Vector2(0, button.size.y))
	_kind_menu.popup()


func _on_add_kind(id: int) -> void:
	if device == null:
		return
	if id < 0 or id >= _kind_menu.item_count:
		return
	var kind_id := String(_kind_menu.get_item_metadata(id))
	if kind_id == "xyx":
		var pad: XYPad = device.add_xy_pad()
		if pad != null:
			_select(pad.x.mod_id)
		return
	var mod = device.add_modulator(kind_id)
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
		_sync_pair_detail()
	elif mod_id == _selected_mod_id:
		_sync_detail()


func _on_route_changed(_mod_id: int, _target: String, _amount: float) -> void:
	for tile in _tiles:
		if tile.modulator != null:
			tile.refresh()


func _on_device_name_changed(_new_name: String) -> void:
	_refresh_selection()


# ============================================================================
# SWAP DRAG
# ============================================================================

## A panel crossed the drag threshold: own the drag, follow the mouse, commit on release.
func _on_panel_drag_started(mod: Modulator) -> void:
	if device == null or _drag != null:
		return
	_drag = ModulatorDrag.start(self, mod)
	if _drag != null:
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


## Drop or cancel: free the ghost, hide the indicator. Nothing needs undoing — nothing moved.
func _end_drag() -> void:
	if _drag != null:
		_drag.preview.queue_free()
		_drag = null
	DropIndicator.hide_indicator(_indicator)


func _exit_tree() -> void:
	_end_drag()


# ============================================================================
# DETAIL
# ============================================================================

func _clear_detail() -> void:
	_controls.clear()
	_detail_mod_id = -1
	_detail_pad = null
	_detail_pad_slider = null
	_source_menu = null
	if _source_menu_project != null:
		if _source_cb_added.is_valid() and _source_menu_project.channel_added.is_connected(_source_cb_added):
			_source_menu_project.channel_added.disconnect(_source_cb_added)
		if _source_cb_removed.is_valid() and _source_menu_project.channel_removed.is_connected(_source_cb_removed):
			_source_menu_project.channel_removed.disconnect(_source_cb_removed)
	_source_menu_project = null
	_source_cb_added = Callable()
	_source_cb_removed = Callable()
	_envelope = null
	_envelope_control = null
	_detail_title = null
	_param_columns = null
	_param_boxes.clear()
	if _detail == null:
		return
	for child in _detail.get_children():
		child.queue_free()


## Push the model's values into the existing controls. Rebuilding here would free the control
## being dragged (every edit echoes back as `modulator_changed`), so only rebuild when the detail
## isn't showing the selected modulator.
func _sync_detail() -> void:
	var mod := device.get_modulator(_selected_mod_id) if device != null else null
	if mod == null or _detail_mod_id != mod.mod_id:
		_refresh_detail()
		return
	if _envelope != null:
		_refresh_envelope(mod)
	for param in mod.get_parameters():
		_refresh_param_control(mod, param)
	_sync_source_menu()


func _refresh_detail() -> void:
	_clear_detail()
	if _detail == null or device == null:
		return
	var mod := device.get_modulator(_selected_mod_id)
	_detail_scroll.visible = mod != null
	if mod == null:
		return
	_detail_mod_id = mod.mod_id
	_detail_title = Label.new()
	_detail_title.text = mod.name
	_detail_title.clip_text = true
	_detail.add_child(_detail_title)

	var kind := mod.kind
	if kind == "adsr" or kind == "ad":
		_build_envelope_detail(mod)
		return
	if kind == "xyx":
		var pad := _pair_of(mod)
		if pad != null:
			_build_pair_detail(pad)
			return
	# A pair's Y slot (or an orphan XY half) shows the generic Position control like any kind.
	_param_columns = HBoxContainer.new()
	_param_columns.add_theme_constant_override("separation", 10)
	_detail.add_child(_param_columns)
	for param in _ordered_params(kind, mod.get_parameters()):
		_build_param_control(mod, param)
	if kind == "sidechain":
		_build_sidechain_source(mod)
	_layout_param_columns.call_deferred()
	if _controls.is_empty() and _detail_pad_slider == null and _source_menu == null:
		var none := Label.new()
		none.text = "No settings"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_child(none)


## The pad `mod` heads (an `xyx` immediately followed by its `xyy`), or null.
func _pair_of(mod: Modulator) -> XYPad:
	if mod == null or mod.kind != "xyx":
		return null
	for pad in device.xy_pairs():
		if pad.x == mod:
			return pad
	return null


## The pair's options: one 140×140 XY slider bound to both slots (spec 036 REQ-005).
func _build_pair_detail(pad: XYPad) -> void:
	_detail_pad = pad
	var slider := XYSlider.new()
	slider.x_min = 0.0
	slider.x_max = 1.0
	slider.y_min = 0.0
	slider.y_max = 1.0
	slider.show_value_labels = false
	slider.show_axis_lines = false
	slider.custom_minimum_size = Vector2(140, 140)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_detail_pad_slider = slider
	_detail.add_child(slider)
	slider.values_changed.connect(func(x: float, y: float): pad.set_position(Vector2(x, y)))
	_sync_pair_detail()


## Follow the model without echoing a `values_changed` back through `set_position`.
func _sync_pair_detail() -> void:
	if _detail_pad == null or _detail_pad_slider == null:
		return
	var pos := _detail_pad.position()
	_detail_pad_slider.set_values_no_signal(pos.x, pos.y)


## The sidechain's Source menu (spec 036 REQ-006): "Device In" plus every project channel by
## name (master included, hardware outputs excluded), item metadata = channel id.
func _build_sidechain_source(mod: Modulator) -> void:
	var channel = mod.owner().get_channel() if mod.owner() != null else null
	var project = channel.get_project() if channel != null else null
	_source_menu = OptionButton.new()
	_source_menu.fit_to_longest_item = false
	_source_menu.clip_text = true
	_detail.add_child(_source_menu)
	_source_menu.item_selected.connect(_on_source_selected)
	if project != null:
		_source_menu_project = project
		_source_cb_added = func(_channel): _rebuild_source_menu()
		_source_cb_removed = func(_channel_id): _rebuild_source_menu()
		project.channel_added.connect(_source_cb_added)
		project.channel_removed.connect(_source_cb_removed)
	_rebuild_source_menu()


## (Re)fill the Source menu's items; the selection follows the stored channel id.
func _rebuild_source_menu() -> void:
	if _source_menu == null:
		return
	_source_menu.clear()
	_source_menu.add_item("Device In")
	_source_menu.set_item_metadata(0, 0)
	var project = _source_menu_project
	if project != null:
		for ch in project.channels:
			if ch.id >= AudioConfig.HARDWARE_OUTPUT_BASE:
				continue
			_source_menu.add_item(ch.name)
			_source_menu.set_item_metadata(_source_menu.item_count - 1, ch.id)
	_sync_source_menu()


func _sync_source_menu() -> void:
	if _source_menu == null or _detail_mod_id < 0 or device == null:
		return
	var mod := device.get_modulator(_detail_mod_id)
	if mod == null or mod.kind != "sidechain":
		return
	var param := mod.get_parameter(SC_SOURCE_PARAM)
	var channel_id := -1
	if param != null:
		channel_id = int(round(param.normalized_to_value(mod.get_param(SC_SOURCE_PARAM))))
	else:
		channel_id = int(round(mod.get_param(SC_SOURCE_PARAM) * 999.0))
	var select_index := -1
	for i in _source_menu.item_count:
		if int(_source_menu.get_item_metadata(i)) == channel_id:
			select_index = i
			break
	if select_index < 0:
		# The stored id no longer exists (channel removed): show it as missing, keep the id.
		_source_menu.add_item("(missing channel)")
		_source_menu.set_item_metadata(_source_menu.item_count - 1, channel_id)
		select_index = _source_menu.item_count - 1
	_source_menu.select(select_index)


func _on_source_selected(index: int) -> void:
	if _source_menu == null or _detail_mod_id < 0 or device == null:
		return
	var mod := device.get_modulator(_detail_mod_id)
	if mod == null:
		return
	var channel_id := int(_source_menu.get_item_metadata(index))
	var param := mod.get_parameter(SC_SOURCE_PARAM)
	# The engine's Source parameter is a channel id in normalized units (linear 0..999).
	var norm := param.value_to_normalized(float(channel_id)) if param != null else float(channel_id) / 999.0
	device.set_modulator_param(_detail_mod_id, SC_SOURCE_PARAM, norm)


## Kind parameters in display order: LFO, Knob and Sidechain have their own; the rest use the
## table order. The sidechain's Source (40) is excluded — the pane builds it as a custom
## channel menu, not a generic control.
func _ordered_params(kind: String, params: Array) -> Array:
	var order: Array = []
	if kind == "lfo":
		order = LFO_ORDER
	elif kind == "knob":
		order = KNOB_ORDER
	elif kind == "sidechain":
		order = SC_ORDER
	if order.is_empty():
		return params
	var by_id := {}
	for param in params:
		by_id[param.id] = param
	var ordered: Array = []
	for id in order:
		if by_id.has(id):
			ordered.append(by_id[id])
	for param in params:
		if ordered.has(param):
			continue
		if kind == "sidechain" and param.id == SC_SOURCE_PARAM:
			continue
		ordered.append(param)
	return ordered


func _build_param_control(mod: Modulator, param: DeviceParameter) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	var caption := Label.new()
	caption.text = param.name
	caption.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	column.add_child(caption)

	if param.param_type == "enum":
		var dropdown := OptionButton.new()
		dropdown.fit_to_longest_item = false
		dropdown.clip_text = true
		for i in range(param.enum_values.size()):
			dropdown.add_item(param.enum_values[i], i)
		dropdown.item_selected.connect(func(index: int):
			var n := maxi(1, param.enum_values.size())
			mod.set_param(param.id, 0.0 if n <= 1 else float(index) / float(n - 1)))
		_controls[param.id] = dropdown
		column.add_child(dropdown)
	elif param.param_type == "bool":
		var toggle := CheckButton.new()
		toggle.text = ""
		toggle.toggled.connect(func(pressed: bool): mod.set_param(param.id, 1.0 if pressed else 0.0))
		_controls[param.id] = toggle
		column.add_child(toggle)
	else:
		var knob := RotaryKnob.new()
		knob.min_value = 0.0
		knob.max_value = 1.0
		knob.value_default = param.value_to_normalized(param.default_value)
		knob.custom_minimum_size = Vector2(40, 40)
		knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		knob.value_text_callback = func(v: float) -> String: return SimpleUnits.format(param, v, "")
		knob.value_changed.connect(func(v: float): mod.set_param(param.id, v))
		ModAssign.attach_modulator(knob, mod.owner(), mod.mod_id, param.id)
		_controls[param.id] = knob
		column.add_child(knob)
	_param_boxes.append(column)
	_refresh_param_control(mod, param)


## Flow the parameter controls into columns that fit the pane's height, so a modulator with many
## options (LFO) widens the pane instead of overflowing it.
func _layout_param_columns() -> void:
	if _laying_out or _param_columns == null or not is_instance_valid(_param_columns) \
			or _param_boxes.is_empty():
		return
	_laying_out = true
	for column in _param_columns.get_children():
		for box in column.get_children():
			column.remove_child(box)
		_param_columns.remove_child(column)
		column.free()
	var budget := _detail_scroll.size.y - _detail_title.get_combined_minimum_size().y \
			- float(_detail.get_theme_constant("separation"))
	if _detail_scroll.size.y <= 0.0:
		budget = INF
	var column: VBoxContainer = null
	var used := 0.0
	for box in _param_boxes:
		var h := box.get_combined_minimum_size().y
		if column == null or (used + h > budget and column.get_child_count() > 0):
			column = VBoxContainer.new()
			column.add_theme_constant_override("separation", 6)
			_param_columns.add_child(column)
			used = 0.0
		column.add_child(box)
		used += h + 6.0
	_laying_out = false


func _refresh_param_control(mod: Modulator, param: DeviceParameter) -> void:
	var control = _controls.get(param.id)
	if control == null:
		return
	var value := mod.get_param(param.id)
	if control is OptionButton:
		var n := maxi(1, param.enum_values.size())
		(control as OptionButton).select(clampi(int(round(value * float(n - 1))), 0, n - 1))
	elif control is CheckButton:
		(control as CheckButton).set_pressed_no_signal(value >= 0.5)
	elif control is RotaryKnob:
		(control as RotaryKnob).set_value_no_signal(value)


# ============================================================================
# ENVELOPE DETAIL
# ============================================================================

func _build_envelope_detail(mod: Modulator) -> void:
	_envelope = Envelope.new()
	_envelope.stages = "adsr" if mod.kind == "adsr" else "ad"
	for stage in [Envelope.Stage.ATTACK, Envelope.Stage.DECAY, Envelope.Stage.SUSTAIN, Envelope.Stage.RELEASE]:
		var param := mod.get_parameter(ENV_STAGE_PARAM[stage])
		if param == null or stage == Envelope.Stage.SUSTAIN:
			continue
		var lo := maxf(0.0, param.min_value)
		_envelope.set_stage_range(stage, lo, maxf(lo + 0.001, param.max_value))
		if param.is_logarithmic or not is_equal_approx(param.skew, 1.0):
			_envelope.set_stage_curve(stage, param.skew, param.is_logarithmic)

	_envelope_control = EnvelopeControl.new()
	_envelope_control.custom_minimum_size = Vector2(120, 64)
	_envelope_control.envelope = _envelope
	_detail.add_child(_envelope_control)

	_envelope.attack_changed.connect(func(value: float): _commit_env(mod, Envelope.Stage.ATTACK, value))
	_envelope.decay_changed.connect(func(value: float): _commit_env(mod, Envelope.Stage.DECAY, value))
	_envelope.sustain_changed.connect(func(value: float): _commit_env(mod, Envelope.Stage.SUSTAIN, value))
	_envelope.release_changed.connect(func(value: float): _commit_env(mod, Envelope.Stage.RELEASE, value))
	_refresh_envelope(mod)


func _commit_env(mod: Modulator, stage: int, value: float) -> void:
	var param := mod.get_parameter(ENV_STAGE_PARAM[stage])
	if param == null:
		return
	if stage == Envelope.Stage.SUSTAIN:
		mod.set_param(param.id, value)
	else:
		mod.set_param(param.id, param.value_to_normalized(value))


func _refresh_envelope(mod: Modulator) -> void:
	if _envelope == null:
		return
	var values: Array[float] = []
	for stage in [Envelope.Stage.ATTACK, Envelope.Stage.DECAY, Envelope.Stage.SUSTAIN, Envelope.Stage.RELEASE]:
		var param := mod.get_parameter(ENV_STAGE_PARAM[stage])
		if param == null:
			values.append(_envelope.get_stage_value(stage))
		elif stage == Envelope.Stage.SUSTAIN:
			values.append(mod.get_param(param.id))
		else:
			values.append(param.normalized_to_value(mod.get_param(param.id)))
	_envelope.set_adsr(values[0], values[1], values[2], values[3])


# ============================================================================
# INPUT
# ============================================================================

## Esc leaves assign mode (the wire button, another modulator or Delete also end it).
func _unhandled_input(event: InputEvent) -> void:
	if ModAssign.is_active() and event.is_action_pressed("ui_cancel"):
		ModAssign.end()
		get_viewport().set_input_as_handled()
