# Browser is a tabbed UI of musical assets and devices from file system and project.
# each category can be a consolidation of multple contributing locations

class_name Browser extends VBoxContainer

enum DisplayMode {
	FLAT_LIST,  # Folder tree on top, contents of the selected folder below
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
@onready var audition_toggle: Button = $Content/VBox/Options/AuditionToggle

# info panel under the content (selected item, waveform, play/stop)
@onready var info_panel: BrowserInfoPanel = $InfoPanel

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

## Presets whose device isn't installed.
const UNAVAILABLE_COLOR := Color(0.5, 0.5, 0.5)

# Display mode
var _display_mode: DisplayMode = DisplayMode.FLAT_LIST
var _applying_tree_state: bool = false
# Asset.TYPE key ("Audio", "Device", "SFZ") -> Dictionary of expanded folder paths.
var _expanded_folders: Dictionary = {}

# Tab management
## Group the browser joins, so other panels can reach it (see show_presets).
const GROUP := "browser"

var _current_tab: Asset.TYPE = Asset.TYPE.Audio
var _splits: Dictionary = {}  # Asset.TYPE -> VSplitContainer (list mode)
var _folder_trees: Dictionary = {}  # Asset.TYPE -> Tree (folders only, top of the split)
var _content_trees: Dictionary = {}  # Asset.TYPE -> Tree (flat contents of the selected folder)
var _trees: Dictionary = {}  # Asset.TYPE -> Tree (tree view mode)
# Asset.TYPE -> {folder key -> {label, parent, children, assets}}, rebuilt with the folder tree.
var _folder_models: Dictionary = {}
# Asset.TYPE -> every search match in ranked order (what the content tree shows while searching).
var _ranked_assets: Dictionary = {}
# Asset.TYPE -> key of the selected folder ("" is "All"), and path of the selected content row.
var _selected_folder: Dictionary = {}
var _selected_content: Dictionary = {}
# Asset.TYPE key -> split offset of the folder/contents split.
var _split_offsets: Dictionary = {}

## Browser preview model (spec 037); the engine plays the sample.
var preview: PreviewPlayer = null
## While on, selecting an audio row on the Samples tab plays it.
var _audition_enabled := false
var _tab_buttons: Dictionary = {}  # Asset.TYPE -> Button

# Asset tracking
var _audio_assets: Array[Asset] = []
var _midi_assets: Array[Asset] = []
var _device_assets: Array[Asset] = []
var _sfz_assets: Array[Asset] = []
var _soundfont_assets: Array[Asset] = []
var _preset_assets: Array[Asset] = []

# Search/filter
var _search_filter: String = ""

# Refresh coalescing: multiple assets_updated signals in one frame/batch collapse
# into a single deferred rebuild.
var _refresh_pending: bool = false

# Right-click menu on asset items ("Open in Containing Folder"); built lazily.
const MENU_OPEN_FOLDER_ID := 1
var _context_menu: PopupMenu = null
var _context_menu_asset: Asset = null

# Tabs whose folder/content/tree contents are stale relative to `_audio_assets` etc.
# (or the current `_search_filter`). Populated lazily when a tab becomes visible.
var _dirty_tabs: Dictionary = {}

var logger := Log.make("Browser")


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	logger.info("Initializing...")
	add_to_group(GROUP)
	_load_ui_state()
	_setup_ui()
	_connect_to_asset_service()
	_refresh_asset_list()


func _setup_ui() -> void:
	# Connect mode toggle button
	mode_toggle_button.pressed.connect(_on_mode_toggle_pressed)
	_sync_mode_toggle_text()

	# Preview: the model, the info panel that shows it, and the audition toggle
	preview = PreviewPlayer.new()
	preview.name = "PreviewPlayer"
	add_child(preview)
	info_panel.setup(preview)
	asset_selected.connect(info_panel.show_asset)
	audition_toggle.icon = preload("res://assets/icons/headphones.svg")
	audition_toggle.set_pressed_no_signal(_audition_enabled)
	audition_toggle.toggled.connect(_on_audition_toggled)
	
	# Setup tab buttons
	_create_tab_button("", "Samples", Asset.TYPE.Audio, preload("res://assets/icons/audio-waveform.svg"))
	_create_tab_button("", "Devices", Asset.TYPE.Device, preload("res://assets/icons/panel-top.svg"))
	_create_tab_button("SFZ", "SFZ", Asset.TYPE.SFZ)
	_create_tab_button("", "Presets", Asset.TYPE.Preset, preload("res://assets/icons/star.svg"))

	# Create the folder/contents split for each category
	_create_split(Asset.TYPE.Audio)
	_create_split(Asset.TYPE.Device)
	_create_split(Asset.TYPE.SFZ)
	_create_split(Asset.TYPE.Preset)
	
	# Create Tree controls for each category
	_create_tree(Asset.TYPE.Audio)
	_create_tree(Asset.TYPE.Device)
	_create_tree(Asset.TYPE.SFZ)
	_create_tree(Asset.TYPE.Preset)

