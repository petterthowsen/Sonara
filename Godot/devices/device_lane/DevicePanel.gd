# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

## Height of every device panel. A panel is as wide as its content needs, but views get only the
## height left below the header and must fit it (the Simple View shrinks its rows); tabs a view
## wants go in the header (`DeviceView.get_header_tabs`), not inside the view.
const HEIGHT := 350.0
const ICON_VIEW_OPEN := preload("res://assets/icons/chevron-right.svg")
const ICON_VIEW_CLOSED := preload("res://assets/icons/chevron-left.svg")

## Widest the device name gets while view tabs share the header with it.
const NAME_MAX_WIDTH := 140.0

## Seconds a pane (View, Parameters/CCs/Modulators/File) takes to slide open/closed and fade.
const PANE_ANIM_DURATION := 0.15

var logger : Log = Log.make("DevicePanel")

## Top header: light and name. Drops onto it go onto the device.
@onready var header : PanelContainer = $VBox/TopHeader

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBox/TopHeader/HBox/DeviceLight
@onready var name_label : Label = $VBox/TopHeader/HBox/Name

## Opens the preset menu (save, load, show in browser).
@onready var preset_button: Button = $VBox/TopHeader/HBox/Preset

## Shown only while the bound device is crashed/failed; reloads the plugin host.
@onready var reload_button: Button = $VBox/TopHeader/HBox/Reload

# Left header: View and Window toggles, then the Parameters/CCs/File tabs (one ButtonGroup)
## Device name written vertically in the left header while the View is closed.
@onready var left_header : PanelContainer = $VBox/HBox/LeftHeader
@onready var vertical_name_label: Label = $VBox/HBox/LeftHeader/VBox/Name/Label
@onready var tab_buttons : BoxContainer = $VBox/HBox/LeftHeader/VBox/TabButtons
@onready var view_button: Button = $VBox/HBox/LeftHeader/VBox/View
@onready var window_button: Button = $VBox/HBox/LeftHeader/VBox/TabButtons/Window
## Switches between a device's own Panel view and the generated Simple View (REQ-011 decision).
## Visible only for a device that has both.
@onready var simple_button: Button = $VBox/HBox/LeftHeader/VBox/TabButtons/Simple
@onready var params_button : Button = $VBox/HBox/LeftHeader/VBox/TabButtons/Parameters
@onready var file_button: Button = $VBox/HBox/LeftHeader/VBox/TabButtons/File

## True while the DeviceLane selected this panel's device. Selection swaps the theme variation
## (`DeviceCard` / `DeviceCardSelected`), so every selectable item shares the neutral border.
var is_selected := false:
	set(selected):
		is_selected = selected
		theme_type_variation = &"DeviceCardSelected" if selected else &"DeviceCard"
## MIDI CC tab (duplicated from Parameters at runtime until it gets its own icon)
var cc_button: Button
var ccs_pane: Control
var ccs_scroll: ScrollContainer
var ccs_box: VBoxContainer
## Clipping wrapper per animatable pane (see _wrap_pane), so pane show/hide slides the layout.
var _pane_wraps := {}

## Modulators tab (spec 018): available for every device, its pane sits beside Parameters/CCs.
const MODULATORS_ICON := preload("res://assets/icons/cable.svg")
var modulators_button: Button
var modulators_pane: Control
var modulators: ModulatorsPane
## Small mark in the collapsed left header so modulation is never invisible.
var _mod_dot: Label

# Content row: [Parameters | CCs | File] [View]
@onready var content_hbox: HBoxContainer = $VBox/HBox/Content/HBox
@onready var parameters_pane: Control = $VBox/HBox/Content/HBox/Parameters
@onready var parameters_scroll : ScrollContainer = $VBox/HBox/Content/HBox/Parameters/Scroll
@onready var parameters_box : VBoxContainer = $VBox/HBox/Content/HBox/Parameters/Scroll/VBox
@onready var file_box: Control = $VBox/HBox/Content/HBox/File

# Custom UI (Panel view, or Companion view while the device window is open)
@onready var view_pane : Control = $VBox/HBox/Content/HBox/View

# For Opening files for devices that support file loading
@onready var file_dialog: FileDialog = $FileDialog
@onready var file_status_label: Label = $VBox/HBox/Content/HBox/File/VBox/StatusLabel
@onready var file_load_button: Button = $VBox/HBox/Content/HBox/File/VBox/LoadButton

# The device window popup (native GUI or Window view) is owned by the global
# DeviceWindowManager so it survives track switches and panel rebuilds.

var device : DeviceInstance
## Channel whose device_parameters_updated this panel listens to.
var _channel: Channel = null
var loaded_file_path: String = ""

## View state
var _panel_view: DeviceView = null
var _companion_view: DeviceView = null

## Universal parameter lists (Parameters and CCs tabs)
var _param_list: ParameterList
var _cc_list: ParameterList

## True while the Parameters tab is open only because the device has no view to show, so it
## closes again once a view arrives. Any tab click by the user clears it.
var _params_auto_opened := false

