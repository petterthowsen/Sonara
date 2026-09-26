# test_collapsing_box_container.gd
# CollapsingBoxContainer: which children collapse at a given size, minimum size, layout.
extends TestBase


func suite_name() -> String:
	return "CollapsingBoxContainer"


func run_tests() -> void:
	await _test_all_fit()
	await _test_hides_last_first()
	await _test_hides_first_first()
	await _test_priority_and_pinned()
	await _test_minimum_size()
	await _test_min_visible_children()
	await _test_cross_axis()
	await _test_vertical_and_expand()
	await _test_user_hidden_stays_hidden()
	await _test_regrow_and_signal()


# Three 50px children, separation 4 -> 158px to show all.
func _make(width: float, height: float = 20.0) -> CollapsingBoxContainer:
	var box := CollapsingBoxContainer.new()
	for i in 3:
		var c := Control.new()
		c.name = "C%d" % i
		c.custom_minimum_size = Vector2(50, 10)
		box.add_child(c)
	root.add_child(box)
	box.size = Vector2(width, height)
	return box


func _settle() -> void:
	await process_frame
	await process_frame


func _shown(box: CollapsingBoxContainer) -> String:
	var names: PackedStringArray = []
	for c in box.get_children():
		if (c as Control).visible:
			names.append(c.name)
	return ",".join(names)


func _test_all_fit() -> void:
	var box := _make(158)
	await _settle()
	_assert(_shown(box) == "C0,C1,C2", "all fit at exact width (got %s)" % _shown(box))
	_assert(box.get_child(2).position.x == 108, "third child placed after separations")
	box.queue_free()


func _test_hides_last_first() -> void:
	var box := _make(157)
	await _settle()
	_assert(_shown(box) == "C0,C1", "one px short hides the last (got %s)" % _shown(box))
	box.size.x = 40
	await _settle()
	_assert(_shown(box) == "", "nothing fits -> all hidden (got %s)" % _shown(box))
	box.queue_free()


func _test_hides_first_first() -> void:
	var box := _make(104)
	box.hide_order = CollapsingBoxContainer.HideOrder.FIRST_FIRST
	await _settle()
	_assert(_shown(box) == "C1,C2", "FIRST_FIRST hides the first (got %s)" % _shown(box))
	_assert(box.get_child(1).position.x == 0, "first shown child starts at 0")
	box.queue_free()


func _test_priority_and_pinned() -> void:
	var box := _make(104)
	CollapsingBoxContainer.set_child_priority(box.get_child(0), -1)
	await _settle()
	_assert(_shown(box) == "C1,C2", "lower priority hides before position order (got %s)" % _shown(box))
	CollapsingBoxContainer.set_child_pinned(box.get_child(0), true)
	box.size.x = 50
	await _settle()
	_assert(_shown(box) == "C0", "pinned child survives (got %s)" % _shown(box))
	box.queue_free()


func _test_minimum_size() -> void:
	var box := _make(200)
	await _settle()
	_assert(box.get_combined_minimum_size() == Vector2(0, 10), "no pinned -> zero main min (got %s)" % box.get_combined_minimum_size())
	CollapsingBoxContainer.set_child_pinned(box.get_child(0), true)
	CollapsingBoxContainer.set_child_pinned(box.get_child(2), true)
	_assert(box.get_combined_minimum_size() == Vector2(104, 10), "pinned children and their separation count")
	box.collapse_main_axis = false
	_assert(box.get_combined_minimum_size().x == 158, "non-collapsing main axis counts everything")
	box.queue_free()


func _test_min_visible_children() -> void:
	var box := _make(10)
	box.min_visible_children = 2
	await _settle()
	_assert(_shown(box) == "C0,C1", "LAST_FIRST keeps the first 2 (got %s)" % _shown(box))
	_assert(box.get_combined_minimum_size().x == 104, "kept children count toward min size")
	box.hide_order = CollapsingBoxContainer.HideOrder.FIRST_FIRST
	await _settle()
	_assert(_shown(box) == "C1,C2", "FIRST_FIRST keeps the last 2 (got %s)" % _shown(box))
	CollapsingBoxContainer.set_child_pinned(box.get_child(0), true)
	await _settle()
	_assert(_shown(box) == "C0,C2", "pinned child counts toward the minimum (got %s)" % _shown(box))
	box.queue_free()


func _test_cross_axis() -> void:
	var box := _make(200, 30)
	(box.get_child(1) as Control).custom_minimum_size.y = 40
	await _settle()
	_assert(_shown(box) == "C0,C1,C2", "cross collapse off keeps tall child")
	_assert(box.get_combined_minimum_size().y == 40, "cross min includes tall child when not collapsing")
	box.collapse_cross_axis = true
	await _settle()
	_assert(_shown(box) == "C0,C2", "tall child hidden when cross collapse on (got %s)" % _shown(box))
	_assert(box.get_child(2).position.x == 54, "remaining children close the gap")
	box.queue_free()


func _test_vertical_and_expand() -> void:
	var box := _make(30, 200)
	box.vertical = true
	(box.get_child(1) as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
	await _settle()
	_assert(_shown(box) == "C0,C1,C2", "vertical: all fit")
	var mid := box.get_child(1) as Control
	_assert(mid.size.y == 200 - 10 - 10 - 8, "expander takes the rest (got %s)" % mid.size.y)
	_assert(box.get_child(2).position.y == 190, "last child pushed to the end")
	box.size.y = 30
	await _settle()
	_assert(_shown(box) == "C0,C1", "vertical: short height hides last (got %s)" % _shown(box))
	box.queue_free()


func _test_user_hidden_stays_hidden() -> void:
	var box := _make(157)
	await _settle()
	(box.get_child(0) as Control).visible = false
	await _settle()
	_assert(_shown(box) == "C1,C2", "user-hidden child frees room for a collapsed one (got %s)" % _shown(box))
	box.size.x = 500
	await _settle()
	_assert(_shown(box) == "C1,C2", "user-hidden child stays hidden with room (got %s)" % _shown(box))
	box.queue_free()


func _test_regrow_and_signal() -> void:
	var box := _make(157)
	var seen: Array = []
	box.collapsed_changed.connect(func(list: Array[Control]) -> void: seen.append(list.size()))
	await _settle()
	box.size.x = 60
	await _settle()
	box.size.x = 300
	await _settle()
	_assert(_shown(box) == "C0,C1,C2", "growing shows everything again")
	_assert(seen == [1, 2, 0], "collapsed_changed fires once per change (got %s)" % [seen])
	var extra := box.get_child(2) as Control
	box.size.x = 60
	await _settle()
	box.remove_child(extra)
	_assert(extra.visible, "removed child is handed back visible")
	extra.free()
	box.queue_free()
