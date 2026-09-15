# ListAssetsTool.gd
class_name ListAssetsTool extends AiTool

const PER_PAGE := 30


func get_name() -> String:
	return "list_assets"


func get_description() -> String:
	return "Browse the asset library by folder. path is library-relative (as shown by list_assets/search_assets); empty lists the library roots. Optional type filter: audio, midi, sfz. 30 files per page; folders always show in full."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Library-relative folder, e.g. \"SFZ/VPO3/Strings\". Empty lists the roots."},
			"type": {
				"type": "string",
				"enum": ["audio", "midi", "sfz"],
				"description": "Optional asset type filter",
			},
			"page": {"type": "integer", "description": "1-based page of files (default 1), 30 per page"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	if AssetService == null:
		return fail("AssetService is not available")
	var path := str(args.get("path", "")).strip_edges()
	while path.ends_with("/") and path.length() > 0:
		path = path.substr(0, path.length() - 1)
	var type_filter := str(args.get("type", "")).strip_edges().to_lower()
	var page := int(args.get("page", 1))
	if page < 1:
		page = 1

	var want := _type_from_filter(type_filter)
	var rel_to_asset: Dictionary = {}
	var rel_paths: Array = []
	for asset in AssetService.get_all_assets():
		if want >= 0 and asset.type != want:
			continue
		var rel: String = AssetService.relative_path(asset)
		rel_paths.append(rel)
		rel_to_asset[rel] = asset

	if path.is_empty():
		return ok_text(_list_roots(rel_paths, type_filter))

	var listing := AssetPaths.build_listing(rel_paths, path, page, PER_PAGE)
	if listing.has("error"):
		if listing.error == "page_out_of_range":
			return fail("page %d out of range (1-%d)" % [page, listing.total_pages])
		return fail("No folder \"%s\". Roots: %s" % [path, _root_labels_text()])

	return ok_text(_format_folder(path, listing, rel_to_asset), {"folders": listing.folders, "files": listing.files})


func _type_from_filter(type_filter: String) -> int:
	match type_filter:
		"audio":
			return Asset.TYPE.Audio
		"midi":
			return Asset.TYPE.Midi
		"sfz":
			return Asset.TYPE.SFZ
		_:
			return -1


func _root_labels_text() -> String:
	var labels: Array[String] = []
	for root in AssetService.get_roots():
		labels.append(str(root.label) + "/")
	labels.sort()
	return ", ".join(labels)


func _list_roots(rel_paths: Array, type_filter: String) -> String:
	var counts: Dictionary = {}
	for raw in rel_paths:
		var rel := str(raw)
		var slash := rel.find("/")
		var label := rel if slash < 0 else rel.substr(0, slash)
		counts[label] = int(counts.get(label, 0)) + 1
	var labels: Array[String] = []
	for root in AssetService.get_roots():
		labels.append(str(root.label))
	labels.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	var kind := (type_filter + " ") if not type_filter.is_empty() else ""
	var lines: Array[String] = []
	lines.append("%d %slibraries:" % [labels.size(), kind])
	for label in labels:
		lines.append("- %s/ (%d)" % [label, int(counts.get(label, 0))])
	return "\n".join(lines)


func _format_folder(path: String, listing: Dictionary, rel_to_asset: Dictionary) -> String:
	var folders: Array = listing.folders
	var files: Array = listing.files
	var total_files: int = listing.total_files
	var total_pages: int = listing.total_pages
	var page: int = listing.page
	var header := "%s/: %d folders, %d files" % [path, folders.size(), total_files]
	if total_pages > 1:
		header += " (page %d/%d, %d per page)" % [page, total_pages, PER_PAGE]
	var lines: Array[String] = [header]
	for f in folders:
		lines.append("- %s/ (%d)" % [f.name, f.count])
	for name in files:
		lines.append("- " + _format_file_row(path, name, rel_to_asset))
	return "\n".join(lines)


func _format_file_row(path: String, name: String, rel_to_asset: Dictionary) -> String:
	var asset: Asset = rel_to_asset.get(path + "/" + name)
	if asset == null:
		return name
	var extras: Array[String] = []
	if asset.favorite:
		extras.append("favorite")
	if not asset.tags.is_empty():
		extras.append("tags: " + ", ".join(asset.tags))
	if extras.is_empty():
		return name
	return name + ", " + ", ".join(extras)