## The shown view's tabs (e.g. Simple View pages), in the top header after the name.
@onready var header_tabs: TabBar = $VBox/TopHeader/HBox/ViewTabs
## View whose tabs `header_tabs` shows (null when none is shown).
var _tabs_view: DeviceView = null
## True while the View is toggled off: the top header then shows only the device light and the
## name runs vertically in the left header.
var _collapsed := false
## True while `header_tabs` is being filled from the view, so its signals don't echo back.
var _syncing_tabs := false

signal request_context_menu()
## The Panel view asked for the context menu of one of the device's slot chains.
signal request_child_context_menu(child: DeviceInstance)
## Left click (left header, top header or panel background). The DeviceLane owns the selection;
## ctrl/cmd = additive, shift = range. Released without a drag collapses a multi-selection.
signal select_requested(panel: DevicePanel, additive: bool, range_select: bool)
signal select_released(panel: DevicePanel)

## Stripe above the header, shown only for note effects (spec 027 REQ-036).
var note_fx_stripe: ColorRect = null

func _ready() -> void:
	custom_minimum_size.y = HEIGHT
	_create_note_fx_stripe()
	DeviceWindowManager.state_changed.connect(_on_window_state_changed)
	_create_cc_tab()
	_create_modulators_tab()
	_setup_header_tabs()
	_create_parameter_lists()
	_create_mod_dot()
	# Panes animate through clipped reveal wrappers, so their opening and closing slides the
	# whole panel layout instead of only fading in place.
	for pane in [parameters_pane, ccs_pane, modulators_pane, file_box, view_pane]:
		_wrap_pane(pane)

	# Parameters/CCs/Modulators/File share a ButtonGroup; clicking the active tab collapses it.
	params_button.button_group.allow_unpress = true
	params_button.toggled.connect(_on_tab_toggled.unbind(1))
	cc_button.toggled.connect(_on_tab_toggled.unbind(1))
	modulators_button.toggled.connect(_on_tab_toggled.unbind(1))
	file_button.toggled.connect(_on_tab_toggled.unbind(1))
	for tab in [params_button, cc_button, modulators_button, file_button]:
		tab.pressed.connect(func(): _params_auto_opened = false)
	view_button.toggled.connect(_on_view_toggled)
	window_button.toggled.connect(_on_window_toggled)
	simple_button.toggled.connect(_on_simple_toggled)
	reload_button.pressed.connect(_on_reload_pressed)
	preset_button.pressed.connect(_on_preset_button_pressed)

	# Connect file loading
	file_load_button.pressed.connect(_on_load_file_pressed)
	file_dialog.file_selected.connect(_on_file_selected)

	# The header shows the name as a plain Label (mouse PASS, so clicks and drags pass through);
	# renaming goes through the context menu (DeviceActions.rename).

	# Initial state: only the View open. The Parameters tab opens by itself only for a device
	# with no view (`_apply_default_tab`).
	view_button.set_pressed_no_signal(true)
	_update_tab_panes()

	# Drag the device from the header and content areas; drops resolve through DeviceDropTarget.
	# The left header lets clicks pass through to this panel (selection) and drags forward like
	# the top header, so it works as a drag handle too.
	left_header.mouse_filter = Control.MOUSE_FILTER_PASS
	header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	left_header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parameters_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	ccs_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	file_box.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)



## Duplicate the Parameters tab button and pane to make a CCs tab for MIDI CCs.
func _create_cc_tab() -> void:
	cc_button = params_button.duplicate()  # keeps the ButtonGroup
	cc_button.name = "CCs"
	cc_button.icon = null
	cc_button.text = "C"
	cc_button.tooltip_text = "MIDI CCs"
	cc_button.button_pressed = false
	cc_button.visible = false
	tab_buttons.add_child(cc_button)
	tab_buttons.move_child(cc_button, file_button.get_index())

	ccs_pane = parameters_pane.duplicate()
	ccs_pane.name = "CCs"
	ccs_pane.visible = false
	content_hbox.add_child(ccs_pane)
	content_hbox.move_child(ccs_pane, file_box.get_index())
	ccs_scroll = ccs_pane.get_node("Scroll")
	ccs_box = ccs_scroll.get_node("VBox")
	for child in ccs_box.get_children():
		child.queue_free()


## Add the Modulators tab button (in the Parameters ButtonGroup) and its pane beside the others.
## Available for every device: builtins, containers and plugins alike.
func _create_modulators_tab() -> void:
	modulators_button = params_button.duplicate()  # keeps the ButtonGroup
	modulators_button.name = "Modulators"
	modulators_button.icon = MODULATORS_ICON
	modulators_button.text = ""
	modulators_button.tooltip_text = "Modulators"
	modulators_button.button_pressed = false
	modulators_button.visible = false
	# Below the View (show/hide) toggle, at the top of the left header.
	var left_column: BoxContainer = view_button.get_parent()
	left_column.add_child(modulators_button)
	left_column.move_child(modulators_button, view_button.get_index() + 1)

	modulators_pane = PanelContainer.new()
	modulators_pane.name = "Modulators"
	modulators_pane.visible = false
	modulators_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	modulators_pane.add_theme_stylebox_override("panel", parameters_pane.get_theme_stylebox("panel"))
	content_hbox.add_child(modulators_pane)
	content_hbox.move_child(modulators_pane, file_box.get_index())

	modulators = ModulatorsPane.new()
	modulators_pane.add_child(modulators)


