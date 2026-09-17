## GridPacker.gd
## First-fit packing of Simple View controls onto fixed-size grid pages.
## Groups are packed as rectangular blocks so group backgrounds never overlap.

class_name GridPacker extends RefCounted

## Returned by `Occupancy.find_free` when nothing fits.
const NONE := Rect2i(-1, -1, 0, 0)


## Cell occupancy for one page, scanned row by row.
class Occupancy:
	var columns: int
	var rows: int
	var cells: PackedByteArray
	## Every cell before this index is occupied, so scans start here.
	var _first_free: int = 0


	func _init(p_columns: int, p_rows: int) -> void:
		columns = maxi(1, p_columns)
		rows = maxi(1, p_rows)
		cells.resize(columns * rows)
		cells.fill(0)


	## True when `rect` lies inside the grid and none of its cells are taken.
	func is_free(rect: Rect2i) -> bool:
		if rect.size.x < 1 or rect.size.y < 1 or rect.position.x < 0 or rect.position.y < 0:
			return false
		if rect.end.x > columns or rect.end.y > rows:
			return false
		for y in range(rect.position.y, rect.end.y):
			var row_start := y * columns
			for x in range(rect.position.x, rect.end.x):
				if cells[row_start + x] != 0:
					return false
		return true


	## Mark every cell of `rect` (clipped to the grid) as taken.
	func mark(rect: Rect2i) -> void:
		for y in range(maxi(0, rect.position.y), mini(rows, rect.end.y)):
			for x in range(maxi(0, rect.position.x), mini(columns, rect.end.x)):
				cells[y * columns + x] = 1
		while _first_free < cells.size() and cells[_first_free] != 0:
			_first_free += 1


	## True when no cell is taken.
	func is_empty() -> bool:
		return _first_free == 0 and not cells.has(1)


	## First free rect of `size` in row-major order, or `GridPacker.NONE`.
	func find_free(size: Vector2i) -> Rect2i:
		if size.x > columns or size.y > rows:
			return GridPacker.NONE
		for i in range(_first_free, cells.size()):
			if cells[i] != 0:
				continue
			var rect := Rect2i(i % columns, i / columns, size.x, size.y)
			if is_free(rect):
				return rect
		return GridPacker.NONE


## Clamp a footprint so it fits a grid of `columns` × `rows`.
static func clamp_size(size: Vector2i, columns: int, rows: int) -> Vector2i:
	return Vector2i(clampi(size.x, 1, maxi(1, columns)), clampi(size.y, 1, maxi(1, rows)))


## Pack a prefix of `sizes` into the smallest block at most `max_cols` × `max_rows`.
## Returns `{count, size: Vector2i, rects: Array[Rect2i]}` with rects relative to the block;
## `count` is how many leading sizes fit (the rest need another block).
static func pack_block(sizes: Array[Vector2i], max_cols: int, max_rows: int) -> Dictionary:
	var min_w := 1
	for s in sizes:
		min_w = maxi(min_w, mini(s.x, max_cols))
	var best := {"count": 0, "size": Vector2i.ZERO, "rects": [] as Array[Rect2i]}
	for w in range(min_w, max_cols + 1):
		var occ := Occupancy.new(w, max_rows)
		var rects: Array[Rect2i] = []
		var used := Vector2i.ZERO
		for s in sizes:
			var rect := occ.find_free(clamp_size(s, w, max_rows))
			if rect == NONE:
				break
			occ.mark(rect)
			rects.append(rect)
			used = Vector2i(maxi(used.x, rect.end.x), maxi(used.y, rect.end.y))
		if _block_is_better(rects.size(), used, best):
			best = {"count": rects.size(), "size": used, "rects": rects}
		if rects.size() == sizes.size() and used.y == 1:
			break  # a single full row can't be beaten by a wider block
	return best


## Prefer more controls, then less area, then fewer rows.
static func _block_is_better(count: int, size: Vector2i, best: Dictionary) -> bool:
	if count != best.count:
		return count > best.count
	var area := size.x * size.y
	var best_size: Vector2i = best.size
	var best_area := best_size.x * best_size.y
	if area != best_area:
		return area < best_area
	return size.y < best_size.y


## Pack `groups` onto pages. Each group is `{id, title, items: [{kind, params, label?}]}`.
## A group starts a new page when it doesn't fit whole on the current one, and splits over
## several pages when it's bigger than a page. Returns layout pages
## `{title, groups: [{id, title, rect}], controls: [{kind, params, rect, group, label?}]}`.
static func pack_pages(groups: Array, columns: int, rows: int) -> Array[Dictionary]:
	var pages: Array[Dictionary] = []
	var page: Dictionary = {}
	var occ: Occupancy = null
	for group in groups:
		var items: Array = group.items
		var sizes: Array[Vector2i] = []
		for item in items:
			sizes.append(clamp_size(SimpleControlKinds.footprint(item.kind), columns, rows))
		var start := 0
		while start < items.size():
			var block := pack_block(sizes.slice(start), columns, rows)
			if block.count == 0:
				break  # unreachable: sizes are clamped to the grid
			var origin := NONE
			if occ != null:
				origin = occ.find_free(block.size)
			if origin == NONE:
				page = {"title": "", "groups": [], "controls": []}
				pages.append(page)
				occ = Occupancy.new(columns, rows)
				origin = Rect2i(Vector2i.ZERO, block.size)
			for i in range(block.count):
				var rect: Rect2i = block.rects[i]
				rect.position += origin.position
				occ.mark(rect)
				page.controls.append(make_control(items[start + i], rect, group.id))
			page.groups.append({"id": group.id, "title": group.title, "rect": rect_to_array(origin)})
			if page.title.is_empty():
				page.title = group.title
			start += block.count
			if start < items.size():
				occ = null  # continuation goes on a fresh page
	return pages


## Layout control dictionary for a generated item placed at `rect`.
static func make_control(item: Dictionary, rect: Rect2i, group_id: String) -> Dictionary:
	var control := {"kind": item.kind, "params": item.params.duplicate(), "rect": rect_to_array(rect)}
	if not group_id.is_empty():
		control["group"] = group_id
	if not String(item.get("label", "")).is_empty():
		control["label"] = item.label
	return control


## `[col, row, w, h]` → Rect2i.
static func rect_from_array(a: Array) -> Rect2i:
	return Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))


## Rect2i → `[col, row, w, h]`.
static func rect_to_array(rect: Rect2i) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
