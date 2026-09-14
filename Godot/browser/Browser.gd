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

# Debounce timer for search input, created in _setup_ui()
var _search_debounce_timer: Timer = null
const SEARCH_DEBOUNCE_SECONDS := 0.2

# ============================================================================
# SIGNALS
# ============================================================================

signal asset_selected(asset: Asset)
signal asset_requested_drag(asset: Asset)  # When user starts dragging an asset


# ============================================================================
# PROPERTIES
# ============================================================================

const CONFIG_KEY := "ui/browser"

# Display mode
var _display_mode: DisplayMode = DisplayMode.FLAT_LIST
var _applying_tree_state: bool = false
# Asset.TYPE key ("Audio", "Device", "SFZ") -> Dictionary of expanded folder paths.
var _expanded_folders: Dictionary = {}

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

# Refresh coalescing: multiple assets_updated signals in one frame/batch collapse
# into a single deferred rebuild.
var _refresh_pending: bool = false

# Tabs whose ItemList/Tree contents are stale relative to `_audio_assets` etc.
# (or the current `_search_filter`). Populated lazily when a tab becomes visible.
var _dirty_tabs: Dictionary = {}


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	print("[Browser] Initializing...")
	_load_ui_state()
	_setup_ui()
	_connect_to_asset_service()
	_refresh_asset_list()


func _setup_ui() -> void:
	# Connect mode toggle button
	mode_toggle_button.pressed.connect(_on_mode_toggle_pressed)
	_sync_mode_toggle_text()
	
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

	# Connect search input, debounced so fast typing doesn't rebuild tabs per keystroke
	search_text.text_changed.connect(_on_search_text_changed)
	_search_debounce_timer = Timer.new()
	_search_debounce_timer.one_shot = true
	_search_debounce_timer.wait_time = SEARCH_DEBOUNCE_SECONDS
	_search_debounce_timer.timeout.connect(_on_search_debounce_timeout)
	add_child(_search_debounce_timer)

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
	tree.item_collapsed.connect(func(item: TreeItem): _on_tree_item_collapsed(item, asset_type))
	tree.set_drag_forwarding(
		Callable(self, "_get_drag_data_tree"),
		Callable(self, "_can_drop_data"),
		Callable(self, "_drop_data")
	)
	
	tabs.add_child(tree)
	_trees[asset_type] = tree


func _connect_to_asset_service() -> void:
	if AssetService:
		# AssetService always emits assets_updated after any batch of
		# additions/removals/modifications (see AssetService._on_provider_assets_changed),
		# so listening to it alone is sufficient and avoids one full rebuild per
		# individual asset_added signal when N files are discovered at once.
		AssetService.assets_updated.connect(_on_assets_updated)
		print("[Browser] Connected to AssetService")


# ============================================================================
# ASSET DISPLAY
# ============================================================================

## Coalesce multiple assets_updated signals (e.g. N files added in one scan)
## into a single deferred rebuild instead of rebuilding per signal.
func _request_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	call_deferred("_perform_pending_refresh")


func _perform_pending_refresh() -> void:
	_refresh_pending = false
	_refresh_asset_list()


## Recompute the per-type asset partitions from AssetService. Cheap: no UI rebuild.
func _rebuild_asset_partitions() -> void:
	_audio_assets.clear()
	_midi_assets.clear()
	_device_assets.clear()
	_sfz_assets.clear()
	_soundfont_assets.clear()

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


## Called when the underlying asset data changed. Rebuilds the cheap partitions,
## marks every tab dirty, and only rebuilds the ItemList/Tree UI for the tab
## that's actually visible right now. Other tabs get rebuilt lazily on switch
## (see `_switch_tab`), avoiding wasted work on hidden tabs.
func _refresh_asset_list() -> void:
	if not AssetService:
		print("[Browser] AssetService not available")
		return

	_rebuild_asset_partitions()

	for asset_type in _item_lists.keys():
		_dirty_tabs[asset_type] = true

	_populate_tab_for(_current_tab)


## Rebuild the ItemList and Tree contents for a single tab and clear its dirty flag.
func _populate_tab_for(asset_type: Asset.TYPE) -> void:
	_applying_tree_state = true
	match asset_type:
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
	_applying_tree_state = false
	_dirty_tabs[asset_type] = false