## The collapsed header's modulator mark: a small dot, shown only when collapsed and the bound
## device has modulators, so modulation is never invisible.
func _create_mod_dot() -> void:
	_mod_dot = Label.new()
	_mod_dot.text = "●"
	_mod_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mod_dot.add_theme_font_size_override("font_size", 11)
	_mod_dot.add_theme_color_override("font_color", ModDisplay.source_color(0))
	vertical_name_label.get_parent().add_child(_mod_dot)
	_mod_dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE)
	_mod_dot.visible = false


func _update_mod_dot() -> void:
	if _mod_dot == null:
		return
	_mod_dot.visible = _collapsed and device != null and device.has_modulation()


## Tab bar for the shown view's tabs (`ViewTabs` in the scene), after the name in the top header.
## It clips and scrolls with arrows, so it never widens the panel by more than one tab. The header
## always keeps the tab bar's height, so panels line up whether or not they show tabs.
func _setup_header_tabs() -> void:
	header_tabs.add_tab("M")
	(header_tabs.get_parent() as Control).custom_minimum_size.y = header_tabs.get_combined_minimum_size().y
	header_tabs.clear_tabs()
	header_tabs.hide()
	header_tabs.tab_changed.connect(_on_header_tab_changed)


## Show the tabs of the view in the View pane (`DeviceView.get_header_tabs`); none while the pane
## is hidden. Follows the view's `header_tabs_changed`.
func _update_header_tabs() -> void:
	if header_tabs == null:
		return
	var view := _shown_view() if view_pane.visible else null
	if view != _tabs_view:
		if is_instance_valid(_tabs_view) and _tabs_view.header_tabs_changed.is_connected(_update_header_tabs):
			_tabs_view.header_tabs_changed.disconnect(_update_header_tabs)
		_tabs_view = view
		if view:
			view.header_tabs_changed.connect(_update_header_tabs)
	var titles := view.get_header_tabs() if view else PackedStringArray()
	_syncing_tabs = true
	var shown := PackedStringArray()
	for i in header_tabs.tab_count:
		shown.append(header_tabs.get_tab_title(i))
	if shown != titles:
		header_tabs.clear_tabs()
		for title in titles:
			header_tabs.add_tab(title)
	if not titles.is_empty():
		header_tabs.current_tab = clampi(view.get_header_tab(), 0, titles.size() - 1)
	_syncing_tabs = false
	header_tabs.visible = not titles.is_empty() and not _collapsed
	_fit_name_to_tabs()


## With tabs showing, the name takes only its text's width (up to `NAME_MAX_WIDTH`) and the tabs
## start right after it, left-aligned; without, the name takes the whole header.
func _fit_name_to_tabs() -> void:
	if header_tabs == null:
		return
	if not header_tabs.visible:
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.custom_minimum_size.x = 0
		return
	var font := name_label.get_theme_font("font")
	var width := font.get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_label.get_theme_font_size("font_size")).x
	name_label.size_flags_horizontal = Control.SIZE_FILL
	name_label.custom_minimum_size.x = minf(ceilf(width) + 4.0, NAME_MAX_WIDTH)


func _on_header_tab_changed(index: int) -> void:
	if not _syncing_tabs and is_instance_valid(_tabs_view):
		_tabs_view.select_header_tab(index)


## The view showing in the View pane: the Companion view while it's up, else the Panel view.
func _shown_view() -> DeviceView:
	if _companion_view and _companion_view.visible:
		return _companion_view
	if _panel_view and _panel_view.visible:
		return _panel_view
	return null


## Host interchangeable ParameterList instances in the Parameters and CCs panes.
func _create_parameter_lists() -> void:
	_param_list = ParameterList.new()
	_param_list.group = "param"
	parameters_box.add_child(_param_list)
	if ccs_box:
		_cc_list = ParameterList.new()
		_cc_list.group = "cc"
		ccs_box.add_child(_cc_list)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			request_context_menu.emit()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				select_requested.emit(self, mb.ctrl_pressed or mb.meta_pressed, mb.shift_pressed)
			else:
				select_released.emit(self)


## Release engine subscriptions and popups when the panel is freed (e.g.
## DeviceLane.clear()/_on_channel_device_removed(), or a parent being freed).
## Without this, custom views (like the spectrum analyzer) never get
## _on_view_hidden(). Device windows are exempt: DeviceWindowManager owns them.
## Not _exit_tree(): DockHost reparents docks, which would wipe the parameter
## controls with nothing to rebuild them.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


