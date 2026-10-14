## One modulator panel in the Modulators pane (spec 018, rebuilt in 033; XY pairs in 036):
## header (colour strip + name/rename), an expanding display area and the wire button(s)
## centered at the bottom. Selection uses the shared `DeviceCard` / `DeviceCardSelected` theme
## variations.
##
## The wire button toggles assign mode for this modulator and pulses while active; an XY pad
## tile (`setup_pair`) shows two of them, one per slot. All wire buttons are non-flat, with label and
## icon colored by their modulator's source colour (REQ-010). A left click selects only on
## release without crossing the drag threshold, so a press-and-drag never toggles selection; the
## pane starts a swap drag past the threshold. Presses on an XY pad's interactive display never
## reach that logic. Right-click opens the panel menu: one entry per route (both slots for a
## pair) with a disconnect action, then Rename / Duplicate / Delete.
class_name ModulatorPanel extends PanelContainer

## The panel was left-clicked (the pane toggles this modulator's detail).
signal selected(mod_id: int)
## A press-and-move crossed the drag threshold (the pane owns the drag from here).
signal drag_started(modulator: Modulator)

const WIRE_ICON := preload("res://assets/icons/cable.svg")

## Movement (px) past which a press becomes a drag instead of a click.
const DRAG_THRESHOLD := 6.0

## Assign-mode wire button pulse: lowest alpha and seconds per half-cycle.
const PULSE_MIN_ALPHA := 0.15
const PULSE_HALF_CYCLE := 0.38

const MENU_RENAME := 100000
const MENU_DUPLICATE := 100001
const MENU_DELETE := 100002

## Theme colour overrides that color a wire button by its source (REQ-010).
const WIRE_COLOR_ROLES := [
	"font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color",
	"icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color",
]

## The panel's modulator: the XY pad's X slot for a pair tile, else the single modulator.
var modulator: Modulator = null
## The XY pad this tile represents, or null for a plain modulator.
var pad: XYPad = null
var _strip: ColorRect = null
var _header: HBoxContainer = null
var _name_label: Label = null
var _rename: LineEdit = null
var _display: Control = null
## Single-modulator wire button; null on a pair tile.
var _wire: Button = null
## Pair tile wire buttons (X, then Y) and the slot mod id each drives.
var _wire_buttons: Array[Button] = []
var _wire_ids: Array[int] = []
var _pulses: Dictionary = {}
var _menu: PopupMenu = null
## The route menu's entries are plain indices; this parallel list maps each route item to the
## slot mod id it disconnects (the tile's modulator for a plain tile).
var _menu_route_mod_ids: Array[int] = []
var _menu_route_count := 0
var _is_selected := false
## Position of the left press (global), valid only while `_pressing`.
var _press_pos := Vector2.ZERO
var _pressing := false
var _dragging := false
## Swallow the release after a double-click rename, so it doesn't toggle the selection.
var _skip_release := false


func setup(mod: Modulator) -> void:
	modulator = mod
	if _name_label == null:
		_build()
	if _display is ModulatorDisplay and modulator.owner() != null:
		(_display as ModulatorDisplay).setup(modulator.owner(), modulator.mod_id)
	refresh()
	_sync_wires()


