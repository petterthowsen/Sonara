# Stage view edit operations (spec 051 T-021, REQ-022): move, end-drag resize and rotate, clamp to
# the room, multi-move and height. Pure functions on stage-state dictionaries.
extends TestBase

var _edit: GDScript
var _stage: GDScript
var _room: Object


func suite_name() -> String:
	return "Stage edit"


func run_tests() -> void:
	_edit = load("res://stage/StageEdit.gd")
	_stage = load("res://data/Stage.gd")
	_room = _stage.new()
	_room.set_room_size(20.0, 30.0, 10.0)
	_test_move()
	_test_clamp_with_size_and_rotation()
	_test_multi_move()
	_test_drag_end()
	_test_height()
	_test_size_rotation()


func _src(x: float, y: float, size := 0.0, rotation := 0.0, z := 1.2) -> Dictionary:
	return {"x": x, "y": y, "z": z, "size": size, "rotation": rotation}


func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.001


func _test_move() -> void:
	var s := _src(5.0, 5.0)
	var m: Dictionary = _edit.move_to(_room, s, Vector2(8.0, 12.0))
	_assert(m.x == 8.0 and m.y == 12.0 and m.z == 1.2, "move sets x and y, keeps z")
	_assert(s.x == 5.0, "the input is not modified")
	var out: Dictionary = _edit.move_to(_room, s, Vector2(-4.0, 99.0))
	_assert(out.x == 0.0 and out.y == 30.0, "a dot stops at the walls")


func _test_clamp_with_size_and_rotation() -> void:
	# A 6 m bar along X keeps 3 m from the side walls.
	var bar: Dictionary = _edit.move_to(_room, _src(10.0, 10.0, 6.0, 0.0), Vector2(0.0, 10.0))
	_assert(_near(bar.x, 3.0), "6 m bar at rotation 0 stops 3 m from the left wall (got %s)" % bar.x)
	# Rotated 90 degrees it spans Y instead.
	var tall: Dictionary = _edit.move_to(_room, _src(10.0, 10.0, 6.0, 90.0), Vector2(0.0, 0.0))
	_assert(_near(tall.x, 0.0) and _near(tall.y, 3.0), "6 m bar at 90 degrees stops 3 m from the front wall (got %s, %s)" % [tall.x, tall.y])
	# At 45 degrees the half extent is size/2 * cos(45).
	var diag: Dictionary = _edit.move_to(_room, _src(10.0, 10.0, 10.0, 45.0), Vector2(0.0, 0.0))
	_assert(_near(diag.x, 5.0 * cos(PI / 4.0)), "diagonal bar clamps by its projection")
	var ends: Array = _edit.ends(diag)
	for e: Vector2 in ends:
		_assert(e.x > -0.001 and e.y > -0.001, "both ends of the clamped bar are in the room")
	# A bar longer than the room axis is centred on it.
	var small = _stage.new()
	small.set_room_size(4.0, 30.0, 10.0)
	var wide: Dictionary = _edit.clamp_state(small, _src(1.0, 5.0, 8.0, 0.0))
	_assert(_near(wide.x, 2.0), "a bar wider than the room is centred (got %s)" % wide.x)
	var high: Dictionary = _edit.clamp_state(_room, _src(5.0, 5.0, 0.0, 0.0, 40.0))
	_assert(high.z == 10.0, "clamp limits the height to the ceiling")


func _test_multi_move() -> void:
	var a := _src(5.0, 5.0)
	var b := _src(8.0, 9.0)
	var moved: Array = _edit.move_by(_room, [a, b], Vector2(2.0, 1.0))
	_assert(moved[0].x == 7.0 and moved[0].y == 6.0 and moved[1].x == 10.0 and moved[1].y == 10.0, "both move by the delta")
	_assert(_near(moved[1].x - moved[0].x, 3.0) and _near(moved[1].y - moved[0].y, 4.0), "offsets are kept")
	# Pushed against the right wall: the group stops when the first source arrives.
	var edge: Array = _edit.move_by(_room, [a, b], Vector2(50.0, 0.0))
	_assert(_near(edge[1].x, 20.0) and _near(edge[0].x, 17.0), "the group stops at the wall with offsets intact")
	_assert(_near(edge[0].y, 5.0), "the other axis is untouched")
	# Pushed past a corner: both axes are limited independently.
	var corner: Array = _edit.move_by(_room, [a, b], Vector2(-50.0, -50.0))
	_assert(_near(corner[0].x, 0.0) and _near(corner[0].y, 0.0), "the leading source reaches the corner")
	_assert(_near(corner[1].x, 3.0) and _near(corner[1].y, 4.0), "the other keeps its offset")
	# A wide bar limits the whole group by its half extent.
	var barred: Array = _edit.move_by(_room, [_src(10.0, 5.0, 8.0, 0.0), _src(12.0, 5.0)], Vector2(-50.0, 0.0))
	_assert(_near(barred[0].x, 4.0) and _near(barred[1].x, 6.0), "a bar in the group limits the move")
	_assert(_edit.move_by(_room, [], Vector2(1, 1)).is_empty(), "an empty selection moves nothing")


