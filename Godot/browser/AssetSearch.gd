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


## Split text on `/ - _ . space` into lowercase words, dropping empties.
static func _tokenize(s: String) -> PackedStringArray:
	var t := s
	for sep in ["/", "-", "_", ".", " "]:
		t = t.replace(sep, " ")
	return Array(t.split(" ", false))


## Split a query on whitespace into lowercase words. Hyphenated words stay intact.
static func _split_query(query: String) -> PackedStringArray:
	var trimmed := query.strip_edges().to_lower()
	if trimmed.is_empty():
		return PackedStringArray()
	return Array(trimmed.split(" ", false))


## Best score for one query word `t` against a single asset's text. See rank_tokens for tiers.
static func _score_word(t: String, name: String, rel: String, tags: PackedStringArray, folders: PackedStringArray, words: PackedStringArray) -> float:
	var name_words := _tokenize(name)
	if t in name_words:
		return 1.0
	for w in name_words:
		if w.begins_with(t):
			return 0.9
	if t in tags:
		return 0.9
	if name.contains(t):
		return 0.8
	if t in folders or rel.contains(t):
		return 0.7
	for w in words:
		if w.length() >= 3 and (t.begins_with(w) or (t.length() >= 3 and w.begins_with(t))):
			return 0.6
	var best_fuzzy := 0.0
	for w in words:
		best_fuzzy = maxf(best_fuzzy, Utils.fuzzy_match(t, w))
	if best_fuzzy > 0.7:
		return 0.5 * best_fuzzy
	return 0.0


## Word-based matching for the AI `search_assets` tool: every query word must score above 0
## against the asset's name, relative path or tags. Returns `{asset, score}`, best first.
## `rel_path_of` maps an asset to its library-relative path (lowercased/extension-stripped here).
## Does not change `score`/`rank`, which the Browser keeps using.
static func rank_tokens(assets: Array, query: String, rel_path_of: Callable) -> Array[Dictionary]:
	var query_words := _split_query(query)
	var results: Array[Dictionary] = []
	if query_words.is_empty():
		for asset in assets:
			results.append({"asset": asset, "score": 1.0})
		return results
	for asset in assets:
		var name: String = asset.get_display_name().to_lower()
		var rel: String = str(rel_path_of.call(asset)).to_lower().get_basename()
		var tags := PackedStringArray()
		for tag in asset.tags:
			tags.append(str(tag).to_lower())
		var folders := PackedStringArray()
		var folder_part := rel.get_base_dir()
		if not folder_part.is_empty():
			folders = _tokenize(folder_part)
		var words: PackedStringArray = _tokenize(name)
		for w in _tokenize(rel):
			words.append(w)
		for w in tags:
			words.append(w)
		var total := 0.0
		var matched := true
		for t in query_words:
			var s := _score_word(t, name, rel, tags, folders, words)
			if s <= 0.0:
				matched = false
				break
			total += s
		if not matched:
			continue
		var asset_score := total / query_words.size()
		if asset.favorite:
			asset_score += 0.05
		var name_word_count := _tokenize(name).size()
		if name_word_count > query_words.size():
			asset_score -= 0.01 * (name_word_count - query_words.size())
		results.append({"asset": asset, "score": asset_score})
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a.score, b.score):
			return a.score > b.score
		var aa: Asset = a.asset
		var bb: Asset = b.asset
		if aa.last_used != bb.last_used:
			return aa.last_used > bb.last_used
		return aa.get_display_name().to_lower() < bb.get_display_name().to_lower()
	)
	return results
