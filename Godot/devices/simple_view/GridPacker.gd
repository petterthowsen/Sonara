## GridPacker.gd
## Packing of Simple View controls onto grid pages that are a fixed number of rows tall and as
## wide as they need to be (up to `SimpleLayout.MAX_PAGE_COLUMNS` when generated). Groups are
## packed as rectangular blocks so group backgrounds never overlap, and placed in columns in
## order so a page reads top to bottom, then left to right.

class_name GridPacker extends RefCounted

## Returned by `Occupancy.find_free` when nothing fits.
const NONE := Rect2i(-1, -1, 0, 0)
## A group of one-row controls covering at most this many cells takes a single row.
const SINGLE_ROW_CELLS := 4
## Height of a group's block when it's more than one row (two groups stack on a 4-row page).
const BLOCK_ROWS := 2
## A `BLOCK_ROWS`-tall block wider than this uses the full page height instead.
const MAX_BLOCK_COLUMNS := 8


## Where the next group block goes on a page: blocks stack top to bottom in a column; a block
## sits beside the previous one when the column is already wide enough, and a block that doesn't
## fit starts a new column to the right of the widest block in the current one.
class Columns:
	var rows: int
	var column_x := 0
	var column_w := 0
	## Current shelf (a band of rows inside the column) and how much of its width is used.
	var shelf_y := 0
	var shelf_h := 0
	var shelf_used := 0


	func _init(p_rows: int) -> void:
		rows = p_rows


	func is_empty() -> bool:
		return column_w == 0


	## Top-left cell for a block of `size`, advancing past it.
	func place(size: Vector2i) -> Vector2i:
		if not is_empty() and shelf_used + size.x <= column_w and size.y <= shelf_h:
			var beside := Vector2i(column_x + shelf_used, shelf_y)
			shelf_used += size.x
			return beside
		if not is_empty() and shelf_y + shelf_h + size.y <= rows:
			shelf_y += shelf_h
		else:
			column_x += column_w
			column_w = 0
			shelf_y = 0
		shelf_h = size.y
		shelf_used = size.x
		column_w = maxi(column_w, size.x)
		return Vector2i(column_x, shelf_y)


	## Leave the current column: the next block starts a new one to the right.
	func break_column() -> void:
		if is_empty():
			return
		column_x += column_w
		column_w = 0
		shelf_y = 0
		shelf_h = 0
		shelf_used = 0


	## True when a block of `size` would land in the column being filled (beside or below).
	func fits_current_column(size: Vector2i) -> bool:
		return not is_empty() and copy().place(size).x == column_x


	## Right edge a block of `size` would reach if placed next.
	func right_edge_for(size: Vector2i) -> int:
		return copy().place(size).x + size.x


	## An independent copy, for trying placements without committing them.
	func copy() -> Columns:
		var probe := Columns.new(rows)
		probe.column_x = column_x
		probe.column_w = column_w
		probe.shelf_y = shelf_y
		probe.shelf_h = shelf_h
		probe.shelf_used = shelf_used
		return probe


