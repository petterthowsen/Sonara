## The Modulators pane of the DevicePanel (spec 018): a grid of `ModulatorTile`s with a **+**
## button on the left, and the selected modulator's settings on the right.
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
const TILE_COLUMNS := 2

## Selected modulator per device instance id, remembered while the session lives.
static var _remembered: Dictionary = {}

var device: DeviceInstance = null

var _grid: GridContainer = null
var _grid_scroll: ChevronScrollContainer = null
var _add_button: MenuButton = null
var _detail: VBoxContainer = null
var _detail_scroll: ScrollContainer = null
var _tiles: Array[ModulatorTile] = []
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
	device.route_changed.connect(_on_route_changed)
	device.name_changed.connect(_on_device_name_changed)
	_rebuild_tiles()


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
	if device.route_changed.is_connected(_on_route_changed):
		device.route_changed.disconnect(_on_route_changed)
	if device.name_changed.is_connected(_on_device_name_changed):
		device.name_changed.disconnect(_on_device_name_changed)
	device = null
	_clear_tiles()
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
	add_child(left)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Modulators"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_add_button = MenuButton.new()
	_add_button.text = "+"
	_add_button.flat = true
	_add_button.focus_mode = Control.FOCUS_NONE
	_add_button.tooltip_text = "Add a modulator"
	_add_button.get_popup().id_pressed.connect(_on_add_kind)
	header.add_child(_add_button)
	left.add_child(header)

	# The tile list pages with chevron buttons (as the mixer's sends do); the selected modulator's
	# settings stay a separate panel to the right.
	_grid_scroll = ChevronScrollContainer.new()
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_grid_scroll.follow_focus = true
	_grid_scroll.snap_to_items = true
	_grid_scroll.reserve_button_space = true
	_grid_scroll.fade_hidden_items = true
	_grid = GridContainer.new()
	_grid.columns = TILE_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(_grid)
	left.add_child(_grid_scroll)

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


## Advertised kinds in the + menu (and again when the registry re-announces them).
func _refresh_kinds() -> void:
	if _add_button == null:
		return
	var popup := _add_button.get_popup()
	popup.clear()
	var registry = _registry()
	var kinds: Array = registry.get_modulator_kinds() if registry != null else []
	for kind in kinds:
		popup.add_item(String(kind.get("name", kind.get("id", ""))), popup.item_count)
		popup.set_item_metadata(popup.item_count - 1, String(kind.get("id", "")))


func _registry():
	var tree := get_tree()
	if tree == null:
		return null
	var service = tree.root.get_node_or_null("AssetService")
	return service.device_registry if service != null else null


# ============================================================================
# TILES
# ============================================================================

func _rebuild_tiles() -> void:
	_clear_tiles()
	if device == null:
		return
	for mod in device.modulators:
		var tile := ModulatorTile.new()
		_grid.add_child(tile)
		tile.setup(mod)
		tile.selected.connect(_on_tile_clicked)
		_tiles.append(tile)
	if _selected_mod_id < 0 or device.get_modulator(_selected_mod_id) == null:
		_selected_mod_id = int(_remembered.get(device.id, device.modulators[0].mod_id if not device.modulators.is_empty() else -1))
	_refresh_selection()


func _clear_tiles() -> void:
	for tile in _tiles:
		tile.queue_free()
	_tiles.clear()


func _refresh_selection() -> void:
	for tile in _tiles:
		if tile.modulator != null:
			tile.set_selected(tile.modulator.mod_id == _selected_mod_id)
			tile.refresh()
	_refresh_detail()


## A tile click: selects it, or deselects it when it already was (which hides the settings).
func _on_tile_clicked(mod_id: int) -> void:
	_select(-1 if mod_id == _selected_mod_id else mod_id)


func _select(mod_id: int) -> void:
	_selected_mod_id = mod_id
	if device != null:
		_remembered[device.id] = mod_id
	_refresh_selection()


func _on_add_kind(id: int) -> void:
	if device == null:
		return
	var popup := _add_button.get_popup()
	if id < 0 or id >= popup.item_count:
		return
	var mod = device.add_modulator(String(popup.get_item_metadata(id)))
	if mod != null:
		_select(mod.mod_id)


func _on_modulator_added(mod: Modulator) -> void:
	_rebuild_tiles()
	_select(mod.mod_id)


func _on_modulator_removed(mod_id: int) -> void:
	if ModAssign.is_active_for(device, mod_id):
		ModAssign.end()
	if _selected_mod_id == mod_id:
		_selected_mod_id = -1
		if device != null:
			_remembered.erase(device.id)
	_rebuild_tiles()


func _on_modulator_changed(mod_id: int) -> void:
	for tile in _tiles:
		if tile.modulator != null and tile.modulator.mod_id == mod_id:
			tile.refresh()
	if mod_id == _selected_mod_id:
		_sync_detail()


func _on_route_changed(_mod_id: int, _target: String, _amount: float) -> void:
	for tile in _tiles:
		if tile.modulator != null:
			tile.refresh()


func _on_device_name_changed(_new_name: String) -> void:
	_refresh_selection()


# ============================================================================
# DETAIL
# ============================================================================

func _clear_detail() -> void:
	_controls.clear()
	_detail_mod_id = -1
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
## being dragged (every edit echoes back as `modulator_changed`), so only rebuild when the
## detail isn't showing the selected modulator.
func _sync_detail() -> void:
	var mod := device.get_modulator(_selected_mod_id) if device != null else null
	if mod == null or _detail_mod_id != mod.mod_id:
		_refresh_detail()
		return
	if _envelope != null:
		_refresh_envelope(mod)
	for param in mod.get_parameters():
		_refresh_param_control(mod, param)


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
	else:
		_param_columns = HBoxContainer.new()
		_param_columns.add_theme_constant_override("separation", 10)
		_detail.add_child(_param_columns)
		for param in _ordered_params(kind, mod.get_parameters()):
			_build_param_control(mod, param)
		_layout_param_columns.call_deferred()
		if _controls.is_empty():
			var none := Label.new()
			none.text = "No settings"
			none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_detail.add_child(none)


## Kind parameters in display order (LFO has its own; the rest use the table order).
func _ordered_params(kind: String, params: Array) -> Array:
	if kind != "lfo":
		return params
	var by_id := {}
	for param in params:
		by_id[param.id] = param
	var ordered: Array = []
	for id in LFO_ORDER:
		if by_id.has(id):
			ordered.append(by_id[id])
	for param in params:
		if not ordered.has(param):
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
