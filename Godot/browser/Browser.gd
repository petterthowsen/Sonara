# Browser is a tabbed UI of musical assets and devices from file system and project.
# each category can be a consolidation of multple contributing locations

class_name Browser extends VBoxContainer

enum DisplayMode {
	FLAT_LIST,  # ItemList - flat display
	TREE_VIEW   # Tree - hierarchical display
}

# header area for toggling categories
@onready var header : PanelContainer = $Header
@onready var tab_buttons : HBoxContainer = $Header/TabButtons

# content area (filter and tabs etc)
@onready var content : PanelContainer = $Content
@onready var tabs : ScrollContainer = $Content/VBox/Tabs
@onready var options_container: HBoxContainer = $Content/VBox/Options
@onready var mode_toggle_button: Button = $Content/VBox/Options/ModeToggle
@onready var search_text: LineEdit = $Content/VBox/Options/SearchText

# ============================================================================
# SIGNALS
# ============================================================================

signal asset_selected(asset: Asset)
signal asset_requested_drag(asset: Asset)  # When user starts dragging an asset


# ============================================================================
# PROPERTIES
# ============================================================================

# Display mode
var _display_mode: DisplayMode = DisplayMode.FLAT_LIST

# Tab management
var _current_tab: Asset.TYPE = Asset.TYPE.Audio
var _item_lists: Dictionary = {}  # Asset.TYPE -> ItemList
var _trees: Dictionary = {}  # Asset.TYPE -> Tree
var _tab_buttons: Dictionary = {}  # Asset.TYPE -> Button

# Asset tracking
var _audio_assets: Array[Asset] = []
var _midi_assets: Array[Asset] = []
var _device_assets: Array[Asset] = []
var _sfz_assets: Array[Asset] = []
var _soundfont_assets: Array[Asset] = []

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
	# Connect mode toggle button
	mode_toggle_button.pressed.connect(_on_mode_toggle_pressed)
	
	# Setup tab buttons
	_create_tab_button("S", "Samples", Asset.TYPE.Audio)
	_create_tab_button("D", "Devices", Asset.TYPE.Device)
	_create_tab_button("SFZ", "SFZ", Asset.TYPE.SFZ)

	# Create ItemLists for each category
	_create_item_list(Asset.TYPE.Audio)
	_create_item_list(Asset.TYPE.Device)
	_create_item_list(Asset.TYPE.SFZ)
	
	# Create Tree controls for each category
	_create_tree(Asset.TYPE.Audio)
	_create_tree(Asset.TYPE.Device)
	_create_tree(Asset.TYPE.SFZ)

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


func _create_tree(asset_type: Asset.TYPE) -> void:
	var tree = Tree.new()
	tree.name = "Tree_%s" % Asset.TYPE.keys()[asset_type]
	tree.hide_root = true
	tree.visible = false  # Hidden by default
	
	# Configure Tree appearance and behavior
	tree.allow_reselect = true
	tree.allow_rmb_select = true
	tree.select_mode = Tree.SELECT_MULTI
	
	# Make Tree fill the parent ScrollContainer
	tree.custom_minimum_size = Vector2(0, 0)
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Connect signals
	tree.item_selected.connect(func(): _on_tree_item_selected(asset_type))
	tree.set_drag_forwarding(
		Callable(self, "_get_drag_data_tree"),
		Callable(self, "_can_drop_data"),
		Callable(self, "_drop_data")
	)
	
	tabs.add_child(tree)
	_trees[asset_type] = tree


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

	# Clear all ItemLists and Trees
	for item_list in _item_lists.values():
		item_list.clear()
	for tree in _trees.values():
		tree.clear()

	# Reset asset tracking
	_audio_assets.clear()
	_midi_assets.clear()
	_device_assets.clear()
	_sfz_assets.clear()
	_soundfont_assets.clear()

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
			Asset.TYPE.SFZ:
				_sfz_assets.append(asset)
			Asset.TYPE.SoundFont:
				_soundfont_assets.append(asset)

	# Populate Samples tab (Audio + MIDI combined)
	_populate_samples_tab()
	_populate_samples_tree()

	# Populate SFZ tab
	_populate_sfz_tab()
	_populate_sfz_tree()

	# Populate Devices tab
	_populate_devices_tab()
	_populate_devices_tree()


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