## Cell occupancy for one page. A bounded grid (`columns` > 0) is scanned row by row; an
## unbounded one (`columns` == 0) grows to the right and is scanned column by column, so it
## fills its rows before it gets wider.
class Occupancy:
	## Column count, or 0 for a grid that grows to the right as needed.
	var columns: int
	var rows: int
	## Column-major: cell (x, y) is at `x * rows + y`. Cells past the end are free.
	var cells: PackedByteArray
	## Every column before this one is full, so unbounded scans start here.
	var _first_open_column: int = 0
	## Row-major index of the first free cell of a bounded grid, so bounded scans start there.
	var _first_free: int = 0


	func _init(p_columns: int, p_rows: int) -> void:
		columns = maxi(0, p_columns)
		rows = maxi(1, p_rows)
		cells.resize(columns * rows)
		cells.fill(0)


	func is_bounded() -> bool:
		return columns > 0


	## True when `rect` lies inside the grid and none of its cells are taken.
	func is_free(rect: Rect2i) -> bool:
		if rect.size.x < 1 or rect.size.y < 1 or rect.position.x < 0 or rect.position.y < 0:
			return false
		if rect.end.y > rows or (is_bounded() and rect.end.x > columns):
			return false
		for x in range(rect.position.x, mini(rect.end.x, cells.size() / rows)):
			var column_start := x * rows
			for y in range(rect.position.y, rect.end.y):
				if cells[column_start + y] != 0:
					return false
		return true


	## Mark every cell of `rect` (clipped to the grid) as taken.
	func mark(rect: Rect2i) -> void:
		var end_x := mini(columns, rect.end.x) if is_bounded() else rect.end.x
		if end_x * rows > cells.size():
			var old_size := cells.size()
			cells.resize(end_x * rows)
			for i in range(old_size, cells.size()):
				cells[i] = 0
		for x in range(maxi(0, rect.position.x), end_x):
			for y in range(maxi(0, rect.position.y), mini(rows, rect.end.y)):
				cells[x * rows + y] = 1
		while (_first_open_column + 1) * rows <= cells.size() and _column_is_full(_first_open_column):
			_first_open_column += 1
		if is_bounded():
			while _first_free < columns * rows and cells[(_first_free % columns) * rows + _first_free / columns] != 0:
				_first_free += 1


	func _column_is_full(x: int) -> bool:
		for y in range(rows):
			if cells[x * rows + y] == 0:
				return false
		return true


	## True when no cell is taken.
	func is_empty() -> bool:
		return not cells.has(1)


	## First free rect of `size`, or `GridPacker.NONE`. Row-major on a bounded grid,
	## column-major on an unbounded one (which always finds room unless `size` is too tall).
	func find_free(size: Vector2i) -> Rect2i:
		if size.x < 1 or size.y < 1 or size.y > rows or (is_bounded() and size.x > columns):
			return GridPacker.NONE
		if is_bounded():
			for i in range(_first_free, columns * rows):
				var rect := Rect2i(i % columns, i / columns, size.x, size.y)
				if rect.end.y > rows:
					break
				if is_free(rect):
					return rect
			return GridPacker.NONE
		var x := _first_open_column
		while true:
			for y in range(rows - size.y + 1):
				var rect := Rect2i(x, y, size.x, size.y)
				if is_free(rect):
					return rect
			x += 1
		return GridPacker.NONE  # unreachable: columns past the end are free


## Clamp a footprint so it fits a grid of `columns` × `rows` (`columns` 0 = unbounded).
static func clamp_size(size: Vector2i, columns: int, rows: int) -> Vector2i:
	var w := maxi(1, size.x) if columns <= 0 else clampi(size.x, 1, columns)
	return Vector2i(w, clampi(size.y, 1, maxi(1, rows)))


## Pack a prefix of `sizes` into the smallest block at most `max_cols` × `max_rows`.
## Returns `{count, size: Vector2i, rects: Array[Rect2i]}` with rects relative to the block;
## `count` is how many leading sizes fit (the rest need another block).
static func pack_block(sizes: Array[Vector2i], max_cols: int, max_rows: int) -> Dictionary:
	var min_w := 1
	var cells := 0
	for s in sizes:
		min_w = maxi(min_w, mini(s.x, max_cols))
		cells += s.x * s.y
	# Narrower than `cells / max_rows` can't fit everything, and wider than `cells` can't beat a
	# block that does. When nothing fits everything, full width fits the most.
	var max_w := mini(max_cols, maxi(min_w, cells))
	min_w = clampi(ceili(float(cells) / max_rows), min_w, max_w)
	var best := {"count": 0, "size": Vector2i.ZERO, "rects": [] as Array[Rect2i]}
	for w in range(min_w, max_w + 1):
		var packed := _try_pack(sizes, w, max_rows)
		if _block_is_better(packed.count, packed.size, best):
			best = packed
		if packed.count == sizes.size() and packed.size.y == 1:
			break  # a single full row can't be beaten by a wider block
	return best


