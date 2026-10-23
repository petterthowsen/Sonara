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
	_test_snapping()
	_test_rectangle()
	_test_depth()
	_test_section_layout()
	_test_section_minimum()
	_test_section_grow()


func _src(x: float, y: float, size := 0.0, rotation := 0.0, z := 1.2) -> Dictionary:
	return {"x": x, "y": y, "z": z, "size": size, "rotation": rotation}


## A rectangle source: size x depth, optionally a Section of `players`.
func _rect(x: float, y: float, size: float, depth: float, rotation := 0.0, players := 0) -> Dictionary:
	var s := _src(x, y, size, rotation)
	s["depth"] = depth
	if players > 0:
		s["display"] = 1
		s["players"] = players
	return s


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


func _test_snapping() -> void:
	var s := _src(10.0, 10.0)
	var snapped_move: Dictionary = _edit.move_to(_room, s, Vector2(3.37, 4.81), _edit.step_m(true, false))
	_assert(_near(snapped_move.x, 3.0) and _near(snapped_move.y, 5.0), "a move to (3.37, 4.81) snaps to (3, 5)")
	var fine_move: Dictionary = _edit.move_to(_room, s, Vector2(3.37, 4.81), _edit.step_m(true, true))
	_assert(_near(fine_move.x, 3.4) and _near(fine_move.y, 4.8), "with the fine step it is (3.4, 4.8)")
	var free_move: Dictionary = _edit.move_to(_room, s, Vector2(3.37, 4.81), _edit.step_m(false, false))
	_assert(_near(free_move.x, 3.37) and _near(free_move.y, 4.81), "snapping off: the move is free (Shift too)")
	_assert(_edit.step_m(false, true) == 0.0 and _edit.step_deg(false, true) == 0.0, "off means step 0")
	_assert(_edit.step_deg(true, false) == 15.0 and _edit.step_deg(true, true) == 1.0, "rotation steps 15 and 1")
	# End drag: size 2.6 -> 3.0 (fine: 2.6); rotation 22 -> 15 (fine: 22).
	var dot := _src(10.0, 10.0)
	var tip := Vector2(10.0, 10.0) + Vector2.from_angle(deg_to_rad(22.0)) * 1.3
	var snap: Dictionary = _edit.drag_end(_room, dot, 1, tip, _edit.step_deg(true, false), _edit.step_m(true, false))
	_assert(_near(snap.size, 3.0) and _near(snap.rotation, 15.0), "end drag snaps size 2.6 to 3.0 and rotation 22 to 15 (got %s, %s)" % [snap.size, snap.rotation])
	var fine: Dictionary = _edit.drag_end(_room, dot, 1, tip, _edit.step_deg(true, true), _edit.step_m(true, true))
	_assert(_near(fine.size, 2.6) and _near(fine.rotation, 22.0), "fine step keeps 2.6 m and 22 degrees (got %s, %s)" % [fine.size, fine.rotation])
	# Multi-move: the dragged (anchor) source snaps, the others keep their offsets.
	var a := _src(5.0, 5.0)
	var b := _src(8.3, 9.4)
	var moved: Array = _edit.move_by(_room, [a, b], Vector2(2.37, 1.81), 0, 1.0)
	_assert(_near(moved[0].x, 7.0) and _near(moved[0].y, 7.0), "the anchor lands on the grid (got %s, %s)" % [moved[0].x, moved[0].y])
	_assert(_near(moved[1].x - moved[0].x, 3.3) and _near(moved[1].y - moved[0].y, 4.4), "the other source keeps its offset")
	var anchored_b: Array = _edit.move_by(_room, [a, b], Vector2(2.0, 1.0), 1, 1.0)
	_assert(_near(anchored_b[1].x, 10.0) and _near(anchored_b[1].y, 10.0), "anchoring the second source snaps its centre (8.3+2, 9.4+1 -> 10, 10)")


