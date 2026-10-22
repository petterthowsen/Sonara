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
class_name StageEdit extends RefCounted

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


## Half the bar's extent along X and Y: how far the centre must stay from the walls.
static func half_extent(size: float, rotation_deg: float) -> Vector2:
	var d := direction(rotation_deg).abs()
	return d * (size * 0.5)


## The state with its centre (x, y) and height (z) inside the room, so that both ends of the bar
## stay in it too. A bar longer than the room on an axis is centred on that axis.
static func clamp_state(room: VirtualStage, state: Dictionary) -> Dictionary:
	var out := state.duplicate()
	var half := half_extent(float(state.get("size", 0.0)), float(state.get("rotation", 0.0)))
	out["x"] = _clamp_axis(float(state.get("x", 0.0)), half.x, room.width)
	out["y"] = _clamp_axis(float(state.get("y", 0.0)), half.y, room.depth)
	out["z"] = clampf(float(state.get("z", 0.0)), 0.0, room.height)
	return out


## Move one source so its centre is at `target` (meters), clamped to the room.
static func move_to(room: VirtualStage, state: Dictionary, target: Vector2) -> Dictionary:
	var out := state.duplicate()
	out["x"] = target.x
	out["y"] = target.y
	return clamp_state(room, out)


## Move several sources by `delta` (meters), keeping their offsets from each other. `states` are
## the sources as they were when the drag started. The delta is shortened as a group, per axis,
## until every source is inside the room, so no one is squeezed against a wall alone.
static func move_by(room: VirtualStage, states: Array, delta: Vector2) -> Array[Dictionary]:
	var lo := Vector2(-INF, -INF)
	var hi := Vector2(INF, INF)
	for state: Dictionary in states:
		var half := half_extent(float(state.get("size", 0.0)), float(state.get("rotation", 0.0)))
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
## is at most the room's longer side, and `snap_deg` > 0 snaps the rotation to its multiples.
## Dragged to within MIN_SIZE of the centre it becomes a dot, keeping its rotation.
static func drag_end(room: VirtualStage, state: Dictionary, which: int, point: Vector2, snap_deg := 0.0) -> Dictionary:
	var out := state.duplicate()
	var center := Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	var offset := point - center
	if which == 0:
		offset = -offset
	var size := offset.length() * 2.0
	if size < MIN_SIZE:
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
	size = minf(size, reach * 2.0)
	size = minf(size, maxf(room.width, room.depth))
	out["size"] = size if size >= MIN_SIZE else 0.0
	out["rotation"] = rotation
	return out


## Set the height (Z, meters) of every selected source, clamped to the room.
static func set_height(room: VirtualStage, states: Array, z: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["z"] = clampf(z, 0.0, room.height)
		out.append(changed)
	return out


## Set the size (meters, 0 = dot) of every selected source, clamped into the room: the bar's ends
## stay inside, so a bar longer than the room allows is shortened to fit.
static func set_size(room: VirtualStage, states: Array, size: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		var dir := direction(float(state.get("rotation", 0.0))).abs()
		var limit := INF
		if dir.x > 0.0001:
			limit = minf(limit, room.width / dir.x)
		if dir.y > 0.0001:
			limit = minf(limit, room.depth / dir.y)
		var wanted := maxf(size, 0.0)
		changed["size"] = (wanted if wanted >= MIN_SIZE else 0.0) if wanted <= limit else limit
		out.append(clamp_state(room, changed))
	return out


## Set the rotation (degrees) of every selected source. The bar is turned about its centre and
## shortened, then moved, where it would leave the room.
static func set_rotation(room: VirtualStage, states: Array, degrees: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for state: Dictionary in states:
		var changed := state.duplicate()
		changed["rotation"] = wrap_rotation(degrees)
		out.append(set_size(room, [changed], float(state.get("size", 0.0)))[0])
	return out


## Keep `value` at least `half` from both walls of an axis of length `length`.
static func _clamp_axis(value: float, half: float, length: float) -> float:
	if half * 2.0 >= length:
		return length * 0.5
	return clampf(value, half, length - half)
