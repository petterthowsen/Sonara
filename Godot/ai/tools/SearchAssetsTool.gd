# SearchAssetsTool.gd
class_name SearchAssetsTool extends AiTool


func get_name() -> String:
	return "search_assets"


func get_description() -> String:
	return "Search the asset library by name, path, or tag. Optional type: audio, midi, device, sfz, soundfont."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {"type": "string", "description": "Case-insensitive search text"},
			"type": {
				"type": "string",
				"enum": ["audio", "midi", "device", "sfz", "soundfont"],
				"description": "Optional asset type filter",
			},
			"limit": {"type": "integer", "description": "Max hits (default 25)"},
		},
		"required": ["query"],
	}


func execute(args: Dictionary) -> Dictionary:
	if AssetService == null:
		return fail("AssetService is not available")
	var query := str(args.get("query", ""))
	var type_filter := str(args.get("type", ""))
	var limit := int(args.get("limit", 25))
	var hits: Array[Asset] = AssetService.search_assets(query, type_filter, limit)
	var rows: Array = []
	for asset in hits:
		rows.append({
			"path": asset.path,
			"name": asset.get_display_name(),
			"type": Asset.TYPE.keys()[asset.type].to_lower(),
			"tags": asset.tags,
			"favorite": asset.favorite,
		})
	return ok({"assets": rows, "count": rows.size()})