func _filter_and_score_assets(assets: Array[Asset]) -> Array[Dictionary]:
	"""Filter and score assets based on fuzzy search. Returns array of {asset, score} dicts."""
	if _search_filter.is_empty():
		# Return all assets with perfect score when no search filter
		var result: Array[Dictionary] = []
		for asset in assets:
			result.append({"asset": asset, "score": 1.0})
		return result

	var scored_results: Array[Dictionary] = []
	var search_lower = _search_filter.to_lower()

	for asset in assets:
		var best_score = 0.0

		# Always check display name
		var display_name = asset.get_display_name().to_lower()
		var display_score = Utils.fuzzy_match(search_lower, display_name)
		best_score = max(best_score, display_score)

		# For device assets, also check category and vendor
		if asset.type == Asset.TYPE.Device:
			var device = AssetService.get_device(asset.path)
			if device:
				var category = device.get_category_string().to_lower()
				var vendor = device.author.to_lower()
				var category_score = Utils.fuzzy_match(search_lower, category)
				var vendor_score = Utils.fuzzy_match(search_lower, vendor)
				best_score = max(best_score, category_score, vendor_score)

		# Only include assets that have some match (score > 0)
		if best_score > 0.5:
			scored_results.append({"asset": asset, "score": best_score})

	# Sort by score (highest first)
	scored_results.sort_custom(func(a, b): return a.score > b.score)

	return scored_results


func _populate_samples_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.Audio]

	# Filter and score assets based on fuzzy search
	var scored_audio = _filter_and_score_assets(_audio_assets)
	var scored_midi = _filter_and_score_assets(_midi_assets)

	# Add Audio section
	if not scored_audio.is_empty():
		var header_idx = item_list.add_item("Audio Files")
		item_list.set_item_custom_fg_color(header_idx, Color.YELLOW)
		item_list.set_item_disabled(header_idx, true)

		for result in scored_audio:
			var asset = result.asset
			var idx = item_list.add_item(asset.get_display_name())
			item_list.set_item_metadata(idx, asset)

	# Add MIDI section
	if not scored_midi.is_empty():
		var header_idx = item_list.add_item("MIDI Files")
		item_list.set_item_custom_fg_color(header_idx, Color.YELLOW)
		item_list.set_item_disabled(header_idx, true)

		for result in scored_midi:
			var asset = result.asset
			var idx = item_list.add_item(asset.get_display_name())
			item_list.set_item_metadata(idx, asset)


func _populate_sfz_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.SFZ]

	# Filter and score assets based on fuzzy search
	var scored_sfz = _filter_and_score_assets(_sfz_assets)

	if scored_sfz.is_empty():
		var message = "(No matches)" if not _search_filter.is_empty() else "(No SFZ instruments)"
		var idx = item_list.add_item(message)
		item_list.set_item_disabled(idx, true)
		return

	for result in scored_sfz:
		var asset = result.asset
		var idx = item_list.add_item(asset.get_display_name())
		item_list.set_item_metadata(idx, asset)


func _populate_devices_tab() -> void:
	var item_list = _item_lists[Asset.TYPE.Device]

	# Filter and score assets based on fuzzy search
	var scored_devices = _filter_and_score_assets(_device_assets)

	if scored_devices.is_empty():
		var message = "(No matches)" if not _search_filter.is_empty() else "(No devices)"
		var idx = item_list.add_item(message)
		item_list.set_item_disabled(idx, true)
		return

	for result in scored_devices:
		var asset = result.asset
		var idx = item_list.add_item(asset.get_display_name())
		item_list.set_item_metadata(idx, asset)


# ============================================================================
# TREE VIEW POPULATION
# ============================================================================

func _populate_samples_tree() -> void:
	var tree = _trees[Asset.TYPE.Audio]
	var root = tree.create_item()

	# Filter and score assets based on fuzzy search
	var scored_audio = _filter_and_score_assets(_audio_assets)
	var scored_midi = _filter_and_score_assets(_midi_assets)

	# Extract assets from scored results for tree building
	var filtered_audio: Array[Asset] = []
	for result in scored_audio:
		filtered_audio.append(result.asset)

	var filtered_midi: Array[Asset] = []
	for result in scored_midi:
		filtered_midi.append(result.asset)
	
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

	_restore_or_expand_tree(tree, Asset.TYPE.Audio)