## Disconnect from the bound device and tear down its views. Idempotent.
func _unbind() -> void:
	if device == null:
		return
	# The window popup stays open: it is owned by DeviceWindowManager, keyed by
	# device, and survives this panel being freed (e.g. a track switch).
	if device.name_changed.is_connected(_on_device_name_changed):
		device.name_changed.disconnect(_on_device_name_changed)
	if device.modulator_added.is_connected(_on_modulators_changed):
		device.modulator_added.disconnect(_on_modulators_changed)
	if device.modulator_removed.is_connected(_on_modulators_changed):
		device.modulator_removed.disconnect(_on_modulators_changed)
	if modulators:
		modulators.unbind()
	if _mod_dot:
		_mod_dot.visible = false
	if device.loading_state_changed.is_connected(_on_device_loading_state_changed):
		device.loading_state_changed.disconnect(_on_device_loading_state_changed)
	if device.host_changed.is_connected(_update_header_tooltip):
		device.host_changed.disconnect(_update_header_tooltip)
	if device.stats_changed.is_connected(_update_header_tooltip):
		device.stats_changed.disconnect(_update_header_tooltip)
	if device.preset_changed.is_connected(_update_preset_tooltip):
		device.preset_changed.disconnect(_update_preset_tooltip)
	if reload_button:
		reload_button.visible = false
	if _channel and _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.disconnect(_on_device_parameters_updated)
	_channel = null
	_clear_parameter_controls()
	_clear_panel_and_companion()
	device = null


## Show the Reload button only while the bound device needs a respawn.
func _update_reload_button_visibility() -> void:
	if reload_button == null:
		return
	var state: String = device.loading_state if device else ""
	reload_button.visible = (state.begins_with("crashed:") or state.begins_with("failed:")) and not _collapsed


func _on_device_loading_state_changed(_state: String) -> void:
	_update_reload_button_visibility()


## Header tooltip: the device type, plus which plugin host process it runs in and how much
## time it takes to process (CLAP).
func _update_header_tooltip() -> void:
	if header == null or device == null:
		return
	var text: String = device.device.name
	var host := device.host_description()
	if not host.is_empty():
		text += "\n" + host
	if device.plugin_stats != null:
		text += "\n" + device.plugin_stats.describe()
	header.tooltip_text = text
	name_label.tooltip_text = text


# ============================================================================
# PRESETS
# ============================================================================

## Subfolder submenus kick in when a device has more presets than this.
const PRESET_SUBMENU_THRESHOLD := 15
## Menu ids must be >= 0 (-1 means "auto-assign"); preset items use 0..n-1.
const PRESET_SAVE := 100001
const PRESET_SAVE_NEW := 100002
const PRESET_BROWSER := 100003

const SaveDialogScene := preload("res://devices/DevicePresetSaveDialog.tscn")

var _preset_menu: PopupMenu = null
var _preset_save_dialog: DevicePresetSaveDialog = null
## Preset file paths of the menu's items; the item id indexes into it.
var _preset_menu_paths: PackedStringArray = []


func _update_preset_tooltip() -> void:
	if preset_button and device:
		preset_button.tooltip_text = device.preset_name if not device.preset_name.is_empty() else "No preset"


func _on_preset_button_pressed() -> void:
	if device == null:
		return
	if _preset_menu == null:
		_preset_menu = PopupMenu.new()
		_preset_menu.theme_type_variation = &"ContextMenuList"
		_preset_menu.id_pressed.connect(_on_preset_menu_id)
		add_child(_preset_menu)
	_build_preset_menu()
	_preset_menu.position = Vector2i(preset_button.get_screen_position() + Vector2(0, preset_button.size.y))
	_preset_menu.popup()


func _build_preset_menu() -> void:
	_preset_menu.clear()
	for i in range(_preset_menu.get_child_count() - 1, -1, -1):
		_preset_menu.get_child(i).queue_free()
	_preset_menu_paths = PackedStringArray()
	_preset_menu.add_item("Save Preset…", PRESET_SAVE)
	_preset_menu.add_item("Save as New Preset…", PRESET_SAVE_NEW)
	_preset_menu.add_separator()
	var presets := PresetLibrary.list_for_device(device.device.id, device.device.name)
	if presets.is_empty():
		_preset_menu.add_item("(No presets)")
		_preset_menu.set_item_disabled(_preset_menu.item_count - 1, true)
	var root := PresetLibrary.folder_for(device.device.name)
	var submenus: Dictionary = {}
	for preset in presets:
		var target := _preset_menu
		var folder := preset.path.get_base_dir()
		if presets.size() > PRESET_SUBMENU_THRESHOLD and folder != root and folder.begins_with(root + "/"):
			var sub_name := folder.substr(root.length() + 1)
			if not submenus.has(sub_name):
				var sub := PopupMenu.new()
				sub.theme_type_variation = &"ContextMenuList"
				sub.name = "Sub%d" % submenus.size()
				sub.id_pressed.connect(_on_preset_menu_id)
				_preset_menu.add_child(sub)
				_preset_menu.add_submenu_node_item(sub_name, sub)
				submenus[sub_name] = sub
			target = submenus[sub_name]
		var id := _preset_menu_paths.size()
		_preset_menu_paths.append(preset.path)
		target.add_check_item(preset.name, id)
		target.set_item_checked(target.item_count - 1, preset.path == device.preset_path)
	_preset_menu.add_separator()
	_preset_menu.add_item("Show in Browser", PRESET_BROWSER)