func _test_rectangle() -> void:
	# A 4 x 2 m source at 30 degrees: the corners are centre +- 2 along the line, +- 1 across it.
	var s := _rect(10.0, 10.0, 4.0, 2.0, 30.0)
	var c: Array = _edit.corners(s)
	var d := Vector2.from_angle(deg_to_rad(30.0))
	var n := Vector2(-d.y, d.x)
	var centre := Vector2(10.0, 10.0)
	var want := [centre - d * 2.0 - n, centre + d * 2.0 - n, centre + d * 2.0 + n, centre - d * 2.0 + n]
	for i in 4:
		_assert(c[i].distance_to(want[i]) < 0.001, "corner %d of the 30 degree rectangle" % i)
	_assert(_near(c[0].distance_to(c[1]), 4.0) and _near(c[1].distance_to(c[2]), 2.0), "side lengths are size and depth")
	_assert(_edit.contains(s, centre + d * 1.9) and not _edit.contains(s, centre + d * 2.2), "contains: inside along the line only")
	_assert(_edit.contains(s, centre + n * 0.9) and not _edit.contains(s, centre + n * 1.2), "contains: depth is across the line")
	# The whole rectangle stays in the room: a 6 x 2 m bar at 0 degrees keeps 1 m from the front wall.
	var near_front: Dictionary = _edit.move_to(_room, _rect(10.0, 10.0, 6.0, 2.0), Vector2(0.0, 0.0))
	_assert(_near(near_front.x, 3.0) and _near(near_front.y, 1.0), "clamp keeps half the depth from the wall (got %s, %s)" % [near_front.x, near_front.y])
	var turned: Dictionary = _edit.move_to(_room, _rect(10.0, 10.0, 6.0, 2.0, 90.0), Vector2(0.0, 0.0))
	_assert(_near(turned.x, 1.0) and _near(turned.y, 3.0), "rotated 90: the depth runs along X (got %s, %s)" % [turned.x, turned.y])
	for corner: Vector2 in _edit.corners(_edit.move_to(_room, _rect(10.0, 10.0, 6.0, 2.0, 30.0), Vector2(-5.0, 99.0))):
		_assert(corner.x > -0.001 and corner.x < 20.001 and corner.y > -0.001 and corner.y < 30.001, "every corner is in the room after a clamp")
	_assert(_edit.half_extent(0.0, 0.0, 2.0) == Vector2.ZERO, "a dot has no extent whatever its depth")


func _test_depth() -> void:
	# A depth drag on a rotated source: the pointer 1.5 m from the line on its normal -> 3 m, centre fixed.
	var s := _rect(10.0, 15.0, 4.0, 2.0, 90.0)
	# Rotated 90 degrees the normal points along -X.
	var out: Dictionary = _edit.drag_edge(_room, s, Vector2(10.0 - 1.5, 15.0))
	_assert(_near(out.depth, 3.0) and _near(out.x, 10.0) and _near(out.y, 15.0), "depth drag on a rotated source (got %s)" % out.depth)
	var other: Dictionary = _edit.drag_edge(_room, s, Vector2(10.0 + 1.5, 15.0))
	_assert(_near(other.depth, 3.0), "the other edge gives the same, symmetric about the centre")
	var along: Dictionary = _edit.drag_edge(_room, s, Vector2(10.0, 15.0 + 4.0))
	_assert(out.size == s.size and along.depth == _edit.MIN_DEPTH, "a pointer on the line gives the minimum depth; size untouched")
	_assert(_near(_edit.drag_edge(_room, s, Vector2(10.0 - 1.3, 15.0), 1.0).depth, 3.0), "depth snaps to whole meters (2.6 -> 3)")
	_assert(_near(_edit.drag_edge(_room, s, Vector2(10.0 - 1.3, 15.0), 0.1).depth, 2.6), "and to 0.1 m with the fine step")
	# Against the back wall: centre 2 m from it, rotation 0 -> depth at most 4 m.
	var back := _rect(10.0, 28.0, 4.0, 2.0)
	var wall: Dictionary = _edit.drag_edge(_room, back, Vector2(10.0, 28.0 + 9.0))
	_assert(_near(wall.depth, 4.0) and _near(wall.y, 28.0), "the depth drag stops at the back wall (got %s)" % wall.depth)
	var set: Array = _edit.set_depth(_room, [back], 50.0)
	_assert(set[0].depth <= 30.0 + 0.001 and set[0].y + set[0].depth * 0.5 <= 30.001, "set_depth keeps the rectangle in the room")
	_assert(_edit.set_depth(_room, [back], 0.0)[0].depth == _edit.MIN_DEPTH, "depth has a minimum")
	# Size edits know about depth: a 2 m deep source at 90 degrees is at most 30 m long, at 0 at most 20.
	_assert(_near(_edit.set_size(_room, [_rect(10.0, 15.0, 4.0, 2.0)], 99.0)[0].size, 20.0), "size limited by the room width")
	# A rotation that no longer fits shrinks the depth (here the room is 2 m wide).
	var narrow = _stage.new()
	narrow.set_room_size(2.0, 30.0, 10.0)
	var rot: Array = _edit.set_rotation(narrow, [_rect(1.0, 15.0, 3.0, 3.0, 0.0)], 90.0)
	_assert(rot[0].depth <= 2.0 + 0.001, "rotating into a narrow room shortens the depth (got %s)" % rot[0].depth)