func _populate_sfz_tree() -> void:
	var tree = _trees[Asset.TYPE.SFZ]
	var root = tree.create_item()

	# Filter and score assets based on fuzzy search
	var scored_sfz = _filter_and_score_assets(_sfz_assets)

	# Extract assets from scored results for tree building
	var filtered_sfz: Array[Asset] = []
	for result in scored_sfz:
		filtered_sfz.append(result.asset)
	
	if filtered_sfz.is_empty():
		var item = tree.create_item(root)
		var message = "(No matches)" if not _search_filter.is_empty() else "(No SFZ instruments)"
		item.set_text(0, message)
		item.set_selectable(0, false)
		return
	
	_build_asset_tree(root, filtered_sfz, tree)
	_prune_empty_directories(root)
	_sort_tree_items(root)
	_restore_or_expand_tree(tree, Asset.TYPE.SFZ)


func _populate_devices_tree() -> void:
	var tree = _trees[Asset.TYPE.Device]
	var root = tree.create_item()

	# Filter and score assets based on fuzzy search
	var scored_devices = _filter_and_score_assets(_device_assets)

	# Extract assets from scored results for tree building
	var filtered_devices: Array[Asset] = []
	for result in scored_devices:
		filtered_devices.append(result.asset)

	if filtered_devices.is_empty():
		var item = tree.create_item(root)
		var message = "(No matches)" if not _search_filter.is_empty() else "(No devices)"
		item.set_text(0, message)
		item.set_selectable(0, false)
		return

	_build_device_hierarchy_tree(root, filtered_devices, tree)
	_sort_tree_items(root)
	_restore_or_expand_tree(tree, Asset.TYPE.Device)


func _build_device_hierarchy_tree(root: TreeItem, devices: Array[Asset], tree: Tree) -> void:
	"""Build a hierarchical tree structure for devices: Type / Vendor / Plugin"""

	# Group devices by category -> vendor -> device
	var hierarchy: Dictionary = {}

	for asset in devices:
		var device = AssetService.get_device(asset.path)
		if not device:
			continue

		var category = device.get_category_string()  # "Instrument", "Effect", "Utility"
		var vendor = device.author if device.author != "" else "Unknown"
		var device_name = device.name

		# Initialize nested dictionaries
		if not hierarchy.has(category):
			hierarchy[category] = {}
		if not hierarchy[category].has(vendor):
			hierarchy[category][vendor] = {}

		# Store the asset under vendor -> device_name
		hierarchy[category][vendor][device_name] = asset

	# Build the tree structure
	for category in hierarchy.keys():
		var category_item = tree.create_item(root)
		category_item.set_text(0, category)
		category_item.set_selectable(0, false)
		category_item.set_custom_color(0, Color.YELLOW)
		category_item.set_collapsed(true)

		for vendor in hierarchy[category].keys():
			var vendor_item = tree.create_item(category_item)
			vendor_item.set_text(0, vendor)
			vendor_item.set_selectable(0, false)
			vendor_item.set_custom_color(0, Color(0.7, 0.7, 0.7))
			vendor_item.set_collapsed(true)

			for device_name in hierarchy[category][vendor].keys():
				var asset = hierarchy[category][vendor][device_name]
				var device_item = tree.create_item(vendor_item)
				device_item.set_text(0, device_name)
				device_item.set_metadata(0, asset)


func _expand_all_tree_items(item: TreeItem) -> void:
	"""Recursively expand all tree items."""
	if not item:
		return

	item.set_collapsed(false)

	# Expand all children recursively
	var child = item.get_first_child()
	while child:
		_expand_all_tree_items(child)
		child = child.get_next()


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
# UI STATE PERSISTENCE
# ============================================================================

## Load list/tree mode and expanded folder paths from Sonara config.
func _load_ui_state() -> void:
	var saved: Variant = Sonara.get_config(CONFIG_KEY, {})
	if not saved is Dictionary:
		return
	var data: Dictionary = saved
	if str(data.get("display_mode", "list")) == "tree":
		_display_mode = DisplayMode.TREE_VIEW
	else:
		_display_mode = DisplayMode.FLAT_LIST
	var expanded: Variant = data.get("expanded", {})
	if not expanded is Dictionary:
		return
	for type_key in expanded:
		var paths: Dictionary = {}
		var list: Variant = expanded[type_key]
		if list is Array:
			for path in list:
				paths[str(path)] = true
		_expanded_folders[str(type_key)] = paths