func _on_preset_menu_id(id: int) -> void:
	if device == null:
		return
	match id:
		PRESET_SAVE:
			_open_preset_save_dialog(true)
		PRESET_SAVE_NEW:
			_open_preset_save_dialog(false)
		PRESET_BROWSER:
			var browser := get_tree().get_first_node_in_group(Browser.GROUP) as Browser
			if browser:
				browser.show_presets(device.device.name)
		_:
			if id >= 0 and id < _preset_menu_paths.size():
				DeviceDropUtil.load_preset_into(device, _preset_menu_paths[id])


func _open_preset_save_dialog(keep_preset: bool) -> void:
	if _preset_save_dialog == null:
		_preset_save_dialog = SaveDialogScene.instantiate()
		add_child(_preset_save_dialog)
	_preset_save_dialog.open_for(device, keep_preset)


func _on_reload_pressed() -> void:
	if device:
		device.reload()


## Refresh the header when the instance is renamed.
func _on_device_name_changed(new_name: String) -> void:
	if name_label:
		name_label.text = new_name
		vertical_name_label.text = new_name
		_fit_name_to_tabs()


## A modulator was added or removed: refresh the collapsed-header mark.
func _on_modulators_changed(_arg = null) -> void:
	_update_mod_dot()





## The note-effect marker: a thin bar in the secondary accent colour at the top of the panel.
func _create_note_fx_stripe() -> void:
	note_fx_stripe = ColorRect.new()
	note_fx_stripe.name = "NoteFxStripe"
	note_fx_stripe.custom_minimum_size.y = 3
	note_fx_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note_fx_stripe.visible = false
	$VBox.add_child(note_fx_stripe)
	$VBox.move_child(note_fx_stripe, 0)


func _update_note_fx_stripe() -> void:
	var is_note_fx := device != null and device.device != null and device.device.is_note_effect()
	note_fx_stripe.visible = is_note_fx
	if is_note_fx:
		note_fx_stripe.color = UiColors.role(&"accent_secondary")


func bind_to_device(dev : DeviceInstance):
	_unbind()
	device = dev

	if not is_node_ready():
		await ready
		if device != dev:
			return
	device_light.bind_to_device_instance(dev)
	_update_note_fx_stripe()
	name_label.text = dev.get_display_name()
	vertical_name_label.text = dev.get_display_name()
	if not dev.name_changed.is_connected(_on_device_name_changed):
		dev.name_changed.connect(_on_device_name_changed)
	if not dev.loading_state_changed.is_connected(_on_device_loading_state_changed):
		dev.loading_state_changed.connect(_on_device_loading_state_changed)
	if not dev.host_changed.is_connected(_update_header_tooltip):
		dev.host_changed.connect(_update_header_tooltip)
	if not dev.stats_changed.is_connected(_update_header_tooltip):
		dev.stats_changed.connect(_update_header_tooltip)
	if not dev.preset_changed.is_connected(_update_preset_tooltip):
		dev.preset_changed.connect(_update_preset_tooltip)
	_update_preset_tooltip()
	_update_reload_button_visibility()
	_update_header_tooltip()
	# Listen for parameter list updates (when plugins load params asynchronously)
	# Individual CompactParameterControls already listen to parameter value changes.
	# Connected before any `await` below: the engine can advertise params
	# (param/count + param/info) while a panel view scene is still loading,
	# and a listener connected only after that await would miss the signal,
	# leaving the parameters pane stuck hidden.
	_channel = dev.get_channel()
	if _channel:
		if not _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
			_channel.device_parameters_updated.connect(_on_device_parameters_updated)

	_create_parameter_controls()
	modulators.bind_to_device(dev)
	if not dev.modulator_added.is_connected(_on_modulators_changed):
		dev.modulator_added.connect(_on_modulators_changed)
	if not dev.modulator_removed.is_connected(_on_modulators_changed):
		dev.modulator_removed.connect(_on_modulators_changed)
	_update_mod_dot()
	_update_cc_tab_visibility()
	# PanelView = custom UI only (not ParameterList, not container children). A device with no
	# Panel view of its own still gets one when it qualifies for the generated Simple View.
	if dev.device.has_panel_view() or dev.device.uses_simple_view(dev.get_parameters()):
		await _load_panel_view(dev)
		if device != dev or not is_inside_tree():
			return
		_show_right_pane_current()
	else:
		_clear_panel_and_companion()
	_update_view_toggle_visibility()
	_update_view_pane_visibility()

	# Window toggle visibility (native GUI or Window view scene); the pressed
	# state mirrors a window that is already open for this device.
	window_button.visible = dev.device.has_gui() or dev.device.has_window_view()
	window_button.set_pressed_no_signal(DeviceWindowManager.is_open(dev))
	if DeviceWindowManager.is_open(dev):
		_apply_window_state()

	# Configure file tab visibility and file dialog
	_configure_file_loading()
	_update_left_pane_visibility()
	_apply_default_tab()


## Bind the universal parameter lists (same API for builtins and plugins).
func _create_parameter_controls() -> void:
	if not device:
		return
	if _param_list:
		_param_list.bind_to_device(device, "param")
	if _cc_list:
		_cc_list.bind_to_device(device, "cc")


## Clear all parameter controls
func _clear_parameter_controls() -> void:
	if _param_list:
		_param_list.clear()
	if _cc_list:
		_cc_list.clear()