func _populate_sfz_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.SFZ]

	# Filter assets based on search
	var filtered_sfz = _filter_assets(_sfz_assets)

	if filtered_sfz.is_empty():
		var message = "(No matches)" if not _search_filter.is_empty() else "(No SFZ instruments)"
		var idx = item_list.add_item(message)
		item_list.set_item_disabled(idx, true)
		return

	for asset in filtered_sfz:
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
# TREE VIEW POPULATION
# ============================================================================

func _populate_samples_tree() -> void:
	var tree = _trees[Asset.TYPE.Audio]
	var root = tree.create_item()
	
	# Filter assets based on search
	var filtered_audio = _filter_assets(_audio_assets)
	var filtered_midi = _filter_assets(_midi_assets)
	
	# Build hierarchical structure for audio files
	if not filtered_audio.is_empty():
		var audio_parent = tree.create_item(root)
		audio_parent.set_text(0, "Audio Files")
		audio_parent.set_custom_color(0, Color.YELLOW)
		audio_parent.set_selectable(0, false)
		audio_parent.set_collapsed(true)
		_build_asset_tree(audio_parent, filtered_audio, tree)
		_prune_empty_directories(audio_parent)
		_sort_tree_items(audio_parent)
	
	# Build hierarchical structure for MIDI files
	if not filtered_midi.is_empty():
		var midi_parent = tree.create_item(root)
		midi_parent.set_text(0, "MIDI Files")
		midi_parent.set_custom_color(0, Color.YELLOW)
		midi_parent.set_selectable(0, false)
		midi_parent.set_collapsed(true)
		_build_asset_tree(midi_parent, filtered_midi, tree)
		_prune_empty_directories(midi_parent)
		_sort_tree_items(midi_parent)


func _populate_sfz_tree() -> void:
	var tree = _trees[Asset.TYPE.SFZ]
	var root = tree.create_item()
	
	# Filter assets based on search
	var filtered_sfz = _filter_assets(_sfz_assets)
	
	if filtered_sfz.is_empty():
		var item = tree.create_item(root)
		var message = "(No matches)" if not _search_filter.is_empty() else "(No SFZ instruments)"
		item.set_text(0, message)
		item.set_selectable(0, false)
		return
	
	_build_asset_tree(root, filtered_sfz, tree)
	_prune_empty_directories(root)
	_sort_tree_items(root)


func _populate_devices_tree() -> void:
	var tree = _trees[Asset.TYPE.Device]
	var root = tree.create_item()
	
	# Filter assets based on search
	var filtered_devices = _filter_assets(_device_assets)
	
	if filtered_devices.is_empty():
		var item = tree.create_item(root)
		var message = "(No matches)" if not _search_filter.is_empty() else "(No devices)"
		item.set_text(0, message)
		item.set_selectable(0, false)
		return
	
	_build_asset_tree(root, filtered_devices, tree)
	_prune_empty_directories(root)
	_sort_tree_items(root)


func _build_asset_tree(parent: TreeItem, assets: Array[Asset], tree: Tree) -> void:
	"""Build a hierarchical tree structure from asset paths."""
	# Get search paths to strip from tree view
	var search_paths = _get_search_paths_for_assets(assets)
	
	# Sort assets by path for consistent tree ordering
	var sorted_assets = assets.duplicate()
	sorted_assets.sort_custom(func(a: Asset, b: Asset) -> bool:
		return a.path < b.path
	)
	
	for asset in sorted_assets:
		# Strip search directory prefix from path
		var relative_path = _strip_search_path_prefix(asset.path, search_paths)
		var path_parts = relative_path.split("/")
		
		# If path has only filename (no directories), add directly to parent
		if path_parts.size() == 1 or (path_parts.size() == 2 and path_parts[0] == ""):
			var asset_item = tree.create_item(parent)
			asset_item.set_text(0, asset.get_display_name())
			asset_item.set_metadata(0, asset)
			continue
		
		# Build directory tree
		var current_path = ""
		var current_parent = parent
		
		# Process all directory parts
		for i in range(path_parts.size() - 1):
			var part = path_parts[i]
			if part == "":
				continue
			
			var next_path = current_path + "/" + part if current_path != "" else part
			
			# Find or create directory item
			var dir_item: TreeItem = null
			for child_idx in range(current_parent.get_child_count()):
				var child = current_parent.get_child(child_idx)
				if child.get_text(0) == part and child.get_metadata(0) == null:
					dir_item = child
					break
			
			if dir_item == null:
				dir_item = tree.create_item(current_parent)
				dir_item.set_text(0, part)
				dir_item.set_selectable(0, false)
				dir_item.set_custom_color(0, Color(0.7, 0.7, 0.7))
				dir_item.set_collapsed(true)  # Collapse directories by default
			
			current_parent = dir_item
			current_path = next_path
		
		# Add the actual asset file
		var item = tree.create_item(current_parent)
		item.set_text(0, asset.get_display_name())
		item.set_metadata(0, asset)


