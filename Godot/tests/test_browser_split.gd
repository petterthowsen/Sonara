# test_browser_split.gd
# Headless tests for the Browser's list mode: the folder tree on top and the contents of the
# selected folder below (spec 037, part 1).
# Run: godot --headless --path Godot -s tests/test_browser_split.gd -- --test
extends TestBase

const TYPE_AUDIO := 0
const TYPE_PRESET := 5

var _asset_script: GDScript
var _browser: Node


func suite_name() -> String:
	return "Browser folder/contents split"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_browser = (load("res://browser/Browser.tscn") as PackedScene).instantiate()
	root.add_child(_browser)
	await process_frame
	_load_samples()
	_test_all_lists_everything()
	_test_folder_lists_direct_assets()
	_test_search_overrides_folder()
	_test_folder_survives_rebuild()
	_test_drag_matches_tree_view()
	_test_presets_keep_unavailable_grey()
	_browser.queue_free()
	await process_frame


func _asset(type: int, path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = type
	asset.path = path
	asset.name = path.get_file()
	return asset


func _load_samples() -> void:
	_browser._audio_assets.assign([
		_asset(TYPE_AUDIO, "/t/drums/kick.wav"),
		_asset(TYPE_AUDIO, "/t/drums/snare.wav"),
		_asset(TYPE_AUDIO, "/t/loops/groove.wav"),
		_asset(TYPE_AUDIO, "/t/top.wav"),
	])
	_browser._midi_assets.clear()
	_browser._search_filter = ""
	_browser._selected_folder.clear()
	_browser._selected_content.clear()
	_browser._populate_tab_for(TYPE_AUDIO)


## Display names of the asset rows of the content tree.
func _asset_rows() -> Array[String]:
	var out: Array[String] = []
	var item: TreeItem = _browser._content_trees[TYPE_AUDIO].get_root().get_first_child()
	while item:
		if item.get_metadata(0) is Object:
			out.append(item.get_text(0))
		item = item.get_next()
	out.sort()
	return out


func _folder_rows() -> Array[String]:
	var out: Array[String] = []
	var item: TreeItem = _browser._content_trees[TYPE_AUDIO].get_root().get_first_child()
	while item:
		if item.has_meta("folder_key"):
			out.append(item.get_text(0))
		item = item.get_next()
	out.sort()
	return out


func _select(key: String) -> void:
	_browser._select_folder(TYPE_AUDIO, key)
	_browser._populate_contents(TYPE_AUDIO)


func _test_all_lists_everything() -> void:
	var root_item: TreeItem = _browser._folder_trees[TYPE_AUDIO].get_root()
	_assert(root_item.get_text(0) == "All", "the folder tree root is All")
	_assert(_browser._selected_folder[TYPE_AUDIO] == "", "All is selected by default")
	_assert(_asset_rows() == ["groove", "kick", "snare", "top"], "All lists every asset recursively: %s" % [_asset_rows()])
	_assert(_folder_rows().is_empty(), "All lists no folder rows")


func _test_folder_lists_direct_assets() -> void:
	_select("audio:/t/drums")
	_assert(_asset_rows() == ["kick", "snare"], "a folder lists only its direct assets: %s" % [_asset_rows()])
	_select("audio:/t")
	_assert(_asset_rows() == ["top"], "a parent folder skips the assets of its subfolders: %s" % [_asset_rows()])
	_assert(_folder_rows() == ["drums", "loops"], "subfolders are listed as rows: %s" % [_folder_rows()])
	# Double-click on a subfolder row enters it.
	var tree: Tree = _browser._content_trees[TYPE_AUDIO]
	var item: TreeItem = tree.get_root().get_first_child()
	item.select(0)
	_browser._on_content_activated(tree, TYPE_AUDIO)
	_assert(_browser._selected_folder[TYPE_AUDIO] == "audio:/t/drums", "activating a folder row enters that folder")
	_assert(_asset_rows() == ["kick", "snare"], "the entered folder lists its assets")


func _test_search_overrides_folder() -> void:
	_select("audio:/t/drums")
	_browser._search_filter = "groove"
	_browser._populate_tab_for(TYPE_AUDIO)
	_assert(_asset_rows() == ["groove"], "a search lists every match whatever folder is selected: %s" % [_asset_rows()])
	_browser._search_filter = ""
	_browser._populate_tab_for(TYPE_AUDIO)
	_assert(_asset_rows() == ["kick", "snare"], "clearing the search returns to the folder")


func _test_folder_survives_rebuild() -> void:
	_select("audio:/t/drums")
	_browser._selected_content[TYPE_AUDIO] = "/t/drums/snare.wav"
	_browser._populate_tab_for(TYPE_AUDIO)
	_assert(_browser._selected_folder[TYPE_AUDIO] == "audio:/t/drums", "the selected folder survives a rebuild")
	var selected: TreeItem = _browser._folder_trees[TYPE_AUDIO].get_selected()
	_assert(selected != null and selected.get_metadata(0) == "audio:/t/drums", "the folder row is selected again")
	var row: TreeItem = _browser._content_trees[TYPE_AUDIO].get_selected()
	_assert(row != null and row.get_metadata(0).path == "/t/drums/snare.wav", "the selected content row survives a rebuild")
	# A vanished folder falls back to All.
	_browser._audio_assets.assign([_asset(TYPE_AUDIO, "/t/top.wav")])
	_browser._populate_tab_for(TYPE_AUDIO)
	_assert(_browser._selected_folder[TYPE_AUDIO] == "", "a vanished folder falls back to All")
	_load_samples()


func _test_drag_matches_tree_view() -> void:
	var outside := Vector2(-1000, -1000)
	var content: Tree = _browser._content_trees[TYPE_AUDIO]
	var from_content: TreeItem = content.get_root().get_first_child()
	while from_content and not (from_content.get_metadata(0) is Object and from_content.get_metadata(0).path == "/t/top.wav"):
		from_content = from_content.get_next()
	from_content.select(0)
	var data_content: Variant = _browser._get_drag_data_tree(outside, content)

	var tree: Tree = _browser._trees[TYPE_AUDIO]
	var from_tree: TreeItem = _find_asset_item(tree.get_root(), "/t/top.wav")
	_assert(from_tree != null, "the tree view lists the same asset")
	from_tree.select(0)
	var data_tree: Variant = _browser._get_drag_data_tree(outside, tree)
	_assert(data_content != null and data_content == data_tree, "drag data from the content tree equals the tree view's")
	_assert(data_content != null and data_content.path == "/t/top.wav", "the drag carries the Asset")


func _find_asset_item(item: TreeItem, path: String) -> TreeItem:
	var asset: Variant = item.get_metadata(0)
	if asset is Object and asset.path == path:
		return item
	var child := item.get_first_child()
	while child:
		var found := _find_asset_item(child, path)
		if found:
			return found
		child = child.get_next()
	return null


func _test_presets_keep_unavailable_grey() -> void:
	var preset: Object = _asset(TYPE_PRESET, "/p/Pads/warm.sonpreset")
	preset.name = "Warm"
	preset.device_id = "missing.device"
	preset.device_name = "Missing"
	_browser._preset_assets.assign([preset])
	_browser._populate_tab_for(TYPE_PRESET)
	var tree: Tree = _browser._content_trees[TYPE_PRESET]
	var row: TreeItem = tree.get_root().get_first_child()
	_assert(row != null and row.get_text(0) == "Warm — Missing", "preset rows show the preset and its device")
	_assert(row.get_custom_color(0) == _browser.UNAVAILABLE_COLOR, "an unavailable preset is greyed out")
	_assert(row.get_tooltip_text(0).contains("not installed"), "an unavailable preset names the missing device in its tooltip")
