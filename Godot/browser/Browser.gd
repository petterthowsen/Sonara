# Browser is a tabbed UI of musical assets and devices from file system and project.
# each category can be a consolidation of multple contributing locations

class_name Browser extends VBoxContainer

# header area for toggling categories
@onready var header : PanelContainer = $Header
@onready var tab_buttons : HBoxContainer = $Header/TabButtons

# content area (filter and tabs etc)
@onready var content : PanelContainer = $Content
@onready var tabs : ScrollContainer = $Content/VBox/Tabs
@onready var search_text: LineEdit = $Content/VBox/Options/SearchText

# ============================================================================
# SIGNALS
# ============================================================================

signal asset_selected(asset: Asset)
signal asset_requested_drag(asset: Asset)  # When user starts dragging an asset


# ============================================================================
# PROPERTIES
# ============================================================================

# Tab management
var _current_tab: Asset.TYPE = Asset.TYPE.Audio
var _item_lists: Dictionary = {}  # Asset.TYPE -> ItemList
var _tab_buttons: Dictionary = {}  # Asset.TYPE -> Button

# Asset tracking
var _audio_assets: Array[Asset] = []
var _midi_assets: Array[Asset] = []
var _device_assets: Array[Asset] = []

# Search/filter
var _search_filter: String = ""


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	print("[Browser] Initializing...")
	_setup_ui()
	_connect_to_asset_service()
	_refresh_asset_list()


func _setup_ui() -> void:
	# Setup tab buttons
	_create_tab_button("S", "Samples (Audio + MIDI)", Asset.TYPE.Audio)
	_create_tab_button("D", "Devices", Asset.TYPE.Device)

	# Create ItemLists for each category
	_create_item_list(Asset.TYPE.Audio)
	_create_item_list(Asset.TYPE.Device)

	# Connect search input
	search_text.text_changed.connect(_on_search_text_changed)

	# Show first tab by default
	_switch_tab(Asset.TYPE.Audio)


func _create_tab_button(text: String, tooltip: String, asset_type: Asset.TYPE) -> void:
	var btn = Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	btn.toggle_mode = true
	btn.pressed.connect(_on_tab_button_pressed.bindv([asset_type]))

	tab_buttons.add_child(btn)
	_tab_buttons[asset_type] = btn


func _create_item_list(asset_type: Asset.TYPE) -> void:
	var item_list = ItemList.new()
	item_list.name = "ItemList_%s" % Asset.TYPE.keys()[asset_type]
	# Connect with bind to pass asset_type as last parameter
	item_list.item_clicked.connect(func(index: int, _at_position: Vector2, _mouse_button_index: int):
		_on_asset_selected(index, asset_type))
	item_list.set_drag_forwarding(
		Callable(self, "_get_drag_data"),
		Callable(self, "_can_drop_data"),
		Callable(self, "_drop_data")
	)
	item_list.visible = false  # Hidden by default, shown when tab is active

	# Configure ItemList appearance and behavior
	item_list.select_mode = ItemList.SELECT_MULTI
	item_list.allow_reselect = true
	item_list.allow_search = true
	item_list.auto_height = false  # Let parent ScrollContainer handle scrolling
	item_list.max_text_lines = 1
	item_list.max_columns = 2
	item_list.same_column_width = true
	item_list.wraparound_items = true

	# Make ItemList fill the parent ScrollContainer
	item_list.custom_minimum_size = Vector2(0, 0)  # Use parent size
	item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL

	tabs.add_child(item_list)
	_item_lists[asset_type] = item_list


func _connect_to_asset_service() -> void:
	if AssetService:
		AssetService.assets_updated.connect(_on_assets_updated)
		AssetService.asset_added.connect(_on_asset_added)
		AssetService.asset_removed.connect(_on_asset_removed)
		print("[Browser] Connected to AssetService")


# ============================================================================
# ASSET DISPLAY
# ============================================================================

func _refresh_asset_list() -> void:
	if not AssetService:
		print("[Browser] AssetService not available")
		return

	# Clear all ItemLists
	for item_list in _item_lists.values():
		item_list.clear()

	# Reset asset tracking
	_audio_assets.clear()
	_midi_assets.clear()
	_device_assets.clear()

	# Get all assets and sort by type
	var all_assets = AssetService.get_all_assets()
	for asset in all_assets:
		match asset.type:
			Asset.TYPE.Audio:
				_audio_assets.append(asset)
			Asset.TYPE.Midi:
				_midi_assets.append(asset)
			Asset.TYPE.Device:
				_device_assets.append(asset)

	# Populate Samples tab (Audio + MIDI combined)
	_populate_samples_tab()

	# Populate Devices tab
	_populate_devices_tab()