	# Connect search input, debounced so fast typing doesn't rebuild tabs per keystroke
	search_text.text_changed.connect(_on_search_text_changed)
	_search_debounce_timer = Timer.new()
	_search_debounce_timer.one_shot = true
	_search_debounce_timer.wait_time = SEARCH_DEBOUNCE_SECONDS
	_search_debounce_timer.timeout.connect(_on_search_debounce_timeout)
	add_child(_search_debounce_timer)

	# Show first tab by default
	_switch_tab(Asset.TYPE.Audio)


func _create_tab_button(text: String, tooltip: String, asset_type: Asset.TYPE, icon: Texture2D = null) -> void:
	var btn = Button.new()
	btn.text = text
	if icon:
		btn.icon = icon
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.expand_icon = false
	btn.tooltip_text = tooltip
	btn.toggle_mode = true
	btn.pressed.connect(_on_tab_button_pressed.bindv([asset_type]))

	tab_buttons.add_child(btn)
	_tab_buttons[asset_type] = btn


## List mode of one tab: folders on top, the selected folder's contents below.
func _create_split(asset_type: Asset.TYPE) -> void:
	var type_name: String = Asset.TYPE.keys()[asset_type]
	var split := VSplitContainer.new()
	split.name = "Split_%s" % type_name
	split.visible = false  # Hidden by default, shown when tab is active
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var folder_tree := Tree.new()
	folder_tree.name = "Folders_%s" % type_name
	folder_tree.hide_root = false
	folder_tree.select_mode = Tree.SELECT_SINGLE
	folder_tree.allow_reselect = true
	folder_tree.custom_minimum_size = Vector2(0, 60)
	folder_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	folder_tree.size_flags_stretch_ratio = 0.8
	folder_tree.item_selected.connect(_on_folder_selected.bind(asset_type))
	folder_tree.item_collapsed.connect(_on_folder_collapsed.bind(asset_type))
	split.add_child(folder_tree)

	var content_tree := Tree.new()
	content_tree.name = "Contents_%s" % type_name
	content_tree.hide_root = true
	_configure_asset_tree(content_tree, asset_type)
	content_tree.custom_minimum_size = Vector2(0, 60)
	content_tree.size_flags_stretch_ratio = 1.2
	content_tree.item_activated.connect(_on_content_activated.bind(content_tree, asset_type))
	split.add_child(content_tree)

	var saved: Variant = _split_offsets.get(type_name, null)
	if saved != null:
		split.split_offset = int(saved)
	split.dragged.connect(_on_split_dragged.bind(split, type_name))

	tabs.add_child(split)
	_splits[asset_type] = split
	_folder_trees[asset_type] = folder_tree
	_content_trees[asset_type] = content_tree


## Shared setup of the Trees that list assets (tree view and the content tree).
func _configure_asset_tree(tree: Tree, asset_type: Asset.TYPE) -> void:
	if asset_type == Asset.TYPE.Device:
		# Column 1 carries the dim CLAP/VST3 tag of plugins installed in both formats.
		tree.columns = 2
		tree.set_column_expand(0, true)
		tree.set_column_expand(1, false)
		tree.set_column_custom_minimum_width(1, 48)

	# Configure Tree appearance and behavior
	tree.allow_reselect = true
	tree.allow_rmb_select = true
	tree.select_mode = Tree.SELECT_MULTI

	# Make Tree fill the parent ScrollContainer
	tree.custom_minimum_size = Vector2(0, 0)
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# SELECT_MULTI trees emit multi_selected, never item_selected. React only to the cursor
	# row, so a Shift range select doesn't audition every row in it.
	tree.multi_selected.connect(_on_tree_multi_selected.bind(tree, asset_type))
	tree.item_mouse_selected.connect(_on_tree_item_context_menu.bind(tree))
	tree.set_drag_forwarding(
		Callable(self, "_get_drag_data_tree").bind(tree),
		Callable(self, "_can_drop_data"),
		Callable(self, "_drop_data")
	)


func _create_tree(asset_type: Asset.TYPE) -> void:
	var tree = Tree.new()
	tree.name = "Tree_%s" % Asset.TYPE.keys()[asset_type]
	tree.hide_root = true
	tree.visible = false  # Hidden by default
	_configure_asset_tree(tree, asset_type)
	tree.item_collapsed.connect(func(item: TreeItem): _on_tree_item_collapsed(item, asset_type))
	tabs.add_child(tree)
	_trees[asset_type] = tree


func _connect_to_asset_service() -> void:
	if AssetService:
		# AssetService always emits assets_updated after any batch of
		# additions/removals/modifications (see AssetService._on_provider_assets_changed),
		# so listening to it alone is sufficient and avoids one full rebuild per
		# individual asset_added signal when N files are discovered at once.
		AssetService.assets_updated.connect(_on_assets_updated)
		# Presets grey out or come back as plugins are scanned.
		AssetService.device_registry.devices_changed.connect(_on_devices_changed)
		logger.info("Connected to AssetService")


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
	_preset_assets.clear()

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
			Asset.TYPE.Preset:
				_preset_assets.append(asset)


## Called when the underlying asset data changed. Rebuilds the cheap partitions,
## marks every tab dirty, and only rebuilds the UI for the tab that's actually
## visible right now. Other tabs get rebuilt lazily on switch (see
## `_switch_tab`), avoiding wasted work on hidden tabs.
func _refresh_asset_list() -> void:
	if not AssetService:
		logger.warn("AssetService not available")
		return