func _get_search_paths_for_assets(assets: Array[Asset]) -> Array[String]:
	"""Get relevant search paths based on asset types."""
	if assets.is_empty():
		return []
	
	var search_paths: Array[String] = []
	var first_type = assets[0].type
	
	match first_type:
		Asset.TYPE.Audio, Asset.TYPE.Midi:
			# For audio/midi, get sample paths
			var paths = Sonara.get_config("assets/samples/paths", [])
			for path in paths:
				search_paths.append(_expand_path(path))
		Asset.TYPE.SFZ:
			# For SFZ, get SFZ paths
			var paths = Sonara.get_config("assets/sfz/paths", [])
			for path in paths:
				search_paths.append(_expand_path(path))
		Asset.TYPE.Device:
			# Devices might not have search paths, return empty
			pass
	
	return search_paths


func _strip_search_path_prefix(asset_path: String, search_paths: Array[String]) -> String:
	"""Strip the longest matching search path prefix from the asset path."""
	var longest_match = ""
	
	for search_path in search_paths:
		# Normalize paths for comparison
		var normalized_search = search_path.rstrip("/")
		var normalized_asset = asset_path
		
		if normalized_asset.begins_with(normalized_search + "/"):
			if normalized_search.length() > longest_match.length():
				longest_match = normalized_search
	
	if longest_match.is_empty():
		return asset_path
	
	# Strip the prefix and leading slash
	return asset_path.substr(longest_match.length() + 1)


func _expand_path(path: String) -> String:
	"""Expand path with environment variables or special prefixes."""
	if path.begins_with("~/"):
		return OS.get_environment("HOME") + path.substr(1)
	elif path.begins_with("$HOME/"):
		return OS.get_environment("HOME") + path.substr(5)
	return path


func _prune_empty_directories(parent: TreeItem) -> bool:
	"""Recursively remove empty directories from the tree. Returns true if parent should be kept."""
	if not parent:
		return false
	
	# If this item has metadata, it's an asset file, keep it
	if parent.get_metadata(0) != null:
		return true
	
	# Process children in reverse order to safely remove them
	var children_to_remove: Array[TreeItem] = []
	var child = parent.get_first_child()
	
	while child:
		var next_child = child.get_next()
		# Recursively check if child should be kept
		if not _prune_empty_directories(child):
			children_to_remove.append(child)
		child = next_child
	
	# Remove empty children
	for empty_child in children_to_remove:
		parent.remove_child(empty_child)
	
	# If this is a directory with no remaining children, it should be removed
	# Exception: Don't remove special category headers (colored yellow)
	if parent.get_child_count() == 0:
		var color = parent.get_custom_color(0)
		if color == Color.YELLOW:
			return true  # Keep category headers even if empty
		return false  # Remove empty directories
	
	return true  # Keep directories that have children


