# CollapsingBoxContainer.gd
# Box layout that hides children that don't fit, instead of growing to fit them.
# See CollapsingContainer for priorities, pinning and how hiding works.
@tool
class_name CollapsingBoxContainer extends CollapsingContainer

## Hide children that don't fit along the layout direction.
@export var collapse_main_axis: bool = true:
	set(value):
		collapse_main_axis = value
		_relayout()
## Hide children whose minimum size across the layout direction exceeds the available space.
@export var collapse_cross_axis: bool = false:
	set(value):
		collapse_cross_axis = value
		_relayout()
@export var separation: int = 4:
	set(value):
		separation = value
		_relayout()
## Where children go when none expand and there is spare space.
@export var alignment: BoxContainer.AlignmentMode = BoxContainer.ALIGNMENT_BEGIN:
	set(value):
		alignment = value
		_relayout()


func _get_minimum_size() -> Vector2:
	# Depends only on the candidate set, never on what is currently collapsed, so
	# collapsing can't feed back into the size our parent gives us.
	var main := 0.0
	var cross := 0.0
	var count := 0
	var candidates := _candidates()
	var kept := _kept(candidates)
	for c in candidates:
		var ms := c.get_combined_minimum_size()
		var pinned := kept.has(c)
		if pinned or not collapse_main_axis:
			main += _main(ms)
			count += 1
		if pinned or not collapse_cross_axis:
			cross = maxf(cross, _cross(ms))
	if count > 1:
		main += separation * (count - 1)
	return Vector2(cross, main) if vertical else Vector2(main, cross)


func _sort() -> void:
	var candidates := _candidates()
	var main_size := _main(size)
	var cross_size := _cross(size)

	var shown: Array[Control] = []
	var hideable: Array[Control] = []
	var kept := _kept(candidates)
	for c in candidates:
		var pinned := kept.has(c)
		if collapse_cross_axis and not pinned and _cross(c.get_combined_minimum_size()) > cross_size:
			continue
		shown.append(c)
		if not pinned:
			hideable.append(c)

	if collapse_main_axis:
		_sort_by_hide_order(hideable, candidates)
		for c in hideable:
			if _main_needed(shown) <= main_size:
				break
			shown.erase(c)

	_collapse_all_but(candidates, shown)
	_layout(shown, main_size, cross_size)


func _layout(shown: Array[Control], main_size: float, cross_size: float) -> void:
	if shown.is_empty():
		return
	var avail := main_size - separation * (shown.size() - 1)
	var lengths := {}
	var ofs := 0.0
	if not _distribute(shown, avail, lengths):
		var used := 0.0
		for c in shown:
			used += lengths[c]
		ofs = _align_offset(alignment, avail - used)
	for c in shown:
		var length: float = lengths[c]
		fit_child_in_rect(c, _rect(ofs, 0.0, length, cross_size))
		ofs += length + separation


func _main_needed(list: Array[Control]) -> float:
	var total := 0.0
	for c in list:
		total += _main(c.get_combined_minimum_size())
	if list.size() > 1:
		total += separation * (list.size() - 1)
	return total