## Handle device parameters updated (for plugins that load parameters asynchronously)
func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	if not device:
		return
	if device == device_instance:
		if _param_list:
			_param_list.refresh()
		if _cc_list:
			_cc_list.refresh()
		_update_cc_tab_visibility()
		_refresh_panel_view_for_params()


## Re-evaluate the Panel view once a plugin/SFZ device's parameter list arrives or changes: a
## device that qualifies for the Simple View only once it has visible parameters (`uses_simple_view`)
## may not have had a Panel view loaded yet. A view that's already showing reconciles and rebuilds
## itself from its own `parameters_updated` subscription (`SimpleView._on_parameters_updated`), so
## this only needs to create one where there wasn't one before.
func _refresh_panel_view_for_params() -> void:
	if device == null:
		return
	_update_view_toggle_visibility()
	if _panel_view == null and (device.device.has_panel_view() or device.device.uses_simple_view(device.get_parameters())):
		var dev := device
		await _load_panel_view(dev)
		if device != dev or not is_inside_tree():
			return
		_show_right_pane_current()
	_update_view_pane_visibility()
	_apply_default_tab()


## The View is what a device normally shows, so the Parameters tab stays closed. A device with
## no view (and no tab open) gets its Parameters instead, until a view shows up.
func _apply_default_tab() -> void:
	if device == null:
		return
	var has_view := _panel_view != null or _companion_view != null
	if has_view:
		if _params_auto_opened and params_button.button_pressed:
			params_button.set_pressed_no_signal(false)
		_params_auto_opened = false
	elif params_button.button_group.get_pressed_button() == null and params_button.visible:
		params_button.set_pressed_no_signal(true)
		_params_auto_opened = true
	_update_tab_panes()


## Show/hide the View toggle (any custom or Simple view exists) and the Simple toggle (only when
## the device has both its own Panel view and visible parameters to generate a Simple View from).
func _update_view_toggle_visibility() -> void:
	if device == null:
		return
	var can_simple := device.device.uses_simple_view(device.get_parameters())
	view_button.visible = device.device.has_panel_view() or device.device.has_companion_view() or can_simple
	simple_button.visible = device.device.has_panel_view() and can_simple
	_update_view_pane_visibility()
	simple_button.set_pressed_no_signal(bool(Sonara.get_config("devices/simple_view/%s" % device.device.device_id, false)))


## "Simple" toggle: switch the Panel pane between the device's own view and the generated Simple
## View, and remember the choice per device id (REQ-011 decision).
func _on_simple_toggled(pressed: bool) -> void:
	if device == null:
		return
	Sonara.set_config("devices/simple_view/%s" % device.device.device_id, pressed)
	await _load_panel_view(device)
	_show_right_pane_current()


## ============================================================================
## TAB SWITCHING
## ============================================================================

## Any of Parameters/CCs/File changed (the ButtonGroup keeps at most one pressed).
func _on_tab_toggled() -> void:
	_update_tab_panes()


## Show the pane of the pressed tab; a hidden tab never shows its pane.
func _update_tab_panes() -> void:
	_animate_pane(parameters_pane, params_button.visible and params_button.button_pressed)
	if ccs_pane:
		_animate_pane(ccs_pane, cc_button.visible and cc_button.button_pressed)
	if modulators_pane:
		_animate_pane(modulators_pane, modulators_button.visible and modulators_button.button_pressed)
	_animate_pane(file_box, file_button.visible and file_button.button_pressed)

## Show or hide `pane` through its reveal wrapper: `reveal` tweens between 0 and 1, so the
## wrapper's width (and so the whole panel layout) slides while the pane fades. The pane is
## drawn at full size and clipped, like a drawer. Tweens live on the pane; a re-toggle kills
## the running one and continues from where it is.
func _animate_pane(pane: Control, show: bool) -> void:
	if pane == null:
		return
	var wrap: PaneReveal = _pane_wraps.get(pane)
	if wrap == null:
		pane.visible = show
		return
	var tween: Tween = pane.get_meta(&"pane_tween") if pane.has_meta(&"pane_tween") else null
	var running := tween != null and tween.is_valid()
	if running:
		tween.kill()
	# Already fully shown or fully hidden: nothing to animate.
	if not running and show and wrap.visible and is_equal_approx(wrap.reveal, 1.0):
		return
	if not running and not show and not wrap.visible:
		return
	if show:
		wrap.visible = true
		pane.visible = true
		tween = pane.create_tween()
		tween.set_parallel(true)
		tween.tween_property(wrap, "reveal", 1.0, PANE_ANIM_DURATION)
		tween.tween_property(pane, "modulate:a", 1.0, PANE_ANIM_DURATION).from(0.0)
		tween.chain().tween_callback(_pane_shown.bind(pane))
	elif wrap.visible:
		tween = pane.create_tween()
		tween.set_parallel(true)
		tween.tween_property(wrap, "reveal", 0.0, PANE_ANIM_DURATION)
		tween.tween_property(pane, "modulate:a", 0.0, PANE_ANIM_DURATION)
		tween.chain().tween_callback(_pane_hidden.bind(pane))
	pane.set_meta(&"pane_tween", tween)


