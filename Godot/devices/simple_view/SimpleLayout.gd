## SimpleLayout.gd
## Saved description of a Simple View: row count, pages, groups and controls. Pages are `rows`
## tall and as wide as their controls need.
## Pages are plain dictionaries in the on-disk JSON shape (see docs/specs/004-simple-view/design.md):
## `{title, groups: [{id, title, rect}], controls: [{kind, params, rect, group?, label?, unit?, stages?}]}`
## with `rect` = `[col, row, w, h]` in cells.

class_name SimpleLayout extends RefCounted

const VERSION := 1
const DEFAULT_ROWS := 4
## Widest a generated page gets, in cells, before its groups continue on another page. Also
## where parameters added to an existing layout stop filling the last page.
const MAX_PAGE_COLUMNS := 24
## Title of pages added for parameters the layout didn't mention.
const OVERFLOW_PAGE_TITLE := "More"

static var logger := Log.make("SimpleLayout")

var device_id: String = ""
var kind: String = "generic"
## False once a user edit has been saved.
var generated: bool = true
## `SimpleLayoutGenerator.VERSION` that generated the layout (1 for files from before it was saved).
var generator_version: int = 1
var rows: int = DEFAULT_ROWS
var pages: Array[Dictionary] = []


## ============================================================================
## SERIALIZATION
## ============================================================================

## Build a layout from parsed JSON. Returns null for an unknown version or a malformed shape.
static func from_dict(data: Variant) -> SimpleLayout:
	if not data is Dictionary:
		return null
	if not _is_number(data.get("version")) or int(data.version) != VERSION:
		return null
	var grid: Variant = data.get("grid")
	# Files from before pages grew sideways also carry `grid.columns`; it's ignored.
	if not grid is Dictionary or not _is_number(grid.get("rows")):
		return null
	var raw_pages: Variant = data.get("pages")
	if not raw_pages is Array:
		return null

	var layout := SimpleLayout.new()
	layout.device_id = str(data.get("device_id", ""))
	layout.kind = str(data.get("kind", "generic"))
	layout.generated = bool(data.get("generated", true))
	layout.generator_version = int(data.generator) if _is_number(data.get("generator")) else 1
	layout.rows = maxi(1, int(grid.rows))
	for raw_page in raw_pages:
		var page := _page_from_dict(raw_page)
		if page.is_empty():
			return null
		layout.pages.append(page)
	return layout


## Plain dictionary ready for `JSON.stringify`.
func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"device_id": device_id,
		"kind": kind,
		"generated": generated,
		"generator": generator_version,
		"grid": {"rows": rows},
		"pages": pages.duplicate(true),
	}


static func _is_number(v: Variant) -> bool:
	return v is int or v is float


