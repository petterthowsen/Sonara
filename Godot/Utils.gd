class_name Utils extends RefCounted

## Convert linear amplitude (0.0 to 1.0+) to decibels
## Returns db_floor for values <= 0.000001 (default: -60.0 dB)
static func lin_to_db(linear: float, db_floor: float = -60.0) -> float:
	if linear <= 0.000001:
		return db_floor
	return 20.0 * log(linear) / log(10.0)


## Convert decibels to linear amplitude
## -inf dB = 0.0 linear, 0 dB = 1.0 linear, +6 dB ≈ 2.0 linear
static func db_to_lin(db: float) -> float:
	return pow(10.0, db / 20.0)