## Put `pane` inside a clipping PaneReveal in its place, so its opening and closing can slide.
func _wrap_pane(pane: Control) -> void:
	if pane == null or not content_hbox.is_ancestor_of(pane):
		return
	var wrap := PaneReveal.new()
	wrap.name = String(pane.name) + "Reveal"
	wrap.clip_contents = true
	wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.reveal = 1.0 if pane.visible else 0.0
	wrap.visible = pane.visible
	content_hbox.add_child(wrap)
	content_hbox.move_child(wrap, pane.get_index())
	pane.size_flags_horizontal = Control.SIZE_FILL
	pane.size_flags_vertical = Control.SIZE_FILL
	content_hbox.remove_child(pane)
	wrap.add_child(pane)
	_pane_wraps[pane] = wrap


## A show animation finished: fully revealed.
func _pane_shown(pane: Control) -> void:
	var wrap: PaneReveal = _pane_wraps.get(pane)
	if wrap:
		wrap.reveal = 1.0
	pane.modulate.a = 1.0


## A hide animation finished: take the pane and its wrapper out of the layout, ready for next time.
func _pane_hidden(pane: Control) -> void:
	pane.visible = false
	pane.modulate.a = 1.0
	var wrap: PaneReveal = _pane_wraps.get(pane)
	if wrap:
		wrap.visible = false
		wrap.reveal = 0.0


## Take `pane` out of the layout at once, without an animation (a device with nothing to show).
func _hide_pane_now(pane: Control) -> void:
	if pane == null:
		return
	if pane.has_meta(&"pane_tween"):
		var tween: Tween = pane.get_meta(&"pane_tween")
		if tween and tween.is_valid():
			tween.kill()
	var wrap: PaneReveal = _pane_wraps.get(pane)
	if wrap:
		wrap.visible = false
		wrap.reveal = 0.0
	pane.visible = false
	pane.modulate.a = 1.0



## View toggle: show or hide the custom UI pane.
func _on_view_toggled(_pressed: bool) -> void:
	_update_view_pane_visibility()


## The View pane shows when toggled on and a Panel or Companion view is loaded.
func _update_view_pane_visibility() -> void:
	if not is_node_ready():
		return
	var has_view := _panel_view != null or _companion_view != null
	if has_view:
		_animate_pane(view_pane, view_button.button_pressed)
	else:
		_hide_pane_now(view_pane)
	_set_collapsed(view_button.visible and not view_button.button_pressed)
	_update_header_tabs()
	_update_reload_button_visibility()


## With the View closed the top header keeps only the device light; the name moves to the left
## header, written vertically. The chevron points left when closed, right when open.
func _set_collapsed(collapsed: bool) -> void:
	_collapsed = collapsed
	view_button.icon = ICON_VIEW_CLOSED if collapsed else ICON_VIEW_OPEN
	preset_button.visible = not collapsed
	name_label.visible = not collapsed
	vertical_name_label.visible = collapsed
	_update_mod_dot()


## Show the CCs tab only when this device has unlabeled MIDI CCs.
func _update_cc_tab_visibility() -> void:
	if not cc_button:
		return
	var show_cc = device != null and device.has_cc_parameters()
	cc_button.visible = show_cc
	if not show_cc and cc_button.button_pressed:
		params_button.button_pressed = true
	_update_left_pane_visibility()


## Hide tab buttons the device has nothing for, then refresh the panes.
func _update_left_pane_visibility() -> void:
	if device == null:
		return
	params_button.visible = not device.get_parameters_in_group("param").is_empty()
	modulators_button.visible = true
	# A pressed tab that just disappeared hands over to the first available one.
	var pressed := params_button.button_group.get_pressed_button()
	if pressed and not pressed.visible:
		pressed.set_pressed_no_signal(false)
		for tab in [params_button, cc_button, modulators_button, file_button]:
			if tab.visible:
				tab.set_pressed_no_signal(true)
				break
	_update_tab_panes()


## ============================================================================
## FILE LOADING
## ============================================================================

## Configure file loading UI based on device capabilities
func _configure_file_loading() -> void:
	if not device:
		return
	
	# Show/hide file tab based on device support
	if device.device.supports_file_loading:
		file_button.visible = true
		
		# Configure file dialog
		file_dialog.title = "Load %s" % device.device.file_type_description
		
		# Build filter string for file dialog
		var filters: PackedStringArray = []
		for ext in device.device.supported_file_extensions:
			filters.append("*%s ; %s Files" % [ext, ext.to_upper().trim_prefix(".")])
		file_dialog.filters = filters
		
		# Restore loaded file status from device instance (for project load)
		if device.loaded_file_path != "":
			loaded_file_path = device.loaded_file_path
			var filename = loaded_file_path.get_file()
			file_status_label.text = filename
		else:
			loaded_file_path = ""
			file_status_label.text = "No File Loaded"
	else:
		file_button.visible = false


## Handle load file button pressed
func _on_load_file_pressed() -> void:
	if not device:
		return
	
	# Open file dialog
	file_dialog.popup_centered()