	_rebuild_asset_partitions()

	for asset_type in _splits.keys():
		_dirty_tabs[asset_type] = true

	_populate_tab_for(_current_tab)


## Rebuild the folder/content split and the Tree for a single tab and clear its dirty flag.
## The selected folder and content row survive when they still exist.
func _populate_tab_for(asset_type: Asset.TYPE) -> void:
	_applying_tree_state = true
	_trees[asset_type].clear()
	match asset_type:
		Asset.TYPE.Audio:
			_populate_samples_tree()
		Asset.TYPE.Device:
			_populate_devices_tree()
		Asset.TYPE.SFZ:
			_populate_sfz_tree()
		Asset.TYPE.Preset:
			_populate_presets_tree()
	_populate_folder_tree(asset_type)
	_applying_tree_state = false
	_populate_contents(asset_type)
	_dirty_tabs[asset_type] = false


## Filter and fuzzy-score assets against the search box. Returns `{asset, score}` dicts, best first.
func _filter_and_score_assets(assets: Array[Asset]) -> Array[Dictionary]:
	return AssetSearch.rank(assets, _search_filter)


# ============================================================================
# FOLDER / CONTENTS SPLIT (LIST MODE)
# ============================================================================

## The "All" row of the folder tree; it lists everything.
const FOLDER_ALL := ""
const SECTION_AUDIO := "audio:"
const SECTION_MIDI := "midi:"


## Ranked search matches of `assets`, best first, as a plain Asset array.
func _ranked(assets: Array[Asset]) -> Array[Asset]:
	var out: Array[Asset] = []
	for result in _filter_and_score_assets(assets):
		out.append(result.asset)
	return out


## Add folder `key` to `model` under `parent` (created once).
func _model_node(model: Dictionary, key: String, label: String, parent: String) -> Dictionary:
	if model.has(key):
		return model[key]
	var node := {"label": label, "parent": parent, "children": [], "assets": []}
	model[key] = node
	if model.has(parent):
		model[parent].children.append(key)
	return node


## Fold `assets` into `model` by directory. Keys are the absolute folder paths
## (prefixed with `prefix` so Audio and MIDI sections can't collide); a non-empty
## `section_label` puts the folders under a section row, like the tree view's
## "Audio Files" / "MIDI Files".
func _add_assets_to_folder_model(model: Dictionary, assets: Array[Asset], prefix: String, section_label: String) -> void:
	if assets.is_empty():
		return
	var base_key := FOLDER_ALL
	if not section_label.is_empty():
		base_key = prefix
		_model_node(model, base_key, section_label, FOLDER_ALL)
	var search_paths := _get_search_paths_for_assets(assets)
	for asset in assets:
		var relative := _strip_search_path_prefix(asset.path, search_paths)
		var parts: Array[String] = []
		for part in relative.split("/"):
			if not part.is_empty():
				parts.append(part)
		parts.resize(maxi(parts.size() - 1, 0))  # drop the filename
		var folder_abs := asset.path.get_base_dir()
		for _i in parts.size():
			folder_abs = folder_abs.get_base_dir()
		var parent := base_key
		for part in parts:
			folder_abs = folder_abs.path_join(part)
			var key := prefix + folder_abs
			_model_node(model, key, part, parent)
			parent = key
		model[parent].assets.append(asset)


## Folder model of tab `asset_type` for the current search; also fills `_ranked_assets`.
func _build_folder_model(asset_type: Asset.TYPE) -> Dictionary:
	var model := {FOLDER_ALL: {"label": "All", "parent": "", "children": [], "assets": []}}
	var ranked: Array[Asset] = []
	match asset_type:
		Asset.TYPE.Audio:
			var audio := _ranked(_audio_assets)
			var midi := _ranked(_midi_assets)
			ranked.append_array(audio)
			ranked.append_array(midi)
			_add_assets_to_folder_model(model, audio, SECTION_AUDIO, "Audio Files")
			_add_assets_to_folder_model(model, midi, SECTION_MIDI, "MIDI Files")
		Asset.TYPE.SFZ:
			ranked = _ranked(_sfz_assets)
			_add_assets_to_folder_model(model, ranked, "", "")
		Asset.TYPE.Preset:
			ranked = _ranked(_preset_assets)
			_add_assets_to_folder_model(model, ranked, "", "")
		Asset.TYPE.Device:
			ranked = _ranked(_device_assets)
			_add_devices_to_folder_model(model, ranked)
	_ranked_assets[asset_type] = ranked
	return model


## Devices: the folders are the Category / Vendor hierarchy of the tree view.
func _add_devices_to_folder_model(model: Dictionary, devices: Array[Asset]) -> void:
	for asset in devices:
		var device = AssetService.get_device(asset.path)
		if not device:
			continue
		var category: String = device.get_browser_group()
		var vendor: String = device.author if device.author != "" else "Unknown"
		_model_node(model, category, category, FOLDER_ALL)
		var vendor_key := category + "/" + vendor
		_model_node(model, vendor_key, vendor, category)
		model[vendor_key].assets.append(asset)


## Child keys of `key`, sorted by label (case-insensitive).
func _sorted_folder_children(model: Dictionary, key: String) -> Array:
	var children: Array = model[key].children.duplicate()
	children.sort_custom(func(a: String, b: String) -> bool:
		return model[a].label.to_lower() < model[b].label.to_lower())
	return children


## Assets of `key` and everything below it, folder by folder.
func _collect_folder_assets(model: Dictionary, key: String, out: Array[Asset]) -> void:
	out.append_array(_sorted_by_name(model[key].assets))
	for child in _sorted_folder_children(model, key):
		_collect_folder_assets(model, child, out)


func _sorted_by_name(assets: Array) -> Array[Asset]:
	var out: Array[Asset] = []
	out.assign(assets)
	out.sort_custom(func(a: Asset, b: Asset) -> bool:
		return a.get_display_name().to_lower() < b.get_display_name().to_lower())
	return out


func _populate_folder_tree(asset_type: Asset.TYPE) -> void:
	var tree: Tree = _folder_trees[asset_type]
	tree.clear()
	var model := _build_folder_model(asset_type)
	_folder_models[asset_type] = model
	var root := tree.create_item()
	root.set_text(0, "All")
	root.set_metadata(0, FOLDER_ALL)
	_add_folder_items(tree, root, model, FOLDER_ALL)
	_restore_or_expand_folder_tree(tree, asset_type)
	_select_folder(asset_type, _selected_folder.get(asset_type, FOLDER_ALL))


func _add_folder_items(tree: Tree, parent: TreeItem, model: Dictionary, key: String) -> void:
	for child_key in _sorted_folder_children(model, key):
		var node: Dictionary = model[child_key]
		var item := tree.create_item(parent)
		item.set_text(0, node.label)
		item.set_metadata(0, child_key)
		if child_key == SECTION_AUDIO or child_key == SECTION_MIDI:
			item.set_custom_color(0, UiColors.role(&"accent_primary"))
		else:
			var folder_path: String = child_key.trim_prefix(SECTION_AUDIO).trim_prefix(SECTION_MIDI)
			if folder_path.begins_with("/"):
				item.set_tooltip_text(0, folder_path)
		item.set_collapsed(true)
		_add_folder_items(tree, item, model, child_key)


## Folder-tree item whose metadata is `key`, or null.
func _find_folder_item(item: TreeItem, key: String) -> TreeItem:
	if item == null:
		return null
	if item.get_metadata(0) == key:
		return item
	var child := item.get_first_child()
	while child:
		var found := _find_folder_item(child, key)
		if found:
			return found
		child = child.get_next()
	return null


## Select folder `key` of tab `asset_type` (falling back to "All") without
## triggering the selection handler, and make its ancestors visible.
func _select_folder(asset_type: Asset.TYPE, key: String) -> void:
	var tree: Tree = _folder_trees[asset_type]
	var item := _find_folder_item(tree.get_root(), key)
	# While searching, folders without a match are missing: show All but remember the folder.
	var remember := item != null or _search_filter.is_empty()
	if item == null:
		item = tree.get_root()
	var was_applying := _applying_tree_state
	_applying_tree_state = true
	var parent := item.get_parent()
	while parent:
		parent.set_collapsed(false)
		parent = parent.get_parent()
	item.select(0)
	tree.scroll_to_item(item)
	_applying_tree_state = was_applying
	if remember:
		_selected_folder[asset_type] = str(item.get_metadata(0))


## Fill the content tree for the selected folder: its subfolders first (double-click
## to enter), then its direct assets. "All" and a non-empty search list every asset.
func _populate_contents(asset_type: Asset.TYPE) -> void:
	var tree: Tree = _content_trees[asset_type]
	tree.clear()
	var root := tree.create_item()
	var model: Dictionary = _folder_models.get(asset_type, {})
	var key: String = _selected_folder.get(asset_type, FOLDER_ALL)
	if not model.has(key):
		key = FOLDER_ALL
	var searching := not _search_filter.is_empty()
	var assets: Array[Asset] = []
	if model.is_empty():
		pass
	elif searching:
		assets = _ranked_assets.get(asset_type, [])
	elif key == FOLDER_ALL:
		_collect_folder_assets(model, FOLDER_ALL, assets)
	else:
		for child_key in _sorted_folder_children(model, key):
			var row := tree.create_item(root)
			row.set_text(0, model[child_key].label)
			row.set_custom_color(0, UiColors.role(&"text_dim"))
			row.set_meta("folder_key", child_key)
		assets = _sorted_by_name(model[key].assets)

