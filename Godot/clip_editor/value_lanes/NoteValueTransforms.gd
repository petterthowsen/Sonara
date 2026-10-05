## Whole-selection transforms behind the value lane's menu (Set, Randomize, Scale).
class_name NoteValueTransforms extends RefCounted


static func set_all(values: Array, v: float, d: NoteValueDescriptor) -> Array[float]:
	var out: Array[float] = []
	for _i in values.size():
		out.append(d.clamp_value(v))
	return out


## Each value moved by a random amount in [-amount, amount].
static func randomize(values: Array, amount: float, rng: RandomNumberGenerator, d: NoteValueDescriptor) -> Array[float]:
	var out: Array[float] = []
	for v in values:
		out.append(d.clamp_value(float(v) + rng.randf_range(-amount, amount)))
	return out


## Spread around the mean: 100 keeps the values, 50 halves each distance to the mean.
static func scale_around_mean(values: Array, percent: float, d: NoteValueDescriptor) -> Array[float]:
	var out: Array[float] = []
	if values.is_empty():
		return out
	var mean := 0.0
	for v in values:
		mean += float(v)
	mean /= values.size()
	for v in values:
		out.append(d.clamp_value(mean + (float(v) - mean) * percent / 100.0))
	return out
