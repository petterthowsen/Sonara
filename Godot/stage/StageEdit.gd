# StageEdit.gd
# Pure edit operations of the Stage view (spec 051, REQ-022): move, end-drag resize and rotate,
# clamp to the room, multi-move and height. Nothing here touches a Channel or sends OSC: every
# function takes stage-state dictionaries (Channel.get_stage_state(): x, y, z, size, rotation in
# meters and degrees) and returns new ones. The view applies the result to the channel through
# set_stage_state inside a PropertyCommand, which is the undo step.
#
# Geometry: room coordinates (meters, origin at the front-left floor corner, X right, Y toward the
# back wall). A source is a bar of `size` meters centred on (x, y), at `rotation` degrees
# counter-clockwise from the X axis (as seen from above with Y up). Size 0 is a dot. The engine
# clamps both ends of the bar into the room, so a bar is clamped as a whole here.
#
# Spec 052: a source is a rectangle, `size` along its line by `depth` across it (visual only,
# a missing `depth` is 0, a bar). The whole rectangle is kept inside the room. In Section display
# (`display` == Channel.StageDisplay.SECTION) the rectangle must fit `players` at the player
# footprint; edits stop at that minimum. Snapping: every edit takes a step (0 = off).
class_name StageEdit extends RefCounted

## Snap steps (spec 052, REQ-009): whole meters and 15 degrees, or 0.1 m and 1 degree with Shift.
const SNAP_M := 1.0
const SNAP_FINE_M := 0.1
const SNAP_DEG := 15.0
const SNAP_FINE_DEG := 1.0
## Smallest depth an edit produces (meters).
const MIN_DEPTH := 0.1
## Channel.StageDisplay.SECTION (this file does not depend on the Channel class).
const DISPLAY_SECTION := 1
const _EPS := 0.0001

## A dragged end closer to the centre than this (meters) makes the source a dot (size 0).
const MIN_SIZE := 0.1


## Unit vector of the bar's direction for `rotation_deg`.
static func direction(rotation_deg: float) -> Vector2:
	return Vector2.from_angle(deg_to_rad(rotation_deg))


## `degrees` wrapped into -180..180.
static func wrap_rotation(degrees: float) -> float:
	var wrapped := fposmod(degrees + 180.0, 360.0) - 180.0
	return 180.0 if is_equal_approx(wrapped, -180.0) and degrees > 0.0 else wrapped


## The two ends of the bar (A at the negative side, B at the positive side), in room meters.
static func ends(state: Dictionary) -> Array[Vector2]:
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var half := direction(float(state.get("rotation", 0.0))) * float(state.get("size", 0.0)) * 0.5
	return [center - half, center + half]


## Half the rectangle's extent along X and Y: how far the centre must stay from the walls. A dot
## (size below MIN_SIZE) has none.
static func half_extent(size: float, rotation_deg: float, depth := 0.0) -> Vector2:
	if size < MIN_SIZE:
		return Vector2.ZERO
	var d := direction(rotation_deg).abs()
	return d * (size * 0.5) + Vector2(d.y, d.x) * (depth * 0.5)


## The state with its centre (x, y) and height (z) inside the room, so that the whole rectangle
## stays in it too. A rectangle larger than the room on an axis is centred on that axis.
static func clamp_state(room: VirtualStage, state: Dictionary) -> Dictionary:
	var out := state.duplicate()
	var half := _half(state)
	out["x"] = _clamp_axis(float(state.get("x", 0.0)), half.x, room.width)
	out["y"] = _clamp_axis(float(state.get("y", 0.0)), half.y, room.depth)
	out["z"] = clampf(float(state.get("z", 0.0)), 0.0, room.height)
	return out


static func _half(state: Dictionary) -> Vector2:
	return half_extent(float(state.get("size", 0.0)), float(state.get("rotation", 0.0)), float(state.get("depth", 0.0)))


# ----------------------------------------------------------------------------
# Snapping
# ----------------------------------------------------------------------------

## Step in meters for a drag: 0 when snapping is off, else 1 m (0.1 m while `fine`).
static func step_m(snap_on: bool, fine: bool) -> float:
	return 0.0 if not snap_on else (SNAP_FINE_M if fine else SNAP_M)