func _test_section_layout() -> void:
	# REQ-016: 12 players in 8 x 2.4 m -> 6 columns x 2 rows.
	var grid: Vector2i = _edit.section_grid(12, 8.0, 2.4)
	_assert(grid == Vector2i(6, 2), "12 players in 8 x 2.4 m: 6 x 2 (got %s)" % grid)
	var s := _rect(10.0, 10.0, 8.0, 2.4, 0.0, 12)
	var pts: Array = _edit.player_positions(s)
	_assert(pts.size() == 12, "one position per player")
	var xs := {}
	var ys := {}
	for p: Vector2 in pts:
		_assert(_edit.contains(s, p), "every player is inside the rectangle")
		xs[snappedf(p.x, 0.001)] = true
		ys[snappedf(p.y, 0.001)] = true
	_assert(xs.size() == 6 and ys.size() == 2, "6 distinct columns and 2 rows (got %d, %d)" % [xs.size(), ys.size()])
	var col_x: Array = xs.keys()
	col_x.sort()
	for i in range(1, col_x.size()):
		_assert(_near(col_x[i] - col_x[i - 1], 8.0 / 6.0), "equal column spacing")
	var row_y: Array = ys.keys()
	row_y.sort()
	_assert(_near(row_y[1] - row_y[0], 1.2), "row spacing is the depth over the rows")
	# The fewest empty seats wins: 7 players in 8 x 2.4 -> one row of 7, none empty.
	_assert(_edit.section_grid(7, 8.0, 2.4) == Vector2i(7, 1), "7 players in 8 x 2.4 m: one row of 7")
	# 7 in 4 x 2.4 -> 4 x 2 with one empty seat; the short last row is centred.
	var uneven: Array = _edit.player_positions(_rect(10.0, 10.0, 4.0, 2.4, 0.0, 7))
	_assert(_edit.section_grid(7, 4.0, 2.4) == Vector2i(4, 2), "7 in 4 x 2.4: 4 x 2")
	var last_row: Array = uneven.slice(4)
	var mid := 0.0
	for p: Vector2 in last_row:
		mid += p.x
	_assert(_near(mid / 3.0, 10.0), "the last, shorter row is centred (mean x %s)" % (mid / 3.0))
	# A room too small for the footprint: closest cell shape, no error, players still inside.
	var tight := _rect(10.0, 10.0, 4.0, 3.0, 0.0, 64)
	var crowd: Array = _edit.player_positions(tight)
	_assert(crowd.size() == 64, "64 players in a too-small rectangle still get positions")
	for p: Vector2 in crowd:
		_assert(_edit.contains(tight, p), "crowded players stay inside")
	_assert(_edit.player_positions(_rect(10.0, 10.0, 0.0, 2.0, 0.0, 8)).is_empty(), "a dot has no player icons")
	# A rotated section keeps its players inside.
	var tilted := _rect(10.0, 10.0, 6.0, 2.4, 40.0, 12)
	for p: Vector2 in _edit.player_positions(tilted):
		_assert(_edit.contains(tilted, p), "rotated players are inside")


