## One modulator tile in the Modulators pane (spec 018): its name, its colour strip (from
## `ModDisplay.SOURCE_COLORS` by tile order) and its wire button.
##
## The wire button toggles assign mode for this modulator and pulses while active. A selected tile
## is highlighted with its colour; clicking it again deselects. Right-click opens the tile menu: one entry per route with a disconnect
## action, then Rename / Duplicate / Delete.
class_name ModulatorTile extends PanelContainer

## The tile was left-clicked (the pane toggles this modulator's detail).
signal selected(mod_id: int)

const WIRE_ICON := preload("res://assets/icons/cable.svg")

const MENU_RENAME := 100000
const MENU_DUPLICATE := 100001
const MENU_DELETE := 100002

var modulator: Modulator = null
var _strip: ColorRect = null
var _name_label: Label = null
var _rename: LineEdit = null
var _wire: Button = null
var _menu: PopupMenu = null
var _pulse: Tween = null
var _style: StyleBoxFlat = null
var _is_selected := false


func setup(mod: Modulator) -> void:
	modulator = mod
	if _name_label == null:
		_build()
	refresh()
	_sync_wire()


func _build() -> void:
	custom_minimum_size = Vector2(86, 42)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_style = StyleBoxFlat.new()
	_style.set_corner_radius_all(3)
	_style.set_content_margin_all(3)
	add_theme_stylebox_override("panel", _style)
	_apply_selected_style()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)

	_strip = ColorRect.new()
	_strip.custom_minimum_size = Vector2(4, 0)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_strip)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(column)

	_name_label = Label.new()
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_name_label)

	_rename = LineEdit.new()
	_rename.visible = false
	_rename.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename.text_submitted.connect(_on_rename_submitted)
	_rename.focus_exited.connect(_commit_rename)
	column.add_child(_rename)

	_wire = Button.new()
	_wire.toggle_mode = true
	_wire.focus_mode = Control.FOCUS_NONE
	_wire.icon = WIRE_ICON
	_wire.custom_minimum_size = Vector2(24, 24)
	_wire.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_wire.tooltip_text = "Assign: click, then drag a control of this device or one of its children"
	_wire.toggled.connect(_on_wire_toggled)
	row.add_child(_wire)

	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_menu.id_pressed.connect(_on_menu_id)
	add_child(_menu)

	ModAssign.holder().changed.connect(_sync_wire)
	mouse_entered.connect(func(): _set_hover(true))
	# Moving onto the wire button still counts as hovering the tile.
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
	_apply_selected_style()
	if _wire != null:
		_wire.tooltip_text = "Assign %s: click, then drag a control of this device or one of its children" % modulator.name


func set_selected(on: bool) -> void:
	_is_selected = on
	_apply_selected_style()


func _apply_selected_style() -> void:
	if _style == null:
		return
	var accent := _color() if modulator != null else Color.WHITE
	_style.bg_color = Color(accent, 0.16) if _is_selected else Color(1, 1, 1, 0.05)
	_style.set_border_width_all(1 if _is_selected else 0)
	_style.border_color = Color(accent, 0.9)
	queue_redraw()


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
# INPUT (select, rename, tile menu)
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if modulator == null or not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_open_menu()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(modulator.mod_id)


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
		return other.name if other != null else target
	return target