	for asset in assets:
		_add_asset_row(tree, root, asset, asset_type)

	if root.get_child_count() == 0:
		var item := tree.create_item(root)
		item.set_text(0, _empty_message(asset_type))
		item.set_selectable(0, false)
		return
	_restore_content_selection(asset_type)


func _empty_message(asset_type: Asset.TYPE) -> String:
	if not _search_filter.is_empty():
		return "(No matches)"
	match asset_type:
		Asset.TYPE.Audio:
			return "(No samples)"
		Asset.TYPE.Device:
			return "(No devices)"
		Asset.TYPE.SFZ:
			return "(No SFZ instruments)"
		Asset.TYPE.Preset:
			return "(No presets)"
	return "(Empty)"


## One asset row of the content tree. Metadata is the Asset, like in the tree view.
func _add_asset_row(tree: Tree, parent: TreeItem, asset: Asset, asset_type: Asset.TYPE) -> TreeItem:
	var item := tree.create_item(parent)
	item.set_text(0, asset.get_display_name())
	item.set_metadata(0, asset)
	match asset_type:
		Asset.TYPE.Preset:
			var device_label := asset.device_name if not asset.device_name.is_empty() else asset.device_id
			item.set_text(0, "%s — %s" % [asset.get_display_name(), device_label])
			item.set_tooltip_text(0, asset.get_preset_tooltip())
			if asset.is_unavailable():
				item.set_custom_color(0, UNAVAILABLE_COLOR)
		Asset.TYPE.Device:
			var device = AssetService.get_device(asset.path)
			if device and device.is_plugin():
				item.set_tooltip_text(0, "%s plugin\n%s" % [device.format_tag(), device.plugin_path])
				if AssetService.device_registry.has_other_format(device):
					item.set_text(1, device.format_tag())
					item.set_custom_color(1, UiColors.role(&"text_dim"))
					item.set_tooltip_text(1, item.get_tooltip_text(0))
	return item


## Reselect the row of the previously selected asset (by path) if it is still listed.
func _restore_content_selection(asset_type: Asset.TYPE) -> void:
	var path: String = _selected_content.get(asset_type, "")
	if path.is_empty():
		return
	var tree: Tree = _content_trees[asset_type]
	var item := tree.get_root().get_first_child()
	while item:
		var asset = item.get_metadata(0)
		if asset is Asset and asset.path == path:
			var was_applying := _applying_tree_state
			_applying_tree_state = true
			item.select(0)
			tree.scroll_to_item(item)
			_applying_tree_state = was_applying
			return
		item = item.get_next()


func _on_folder_selected(asset_type: Asset.TYPE) -> void:
	if _applying_tree_state:
		return
	var selected: TreeItem = _folder_trees[asset_type].get_selected()
	if selected == null:
		return
	_selected_folder[asset_type] = str(selected.get_metadata(0))
	_selected_content.erase(asset_type)
	_populate_contents(asset_type)
	_clear_selection_preview()
	_save_ui_state()


## Double-click on a subfolder row enters that folder.
func _on_content_activated(tree: Tree, asset_type: Asset.TYPE) -> void:
	var item := tree.get_selected()
	if item == null or not item.has_meta("folder_key"):
		return
	_selected_content.erase(asset_type)
	_select_folder(asset_type, str(item.get_meta("folder_key")))
	_populate_contents(asset_type)
	_clear_selection_preview()
	_save_ui_state()


func _on_audition_toggled(on: bool) -> void:
	_audition_enabled = on
	if not on:
		preview.stop()
	_save_ui_state()


## Selecting an audio row on the Samples tab plays it while audition is on; any other selection
## stops the preview.
func _audition(asset: Asset) -> void:
	if _audition_enabled and _current_tab == Asset.TYPE.Audio and asset.is_audio():
		preview.play(asset.path)
	else:
		preview.stop()


## Nothing is selected any more (a folder was picked or the tab changed): stop and hide the info panel.
func _clear_selection_preview() -> void:
	preview.stop()
	info_panel.clear_asset()


func _on_split_dragged(offset: int, _split: VSplitContainer, type_name: String) -> void:
	_split_offsets[type_name] = offset
	_save_ui_state()


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
		audio_parent.set_custom_color(0, UiColors.role(&"accent_primary"))
		audio_parent.set_selectable(0, false)
		audio_parent.set_collapsed(true)
		_build_asset_tree(audio_parent, filtered_audio, tree)
		_prune_empty_directories(audio_parent)
		_sort_tree_items(audio_parent)