func _filter_assets(assets: Array[Asset]) -> Array[Asset]:
	"""Filter assets based on current search filter."""
	if _search_filter.is_empty():
		return assets
	
	var filtered: Array[Asset] = []
	var search_lower = _search_filter.to_lower()
	
	for asset in assets:
		var display_name = asset.get_display_name().to_lower()
		if display_name.contains(search_lower):
			filtered.append(asset)
	
	return filtered


func _populate_samples_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.Audio]

	# Filter assets based on search
	var filtered_audio = _filter_assets(_audio_assets)
	var filtered_midi = _filter_assets(_midi_assets)

	# Add Audio section
	if not filtered_audio.is_empty():
		var header_idx = item_list.add_item("Audio Files")
		item_list.set_item_custom_fg_color(header_idx, Color.YELLOW)
		item_list.set_item_disabled(header_idx, true)

		for asset in filtered_audio:
			var idx = item_list.add_item(asset.get_display_name())
			item_list.set_item_metadata(idx, asset)

	# Add MIDI section
	if not filtered_midi.is_empty():
		var header_idx = item_list.add_item("MIDI Files")
		item_list.set_item_custom_fg_color(header_idx, Color.YELLOW)
		item_list.set_item_disabled(header_idx, true)

		for asset in filtered_midi:
			var idx = item_list.add_item(asset.get_display_name())
			item_list.set_item_metadata(idx, asset)


func _populate_devices_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.Device]

	# Filter assets based on search
	var filtered_devices = _filter_assets(_device_assets)

	if filtered_devices.is_empty():
		var message = "(No matches)" if not _search_filter.is_empty() else "(No devices)"
		var idx = item_list.add_item(message)
		item_list.set_item_disabled(idx, true)
		return

	for asset in filtered_devices:
		var idx = item_list.add_item(asset.get_display_name())
		item_list.set_item_metadata(idx, asset)


# ============================================================================
# TAB SWITCHING
# ============================================================================

func _switch_tab(asset_type: Asset.TYPE) -> void:
	# Hide all ItemLists
	for item_list in _item_lists.values():
		item_list.visible = false

	# Show selected tab
	_item_lists[asset_type].visible = true

	# Update button states
	for type in _tab_buttons.keys():
		_tab_buttons[type].button_pressed = (type == asset_type)

	_current_tab = asset_type


func _on_tab_button_pressed(asset_type: Asset.TYPE) -> void:
	_switch_tab(asset_type)


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(position: Vector2) -> Variant:
	var item_list = _item_lists[_current_tab]
	var selected_idx = item_list.get_item_at_position(position)
	if selected_idx < 0:
		return null

	var asset = item_list.get_item_metadata(selected_idx)
	if not asset is Asset:
		return null

	asset_requested_drag.emit(asset)
	return asset


func _can_drop_data(position: Vector2, data: Variant) -> bool:
	return data is Asset


func _drop_data(position: Vector2, data: Variant) -> void:
	# This is typically handled by the target (timeline/arranger)
	# but we can log for debugging
	if data is Asset:
		print("[Browser] Drop event for asset: %s" % data.path)


# ============================================================================
# CALLBACKS
# ============================================================================

func _on_asset_selected(index: int, asset_type: Asset.TYPE) -> void:
	var item_list = _item_lists[asset_type]
	var asset = item_list.get_item_metadata(index)
	if asset is Asset:
		asset_selected.emit(asset)
		AssetService.mark_asset_used(asset.path)


func _on_assets_updated() -> void:
	_refresh_asset_list()


func _on_asset_added(asset: Asset) -> void:
	_refresh_asset_list()


func _on_asset_removed(asset: Asset) -> void:
	print("[Browser] Asset removed: %s" % asset.get_display_name())
	_refresh_asset_list()


func _on_search_text_changed(new_text: String) -> void:
	_search_filter = new_text.strip_edges()
	
	# Only repopulate the currently visible tab for efficiency
	match _current_tab:
		Asset.TYPE.Audio:
			_item_lists[Asset.TYPE.Audio].clear()
			_populate_samples_tab()
		Asset.TYPE.Device:
			_item_lists[Asset.TYPE.Device].clear()
			_populate_devices_tab()