## Block for a whole group (see `pack_block` for the result): a single row when it's a few
## one-row controls, else the full page height when it holds a fader, else the narrowest `BLOCK_ROWS`-tall block up to `MAX_BLOCK_COLUMNS` wide,
## else the narrowest full-height one. A group too big for a page gets as much as fits.
static func group_block(sizes: Array[Vector2i], rows: int, max_columns: int) -> Dictionary:
	var cells := 0
	var one_row := true
	var has_fader := false
	for s in sizes:
		cells += s.x * s.y
		one_row = one_row and s.y == 1
		has_fader = has_fader or s == SimpleControlKinds.footprint(SimpleControlKinds.FADER)
	if has_fader:
		# a fader would be squashed in a two-row block: give the group the page height
		var tall := _narrowest_block(sizes, rows, max_columns)
		if not tall.is_empty():
			return tall
	if one_row and cells <= SINGLE_ROW_CELLS:
		var row := _narrowest_block(sizes, 1, max_columns)
		if not row.is_empty():
			return row
	var block := _narrowest_block(sizes, mini(BLOCK_ROWS, rows), mini(MAX_BLOCK_COLUMNS, max_columns))
	if block.is_empty():
		block = _narrowest_block(sizes, rows, max_columns)
	return block if not block.is_empty() else pack_block(sizes, max_columns, rows)


## Narrowest block `height` rows tall (at most `max_w` wide) that fits all of `sizes`, or {}.
static func _narrowest_block(sizes: Array[Vector2i], height: int, max_w: int) -> Dictionary:
	var min_w := 1
	var cells := 0
	for s in sizes:
		min_w = maxi(min_w, s.x)
		cells += s.x * s.y
	for w in range(maxi(min_w, ceili(float(cells) / height)), max_w + 1):
		var packed := _try_pack(sizes, w, height)
		if packed.count == sizes.size():
			return packed
	return {}


## Row-major first fit of a prefix of `sizes` into a `w` × `h` block.
static func _try_pack(sizes: Array[Vector2i], w: int, h: int) -> Dictionary:
	var occ := Occupancy.new(w, h)
	var rects: Array[Rect2i] = []
	var used := Vector2i.ZERO
	for s in sizes:
		var rect := occ.find_free(clamp_size(s, w, h))
		if rect == NONE:
			break
		occ.mark(rect)
		rects.append(rect)
		used = Vector2i(maxi(used.x, rect.end.x), maxi(used.y, rect.end.y))
	return {"count": rects.size(), "size": used, "rects": rects}


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


## Pack `groups` onto pages `rows` tall. Each group is `{id, title, page, items: [{kind, params,
## label?}]}`; groups with the same `page` title share a page, in order of first appearance.
## A page grows to the right up to `max_columns`, then continues on a new page titled after the
## first group (or family of groups) on it. A group is only split when it's wider than
## `max_columns` on its own; groups may carry `family` and `family_title` to be kept together.
## Page titles are made unique ("Controls", "Controls 2"). Returns layout pages
## `{title, groups: [{id, title, rect}], controls: [{kind, params, rect, group, label?}]}`.
static func pack_pages(groups: Array, rows: int, max_columns: int) -> Array[Dictionary]:
	var sections: Array[Dictionary] = []
	var by_title := {}
	for group in groups:
		var title := String(group.get("page", ""))
		if not by_title.has(title):
			by_title[title] = {"title": title, "groups": []}
			sections.append(by_title[title])
		by_title[title].groups.append(group)
	var pages: Array[Dictionary] = []
	for section in sections:
		pages.append_array(_pack_section(section.groups, section.title, rows, max_columns))
	_make_titles_unique(pages)
	return pages