func _test_drag_end() -> void:
	var dot := _src(10.0, 10.0)
	# Drag end B to the right: size doubles the distance, rotation 0.
	var r: Dictionary = _edit.drag_end(_room, dot, 1, Vector2(13.0, 10.0))
	_assert(_near(r.size, 6.0) and _near(r.rotation, 0.0) and r.x == 10.0 and r.y == 10.0, "end B right: 6 m at 0 degrees, centre fixed")
	# End B straight up (toward the back wall): rotation 90.
	var up: Dictionary = _edit.drag_end(_room, dot, 1, Vector2(10.0, 12.0))
	_assert(_near(up.size, 4.0) and _near(up.rotation, 90.0), "end B toward the back wall: 90 degrees")
	# End A dragged left is the same bar as end B dragged right.
	var left: Dictionary = _edit.drag_end(_room, dot, 0, Vector2(7.0, 10.0))
	_assert(_near(left.size, 6.0) and _near(left.rotation, 0.0), "end A dragged left keeps rotation 0")
	# End A dragged right flips the bar: rotation 180 (wrapped).
	var flipped: Dictionary = _edit.drag_end(_room, dot, 0, Vector2(13.0, 10.0))
	_assert(_near(absf(flipped.rotation), 180.0), "end A dragged to the right turns the bar around (got %s)" % flipped.rotation)
	# Clamped by the wall: the opposite end must stay inside too.
	var near_wall := _src(2.0, 10.0)
	var cl: Dictionary = _edit.drag_end(_room, near_wall, 1, Vector2(8.0, 10.0))
	_assert(_near(cl.size, 4.0), "the bar shortens so the other end stays in the room (got %s)" % cl.size)
	for e: Vector2 in _edit.ends(cl):
		_assert(e.x > -0.001, "both ends are inside after the clamp")
	# Dragged onto the centre: a dot again, rotation kept.
	var bar := _src(10.0, 10.0, 4.0, 30.0)
	var back: Dictionary = _edit.drag_end(_room, bar, 1, Vector2(10.02, 10.0))
	_assert(back.size == 0.0 and _near(back.rotation, 30.0), "dragged to the centre: size 0, rotation kept")
	# Snapping.
	var snapped: Dictionary = _edit.drag_end(_room, dot, 1, Vector2(13.0, 10.9), 15.0)
	_assert(_near(snapped.rotation, 15.0), "rotation snaps to 15 degrees (got %s)" % snapped.rotation)
	# Size is capped by the room's longer side.
	var huge = _stage.new()
	huge.set_room_size(10.0, 12.0, 5.0)
	var capped: Dictionary = _edit.drag_end(huge, _src(5.0, 6.0), 1, Vector2(5.0, 12.0))
	_assert(capped.size <= 12.0 + 0.001, "size is capped (got %s)" % capped.size)
	_assert(_near(_edit.wrap_rotation(190.0), -170.0) and _near(_edit.wrap_rotation(-190.0), 170.0), "rotation wraps to -180..180")


func _test_height() -> void:
	var out: Array = _edit.set_height(_room, [_src(1, 1, 0, 0, 1.0), _src(2, 2, 0, 0, 5.0)], 4.0)
	_assert(out[0].z == 4.0 and out[1].z == 4.0 and out[0].x == 1.0, "height applies to every selected source, x and y untouched")
	var capped: Array = _edit.set_height(_room, [_src(1, 1)], 99.0)
	_assert(capped[0].z == 10.0, "height is capped at the ceiling")
	var floor_: Array = _edit.set_height(_room, [_src(1, 1)], -3.0)
	_assert(floor_[0].z == 0.0, "height is not below the floor")


func _test_size_rotation() -> void:
	var sized: Array = _edit.set_size(_room, [_src(10, 10, 0, 0), _src(10, 10, 0, 90)], 4.0)
	_assert(_near(sized[0].size, 4.0) and _near(sized[1].size, 4.0), "size applies to every selected source")
	var tiny: Array = _edit.set_size(_room, [_src(10, 10, 2.0, 0)], 0.04)
	_assert(tiny[0].size == 0.0, "a size below the minimum becomes a dot")
	var big: Array = _edit.set_size(_room, [_src(10, 10, 0, 0)], 500.0)
	_assert(big[0].size <= _room.width + 0.001, "size is capped so the bar fits the room")
	var turned: Array = _edit.set_rotation(_room, [_src(10, 10, 4.0, 0)], 190.0)
	_assert(_near(turned[0].rotation, -170.0) and _near(turned[0].size, 4.0), "rotation wraps, size kept when it fits")