## Build this tile as one XY pad: name/rename from the X slot, an interactive `XYPadPanel` as
## the display, and one wire button per slot. Call instead of `setup`, before the tile is used.
func setup_pair(p_pad: XYPad) -> void:
	pad = p_pad
	modulator = p_pad.x
	if _name_label == null:
		_build()
	if _display is XYPadPanel:
		(_display as XYPadPanel).setup(p_pad)
	refresh()
	_sync_wires()


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"DeviceCard" if not _is_selected else &"DeviceCardSelected"

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)

	# The source colour as a horizontal strip along the tile's top edge.
	_strip = ColorRect.new()
	_strip.custom_minimum_size = Vector2(0, 3)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_strip)

	_header = HBoxContainer.new()
	_header.add_theme_constant_override("separation", 4)
	column.add_child(_header)

	var name_column := VBoxContainer.new()
	name_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(name_column)

	_name_label = Label.new()
	_name_label.clip_text = true
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_column.add_child(_name_label)

	_rename = LineEdit.new()
	_rename.visible = false
	_rename.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename.text_submitted.connect(_on_rename_submitted)
	_rename.focus_exited.connect(_commit_rename)
	# Esc reverts without committing; Enter (or losing focus) commits.
	_rename.gui_input.connect(_on_rename_gui_input)
	name_column.add_child(_rename)

	# The display area; expands so the wire button(s) sit at the bottom.
	if pad != null:
		_display = XYPadPanel.new()
	else:
		_display = ModulatorDisplay.new()
		_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_display)

	# The wire button(s): colored by their slot's source colour (REQ-010).
	if pad != null:
		var wires := HBoxContainer.new()
		wires.add_theme_constant_override("separation", 4)
		wires.alignment = BoxContainer.ALIGNMENT_CENTER
		wires.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		column.add_child(wires)
		for slot in [[pad.x, "X"], [pad.y, "Y"]]:
			var mod: Modulator = slot[0]
			var button := _make_wire_button(String(slot[1]))
			button.toggled.connect(_on_wire_toggled.bind(mod.mod_id))
			wires.add_child(button)
			_wire_buttons.append(button)
			_wire_ids.append(mod.mod_id)
	else:
		_wire = _make_wire_button("")
		_wire.toggled.connect(_on_wire_toggled.bind(-1))
		column.add_child(_wire)

	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_menu.id_pressed.connect(_on_menu_id)
	add_child(_menu)

	ModAssign.holder().changed.connect(_sync_wires)
	mouse_entered.connect(func(): _set_hover(true))
	# Moving onto the wire button still counts as hovering the panel.
	mouse_exited.connect(func(): _set_hover(get_global_rect().has_point(get_global_mouse_position())))
	tree_exiting.connect(func(): _set_hover(false))


func _make_wire_button(label: String) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.flat = false
	button.focus_mode = Control.FOCUS_NONE
	button.icon = WIRE_ICON
	if label != "":
		button.text = label
	button.custom_minimum_size = Vector2(24, 24)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = "Assign: click, then drag a control of this device or one of its children"
	return button


## Ask the controls this modulator is bound to to show its amounts.
func _set_hover(on: bool) -> void:
	if modulator == null or modulator.owner() == null:
		return
	ModAssign.set_hover(modulator.owner(), modulator.mod_id, on)


## Name, colour strip and wire state from the model.
func refresh() -> void:
	if modulator == null:
		return
	if _name_label != null:
		_name_label.text = modulator.name
	if _strip != null:
		_strip.color = _color()
	set_selected(_is_selected)
	if _wire != null:
		_wire.tooltip_text = "Assign %s: click, then drag a control of this device or one of its children" % modulator.name
	for i in _wire_buttons.size():
		_wire_buttons[i].tooltip_text = "Assign %s (%s): click, then drag a control of this device or one of its children" % [modulator.name, "X" if i == 0 else "Y"]
	for i in _wire_buttons.size():
		_apply_wire_color(_wire_buttons[i], _wire_ids[i])
	if _wire != null:
		_apply_wire_color(_wire, modulator.mod_id)


func set_selected(on: bool) -> void:
	_is_selected = on
	theme_type_variation = &"DeviceCardSelected" if _is_selected else &"DeviceCard"


## Source colour of the modulator `mod_id` (its array index), WHITE when it's gone.
func _color_for_mod(mod_id: int) -> Color:
	var owner = modulator.owner() if modulator != null else null
	if owner == null:
		return ModDisplay.source_color(0)
	var mod = owner.get_modulator(mod_id)
	if mod == null:
		return ModDisplay.source_color(0)
	return ModDisplay.source_color(maxi(owner.modulators.find(mod), 0))


func _color() -> Color:
	return _color_for_mod(modulator.mod_id)


## True when this tile shows the modulator `mod_id` (either slot of a pair).
func represents(mod_id: int) -> bool:
	if pad != null:
		return pad.holds(mod_id)
	return modulator != null and modulator.mod_id == mod_id


