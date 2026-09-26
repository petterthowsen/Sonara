# CollapsingFlowContainer.gd
# Flow layout (children wrap into lines) that hides children once the lines no longer
# fit, instead of growing to fit them. Horizontal flow fills rows left to right and hides
# when the rows exceed the height; vertical flow fills columns and hides on width.
# See CollapsingContainer for priorities, pinning and how hiding works.
@tool
class_name CollapsingFlowContainer extends CollapsingContainer

## Hide children once the wrapped lines take more space than is available.
@export var collapse_lines: bool = true:
	set(value):
		collapse_lines = value
		_relayout()
## Hide a child that is longer than a whole line (wider than a horizontal flow).
@export var collapse_oversized: bool = false:
	set(value):
		collapse_oversized = value
		_relayout()
## Space between children within a line.
@export var separation: int = 4:
	set(value):
		separation = value
		_relayout()
## Space between lines.
@export var line_separation: int = 4:
	set(value):
		line_separation = value
		_relayout()
## Where each line's children go when none of them expand.
@export var alignment: FlowContainer.AlignmentMode = FlowContainer.ALIGNMENT_BEGIN:
	set(value):
		alignment = value
		_relayout()

# Main size the minimum was last computed for; the cross minimum depends on it.
var _min_main_size: float = -1.0


func _notification(what: int) -> void:
	# Base _notification also runs and handles sorting.
	if what == NOTIFICATION_RESIZED and _main(size) != _min_main_size:
		update_minimum_size()


func _get_minimum_size() -> Vector2:
	# Main axis: the longest child that can't be hidden for being oversized. Cross axis:
	# the lines the kept children need at the current main size (like FlowContainer,
	# the minimum height of a horizontal flow depends on its width).
	var candidates := _candidates()
	var kept := _kept(candidates)
	var main_size := _main(size)
	_min_main_size = main_size
	var main := 0.0
	var must_flow: Array[Control] = []
	for c in candidates:
		var m := _main(c.get_combined_minimum_size())
		var is_kept := kept.has(c)
		if is_kept or not collapse_oversized:
			main = maxf(main, m)
		if is_kept or not (collapse_lines or (collapse_oversized and m > main_size)):
			must_flow.append(c)
	var cross := _lines_extent(_flow_lines(must_flow, maxf(main_size, main)))
	return Vector2(cross, main) if vertical else Vector2(main, cross)


func _sort() -> void:
	var candidates := _candidates()
	var main_size := _main(size)
	var cross_size := _cross(size)

	var shown: Array[Control] = []
	var hideable: Array[Control] = []
	var kept := _kept(candidates)
	for c in candidates:
		var is_kept := kept.has(c)
		if collapse_oversized and not is_kept and _main(c.get_combined_minimum_size()) > main_size:
			continue
		shown.append(c)
		if not is_kept:
			hideable.append(c)

	if collapse_lines:
		_sort_by_hide_order(hideable, candidates)
		for c in hideable:
			if _lines_extent(_flow_lines(shown, main_size)) <= cross_size:
				break
			shown.erase(c)

	_collapse_all_but(candidates, shown)
	_layout(_flow_lines(shown, main_size), main_size)


func _layout(lines: Array, main_size: float) -> void:
	var cross_ofs := 0.0
	for line: Array[Control] in lines:
		var line_cross := _line_cross(line)
		var avail := main_size - separation * (line.size() - 1)
		var lengths := {}
		var ofs := 0.0
		if not _distribute(line, avail, lengths):
			var used := 0.0
			for c in line:
				used += lengths[c]
			ofs = _align_offset(alignment, avail - used)
		for c in line:
			var length: float = lengths[c]
			fit_child_in_rect(c, _rect(ofs, cross_ofs, length, line_cross))
			ofs += length + separation
		cross_ofs += line_cross + line_separation


# Greedy wrap: a child starts a new line when it doesn't fit after the previous one.
# Returns an Array of Array[Control].
func _flow_lines(list: Array[Control], main_size: float) -> Array:
	var lines: Array = []
	var line: Array[Control] = []
	var line_len := 0.0
	for c in list:
		var m := _main(c.get_combined_minimum_size())
		if not line.is_empty() and line_len + separation + m > main_size:
			lines.append(line)
			line = []
			line_len = 0.0
		line_len += m if line.is_empty() else separation + m
		line.append(c)
	if not line.is_empty():
		lines.append(line)
	return lines


func _lines_extent(lines: Array) -> float:
	if lines.is_empty():
		return 0.0
	var total := line_separation * (lines.size() - 1.0)
	for line: Array[Control] in lines:
		total += _line_cross(line)
	return total


func _line_cross(line: Array[Control]) -> float:
	var cross := 0.0
	for c in line:
		cross = maxf(cross, _cross(c.get_combined_minimum_size()))
	return cross
