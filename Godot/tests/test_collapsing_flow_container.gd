# test_collapsing_flow_container.gd
# CollapsingFlowContainer: wrapping, which children collapse when lines overflow, minimum size.
extends TestBase


func suite_name() -> String:
	return "CollapsingFlowContainer"


func run_tests() -> void:
	await _test_wraps_when_all_fit()
	await _test_hides_when_lines_overflow()
	await _test_first_first_and_min_visible()
	await _test_minimum_size()
	await _test_oversized()
	await _test_vertical_and_expand()
	await _test_regrow()


# Three 50x10 children, separations 4. At width 104 two fit per row: rows 10 + 4 + 10 = 24.
func _make(width: float, height: float) -> CollapsingFlowContainer:
	var flow := CollapsingFlowContainer.new()
	for i in 3:
		var c := Control.new()
		c.name = "C%d" % i
		c.custom_minimum_size = Vector2(50, 10)
		flow.add_child(c)
	root.add_child(flow)
	flow.size = Vector2(width, height)
	return flow


func _settle() -> void:
	await process_frame
	await process_frame


func _shown(flow: CollapsingFlowContainer) -> String:
	var names: PackedStringArray = []
	for c in flow.get_children():
		if (c as Control).visible:
			names.append(c.name)
	return ",".join(names)


func _pos(flow: CollapsingFlowContainer, i: int) -> Vector2:
	return (flow.get_child(i) as Control).position


func _test_wraps_when_all_fit() -> void:
	var flow := _make(104, 24)
	await _settle()
	_assert(_shown(flow) == "C0,C1,C2", "two rows fit (got %s)" % _shown(flow))
	_assert(_pos(flow, 1) == Vector2(54, 0), "second child on first row (got %s)" % _pos(flow, 1))
	_assert(_pos(flow, 2) == Vector2(0, 14), "third child wraps to second row (got %s)" % _pos(flow, 2))
	flow.queue_free()


func _test_hides_when_lines_overflow() -> void:
	var flow := _make(104, 23)
	await _settle()
	_assert(_shown(flow) == "C0,C1", "second row doesn't fit -> last hidden (got %s)" % _shown(flow))
	flow.size.x = 60
	await _settle()
	_assert(_shown(flow) == "C0", "narrower: one per row, only one row fits (got %s)" % _shown(flow))
	flow.size.y = 5
	await _settle()
	_assert(_shown(flow) == "", "nothing fits -> all hidden (got %s)" % _shown(flow))
	flow.queue_free()


func _test_first_first_and_min_visible() -> void:
	var flow := _make(104, 10)
	flow.hide_order = CollapsingContainer.HideOrder.FIRST_FIRST
	await _settle()
	_assert(_shown(flow) == "C1,C2", "FIRST_FIRST hides the first (got %s)" % _shown(flow))
	_assert(_pos(flow, 1) == Vector2(0, 0), "remaining children reflow from the start")
	flow.hide_order = CollapsingContainer.HideOrder.LAST_FIRST
	flow.min_visible_children = 3
	await _settle()
	_assert(_shown(flow) == "C0,C1,C2", "min_visible_children keeps all (got %s)" % _shown(flow))
	_assert(flow.get_combined_minimum_size().y == 24, "kept children's rows count toward min height")
	flow.queue_free()


func _test_minimum_size() -> void:
	var flow := _make(104, 50)
	await _settle()
	_assert(flow.get_combined_minimum_size() == Vector2(50, 0), "min: widest child, no rows (got %s)" % flow.get_combined_minimum_size())
	flow.collapse_lines = false
	_assert(flow.get_combined_minimum_size().y == 24, "not collapsing lines: rows count")
	flow.size.x = 200
	await _settle()
	_assert(flow.get_combined_minimum_size().y == 10, "min height follows width (got %s)" % flow.get_combined_minimum_size().y)
	flow.queue_free()


func _test_oversized() -> void:
	var flow := _make(104, 50)
	(flow.get_child(1) as Control).custom_minimum_size.x = 120
	await _settle()
	_assert(flow.get_combined_minimum_size().x == 120, "oversized child counts toward min width")
	flow.collapse_oversized = true
	await _settle()
	_assert(_shown(flow) == "C0,C2", "oversized child hidden (got %s)" % _shown(flow))
	_assert(flow.get_combined_minimum_size().x == 0, "only kept children count toward min width")
	CollapsingContainer.set_child_pinned(flow.get_child(0), true)
	_assert(flow.get_combined_minimum_size().x == 50, "pinned child sets min width (got %s)" % flow.get_combined_minimum_size())
	_assert(_pos(flow, 2) == Vector2(54, 0), "others share the row")
	flow.queue_free()


func _test_vertical_and_expand() -> void:
	var flow := _make(24, 104)
	flow.vertical = true
	for c in flow.get_children():
		(c as Control).custom_minimum_size = Vector2(10, 50)
	(flow.get_child(2) as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
	await _settle()
	_assert(_shown(flow) == "C0,C1,C2", "vertical: two columns fit (got %s)" % _shown(flow))
	_assert(_pos(flow, 2) == Vector2(14, 0), "third child starts second column (got %s)" % _pos(flow, 2))
	_assert((flow.get_child(2) as Control).size.y == 104, "expander fills its column")
	flow.size.x = 20
	await _settle()
	_assert(_shown(flow) == "C0,C1", "vertical: narrow width drops second column (got %s)" % _shown(flow))
	flow.queue_free()


func _test_regrow() -> void:
	var flow := _make(104, 10)
	var seen: Array = []
	flow.collapsed_changed.connect(func(list: Array[Control]) -> void: seen.append(list.size()))
	await _settle()
	flow.size.y = 100
	await _settle()
	_assert(_shown(flow) == "C0,C1,C2", "growing shows everything again")
	_assert(seen == [1, 0], "collapsed_changed per change (got %s)" % [seen])
	flow.queue_free()
