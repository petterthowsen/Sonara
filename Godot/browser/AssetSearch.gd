# AssetSearch.gd
# Fuzzy asset scoring shared by the Browser search box and the AI search_assets tool,
# so both find the same assets for the same query.
class_name AssetSearch extends RefCounted

## Scores at or below this are not a match.
const MATCH_THRESHOLD := 0.5

## Score for a query found only in the asset's directory path (just above the threshold).
const PATH_MATCH_SCORE := 0.55


## Best fuzzy score (0–1) of `query` against the asset's display name, file name and tags,
## plus category and vendor for devices. `include_path` also accepts a substring hit on the path.
static func score(asset: Asset, query: String, include_path: bool = false) -> float:
	if asset == null:
		return 0.0
	var needle := query.strip_edges().to_lower()
	if needle.is_empty():
		return 1.0
	var best := Utils.fuzzy_match(needle, asset.get_display_name())
	if asset.name != asset.get_display_name():
		best = maxf(best, Utils.fuzzy_match(needle, asset.name))
	for tag in asset.tags:
		best = maxf(best, Utils.fuzzy_match(needle, str(tag)))
	if asset.type == Asset.TYPE.Device:
		var device := AssetService.get_device(asset.path)
		if device:
			best = maxf(best, Utils.fuzzy_match(needle, device.get_category_string()))
			best = maxf(best, Utils.fuzzy_match(needle, device.author))
	if include_path and best <= MATCH_THRESHOLD and asset.path.to_lower().contains(needle):
		best = PATH_MATCH_SCORE
	return best


## Matching assets as `{asset, score}`, best first. An empty query returns every asset with score 1.
static func rank(assets: Array, query: String, include_path: bool = false) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for asset in assets:
		var s := score(asset, query, include_path)
		if s > MATCH_THRESHOLD:
			results.append({"asset": asset, "score": s})
	if not query.strip_edges().is_empty():
		results.sort_custom(func(a, b): return a.score > b.score)
	return results