## Pages for one section: its groups in columns, in order, spilling onto more pages past
## `max_columns`. The groups of one family ("Effect Slot 1", "Effect Slot 2", …) stay on one page:
## a family that doesn't fit beside what's already on the page starts a new one, titled after the
## family, unless it's too big for a page of its own anyway.
static func _pack_section(groups: Array, title: String, rows: int, max_columns: int) -> Array[Dictionary]:
	var pages: Array[Dictionary] = []
	var page: Dictionary = {}
	var columns: Columns = null
	var family_end := 0
	groups = groups.duplicate()
	var g := -1
	while g + 1 < groups.size():
		g += 1
		if g >= family_end and _family_end(groups, g) - g > 1 and columns != null:
			_backfill_column(groups, g, columns, rows, max_columns)
		var group: Dictionary = groups[g]
		var page_title := String(group.title)
		if g >= family_end:
			family_end = _family_end(groups, g)
			var family := groups.slice(g, family_end)
			if family.size() > 1:
				page_title = String(group.get("family_title", group.title))
				if columns != null and not columns.is_empty() \
						and not _groups_fit(family, columns.copy(), rows, max_columns) \
						and _groups_fit(family, Columns.new(rows), rows, max_columns):
					columns = null  # start the family on a fresh page
				if columns != null:
					columns.break_column()  # a family gets a column of its own, its groups aligned
		var items: Array = group.items
		var sizes := _item_sizes(items, rows, max_columns)
		var start := 0
		while start < items.size():
			var block := group_block(sizes.slice(start), rows, max_columns)
			if block.count == 0:
				break  # unreachable: sizes are clamped to the grid
			if columns == null or columns.right_edge_for(block.size) > max_columns:
				page = {"title": title if pages.is_empty() or title.is_empty() else page_title,
					"groups": [], "controls": []}
				pages.append(page)
				columns = Columns.new(rows)
			var origin := Rect2i(columns.place(block.size), block.size)
			for i in range(block.count):
				var rect: Rect2i = block.rects[i]
				rect.position += origin.position
				page.controls.append(make_control(items[start + i], rect, group.id))
			page.groups.append({"id": group.id, "title": group.title, "rect": rect_to_array(origin)})
			if page.title.is_empty():
				page.title = group.title
			start += block.count
			page_title = String(group.title)
	return pages


## Before a family starts a column of its own, move the next single-group block that fits under
## what the current column already holds to just before the family (`groups[at]`), so the column
## isn't left half empty. Repeats while something fits.
static func _backfill_column(groups: Array, at: int, columns: Columns, rows: int, max_columns: int) -> void:
	var probe := columns.copy()
	var family_end := _family_end(groups, at)
	var i := family_end
	while i < groups.size():
		var end := _family_end(groups, i)
		if end - i == 1:
			var group: Dictionary = groups[i]
			var block := group_block(_item_sizes(group.items, rows, max_columns), rows, max_columns)
			if block.count == group.items.size() and probe.fits_current_column(block.size):
				probe.place(block.size)
				groups.remove_at(i)
				groups.insert(at, group)
				at += 1
				family_end += 1
				i = family_end
				continue
		i = end


## Index just past the run of groups starting at `start` that share its family (a group without
## one is its own family).
static func _family_end(groups: Array, start: int) -> int:
	var family: String = groups[start].get("family", groups[start].id)
	var end := start + 1
	while end < groups.size() and groups[end].get("family", groups[end].id) == family:
		end += 1
	return end


## True when every group in `groups` fits, whole, on the page `columns` is filling.
static func _groups_fit(groups: Array, columns: Columns, rows: int, max_columns: int) -> bool:
	for group in groups:
		var sizes := _item_sizes(group.items, rows, max_columns)
		var block := group_block(sizes, rows, max_columns)
		if block.count < sizes.size() or columns.right_edge_for(block.size) > max_columns:
			return false
		columns.place(block.size)
	return true


static func _item_sizes(items: Array, rows: int, max_columns: int) -> Array[Vector2i]:
	var sizes: Array[Vector2i] = []
	for item in items:
		sizes.append(clamp_size(SimpleControlKinds.footprint(item.kind), max_columns, rows))
	return sizes


## Suffix repeated page titles with a number: "Controls", "Controls 2", "Controls 3".
static func _make_titles_unique(pages: Array[Dictionary]) -> void:
	var seen := {}
	for page in pages:
		var base := String(page.title)
		var title := base
		var n := 1
		while seen.has(title):
			n += 1
			title = "%s %d" % [base, n]
		seen[title] = true
		page.title = title


## Layout control dictionary for a generated item placed at `rect`.
static func make_control(item: Dictionary, rect: Rect2i, group_id: String) -> Dictionary:
	var control := {"kind": item.kind, "params": item.params.duplicate(), "rect": rect_to_array(rect)}
	if not group_id.is_empty():
		control["group"] = group_id
	if not String(item.get("label", "")).is_empty():
		control["label"] = item.label
	if item.has("stages"):
		control["stages"] = item.stages
	return control


## `[col, row, w, h]` → Rect2i.
static func rect_from_array(a: Array) -> Rect2i:
	return Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))


## Rect2i → `[col, row, w, h]`.
static func rect_to_array(rect: Rect2i) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