func _sort_tree_items(parent: TreeItem) -> void:
	"""Recursively sort tree items alphabetically."""
	if not parent or parent.get_child_count() == 0:
		return
	
	# Collect all children with their text
	var children_data: Array = []
	var child = parent.get_first_child()
	
	while child:
		var next_child = child.get_next()
		children_data.append({
			"item": child,
			"text": child.get_text(0),
			"is_dir": child.get_metadata(0) == null  # Directories have no metadata
		})
		child = next_child
	
	# Sort: directories first, then files, both alphabetically
	children_data.sort_custom(func(a, b) -> bool:
		# Directories come before files
		if a.is_dir != b.is_dir:
			return a.is_dir
		# Within same type, sort alphabetically (case-insensitive)
		return a.text.to_lower() < b.text.to_lower()
	)
	
	# Reorder children
	for i in range(children_data.size()):
		var child_item = children_data[i].item
		parent.remove_child(child_item)
		parent.add_child(child_item)
		if i > 0:
			child_item.move_after(children_data[i - 1].item)
		
		# Recursively sort this child's children
		_sort_tree_items(child_item)


# ============================================================================
# TAB SWITCHING
# ============================================================================

func _switch_tab(asset_type: Asset.TYPE) -> void:
	# Hide all ItemLists and Trees
	for item_list in _item_lists.values():
		item_list.visible = false
	for tree in _trees.values():
		tree.visible = false

	# Show selected tab based on current display mode
	if _display_mode == DisplayMode.FLAT_LIST:
		_item_lists[asset_type].visible = true
	else:
		_trees[asset_type].visible = true

	# Update button states
	for type in _tab_buttons.keys():
		_tab_buttons[type].button_pressed = (type == asset_type)

	_current_tab = asset_type


func _on_tab_button_pressed(asset_type: Asset.TYPE) -> void:
	_switch_tab(asset_type)


func _on_mode_toggle_pressed() -> void:
	# Toggle between modes
	if _display_mode == DisplayMode.FLAT_LIST:
		_display_mode = DisplayMode.TREE_VIEW
		mode_toggle_button.text = "Tree"
	else:
		_display_mode = DisplayMode.FLAT_LIST
		mode_toggle_button.text = "List"
	
	# Update visibility for current tab
	_switch_tab(_current_tab)


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(at_position: Vector2) -> Variant:
	var item_list = _item_lists[_current_tab]
	var clicked_idx = item_list.get_item_at_position(at_position)
	if clicked_idx < 0:
		return null

	# Get all selected items
	var selected_indices = item_list.get_selected_items()
	
	# If nothing is selected, or the clicked item isn't selected, just drag the clicked item
	if selected_indices.is_empty() or not clicked_idx in selected_indices:
		var asset = item_list.get_item_metadata(clicked_idx)
		if not asset is Asset:
			return null
		asset_requested_drag.emit(asset)
		return asset
	
	# Multiple items selected - collect all assets
	var assets: Array[Asset] = []
	for idx in selected_indices:
		var asset = item_list.get_item_metadata(idx)
		if asset is Asset:
			assets.append(asset)
			asset_requested_drag.emit(asset)
	
	# Return array if multiple, single asset if only one
	if assets.size() == 1:
		return assets[0]
	elif assets.size() > 1:
		return assets
	
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Asset


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	# This is typically handled by the target (timeline/arranger)
	# but we can log for debugging
	if data is Asset:
		print("[Browser] Drop event for asset: %s" % data.path)


func _get_drag_data_tree(_at_position: Vector2) -> Variant:
	var tree = _trees[_current_tab]
	var selected = tree.get_selected()
	if not selected:
		return null
	
	var asset = selected.get_metadata(0)
	if not asset is Asset:
		return null
	
	asset_requested_drag.emit(asset)
	return asset


func _on_tree_item_selected(asset_type: Asset.TYPE) -> void:
	var tree = _trees[asset_type]
	var selected = tree.get_selected()
	if not selected:
		return
	
	var asset = selected.get_metadata(0)
	if asset is Asset:
		asset_selected.emit(asset)
		AssetService.mark_asset_used(asset.path)


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


func _on_asset_added(_asset: Asset) -> void:
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
			_trees[Asset.TYPE.Audio].clear()
			_populate_samples_tab()
			_populate_samples_tree()
		Asset.TYPE.Device:
			_item_lists[Asset.TYPE.Device].clear()
			_trees[Asset.TYPE.Device].clear()
			_populate_devices_tab()
			_populate_devices_tree()
		Asset.TYPE.SFZ:
			_item_lists[Asset.TYPE.SFZ].clear()
			_trees[Asset.TYPE.SFZ].clear()
			_populate_sfz_tab()
			_populate_sfz_tree()