	# Build hierarchical structure for MIDI files
	if not filtered_midi.is_empty():
		var midi_parent = tree.create_item(root)
		midi_parent.set_text(0, "MIDI Files")
		midi_parent.set_custom_color(0, UiColors.role(&"accent_primary"))
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


func _populate_presets_tree() -> void:
	var tree = _trees[Asset.TYPE.Preset]
	var root = tree.create_item()
	var filtered: Array[Asset] = []
	for result in _filter_and_score_assets(_preset_assets):
		filtered.append(result.asset)

	if filtered.is_empty():
		var item = tree.create_item(root)
		item.set_text(0, "(No matches)" if not _search_filter.is_empty() else "(No presets)")
		item.set_selectable(0, false)
		return

	_build_asset_tree(root, filtered, tree)
	_prune_empty_directories(root)
	_sort_tree_items(root)
	_decorate_preset_items(root)
	_restore_or_expand_tree(tree, Asset.TYPE.Preset)


## Tooltips on preset rows, and grey for those whose device isn't installed.
func _decorate_preset_items(item: TreeItem) -> void:
	var child := item.get_first_child()
	while child:
		var asset = child.get_metadata(0)
		if asset is Asset:
			child.set_tooltip_text(0, asset.get_preset_tooltip())
			if asset.is_unavailable():
				child.set_custom_color(0, UNAVAILABLE_COLOR)
		else:
			_decorate_preset_items(child)
		child = child.get_next()


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

