## SimpleLayout.gd
## Saved description of a Simple View: grid size, pages, groups and controls.
## Pages are plain dictionaries in the on-disk JSON shape (see docs/specs/004-simple-view/design.md):
## `{title, groups: [{id, title, rect}], controls: [{kind, params, rect, group?, label?, unit?}]}`
## with `rect` = `[col, row, w, h]` in cells.

class_name SimpleLayout extends RefCounted

const VERSION := 1
const DEFAULT_COLUMNS := 6
const DEFAULT_ROWS := 4
## Title of pages added for parameters the layout didn't mention.
const OVERFLOW_PAGE_TITLE := "More"

static var logger := Log.make("SimpleLayout")

var device_id: String = ""
var kind: String = "generic"
## False once a user edit has been saved.
var generated: bool = true
var columns: int = DEFAULT_COLUMNS
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
	if not grid is Dictionary or not _is_number(grid.get("columns")) or not _is_number(grid.get("rows")):
		return null
	var raw_pages: Variant = data.get("pages")
	if not raw_pages is Array:
		return null

	var layout := SimpleLayout.new()
	layout.device_id = str(data.get("device_id", ""))
	layout.kind = str(data.get("kind", "generic"))
	layout.generated = bool(data.get("generated", true))
	layout.columns = maxi(1, int(grid.columns))
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
		"grid": {"columns": columns, "rows": rows},
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
		for key in ["group", "label", "unit"]:
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
		var occ := GridPacker.Occupancy.new(columns, rows)
		for control in pages[page_index].controls:
			var rect := GridPacker.rect_from_array(control.rect)
			var where := "page %d control %s at %s" % [page_index, control.params, control.rect]
			if not SimpleControlKinds.is_valid(control.kind):
				problems.append("%s: unknown kind '%s'" % [where, control.kind])
			elif control.params.size() != SimpleControlKinds.param_count(control.kind):
				problems.append("%s: %s needs %d params" % [where, control.kind, SimpleControlKinds.param_count(control.kind)])
			if rect.size.x < 1 or rect.size.y < 1 or rect.position.x < 0 or rect.position.y < 0 \
					or rect.end.x > columns or rect.end.y > rows:
				problems.append("%s: outside the %d×%d grid" % [where, columns, rows])
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
	var rect := _occupancy(pages[page_index]).find_free(GridPacker.clamp_size(Vector2i(w, h), columns, rows))
	return [] if rect == GridPacker.NONE else GridPacker.rect_to_array(rect)


func _occupancy(page: Dictionary) -> GridPacker.Occupancy:
	var occ := GridPacker.Occupancy.new(columns, rows)
	for control in page.controls:
		occ.mark(GridPacker.rect_from_array(control.rect))
	return occ


## ============================================================================
## EDITS
## ============================================================================

## Change the grid size (REQ-010). Controls that still fit stay put; the rest move to the next
## free space on their page or a later one, with pages added at the end as needed.
func resize_grid(new_columns: int, new_rows: int) -> void:
	columns = maxi(1, new_columns)
	rows = maxi(1, new_rows)
	var pending: Array[Dictionary] = []
	for page in pages:
		var occ := GridPacker.Occupancy.new(columns, rows)
		var kept: Array = []
		var overflow: Array[Dictionary] = []
		for control in page.controls:
			var rect := GridPacker.rect_from_array(control.rect)
			rect.size = GridPacker.clamp_size(rect.size, columns, rows)
			control.rect = GridPacker.rect_to_array(rect)
			if occ.is_free(rect):
				occ.mark(rect)
				kept.append(control)
			else:
				overflow.append(control)
		page.controls = kept
		pending.append_array(overflow)
		pending = _place_where_free(page, occ, pending)
	while not pending.is_empty():
		var page := _append_page(pages[-1].title if not pages.is_empty() else OVERFLOW_PAGE_TITLE)
		var before := pending.size()
		pending = _place_where_free(page, _occupancy(page), pending)
		if pending.size() == before:
			break  # unreachable: sizes are clamped to the grid
	refresh_groups()


## Place `controls` first-fit on `page`; returns the ones that didn't fit.
func _place_where_free(page: Dictionary, occ: GridPacker.Occupancy, controls: Array[Dictionary]) -> Array[Dictionary]:
	var left: Array[Dictionary] = []
	for control in controls:
		var size := GridPacker.clamp_size(Vector2i(control.rect[2], control.rect[3]), columns, rows)
		var rect := occ.find_free(size)
		if rect == GridPacker.NONE:
			left.append(control)
			continue
		occ.mark(rect)
		control.rect = GridPacker.rect_to_array(rect)
		page.controls.append(control)
	return left


func _append_page(title: String) -> Dictionary:
	var page := {"title": title, "groups": [], "controls": []}
	pages.append(page)
	return page


## Recompute each page's group rects as the bounds of the controls in that group. Groups with no
## controls on a page are kept when they still fit the grid; groups that controls moved onto a
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
				if rect.end.x <= columns and rect.end.y <= rows:
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


## Put a generated `{kind, params}` item on the last page, or a new one when it's full.
func _place_on_last_page(item: Dictionary) -> void:
	var size := GridPacker.clamp_size(SimpleControlKinds.footprint(item.kind), columns, rows)
	var page: Dictionary = pages[-1] if not pages.is_empty() else _append_page(OVERFLOW_PAGE_TITLE)
	var occ := _occupancy(page)
	var rect := occ.find_free(size)
	if rect == GridPacker.NONE:
		page = _append_page(OVERFLOW_PAGE_TITLE)
		rect = Rect2i(Vector2i.ZERO, size)
	page.controls.append(GridPacker.make_control(item, rect, ""))