## Rotation step in degrees for a drag: 0 when snapping is off, else 15 (1 while `fine`).
static func step_deg(snap_on: bool, fine: bool) -> float:
	return 0.0 if not snap_on else (SNAP_FINE_DEG if fine else SNAP_DEG)


## `p` snapped to multiples of `step` on both axes (`step` <= 0: unchanged).
static func snap_point(p: Vector2, step: float) -> Vector2:
	return Vector2(snap_length(p.x, step), snap_length(p.y, step))


## `value` snapped to a multiple of `step` (`step` <= 0: unchanged).
static func snap_length(value: float, step: float) -> float:
	return snappedf(value, step) if step > 0.0 else value


# ----------------------------------------------------------------------------
# Rectangle geometry
# ----------------------------------------------------------------------------

## Unit vector across the line (the depth direction): the line turned 90 degrees counter-clockwise.
static func normal(rotation_deg: float) -> Vector2:
	var d := direction(rotation_deg)
	return Vector2(-d.y, d.x)


## The four corners, in room meters: back-left of the line's A end first, then around.
static func corners(state: Dictionary) -> Array[Vector2]:
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var rot := float(state.get("rotation", 0.0))
	var d := direction(rot) * (float(state.get("size", 0.0)) * 0.5)
	var n := normal(rot) * (float(state.get("depth", 0.0)) * 0.5)
	return [center - d - n, center + d - n, center + d + n, center - d + n]


## `point` in the rectangle's own frame: x along the line, y across it, from the centre.
static func to_local(state: Dictionary, point: Vector2) -> Vector2:
	var rot := float(state.get("rotation", 0.0))
	var offset := point - Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	return Vector2(offset.dot(direction(rot)), offset.dot(normal(rot)))


## True when `point` is inside the rectangle grown by `margin` meters.
static func contains(state: Dictionary, point: Vector2, margin := 0.0) -> bool:
	var local := to_local(state, point)
	return absf(local.x) <= float(state.get("size", 0.0)) * 0.5 + margin \
			and absf(local.y) <= float(state.get("depth", 0.0)) * 0.5 + margin


## The midpoints of the two edges across the line's width: [front (negative side), back].
static func edge_midpoints(state: Dictionary) -> Array[Vector2]:
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var n := normal(float(state.get("rotation", 0.0))) * (float(state.get("depth", 0.0)) * 0.5)
	return [center - n, center + n]


## Largest size that keeps a rectangle of `depth` inside the room at `rotation_deg` (some centre).
static func max_size(room: VirtualStage, depth: float, rotation_deg: float) -> float:
	var d := direction(rotation_deg).abs()
	var limit := INF
	if d.x > 0.0001:
		limit = minf(limit, (room.width - d.y * depth) / d.x)
	if d.y > 0.0001:
		limit = minf(limit, (room.depth - d.x * depth) / d.y)
	return maxf(limit, 0.0)


## Largest depth that keeps a rectangle of `size` inside the room at `rotation_deg` (some centre).
static func max_depth(room: VirtualStage, size: float, rotation_deg: float) -> float:
	var d := direction(rotation_deg).abs()
	var limit := INF
	if d.y > 0.0001:
		limit = minf(limit, (room.width - d.x * size) / d.y)
	if d.x > 0.0001:
		limit = minf(limit, (room.depth - d.y * size) / d.x)
	return maxf(limit, 0.0)


## Move one source so its centre is at `target` (meters), clamped to the room.
## `step` > 0 snaps the centre to multiples of it first.
static func move_to(room: VirtualStage, state: Dictionary, target: Vector2, step := 0.0) -> Dictionary:
	var out := state.duplicate()
	var at := snap_point(target, step)
	out["x"] = at.x
	out["y"] = at.y
	return clamp_state(room, out)