		var category = device.get_browser_group()  # "Instrument", "Effect", "Utility" or "Drums"
		var vendor = device.author if device.author != "" else "Unknown"
		var device_name = device.name

		# Initialize nested dictionaries
		if not hierarchy.has(category):
			hierarchy[category] = {}
		if not hierarchy[category].has(vendor):
			hierarchy[category][vendor] = {}

		# Keyed by device id: a plugin installed as CLAP and VST3 shares name and vendor.
		hierarchy[category][vendor][asset.path] = asset

	# Build the tree structure
	for category in hierarchy.keys():
		var category_item = tree.create_item(root)
		category_item.set_text(0, category)
		category_item.set_selectable(0, false)
		category_item.set_custom_color(0, UiColors.role(&"accent_primary"))
		category_item.set_collapsed(true)

		for vendor in hierarchy[category].keys():
			var vendor_item = tree.create_item(category_item)
			vendor_item.set_text(0, vendor)
			vendor_item.set_selectable(0, false)
			vendor_item.set_custom_color(0, UiColors.role(&"text_dim"))
			vendor_item.set_collapsed(true)

			for device_id in hierarchy[category][vendor].keys():
				var asset = hierarchy[category][vendor][device_id]
				var device = AssetService.get_device(device_id)
				var device_item = tree.create_item(vendor_item)
				device_item.set_text(0, device.name)
				device_item.set_metadata(0, asset)
				if device.is_plugin():
					device_item.set_tooltip_text(0, "%s plugin\n%s" % [device.format_tag(), device.plugin_path])
					if AssetService.device_registry.has_other_format(device):
						device_item.set_text(1, device.format_tag())
						device_item.set_custom_color(1, UiColors.role(&"text_dim"))
						device_item.set_tooltip_text(1, device_item.get_tooltip_text(0))


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
				dir_item.set_custom_color(0, UiColors.role(&"text_dim"))
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
			var paths = Settings.get_value("assets/samples/paths")
			for path in paths:
				search_paths.append(Utils.expand_path(path))
		Asset.TYPE.SFZ:
			# For SFZ, get SFZ paths
			var paths = Settings.get_value("assets/sfz/paths")
			for path in paths:
				search_paths.append(Utils.expand_path(path))
		Asset.TYPE.Preset:
			search_paths.append(PresetLibrary.root_dir())
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
		if color == UiColors.role(&"accent_primary"):
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
			"tag": child.get_text(1) if child.get_tree() and child.get_tree().columns > 1 else "",
			"is_dir": child.get_metadata(0) == null  # Directories have no metadata
		})
		child = next_child
	
	# Sort: directories first, then files, both alphabetically
	children_data.sort_custom(func(a, b) -> bool:
		# Directories come before files
		if a.is_dir != b.is_dir:
			return a.is_dir
		# Within same type, sort alphabetically (case-insensitive)
		if a.text.to_lower() != b.text.to_lower():
			return a.text.to_lower() < b.text.to_lower()
		return a.tag == "CLAP" and b.tag != "CLAP"  # same name: CLAP first
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

## Load list/tree mode, expanded folder paths, selected folders and split offsets from Sonara config.
func _load_ui_state() -> void:
	var saved: Variant = Sonara.get_config(CONFIG_KEY, {})
	if not saved is Dictionary:
		return
	var data: Dictionary = saved
	if str(data.get("display_mode", "list")) == "tree":
		_display_mode = DisplayMode.TREE_VIEW
	else:
		_display_mode = DisplayMode.FLAT_LIST
	_audition_enabled = bool(data.get("audition", false))
	var folder: Variant = data.get("folder", {})
	if folder is Dictionary:
		for type_key in folder:
			var type_index: int = Asset.TYPE.keys().find(str(type_key))
			if type_index >= 0:
				_selected_folder[type_index] = str(folder[type_key])
	var split: Variant = data.get("split", {})
	if split is Dictionary:
		for type_key in split:
			_split_offsets[str(type_key)] = int(split[type_key])
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


## Write display mode, expanded folders, selected folders and split offsets to config.json.
func _save_ui_state() -> void:
	var expanded_out := {}
	for type_key in _expanded_folders:
		expanded_out[type_key] = _expanded_folders[type_key].keys()
	var folder_out := {}
	for asset_type in _selected_folder:
		folder_out[_type_key(asset_type)] = _selected_folder[asset_type]
	# Merge into the stored dictionary: the info panel keeps its own `info_collapsed` there.
	var stored: Variant = Sonara.get_config(CONFIG_KEY, {})
	var out: Dictionary = (stored as Dictionary).duplicate() if stored is Dictionary else {}
	out["display_mode"] = "tree" if _display_mode == DisplayMode.TREE_VIEW else "list"
	out["expanded"] = expanded_out
	out["folder"] = folder_out
	out["split"] = _split_offsets
	out["audition"] = _audition_enabled
	Sonara.set_config(CONFIG_KEY, out)
	Sonara.save_config()


## Keep the mode button label in sync with `_display_mode`.
func _sync_mode_toggle_text() -> void:
	mode_toggle_button.text = "Tree" if _display_mode == DisplayMode.TREE_VIEW else "List"


## Config key for an asset tab's expanded-folder map.
func _type_key(asset_type: Asset.TYPE) -> String:
	return Asset.TYPE.keys()[asset_type]


## Expanded-path set for `asset_type`, creating it if missing.
func _expanded_for(asset_type: Asset.TYPE) -> Dictionary:
	return _expanded_set(_type_key(asset_type))


## Expanded set of the folder tree (list mode) of `asset_type`; its keys are folder keys.
func _expanded_for_folders(asset_type: Asset.TYPE) -> Dictionary:
	return _expanded_set(_type_key(asset_type) + "/folders")


func _expanded_set(key: String) -> Dictionary:
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


## Expand everything while searching; otherwise restore the persisted folds of the folder tree.
func _restore_or_expand_folder_tree(tree: Tree, asset_type: Asset.TYPE) -> void:
	var was_applying := _applying_tree_state
	_applying_tree_state = true
	var root := tree.get_root()
	if root:
		root.set_collapsed(false)
		if _search_filter.is_empty():
			var expanded := _expanded_for_folders(asset_type)
			_apply_expanded_folder_keys(root, expanded)
		else:
			_expand_all_tree_items(root)
	_applying_tree_state = was_applying


func _apply_expanded_folder_keys(item: TreeItem, expanded: Dictionary) -> void:
	var child := item.get_first_child()
	while child:
		if child.get_child_count() > 0:
			child.set_collapsed(not expanded.has(str(child.get_metadata(0))))
			_apply_expanded_folder_keys(child, expanded)
		child = child.get_next()


## Record a user fold/unfold of the folder tree; ignored during rebuild and while searching.
func _on_folder_collapsed(item: TreeItem, asset_type: Asset.TYPE) -> void:
	if _applying_tree_state or not _search_filter.is_empty():
		return
	var key := str(item.get_metadata(0))
	if key == FOLDER_ALL:
		return
	var expanded := _expanded_for_folders(asset_type)
	if item.is_collapsed():
		expanded.erase(key)
	else:
		expanded[key] = true
	_save_ui_state()


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
	# Hide all splits and Trees
	for split in _splits.values():
		split.visible = false
	for tree in _trees.values():
		tree.visible = false

	# Tabs are only rebuilt lazily: asset/search changes mark tabs dirty but
	# only rebuild the currently visible one, so catch this tab up now if needed.
	if _dirty_tabs.get(asset_type, false):
		_populate_tab_for(asset_type)

	# Show selected tab based on current display mode
	if _display_mode == DisplayMode.FLAT_LIST:
		_splits[asset_type].visible = true
	else:
		_trees[asset_type].visible = true

	# Switching tabs ends the preview; audition is a Samples tab feature.
	if asset_type != _current_tab and preview:
		_clear_selection_preview()
	audition_toggle.visible = asset_type == Asset.TYPE.Audio

	# Update button states
	for type in _tab_buttons.keys():
		_tab_buttons[type].button_pressed = (type == asset_type)

	_current_tab = asset_type


## Switch to the Presets tab and filter it by `filter`.
func show_presets(filter: String = "") -> void:
	search_text.text = filter
	_search_filter = filter.strip_edges()
	_switch_tab(Asset.TYPE.Preset)
	_populate_tab_for(Asset.TYPE.Preset)


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

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Asset


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	# This is typically handled by the target (timeline/arranger)
	# but we can log for debugging
	if data is Asset:
		logger.info("Drop event for asset: %s" % data.path)


func _get_drag_data_tree(at_position: Vector2, tree: Tree) -> Variant:
	var clicked: TreeItem = tree.get_item_at_position(at_position)

	# Collect every selected asset (the tree is multi-select).
	var assets: Array[Asset] = []
	var item: TreeItem = tree.get_next_selected(null)
	var clicked_is_selected := false
	while item:
		var asset = item.get_metadata(0)
		if asset is Asset and not asset.is_unavailable():
			assets.append(asset)
		if item == clicked:
			clicked_is_selected = true
		item = tree.get_next_selected(item)

	# Dragging an unselected item drags just that item.
	if clicked and not clicked_is_selected:
		assets.clear()
		var asset = clicked.get_metadata(0)
		if asset is Asset and not asset.is_unavailable():
			assets.append(asset)

	for asset in assets:
		asset_requested_drag.emit(asset)
	if assets.size() == 1:
		return assets[0]
	elif assets.size() > 1:
		return assets
	return null


func _on_tree_multi_selected(item: TreeItem, _column: int, selected: bool, tree: Tree, asset_type: Asset.TYPE) -> void:
	if selected and item == tree.get_selected():
		_on_tree_item_selected(tree, asset_type)


func _on_tree_item_selected(tree: Tree, asset_type: Asset.TYPE) -> void:
	if _applying_tree_state:
		return
	var selected = tree.get_selected()
	if not selected:
		return

	var asset = selected.get_metadata(0)
	if asset is Asset:
		if tree == _content_trees.get(asset_type):
			_selected_content[asset_type] = asset.path
		asset_selected.emit(asset)
		_audition(asset)
		AssetService.mark_asset_used(asset.path)
	else:
		# A subfolder row of the content tree.
		_clear_selection_preview()


# ============================================================================
# ASSET CONTEXT MENU
# ============================================================================

## Build (lazily) the right-click menu for `asset` and add its entry. Returns
## false when there is nothing to show: built-in devices are not files, and
## anything that isn't an Asset has no menu.
func _prepare_asset_context_menu(asset: Asset) -> bool:
	var state := asset.get_folder_menu_state() if asset is Asset else Asset.FolderMenu.Hidden
	if state == Asset.FolderMenu.Hidden:
		return false

	if _context_menu == null:
		_context_menu = PopupMenu.new()
		_context_menu.theme_type_variation = &"ContextMenuList"
		_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
		add_child(_context_menu)
	_context_menu.clear()
	_context_menu.add_item("Open in Containing Folder", MENU_OPEN_FOLDER_ID)
	_context_menu.set_item_disabled(0, state == Asset.FolderMenu.Disabled)
	_context_menu_asset = asset
	return true


## Right-click on a tree row (allow_rmb_select): the context menu for its asset.
## Godot 4.7's `item_mouse_selected` carries (local mouse position, button
## index) - not the clicked item - so resolve the row from the position.
func _on_tree_item_context_menu(mouse_position: Vector2, id: int, tree: Tree) -> void:
	if id != MOUSE_BUTTON_RIGHT:
		return
	var item: TreeItem = tree.get_item_at_position(mouse_position)
	if item == null:
		return
	var asset = item.get_metadata(0)
	if _prepare_asset_context_menu(asset):
		ContextMenuPopup.popup_at_mouse(_context_menu)


func _on_context_menu_id_pressed(id: int) -> void:
	if id != MENU_OPEN_FOLDER_ID or _context_menu_asset == null:
		return
	var file_path := _context_menu_asset.get_file_path()
	if file_path.is_empty():
		return
	logger.info("Revealing asset in file manager: %s" % file_path)
	Utils.reveal_in_file_manager(file_path)


# ============================================================================
# CALLBACKS
# ============================================================================

func _on_assets_updated() -> void:
	# Coalesce: a batch of N added/removed/modified assets fires this once per
	# batch already (see AssetService), and _request_refresh further coalesces
	# any signals that still land in the same frame into one deferred rebuild.
	_request_refresh()


func _on_devices_changed(_added: Array[Device], _removed: Array[Device]) -> void:
	_dirty_tabs[Asset.TYPE.Preset] = true
	if _current_tab == Asset.TYPE.Preset:
		_populate_tab_for(Asset.TYPE.Preset)


func _on_search_text_changed(_new_text: String) -> void:
	# Debounce: restart the timer on every keystroke so filtering only runs
	# once typing pauses, instead of rebuilding tabs per character.
	_search_debounce_timer.start()


func _on_search_debounce_timeout() -> void:
	_search_filter = search_text.text.strip_edges()

	# The filter affects every tab; mark them all dirty but only rebuild the
	# one that's currently visible. Others catch up lazily on switch.
	for asset_type in _splits.keys():
		_dirty_tabs[asset_type] = true
	_populate_tab_for(_current_tab)