## Normalized page, or `{}` when malformed.
static func _page_from_dict(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var page := {"title": str(raw.get("title", "")), "groups": [], "controls": []}
	var raw_groups: Variant = raw.get("groups", [])
	var raw_controls: Variant = raw.get("controls", [])
	if not raw_groups is Array or not raw_controls is Array:
		return {}
	for g in raw_groups:
		if not g is Dictionary or not _is_rect(g.get("rect")):
			return {}
		page.groups.append({"id": str(g.get("id", "")), "title": str(g.get("title", "")), "rect": _int_array(g.rect)})
	for c in raw_controls:
		if not c is Dictionary or not _is_rect(c.get("rect")) or not c.get("params") is Array:
			return {}
		var params: Array = []
		for p in c.params:
			if not _is_number(p):
				return {}
			params.append(int(p))
		var control := {"kind": str(c.get("kind", "")), "params": params, "rect": _int_array(c.rect)}
		for key in ["group", "label", "unit", "stages"]:
			if c.has(key):
				control[key] = str(c[key])
		page.controls.append(control)
	return page


static func _is_rect(v: Variant) -> bool:
	if not v is Array or v.size() != 4:
		return false
	for n in v:
		if not _is_number(n):
			return false
	return true


static func _int_array(a: Array) -> Array:
	var out: Array = []
	for n in a:
		out.append(int(n))
	return out


## ============================================================================
## QUERIES
## ============================================================================

## Problems with the layout (unknown kinds, wrong param counts, out of bounds, overlaps). Empty when valid.
func validate() -> Array[String]:
	var problems: Array[String] = []
	for page_index in range(pages.size()):
		var occ := GridPacker.Occupancy.new(0, rows)
		for control in pages[page_index].controls:
			var rect := GridPacker.rect_from_array(control.rect)
			var where := "page %d control %s at %s" % [page_index, control.params, control.rect]
			if not SimpleControlKinds.is_valid(control.kind):
				problems.append("%s: unknown kind '%s'" % [where, control.kind])
			elif control.params.size() != SimpleControlKinds.control_param_count(control):
				problems.append("%s: %s needs %d params" % [where, control.kind, SimpleControlKinds.control_param_count(control)])
			if rect.size.x < 1 or rect.size.y < 1 or rect.position.x < 0 or rect.position.y < 0 \
					or rect.end.y > rows:
				problems.append("%s: outside the %d-row grid" % [where, rows])
			elif not occ.is_free(rect):
				problems.append("%s: overlaps another control" % where)
			else:
				occ.mark(rect)
	return problems


## Every parameter id referenced by a control, in page order.
func param_ids() -> Array[int]:
	var ids: Array[int] = []
	for page in pages:
		for control in page.controls:
			for id in control.params:
				ids.append(int(id))
	return ids


## First free `[col, row, w, h]` of `w` × `h` cells on page `page_index`, or `[]`.
func find_free_rect(page_index: int, w: int, h: int) -> Array:
	if page_index < 0 or page_index >= pages.size():
		return []
	var rect := _occupancy(pages[page_index]).find_free(GridPacker.clamp_size(Vector2i(w, h), 0, rows))
	return [] if rect == GridPacker.NONE else GridPacker.rect_to_array(rect)


func _occupancy(page: Dictionary) -> GridPacker.Occupancy:
	var occ := GridPacker.Occupancy.new(0, rows)
	for control in page.controls:
		occ.mark(GridPacker.rect_from_array(control.rect))
	return occ


## ============================================================================
## EDITS
## ============================================================================

## Change the row count (REQ-010). Controls that still fit stay put; the rest (and controls
## taller than the new row count, which shrink to it) move to the next free space on their page,
## which grows sideways as needed.
func set_rows(new_rows: int) -> void:
	rows = maxi(1, new_rows)
	for page in pages:
		var occ := GridPacker.Occupancy.new(0, rows)
		var kept: Array = []
		var overflow: Array[Dictionary] = []
		for control in page.controls:
			var rect := GridPacker.rect_from_array(control.rect)
			rect.size = GridPacker.clamp_size(rect.size, 0, rows)
			control.rect = GridPacker.rect_to_array(rect)
			if occ.is_free(rect):
				occ.mark(rect)
				kept.append(control)
			else:
				overflow.append(control)
		page.controls = kept
		_place_where_free(page, occ, overflow)
	refresh_groups()


## Place `controls` first-fit on `page` (whose occupancy is `occ`).
func _place_where_free(page: Dictionary, occ: GridPacker.Occupancy, controls: Array[Dictionary]) -> void:
	for control in controls:
		var size := GridPacker.clamp_size(Vector2i(control.rect[2], control.rect[3]), 0, rows)
		var rect := occ.find_free(size)
		occ.mark(rect)
		control.rect = GridPacker.rect_to_array(rect)
		page.controls.append(control)


func _append_page(title: String) -> Dictionary:
	var page := {"title": title, "groups": [], "controls": []}
	pages.append(page)
	return page


## Recompute each page's group rects as the bounds of the controls in that group. Groups with no
## controls on a page are kept when they still fit the rows; groups that controls moved onto a
## page are added with their existing title.
func refresh_groups() -> void:
	var titles := {}
	for page in pages:
		for group in page.groups:
			titles[group.id] = group.title
	for page in pages:
		var bounds := {}
		for control in page.controls:
			var gid := str(control.get("group", ""))
			if gid.is_empty():
				continue
			var rect := GridPacker.rect_from_array(control.rect)
			bounds[gid] = bounds[gid].merge(rect) if bounds.has(gid) else rect
		var groups: Array = []
		for group in page.groups:
			if bounds.has(group.id):
				group.rect = GridPacker.rect_to_array(bounds[group.id])
				bounds.erase(group.id)
				groups.append(group)
			else:
				var rect := GridPacker.rect_from_array(group.rect)
				if rect.end.y <= rows:
					groups.append(group)
		for gid in bounds:
			groups.append({"id": gid, "title": titles.get(gid, gid), "rect": GridPacker.rect_to_array(bounds[gid])})
		page.groups = groups


## Bring the layout in line with the device's parameters (REQ-016). Controls that refer to
## parameters the device no longer has (or that are now hidden) are dropped; visible parameters
## the layout doesn't mention are added on free cells of the last page. Other controls don't move.
## Returns `{removed: Array[int], added: Array[int]}`.
func reconcile(params: Array) -> Dictionary:
	var visible := {}
	var ordered: Array[DeviceParameter] = []
	for param in params:
		if ParamClassifier.is_visible(param):
			visible[param.id] = param
			ordered.append(param)

	var removed: Array[int] = []
	var present := {}
	for page in pages:
		var kept: Array = []
		for control in page.controls:
			var missing: Array[int] = []
			for id in control.params:
				if not visible.has(int(id)):
					missing.append(int(id))
			if missing.is_empty():
				kept.append(control)
				for id in control.params:
					present[int(id)] = true
			else:
				removed.append_array(missing)
		page.controls = kept

	var added: Array[int] = []
	for param in ordered:
		if present.has(param.id):
			continue
		var item := {"kind": ParamClassifier.control_kind(param), "params": [param.id]}
		_place_on_last_page(item)
		present[param.id] = true
		added.append(param.id)

	if not removed.is_empty():
		logger.warning("Layout for %s refers to missing parameters %s; left them out" % [device_id, removed])
	if not added.is_empty():
		logger.info("Layout for %s: added parameters %s" % [device_id, added])
	if not removed.is_empty() or not added.is_empty():
		refresh_groups()
	return {"removed": removed, "added": added}


## Put a generated `{kind, params}` item on the last page, or a new one when the last page is
## already `MAX_PAGE_COLUMNS` wide.
func _place_on_last_page(item: Dictionary) -> void:
	var size := GridPacker.clamp_size(SimpleControlKinds.footprint(item.kind), MAX_PAGE_COLUMNS, rows)
	var page: Dictionary = pages[-1] if not pages.is_empty() else _append_page(OVERFLOW_PAGE_TITLE)
	var occ := _occupancy(page)
	var rect := occ.find_free(size)
	if rect.end.x > MAX_PAGE_COLUMNS and not occ.is_empty():
		page = _append_page(OVERFLOW_PAGE_TITLE)
		rect = Rect2i(Vector2i.ZERO, size)
	page.controls.append(GridPacker.make_control(item, rect, ""))