## Move several sources by `delta` (meters), keeping their offsets from each other. `states` are
## the sources as they were when the drag started. The delta is shortened as a group, per axis,
## until every source is inside the room, so no one is squeezed against a wall alone. With
## `step` > 0 the `anchor` source (the one being dragged, an index into `states`) has its centre
## snapped to multiples of `step`, and the others move by the same delta, keeping their offsets.
static func move_by(room: VirtualStage, states: Array, delta: Vector2, anchor := -1, step := 0.0) -> Array[Dictionary]:
	if step > 0.0 and anchor >= 0 and anchor < states.size():
		var a: Dictionary = states[anchor]
		var from := Vector2(float(a.get("x", 0.0)), float(a.get("y", 0.0)))
		delta = snap_point(from + delta, step) - from
	var lo := Vector2(-INF, -INF)
	var hi := Vector2(INF, INF)
	for state: Dictionary in states:
		var half := _half(state)
		var x := float(state.get("x", 0.0))
		var y := float(state.get("y", 0.0))
		lo.x = maxf(lo.x, half.x - x)
		hi.x = minf(hi.x, room.width - half.x - x)
		lo.y = maxf(lo.y, half.y - y)
		hi.y = minf(hi.y, room.depth - half.y - y)
	var applied := delta
	# An empty range (a source that doesn't fit) leaves that axis alone.
	applied.x = clampf(delta.x, lo.x, hi.x) if lo.x <= hi.x else 0.0
	applied.y = clampf(delta.y, lo.y, hi.y) if lo.y <= hi.y else 0.0
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var moved := state.duplicate()
		moved["x"] = float(state.get("x", 0.0)) + applied.x
		moved["y"] = float(state.get("y", 0.0)) + applied.y
		out.append(clamp_state(room, moved))
	return out


## Drag one end of the bar to `point` (meters) with the centre fixed: the size becomes twice the
## distance to the centre and the rotation follows the pointer. `which` is 0 for end A (negative
## side) and 1 for end B. Both ends stay in the room (the bar shortens against a wall), the size
## is at most the room's longer side, `snap_deg` > 0 snaps the rotation to its multiples and
## `length_step` > 0 snaps the size. Dragged to within MIN_SIZE of the centre it becomes a dot,
## keeping its rotation. A Section stops at the smallest size that fits its players. A rectangle
## whose depth would leave the room has its centre moved in.
static func drag_end(room: VirtualStage, state: Dictionary, which: int, point: Vector2, snap_deg := 0.0, length_step := 0.0) -> Dictionary:
	var out := state.duplicate()
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var offset := point - center
	if which == 0:
		offset = -offset
	var size := snap_length(offset.length() * 2.0, length_step)
	var min_size := _section_min_size(state)
	if size < MIN_SIZE and min_size <= 0.0:
		out["size"] = 0.0
		return out
	var rotation := rad_to_deg(offset.angle())
	if snap_deg > 0.0:
		rotation = snappedf(rotation, snap_deg)
	rotation = wrap_rotation(rotation)
	var dir := direction(rotation)
	# Longest half-bar that keeps both ends inside the room from this centre.
	var reach := INF
	if absf(dir.x) > 0.0001:
		reach = minf(reach, minf(center.x, room.width - center.x) / absf(dir.x))
	if absf(dir.y) > 0.0001:
		reach = minf(reach, minf(center.y, room.depth - center.y) / absf(dir.y))
	size = maxf(size, min_size)
	size = minf(size, reach * 2.0)
	size = minf(size, maxf(room.width, room.depth))
	size = minf(size, max_size(room, float(state.get("depth", 0.0)), rotation))
	out["size"] = size if size >= MIN_SIZE else 0.0
	out["rotation"] = rotation
	return clamp_state(room, out)


## Drag the front or back edge to `point` (meters): the depth becomes twice the pointer's distance
## from the line, symmetric about the centre, so the centre stays. `step` > 0 snaps the depth. The
## rectangle stays inside the room, and a Section stops at the smallest depth that fits its players.
static func drag_edge(room: VirtualStage, state: Dictionary, point: Vector2, step := 0.0) -> Dictionary:
	var out := state.duplicate()
	var depth := snap_length(absf(to_local(state, point).y) * 2.0, step)
	var size := float(state.get("size", 0.0))
	var rot := float(state.get("rotation", 0.0))
	# Centre fixed: the room limits the depth by the distance from the centre to each wall.
	var d := direction(rot).abs()
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var reach := INF
	if d.y > 0.0001:
		reach = minf(reach, (2.0 * minf(center.x, room.width - center.x) - d.x * size) / d.y)
	if d.x > 0.0001:
		reach = minf(reach, (2.0 * minf(center.y, room.depth - center.y) - d.y * size) / d.x)
	depth = maxf(depth, maxf(MIN_DEPTH, _section_min_depth(state)))
	depth = minf(depth, maxf(reach, 0.0))
	depth = minf(depth, max_depth(room, size, rot))
	out["depth"] = maxf(depth, 0.0)
	return clamp_state(room, out)


