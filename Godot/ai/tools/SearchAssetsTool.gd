# SearchAssetsTool.gd
class_name SearchAssetsTool extends AiTool


func get_name() -> String:
	return "search_assets"


func get_description() -> String:
	return "Search the asset library. Every word must match the name, a tag, or a folder in the path. Optional type: audio, midi, device, sfz, soundfont. Use list_assets to browse folders."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {"type": "string", "description": "Case-insensitive search text; every word must match"},
			"type": {
				"type": "string",
				"enum": ["audio", "midi", "device", "sfz", "soundfont"],
				"description": "Optional asset type filter",
			},
			"limit": {"type": "integer", "description": "Max hits (default 25)"},
			"offset": {"type": "integer", "description": "Skip this many hits (default 0), for paging past `limit`"},
		},
		"required": ["query"],
	}


func execute(args: Dictionary) -> Dictionary:
	if AssetService == null:
		return fail("AssetService is not available")
	var query := str(args.get("query", ""))
	var type_filter := str(args.get("type", ""))
	var limit := int(args.get("limit", 25))
	var offset := int(args.get("offset", 0))
	var result := AssetService.search_assets(query, type_filter, limit, offset)
	var hits: Array[Asset] = result.assets
	var total: int = result.total
	return ok_text(_format_text(hits, total, query, type_filter, offset), {"total": total, "paths": _paths(hits)})


func _paths(hits: Array[Asset]) -> Array:
	var paths: Array = []
	for asset in hits:
		paths.append(AssetService.relative_path(asset))
	return paths


func _format_text(hits: Array[Asset], total: int, query: String, type_filter: String, offset: int) -> String:
	if total == 0:
		return "No assets match \"%s\". Try fewer words or list_assets." % query
	var shown := offset + hits.size()
	var kind := (type_filter.strip_edges().to_lower() + " ") if not type_filter.strip_edges().is_empty() else ""
	var lines: Array[String] = []
	lines.append("%d of %d %sassets match \"%s\" (offset %d)." % [hits.size(), total, kind, query, offset])
	for asset in hits:
		lines.append("- " + _format_row(asset))
	if shown < total:
		lines[0] += " Pass offset %d for more." % shown
	return "\n".join(lines)


func _format_row(asset: Asset) -> String:
	if asset.type == Asset.TYPE.Device:
		var device := AssetService.get_device(asset.path)
		var category := device.get_category_string().to_lower() if device else ""
		return "%s (device: %s, %s)" % [asset.get_display_name(), asset.path, category]
	var row := AssetService.relative_path(asset)
	var extras: Array[String] = []
	if asset.favorite:
		extras.append("favorite")
	if not asset.tags.is_empty():
		extras.append("tags: " + ", ".join(asset.tags))
	if not extras.is_empty():
		row += ", " + ", ".join(extras)
	return row