func _test_section_minimum() -> void:
	# REQ-018: 12 players at 6 x 2.4 (6 x 2 = 12) -> shrinking the size to 4 stops at 6.
	var s := _rect(10.0, 10.0, 6.0, 2.4, 0.0, 12)
	_assert(_edit.section_fits(12, 6.0, 2.4) and not _edit.section_fits(12, 4.0, 2.4), "fit rule: floor(size/1.0) * floor(depth/1.2)")
	_assert(_near(_edit.set_size(_room, [s], 4.0)[0].size, 6.0), "set_size stops at the smallest size that fits")
	_assert(_near(_edit.set_size(_room, [s], 9.0)[0].size, 9.0), "a larger size is fine")
	_assert(_near(_edit.set_depth(_room, [s], 1.0)[0].depth, 2.4), "set_depth stops at the smallest depth that fits")
	var end: Dictionary = _edit.drag_end(_room, s, 1, Vector2(10.0 + 1.0, 10.0), 0.0, 1.0)
	_assert(_near(end.size, 6.0), "an end drag stops at the minimum, never a dot (got %s)" % end.size)
	var edge: Dictionary = _edit.drag_edge(_room, s, Vector2(10.0, 10.0 + 0.3))
	_assert(_near(edge.depth, 2.4), "an edge drag stops at the minimum depth (got %s)" % edge.depth)
	# Under automation the section minimum does not apply: only edits are clamped. StageCanvas
	# draws the automated state as is, and the layout still works for an undersized rectangle.
	var automated := _rect(10.0, 10.0, 3.0, 2.4, 0.0, 12)
	_assert(_edit.player_positions(automated).size() == 12, "an automated, undersized section still lays out its players")
	for p: Vector2 in _edit.player_positions(automated):
		_assert(_edit.contains(automated, p), "and keeps them inside")
	# Players are clamped to 1..64.
	_assert(_edit.set_players(_room, [_rect(10.0, 10.0, 6.0, 2.4)], 0)[0].players == 1, "players have a minimum of 1")
	_assert(_edit.set_players(_room, [_rect(10.0, 10.0, 6.0, 2.4)], 500)[0].players == 64, "and a maximum of 64")
	var block := _rect(10.0, 10.0, 1.0, 1.0)
	_assert(_edit.set_size(_room, [block], 2.0)[0].size == 2.0, "a Block has no minimum")


func _test_section_grow() -> void:
	# 16 players from 6 x 2.4: depth grows to 3.6 (6 x 3 = 18).
	var s := _rect(10.0, 10.0, 6.0, 2.4)
	var more: Dictionary = _edit.set_players(_room, [_edit.set_display(_room, [s], 1.0)[0]], 16.0)[0]
	_assert(_near(more.depth, 3.6) and _near(more.size, 6.0) and more.players == 16, "16 players: depth grows to 3.6 first (got %s x %s)" % [more.size, more.depth])
	_assert(_edit.section_fits(16, more.size, more.depth), "and they fit")
	# Switching to Section grows too: 8 players in a 3 x 2 Block.
	var block := _rect(10.0, 10.0, 3.0, 2.0)
	block["players"] = 8
	var section: Dictionary = _edit.set_display(_room, [block], 1.0)[0]
	_assert(section.display == 1 and _edit.section_fits(8, section.size, section.depth), "switching to Section fits the players (got %s x %s)" % [section.size, section.depth])
	_assert(_near(section.depth, 3.6) and _near(section.size, 3.0), "depth grows first (3.6 gives 3 x 3 seats), the size stays")
	# Back to Block leaves the rectangle as it is.
	var back: Dictionary = _edit.set_display(_room, [section], 0.0)[0]
	_assert(back.display == 0 and back.size == section.size and back.depth == section.depth, "Block keeps the rectangle")
	# Depth is limited by the room, then the size grows: a 20 x 3 m room, 40 players at 6 x 2.4.
	var shallow = _stage.new()
	shallow.set_room_size(20.0, 3.0, 10.0)
	var wide: Dictionary = _edit.set_players(shallow, [_rect(10.0, 1.5, 6.0, 2.4, 0.0, 8)], 40.0)[0]
	_assert(_near(wide.depth, 3.0) and _near(wide.size, 20.0) and _edit.section_fits(40, wide.size, wide.depth),
			"the room limits the depth (3 m = 2 rows), then the size grows to 20 (got %s x %s)" % [wide.size, wide.depth])
	# A 4 x 3 m room with 64 players: as large as the room allows, no error.
	var tiny = _stage.new()
	tiny.set_room_size(4.0, 3.0, 5.0)
	var full: Dictionary = _edit.set_players(tiny, [_rect(2.0, 1.5, 2.0, 1.2, 0.0, 8)], 64.0)[0]
	_assert(full.size <= 4.0 + 0.001 and full.depth <= 3.0 + 0.001 and full.size >= 3.99 and full.depth >= 2.99, "64 players in a 4 x 3 m room: clamped to the room (got %s x %s)" % [full.size, full.depth])
	_assert(_edit.player_positions(full).size() == 64, "and all 64 are still placed")