## Set the height (Z, meters) of every selected source, clamped to the room.
static func set_height(room: VirtualStage, states: Array, z: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["z"] = clampf(z, 0.0, room.height)
		out.append(changed)
	return out


## Set the size (meters, 0 = dot) of every selected source, clamped into the room: the rectangle
## stays inside, so a size larger than the room allows is shortened to fit. A Section stops at the
## smallest size that fits its players.
static func set_size(room: VirtualStage, states: Array, size: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		var limit := max_size(room, float(state.get("depth", 0.0)), float(state.get("rotation", 0.0)))
		var wanted := maxf(size, _section_min_size(state))
		changed["size"] = (wanted if wanted >= MIN_SIZE else 0.0) if wanted <= limit else limit
		out.append(clamp_state(room, changed))
	return out


## Set the depth (meters) of every selected source, inside the room. A Section stops at the
## smallest depth that fits its players.
static func set_depth(room: VirtualStage, states: Array, depth: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		var wanted := maxf(maxf(depth, MIN_DEPTH), _section_min_depth(state))
		var limit := max_depth(room, float(state.get("size", 0.0)), float(state.get("rotation", 0.0)))
		changed["depth"] = minf(wanted, limit)
		out.append(clamp_state(room, changed))
	return out


## Set the rotation (degrees) of every selected source. The rectangle is turned about its centre
## and shortened, then moved, where it would leave the room.
static func set_rotation(room: VirtualStage, states: Array, degrees: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["rotation"] = wrap_rotation(degrees)
		var fitted := set_size(room, [changed], float(state.get("size", 0.0)))[0]
		if fitted.has("depth"):
			fitted["depth"] = minf(float(fitted["depth"]), max_depth(room, float(fitted.get("size", 0.0)), degrees))
		out.append(clamp_state(room, fitted))
	return out


# ----------------------------------------------------------------------------
# Display mode and sections (spec 052)
# ----------------------------------------------------------------------------

## Set the display mode (Channel.StageDisplay value) of every selected source. A source that
## becomes a Section grows until its players fit.
static func set_display(room: VirtualStage, states: Array, display: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["display"] = clampi(int(display), 0, DISPLAY_SECTION)
		out.append(fit_section(room, changed))
	return out


## Set the player count (1 to 64) of every selected source. A Section grows until they fit.
static func set_players(room: VirtualStage, states: Array, players: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["players"] = clampi(int(players), VirtualStage.MIN_PLAYERS, VirtualStage.MAX_PLAYERS)
		out.append(fit_section(room, changed))
	return out


static func _is_section(state: Dictionary) -> bool:
	return int(state.get("display", 0)) == DISPLAY_SECTION


static func _players(state: Dictionary) -> int:
	return clampi(int(state.get("players", VirtualStage.DEFAULT_PLAYERS)), VirtualStage.MIN_PLAYERS, VirtualStage.MAX_PLAYERS)


## True when a `size` x `depth` rectangle holds `players` at the footprint:
## floor(size / 1.0) * floor(depth / 1.2) >= players.
static func section_fits(players: int, size: float, depth: float) -> bool:
	var fp := VirtualStage.PLAYER_FOOTPRINT
	return int(floor(size / fp.x + _EPS)) * int(floor(depth / fp.y + _EPS)) >= players


## Smallest size that fits the Section's players at its current depth; 0 when not a Section, or
## when the depth is too small for even one row (then growing depth is the only fix).
static func _section_min_size(state: Dictionary) -> float:
	if not _is_section(state):
		return 0.0
	var fp := VirtualStage.PLAYER_FOOTPRINT
	var rows := int(floor(float(state.get("depth", 0.0)) / fp.y + _EPS))
	if rows < 1:
		return 0.0
	return ceilf(float(_players(state)) / rows - _EPS) * fp.x


## Smallest depth that fits the Section's players at its current size; 0 when not a Section or
## when the size is too small for even one column.
static func _section_min_depth(state: Dictionary) -> float:
	if not _is_section(state):
		return 0.0
	var fp := VirtualStage.PLAYER_FOOTPRINT
	var cols := int(floor(float(state.get("size", 0.0)) / fp.x + _EPS))
	if cols < 1:
		return 0.0
	return snappedf(ceilf(float(_players(state)) / cols - _EPS) * fp.y, _EPS)


## A Section whose players do not fit grows until they do: depth first (up to what the room
## allows), then size. If the room cannot hold it, the rectangle is as large as the room allows
## and the players are drawn closer. A Block, or a Section that fits, is returned unchanged.
static func fit_section(room: VirtualStage, state: Dictionary) -> Dictionary:
	if not _is_section(state):
		return state
	var out := state.duplicate()
	var n := _players(out)
	var fp := VirtualStage.PLAYER_FOOTPRINT
	var rot := float(out.get("rotation", 0.0))
	if section_fits(n, float(out.get("size", 0.0)), float(out.get("depth", 0.0))):
		return out
	# A section is at least one footprint wide, so the depth has columns to be counted in.
	if float(out.get("size", 0.0)) < fp.x:
		out["size"] = minf(fp.x, max_size(room, float(out.get("depth", 0.0)), rot))
	var depth_need := _section_min_depth(out)
	if depth_need > 0.0 and depth_need > float(out.get("depth", 0.0)):
		out["depth"] = minf(depth_need, max_depth(room, float(out.get("size", 0.0)), rot))
	if not section_fits(n, float(out.get("size", 0.0)), float(out.get("depth", 0.0))):
		# Depth is as large as it gets (or the size was tiny): widen.
		var rows := int(floor(float(out.get("depth", 0.0)) / fp.y + _EPS))
		if rows < 1:
			out["depth"] = minf(fp.y, max_depth(room, float(out.get("size", 0.0)), rot))
		var size_need := _section_min_size(out)
		if size_need > float(out.get("size", 0.0)):
			out["size"] = minf(size_need, max_size(room, float(out.get("depth", 0.0)), rot))
	return clamp_state(room, out)


## Columns x rows of a Section's grid for `players` in a `size` x `depth` rectangle. Among the
## grids that fit the footprint it takes the one with the fewest empty seats, and on a tie the cell
## shape closest to the footprint's. If none fits, the cell shape closest to the footprint's.
static func section_grid(players: int, size: float, depth: float) -> Vector2i:
	var n := maxi(players, 1)
	var fp := VirtualStage.PLAYER_FOOTPRINT
	var best := Vector2i(1, n)
	var best_fits := false
	var best_empty := INF
	var best_shape := INF
	for cols in range(1, n + 1):
		var rows := ceili(float(n) / cols)
		var fits: bool = cols * fp.x <= size + _EPS and rows * fp.y <= depth + _EPS
		var empty := float(cols * rows - n)
		var cell_w := maxf(size, 0.01) / cols
		var cell_h := maxf(depth, 0.01) / rows
		var shape := absf(log((cell_w / cell_h) / (fp.x / fp.y)))
		var better := false
		if fits != best_fits:
			better = fits
		elif fits:
			better = empty < best_empty or (empty == best_empty and shape < best_shape - 0.000001)
		else:
			better = shape < best_shape - 0.000001 or (absf(shape - best_shape) <= 0.000001 and empty < best_empty)
		if better:
			best = Vector2i(cols, rows)
			best_fits = fits
			best_empty = empty
			best_shape = shape
	return best


## Room positions of a Section's players: a grid over the rectangle, cell centres, the last row
## centred. Empty for a dot.
static func player_positions(state: Dictionary) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var size := float(state.get("size", 0.0))
	if size < MIN_SIZE:
		return out
	var depth := float(state.get("depth", 0.0))
	var n := _players(state)
	var grid := section_grid(n, size, depth)
	var cell := Vector2(size / grid.x, depth / grid.y)
	var rot := float(state.get("rotation", 0.0))
	var d := direction(rot)
	var nrm := normal(rot)
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	for i in n:
		var row := i / grid.x
		var col := i % grid.x
		var in_row := mini(grid.x, n - row * grid.x)
		# A short last row is centred: shift it by half the empty cells.
		var shift := (grid.x - in_row) * 0.5
		var local := Vector2((col + shift + 0.5) * cell.x - size * 0.5, (row + 0.5) * cell.y - depth * 0.5)
		out.append(center + d * local.x + nrm * local.y)
	return out


## Keep `value` at least `half` from both walls of an axis of length `length`.
static func _clamp_axis(value: float, half: float, length: float) -> float:
	if half * 2.0 >= length:
		return length * 0.5
	return clampf(value, half, length - half)