# ============================================================================
# ASSIGN MODE
# ============================================================================

func _on_wire_toggled(pressed: bool, mod_id: int) -> void:
	if mod_id < 0:
		if modulator == null:
			return
		mod_id = modulator.mod_id
	if pressed:
		ModAssign.begin(modulator.owner(), mod_id)
	elif ModAssign.is_active_for(modulator.owner(), mod_id):
		ModAssign.end()


## Follow the shared state across this tile's wire buttons: pressed while their slot is the
## active one, pulsing; colours re-applied (the array index may have changed).
func _sync_wires() -> void:
	for button in _pulses.keys():
		_stop_pulse(button)
	if _wire != null:
		_sync_one_wire(_wire, modulator.mod_id if modulator != null else -1)
	for i in _wire_buttons.size():
		_sync_one_wire(_wire_buttons[i], _wire_ids[i])


## Kept for callers of the old single-wire name; the pair tile syncs through `_sync_wires`.
func _sync_wire() -> void:
	_sync_wires()


func _sync_one_wire(button: Button, mod_id: int) -> void:
	var active := mod_id >= 0 and ModAssign.is_active_for(modulator.owner(), mod_id)
	button.set_pressed_no_signal(active)
	_apply_wire_color(button, mod_id)
	if active:
		_start_pulse(button)
	else:
		_stop_pulse(button)


func _apply_wire_color(button: Button, mod_id: int) -> void:
	button.flat = false
	var color := _color_for_mod(mod_id)
	for role in WIRE_COLOR_ROLES:
		button.add_theme_color_override(role, color)


func _start_pulse(button: Button) -> void:
	_stop_pulse(button)
	_pulses[button] = create_tween().set_loops()
	_pulses[button].tween_property(button, "modulate:a", PULSE_MIN_ALPHA, PULSE_HALF_CYCLE)
	_pulses[button].tween_property(button, "modulate:a", 1.0, PULSE_HALF_CYCLE)


func _stop_pulse(button: Button) -> void:
	var pulse: Tween = _pulses.get(button)
	if pulse != null:
		pulse.kill()
		_pulses.erase(button)
	button.modulate.a = 1.0


# ============================================================================
# INPUT (select on release, drag, rename, panel menu)
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if modulator == null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_open_menu()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# A press on the pair's interactive pad is the pad's, never a tile select/drag.
			if _display is XYPadPanel and _display.get_rect().has_point(event.position):
				return
			if event.pressed:
				# Double-click the header renames in place; the release that follows
				# must not toggle the selection.
				if event.double_click and _header != null \
						and _header.get_rect().has_point(event.position):
					_start_rename()
					_skip_release = true
					accept_event()
					return
				_pressing = true
				_press_pos = event.global_position
				_dragging = false
			else:
				if _skip_release:
					_skip_release = false
					return
				var moved := _pressing and _press_pos.distance_to(event.global_position) > DRAG_THRESHOLD
				_pressing = false
				var was_dragging := _dragging
				_dragging = false
				if not was_dragging and not moved:
					selected.emit(modulator.mod_id)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if not _pressing or _dragging:
			return
		if event.global_position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_dragging = true
			drag_started.emit(modulator)


func _start_rename() -> void:
	_rename.text = modulator.name
	_rename.visible = true
	_name_label.visible = false
	_rename.grab_focus()
	_rename.select_all()


func _on_rename_submitted(_text: String) -> void:
	_commit_rename()

## Esc in the rename box reverts without committing (the gui_input signal fires
## before LineEdit's own handling, so accepting keeps its default out).
func _on_rename_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_cancel_rename()
		accept_event()


func _cancel_rename() -> void:
	if not _rename.visible:
		return
	_rename.visible = false
	_name_label.visible = true
	_rename.release_focus()


func _commit_rename() -> void:
	if _rename.visible:
		_rename.visible = false
		_name_label.visible = true
		if modulator != null:
			modulator.set_name(_rename.text)
		refresh()