## Write display mode and expanded folders to config.json.
func _save_ui_state() -> void:
	var expanded_out := {}
	for type_key in _expanded_folders:
		expanded_out[type_key] = _expanded_folders[type_key].keys()
	Sonara.set_config(CONFIG_KEY, {
		"display_mode": "tree" if _display_mode == DisplayMode.TREE_VIEW else "list",
		"expanded": expanded_out,
	})
	Sonara.save_config()


## Keep the mode button label in sync with `_display_mode`.
func _sync_mode_toggle_text() -> void:
	mode_toggle_button.text = "Tree" if _display_mode == DisplayMode.TREE_VIEW else "List"


## Config key for an asset tab's expanded-folder map.
func _type_key(asset_type: Asset.TYPE) -> String:
	return Asset.TYPE.keys()[asset_type]


## Expanded-path set for `asset_type`, creating it if missing.
func _expanded_for(asset_type: Asset.TYPE) -> Dictionary:
	var key := _type_key(asset_type)
	if not _expanded_folders.has(key):
		_expanded_folders[key] = {}
	return _expanded_folders[key]


## Slash path from the hidden root down to `item` (folder labels only).
func _tree_item_path(item: TreeItem) -> String:
	var parts: Array[String] = []
	var current := item
	while current:
		var parent := current.get_parent()
		if parent == null:
			break
		parts.append(current.get_text(0))
		current = parent
	parts.reverse()
	return "/".join(PackedStringArray(parts))


## Expand everything while searching; otherwise restore persisted folder folds.
func _restore_or_expand_tree(tree: Tree, asset_type: Asset.TYPE) -> void:
	var was_applying := _applying_tree_state
	_applying_tree_state = true
	var root := tree.get_root()
	if root:
		if _search_filter.is_empty():
			_apply_expanded_folders(root, "", _expanded_for(asset_type))
		else:
			_expand_all_tree_items(root)
	_applying_tree_state = was_applying


## Recursively collapse folders unless their path is in the saved expanded set.
func _apply_expanded_folders(item: TreeItem, parent_path: String, expanded: Dictionary) -> void:
	var child := item.get_first_child()
	while child:
		var path := child.get_text(0) if parent_path.is_empty() else parent_path + "/" + child.get_text(0)
		if child.get_metadata(0) == null and child.get_child_count() > 0:
			child.set_collapsed(not expanded.has(path))
			_apply_expanded_folders(child, path, expanded)
		child = child.get_next()


## Record a user fold/unfold; ignored during rebuild and while a search is active.
func _on_tree_item_collapsed(item: TreeItem, asset_type: Asset.TYPE) -> void:
	if _applying_tree_state or not _search_filter.is_empty():
		return
	if item.get_metadata(0) != null:
		return
	var path := _tree_item_path(item)
	if path.is_empty():
		return
	var expanded := _expanded_for(asset_type)
	if item.is_collapsed():
		expanded.erase(path)
	else:
		expanded[path] = true
	_save_ui_state()


# ============================================================================
# TAB SWITCHING
# ============================================================================

func _switch_tab(asset_type: Asset.TYPE) -> void:
	# Hide all ItemLists and Trees
	for item_list in _item_lists.values():
		item_list.visible = false
	for tree in _trees.values():
		tree.visible = false

	# Tabs are only rebuilt lazily: asset/search changes mark tabs dirty but
	# only rebuild the currently visible one, so catch this tab up now if needed.
	if _dirty_tabs.get(asset_type, false):
		_populate_tab_for(asset_type)

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
	else:
		_display_mode = DisplayMode.FLAT_LIST
	_sync_mode_toggle_text()
	_save_ui_state()
	
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
	# Coalesce: a batch of N added/removed/modified assets fires this once per
	# batch already (see AssetService), and _request_refresh further coalesces
	# any signals that still land in the same frame into one deferred rebuild.
	_request_refresh()


func _on_search_text_changed(_new_text: String) -> void:
	# Debounce: restart the timer on every keystroke so filtering only runs
	# once typing pauses, instead of rebuilding tabs per character.
	_search_debounce_timer.start()


func _on_search_debounce_timeout() -> void:
	_search_filter = search_text.text.strip_edges()

	# The filter affects every tab; mark them all dirty but only rebuild the
	# one that's currently visible. Others catch up lazily on switch.
	for asset_type in _item_lists.keys():
		_dirty_tabs[asset_type] = true
	_populate_tab_for(_current_tab)
