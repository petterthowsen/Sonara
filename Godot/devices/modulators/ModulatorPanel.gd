## One modulator panel in the Modulators pane (spec 018, rebuilt in 033): header (colour strip +
## name/rename), an expanding display area (phase 3) and the wire button centered at the bottom.
## Selection uses the shared `DeviceCard` / `DeviceCardSelected` theme variations.
##
## The wire button toggles assign mode for this modulator and pulses while active. A left click
## selects only on release without crossing the drag threshold, so a press-and-drag never toggles
## selection; the pane starts a swap drag past the threshold. Right-click opens the panel menu: one
## entry per route with a disconnect action, then Rename / Duplicate / Delete.
class_name ModulatorPanel extends PanelContainer

## The panel was left-clicked (the pane toggles this modulator's detail).
signal selected(mod_id: int)
## A press-and-move crossed the drag threshold (the pane owns the drag from here).
signal drag_started(modulator: Modulator)

const WIRE_ICON := preload("res://assets/icons/cable.svg")

## Movement (px) past which a press becomes a drag instead of a click.
const DRAG_THRESHOLD := 6.0

const MENU_RENAME := 100000
const MENU_DUPLICATE := 100001
const MENU_DELETE := 100002

var modulator: Modulator = null
var _strip: ColorRect = null
var _name_label: Label = null
var _rename: LineEdit = null
var _display: Control = null
var _wire: Button = null
var _menu: PopupMenu = null
var _pulse: Tween = null
var _is_selected := false
## Position of the left press (global), valid only while `_pressing`.
var _press_pos := Vector2.ZERO
var _pressing := false
var _dragging := false


func setup(mod: Modulator) -> void:
	modulator = mod
	if _name_label == null:
		_build()
	if _display is ModulatorDisplay and modulator.owner() != null:
		(_display as ModulatorDisplay).setup(modulator.owner(), modulator.mod_id)
	refresh()
	_sync_wire()


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"DeviceCard" if not _is_selected else &"DeviceCardSelected"
	custom_minimum_size = Vector2(56, 56)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	column.add_child(header)

	_strip = ColorRect.new()
	_strip.custom_minimum_size = Vector2(2, 0)
	_strip.size_flags_vertical = Control.SIZE_FILL
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_strip)

	var name_column := VBoxContainer.new()
	name_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(name_column)

	_name_label = Label.new()
	_name_label.clip_text = true
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_column.add_child(_name_label)

	_rename = LineEdit.new()
	_rename.visible = false
	_rename.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename.text_submitted.connect(_on_rename_submitted)
	_rename.focus_exited.connect(_commit_rename)
	name_column.add_child(_rename)

	# The display area (phase 3); expands so the wire button sits at the bottom.
	_display = ModulatorDisplay.new()
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_display)

	_wire = Button.new()
	_wire.toggle_mode = true
	_wire.focus_mode = Control.FOCUS_NONE
	_wire.icon = WIRE_ICON
	_wire.custom_minimum_size = Vector2(24, 24)
	_wire.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_wire.tooltip_text = "Assign: click, then drag a control of this device or one of its children"
	_wire.toggled.connect(_on_wire_toggled)
	column.add_child(_wire)

	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_menu.id_pressed.connect(_on_menu_id)
	add_child(_menu)

	ModAssign.holder().changed.connect(_sync_wire)
	mouse_entered.connect(func(): _set_hover(true))
	# Moving onto the wire button still counts as hovering the panel.
	mouse_exited.connect(func(): _set_hover(get_global_rect().has_point(get_global_mouse_position())))
	tree_exiting.connect(func(): _set_hover(false))


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


func set_selected(on: bool) -> void:
	_is_selected = on
	theme_type_variation = &"DeviceCardSelected" if _is_selected else &"DeviceCard"


func _color() -> Color:
	var owner = modulator.owner()
	if owner == null:
		return ModDisplay.source_color(0)
	return ModDisplay.source_color(maxi(owner.modulators.find(modulator), 0))


# ============================================================================
# ASSIGN MODE
# ============================================================================

func _on_wire_toggled(pressed: bool) -> void:
	if modulator == null:
		return
	if pressed:
		ModAssign.begin(modulator.owner(), modulator.mod_id)
	elif ModAssign.is_active_for(modulator.owner(), modulator.mod_id):
		ModAssign.end()


## Follow the shared state: pressed while this modulator is the active one, pulsing.
func _sync_wire() -> void:
	if _wire == null or modulator == null:
		return
	var active := ModAssign.is_active_for(modulator.owner(), modulator.mod_id)
	_wire.set_pressed_no_signal(active)
	if active:
		_start_pulse()
	else:
		_stop_pulse()


func _start_pulse() -> void:
	_stop_pulse()
	_pulse = create_tween().set_loops()
	_pulse.tween_property(_wire, "modulate:a", 0.35, 0.5)
	_pulse.tween_property(_wire, "modulate:a", 1.0, 0.5)


func _stop_pulse() -> void:
	if _pulse != null:
		_pulse.kill()
		_pulse = null
	if _wire != null:
		_wire.modulate.a = 1.0


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
			if event.pressed:
				_pressing = true
				_press_pos = event.global_position
				_dragging = false
			else:
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


func _commit_rename() -> void:
	if _rename.visible:
		_rename.visible = false
		_name_label.visible = true
		if modulator != null:
			modulator.set_name(_rename.text)
		refresh()


## Route entries (disconnect on pick), then Rename / Duplicate / Delete.
func _open_menu() -> void:
	_menu.clear()
	var index := 0
	for target in modulator.routes:
		_menu.add_item("%s  %s  ✕" % [_target_name(String(target)), ModDisplay.default_amount_text(float(modulator.routes[target]))], index)
		_menu.set_item_metadata(index, String(target))
		index += 1
	if index > 0:
		_menu.add_separator()
	_menu.add_item("Rename", MENU_RENAME)
	_menu.add_item("Duplicate", MENU_DUPLICATE)
	_menu.add_item("Delete", MENU_DELETE)
	_menu.position = Vector2i(get_screen_position() + Vector2(0, size.y))
	_menu.popup()


func _on_menu_id(id: int) -> void:
	if modulator == null:
		return
	var owner = modulator.owner()
	if owner == null:
		return
	if id == MENU_RENAME:
		_start_rename()
	elif id == MENU_DUPLICATE:
		owner.duplicate_modulator(modulator.mod_id)
	elif id == MENU_DELETE:
		owner.remove_modulator(modulator.mod_id)
	elif id >= 0 and id < modulator.routes.size():
		var target := str(_menu.get_item_metadata(id))
		owner.set_route_amount(modulator.mod_id, target, 0.0)
		ModAssign.notify_changed()


## Human-readable name of a route target relative to the owning device.
func _target_name(target: String) -> String:
	var owner = modulator.owner()
	if owner == null:
		return target
	var parts := target.split("/")
	if parts.size() >= 2 and parts[0] == "param":
		var param = owner.get_parameter(int(parts[1]))
		return param.name if param != null else target
	if parts.size() >= 4 and parts[0] == "child":
		var device = owner
		for piece in parts[1].split("."):
			if device == null or not (piece as String).is_valid_int():
				return target
			var child_index := int(piece)
			if child_index < 0 or child_index >= device.children.size():
				return target
			device = device.children[child_index]
		var child_param = device.get_parameter(int(parts[3])) if device != null else null
		return child_param.name if child_param != null else target
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