## Route entries of this tile's slot(s) (disconnect on pick), then Rename / Duplicate / Delete.
func _open_menu() -> void:
	_menu.clear()
	_menu_route_mod_ids.clear()
	_menu_route_count = 0
	var entries: Array = []
	if pad != null:
		entries = [[pad.x, "X"], [pad.y, "Y"]]
	elif modulator != null:
		entries = [[modulator, ""]]
	# Identical labels (e.g. two same-named children) get " (2)", " (3)" … so each stays distinguishable.
	var seen: Dictionary = {}
	for entry in entries:
		var mod: Modulator = entry[0]
		var axis: String = entry[1]
		for target in mod.routes:
			var prefix := "" if axis == "" else "%s " % axis
			var label := prefix + _target_name(String(target))
			seen[label] = int(seen.get(label, 0)) + 1
			if seen[label] > 1:
				label += " (%d)" % seen[label]
			_menu.add_item("%s  %s  ✕" % [label,
				ModDisplay.default_amount_text(float(mod.routes[target]))], _menu.item_count)
			_menu.set_item_metadata(_menu.item_count - 1, String(target))
			_menu_route_mod_ids.append(mod.mod_id)
			_menu_route_count += 1
	if _menu_route_count > 0:
		_menu.add_separator()
	_menu.add_item("Rename", MENU_RENAME)
	_menu.add_item("Duplicate", MENU_DUPLICATE)
	_menu.add_item("Delete", MENU_DELETE)
	ContextMenuPopup.popup_below_control(_menu, self)


func _on_menu_id(id: int) -> void:
	if modulator == null:
		return
	var owner = modulator.owner()
	if owner == null:
		return
	if id == MENU_RENAME:
		_start_rename()
	elif id == MENU_DUPLICATE:
		if pad != null:
			owner.duplicate_xy_pad(pad)
		else:
			owner.duplicate_modulator(modulator.mod_id)
	elif id == MENU_DELETE:
		if pad != null:
			owner.remove_xy_pad(pad)
		else:
			owner.remove_modulator(modulator.mod_id)
	elif id >= 0 and id < _menu_route_count:
		var target := str(_menu.get_item_metadata(id))
		owner.set_route_amount(_menu_route_mod_ids[id], target, 0.0)
		ModAssign.notify_changed()


## A parameter's name, prefixed with its module when several parameters of the device share the
## name (an EQ's per-band Gain becomes "Band 2 › Gain"); a unique name stays bare.
func _param_label(device, param) -> String:
	if param.module != "":
		for other in device.get_parameters_in_group(param.group if param.group != "" else "param"):
			if other != param and other.name == param.name:
				return "%s › %s" % [param.module, param.name]
	return param.name


## Human-readable name of a route target relative to the owning device.
func _target_name(target: String) -> String:
	var owner = modulator.owner()
	if owner == null:
		return target
	var parts := target.split("/")
	if parts.size() >= 2 and parts[0] == "param":
		var param = owner.get_parameter(int(parts[1]))
		return _param_label(owner, param) if param != null else target
	if parts.size() >= 4 and parts[0] == "child":
		var device = owner
		var names: PackedStringArray = []
		for piece in parts[1].split("."):
			if device == null or not (piece as String).is_valid_int():
				return target
			var child_index := int(piece)
			if child_index < 0 or child_index >= device.children.size():
				return target
			device = device.children[child_index]
			names.append(device.get_display_name())
		var child_param = device.get_parameter(int(parts[3])) if device != null else null
		if child_param == null:
			return target
		names.append(_param_label(device, child_param))
		return " › ".join(names)
	if parts.size() >= 2 and parts[0] == "mod":
		var other = owner.get_modulator(int(parts[1]))
		if other == null:
			return target
		if parts.size() >= 4 and parts[2] == "param":
			var mod_param = other.get_parameter(int(parts[3]))
			var mod_param_name: String = mod_param.name if mod_param != null else "param %s" % parts[3]
			return "%s › %s" % [other.name, mod_param_name]
		return other.name
	return target