## Handle file selected from dialog
func _on_file_selected(path: String) -> void:
	if not device:
		return
	
	logger.info("Loading file: %s" % path)
	
	# Load file into device
	device.load_file(path)
	
	# Update UI
	loaded_file_path = path
	var filename = path.get_file()
	file_status_label.text = filename
	
	logger.info("✓ File loaded: %s" % filename)


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Start a device drag (a DeviceDrag payload). Nothing moves until the drop.
func _get_drag_data(_at_position: Vector2) -> Variant:
	var root := DeviceDropTarget.find_root(self)
	var lane := root as DeviceLane
	return DeviceDrag.start(self, device, lane.selection_containing(device) if lane else [])


## Resolve from the pointer in the enclosing device lane: insert beside this panel, or onto its
## header (child into a container, file load). Outside a lane, only drops onto the device.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if DeviceDropTarget.find_root(self):
		return DeviceDropTarget.resolve_for(self, data).is_valid()
	return DeviceDropUtil.can_drop_on_device(device, data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if device == null:
		return
	if DeviceDropTarget.find_root(self):
		DeviceDropTarget.resolve_for(self, data).commit(data)
		return
	after_drop_onto(DeviceDropUtil.drop_on_device(device, data))


## After a drop onto this panel: open the slot of a child added to a container (the last child),
## or show a loaded file.
func after_drop_onto(added_child: bool) -> void:
	if device == null:
		return
	if added_child:
		if device.is_container() and not device.children.is_empty():
			device.reveal_child(device.children[device.children.size() - 1])
	elif not device.loaded_file_path.is_empty():
		loaded_file_path = device.loaded_file_path
		file_status_label.text = loaded_file_path.get_file()


## ============================================================================
## VIEW MANAGEMENT (Panel / Companion / Window)
## ============================================================================

func _load_panel_view(dev: DeviceInstance) -> void:
	_clear_panel_view()
	_panel_view = DeviceViewFactory.create(dev, Device.ViewType.Panel)
	if _panel_view:
		# Bind first so view has device context before any show/subscription
		_panel_view.bind_to_device(dev)
		_panel_view.child_context_menu_requested.connect(request_child_context_menu.emit)
		view_pane.add_child(_panel_view)
		_panel_view.visible = true
		if not _panel_view.is_node_ready():
			await _panel_view.ready


func _clear_panel_view() -> void:
	if _panel_view:
		if _panel_view.has_method("hide_view"):
			_panel_view.hide_view()
		_panel_view.queue_free()
		_panel_view = null


func _load_companion_view(dev: DeviceInstance) -> void:
	_clear_companion_view()
	_companion_view = DeviceViewFactory.create(dev, Device.ViewType.Companion)
	if _companion_view:
		# Bind first so view has device context before any show/subscription
		_companion_view.bind_to_device(dev)
		view_pane.add_child(_companion_view)
		_companion_view.visible = false
		if not _companion_view.is_node_ready():
			await _companion_view.ready


func _clear_companion_view() -> void:
	if _companion_view:
		if _companion_view.has_method("hide_view"):
			_companion_view.hide_view()
		_companion_view.queue_free()
		_companion_view = null


func _clear_panel_and_companion() -> void:
	_clear_panel_view()
	_clear_companion_view()
	_update_view_pane_visibility()


func _show_panel_view() -> void:
	# The panel view is hidden, not freed, while the companion view is up, so don't test `visible`.
	if _panel_view and not _panel_view.is_queued_for_deletion():
		logger.info("showing panel view")

		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_shown...")
		_panel_view.show()
		_panel_view.show_view()
	
	if _companion_view and _companion_view.visible:
		logger.info("hiding companion view")

		if not _companion_view.is_node_ready():
			logger.info("waiting for companion view to be ready...")
			await _companion_view.ready

		logger.info("companion view is ready, calling _on_view_hidden...")
		_companion_view.hide()
		_companion_view.hide_view()
	
	_update_view_pane_visibility()

func _show_companion_view() -> void:
	if _companion_view and not _companion_view.visible:
		if not _companion_view.is_node_ready():
			logger.info("waiting for companion view to be ready...")
			await _companion_view.ready

		logger.info("companion view is ready, calling _on_view_shown...")
		_companion_view.show()
		_companion_view.show_view()
	
	if _panel_view and _panel_view.visible:
		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_hidden...")
		_panel_view.hide()
		_panel_view.hide_view()
	
	_update_view_pane_visibility()


func _hide_companion_show_panel() -> void:
	_show_panel_view()


func _show_right_pane_current() -> void:
	if device and DeviceWindowManager.is_open(device) and _companion_view:
		_show_companion_view()
	else:
		_show_panel_view()


func _on_window_toggled(pressed: bool) -> void:
	if device == null:
		return
	if pressed:
		DeviceWindowManager.open(device)
	else:
		DeviceWindowManager.close(device)


## A device window opened or closed (from any panel or the window's own close
## button): refresh the toggle and the companion view when it is this device's.
func _on_window_state_changed(dev: DeviceInstance) -> void:
	if dev != device:
		return
	_apply_window_state()


func _apply_window_state() -> void:
	var open := device != null and DeviceWindowManager.is_open(device)
	if open and device.device.has_companion_view():
		if _companion_view == null:
			_load_companion_view(device)
		_show_companion_view()
	else:
		_hide_companion_show_panel()

	window_button.set_pressed_no_signal(open)
