## ParamRules.gd
## Which parameters of a device don't apply in its current state (spec 027 REQ-037), by device id:
## Strum Direction while Strum is 0, Repeat Ends while Ping-Pong is off, a Transpose root and scale
## type while Scale isn't Custom. The Simple View shows those controls disabled (greyed and
## inert, value still visible). Rules read other parameters' normalized values through a
## callable, so they need no device instance and stay plain data in a test.
class_name ParamRules extends RefCounted

## A normalized value below this counts as zero (Strum 0 ms).
const ZERO_EPSILON := 0.0001


## Parameter ids of `device_id` that are disabled. `normalized_of` is `func(param_id: int) -> float`
## returning that parameter's normalized value (0..1). Devices without rules return [].
static func disabled_ids(device_id: String, normalized_of: Callable) -> Array[int]:
	var out: Array[int] = []
	match device_id:
		"sonara.builtin.transpose":
			# Scale {Off, Follow Project, Custom}: root and type only apply to Custom.
			if _choice(normalized_of.call(10), 3) != 2:
				out.append_array([11, 12])
		"sonara.builtin.chord":
			# Strum Direction only matters while Strum (ms) is above 0.
			if float(normalized_of.call(1)) <= ZERO_EPSILON:
				out.append(2)
		"sonara.builtin.note_echo":
			# Sync picks the time unit: Rate when on, ms when off.
			if _is_on(normalized_of.call(1)):
				out.append(3)
			else:
				out.append(2)
		"sonara.builtin.note_length":
			if _is_on(normalized_of.call(1)):
				out.append(3)
			else:
				out.append(2)
		"sonara.builtin.arpeggiator":
			# Repeat Ends is a ping-pong option.
			if not _is_on(normalized_of.call(2)):
				out.append(3)
	return out


## Index of the choice a normalized enum value selects (choice i of n sits at i / (n - 1)).
static func _choice(normalized: float, count: int) -> int:
	return clampi(roundi(normalized * float(count - 1)), 0, count - 1)


## True for an on bool (normalized 1.0).
static func _is_on(normalized: float) -> bool:
	return normalized >= 0.5
