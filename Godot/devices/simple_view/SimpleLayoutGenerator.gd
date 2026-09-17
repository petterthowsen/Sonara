## SimpleLayoutGenerator.gd
## Builds a Simple View layout from a device's parameters: device kind → classify → compounds →
## groups → pages (docs/specs/004-simple-view/design.md). Every step works on plain data.

class_name SimpleLayoutGenerator extends RefCounted

const MAIN_PAGE_TITLE := "Main"
## Only items at least this important go on the Main page of a multi-page layout.
const MAIN_MIN_IMPORTANCE := 0.6
## Share of one page's cells the Main page may fill before the group pages take over.
const MAIN_CELL_SHARE := 0.5


## Strategy for a `DeviceKind` value.
static func strategy_for(kind: String) -> GenericStrategy:
	match kind:
		DeviceKind.SYNTH:
			return SynthStrategy.new()
		DeviceKind.REVERB:
			return ReverbStrategy.new()
		DeviceKind.DELAY:
			return DelayStrategy.new()
		DeviceKind.COMPRESSOR:
			return CompressorStrategy.new()
		DeviceKind.EQ:
			return EqStrategy.new()
		_:
			return GenericStrategy.new()


## Generate a layout for `device` from `params` (an instance's parameters; falls back to the
## device's own list when empty).
static func generate(device: Device, params: Array, columns: int = SimpleLayout.DEFAULT_COLUMNS,
		rows: int = SimpleLayout.DEFAULT_ROWS) -> SimpleLayout:
	if params.is_empty() and device != null:
		params = device.parameters
	var kind := DeviceKind.infer(device)
	var strategy := strategy_for(kind)
	var items := CompoundDetector.detect(ParamClassifier.classify(params, strategy))

	var layout := SimpleLayout.new()
	layout.device_id = device.device_id if device != null else ""
	layout.kind = kind
	layout.generated = true
	layout.columns = maxi(1, columns)
	layout.rows = maxi(1, rows)
	layout.pages = build_pages(items, strategy, layout.columns, layout.rows)
	return layout


## Pages for `items`: one Main page when everything fits, else a Main page with the most
## important items followed by pages per group (REQ-007).
static func build_pages(items: Array[Dictionary], strategy: GenericStrategy, columns: int, rows: int) -> Array[Dictionary]:
	var all_pages := GridPacker.pack_pages(group_items(items, strategy), columns, rows)
	if all_pages.size() <= 1:
		if not all_pages.is_empty():
			all_pages[0].title = MAIN_PAGE_TITLE
		return all_pages

	var main_items := select_main_items(items, columns, rows)
	if main_items.is_empty():
		return all_pages
	var in_main := {}
	for item in main_items:
		in_main[item.index] = true
	var rest: Array[Dictionary] = []
	for item in items:
		if not in_main.has(item.index):
			rest.append(item)
	var pages := GridPacker.pack_pages(group_items(main_items, strategy), columns, rows)
	pages[0].title = MAIN_PAGE_TITLE
	pages.append_array(GridPacker.pack_pages(group_items(rest, strategy), columns, rows))
	return pages


## The most important items (at least `MAIN_MIN_IMPORTANCE`) whose footprints fill at most
## `MAIN_CELL_SHARE` of a page, in their original order.
static func select_main_items(items: Array[Dictionary], columns: int, rows: int) -> Array[Dictionary]:
	var ranked := items.duplicate()
	ranked.sort_custom(_by_importance)
	var budget := int(columns * rows * MAIN_CELL_SHARE)
	var chosen: Array[Dictionary] = []
	for item in ranked:
		if item.importance < MAIN_MIN_IMPORTANCE:
			break
		var size := GridPacker.clamp_size(SimpleControlKinds.footprint(item.kind), columns, rows)
		if size.x * size.y > budget:
			continue
		budget -= size.x * size.y
		chosen.append(item)
	chosen.sort_custom(func(a, b): return a.index < b.index)
	return chosen


## Group items by the first segment of their module path when the device's modules actually group
## parameters, otherwise by the strategy (REQ-006). Groups are ordered by their most important
## item, then by first appearance; items keep their order inside a group.
static func group_items(items: Array[Dictionary], strategy: GenericStrategy) -> Array[Dictionary]:
	var use_modules := modules_group_parameters(items)
	var by_id := {}
	var groups: Array[Dictionary] = []
	for item in items:
		var def: Dictionary
		var segment := module_segment(item.module)
		if use_modules and not segment.is_empty():
			def = {"id": "module_" + segment.to_lower().replace(" ", "_"), "title": segment}
		else:
			def = strategy.group_for_item(item)
		var group: Dictionary = by_id.get(def.id, {})
		if group.is_empty():
			group = {"id": def.id, "title": def.title, "items": [], "importance": item.importance, "index": item.index}
			by_id[def.id] = group
			groups.append(group)
		group.items.append(item)
		group.importance = maxf(group.importance, item.importance)
	groups.sort_custom(_by_importance)
	return groups


## True when module paths carry grouping: some path is hierarchical ("Early/Size"), or two items
## share a first segment. Plugins with one flat module per parameter don't count.
static func modules_group_parameters(items: Array[Dictionary]) -> bool:
	var seen := {}
	for item in items:
		var module: String = item.module
		if module.is_empty():
			continue
		if module.contains("/"):
			return true
		if seen.has(module):
			return true
		seen[module] = true
	return false


## First segment of a module path ("Early/Size" → "Early").
static func module_segment(module: String) -> String:
	return module.get_slice("/", 0).strip_edges()


static func _by_importance(a: Dictionary, b: Dictionary) -> bool:
	if not is_equal_approx(a.importance, b.importance):
		return a.importance > b.importance
	return a.index < b.index
