## One XY pad (spec 036): two engine modulator slots (`xyx` and `xyy`) presented as a single
## UI control. The engine sees two plain modulators; Godot groups adjacent array entries into
## a pad (`DeviceInstance.xy_pairs`). Each slot syncs to the engine through the existing
## modulator paths, so the pair adds no sync code of its own.
class_name XYPad extends RefCounted

## The X slot (`xyx`), the first of the adjacent pair.
var x: Modulator
## The Y slot (`xyy`), immediately after `x` in the device's modulator array.
var y: Modulator


## Display name: the X slot's (renaming the pad renames both slots).
var name: String:
	get:
		return x.name if x != null else ""


## The device both slots belong to (a `DeviceInstance`), or null.
func owner():
	return x.owner() if x != null else null


## The pad's position, normalized 0..1 per axis (the slots' parameter 0).
func position() -> Vector2:
	return Vector2(
		x.get_param(0) if x != null else 0.5,
		y.get_param(0) if y != null else 0.5)


## Move the pad: one `set_modulator_param(id, 0, …)` per slot, clamped to 0..1.
func set_position(v: Vector2) -> void:
	if x != null:
		x.set_param(0, clampf(v.x, 0.0, 1.0))
	if y != null:
		y.set_param(0, clampf(v.y, 0.0, 1.0))


## The pair's engine modulator ids, X first.
func mod_ids() -> Array[int]:
	var out: Array[int] = []
	if x != null:
		out.append(x.mod_id)
	if y != null:
		out.append(y.mod_id)
	return out


## True when `mod_id` is one of this pad's slots.
func holds(mod_id: int) -> bool:
	return (x != null and x.mod_id == mod_id) or (y != null and y.mod_id == mod_id)
