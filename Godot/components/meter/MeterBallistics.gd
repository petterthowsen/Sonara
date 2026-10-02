## Time-based meter ballistics in dB, shared by meters that draw their own bars: instant-attack
## peak with a constant dB/s release, a peak hold line that sticks and then falls, and a one-pole
## RMS with separate attack and release. Lifted from `Meter.gd`.
##
## Feed it with `push()` whenever a level arrives and call `step(delta)` every frame until
## `settled` is true. Values are plain dB; "bigger is more" holds for gain reduction too, so a
## reduction meter uses the same class with `floor_db` = 0.
class_name MeterBallistics extends RefCounted

var floor_db := -60.0 ## Silence. Inputs are clamped to it and the meter starts here
var peak_release_db_per_sec := 30.0 ## Peak falls at this rate after a transient
var hold_time := 1.5 ## Seconds a hold line sticks at its max
var hold_release_db_per_sec := 15.0 ## Hold line fall rate once the hold time is over
var rms_attack_time := 0.05 ## RMS time constant while rising (seconds)
var rms_release_time := 0.3 ## RMS time constant while falling (seconds)

var peak_db := -60.0
var rms_db := -60.0
var peak_hold_db := -INF
var rms_hold_db := -INF
## Highest value since the last `reset_max()`, for the numeric readout.
var max_peak_db := -INF
var max_rms_db := -INF

var _target_peak := -60.0
var _target_rms := -60.0
var _rms_lin := 0.0
var _peak_hold_timer := 0.0
var _rms_hold_timer := 0.0


func _init(silence_db := -60.0) -> void:
	set_floor(silence_db)


func set_floor(db: float) -> void:
	floor_db = db
	peak_db = db
	rms_db = db
	_target_peak = db
	_target_rms = db
	_rms_lin = db_to_linear(db)


## New measured level. A peak above the current one is taken at once, so a transient between two
## frames is never missed. `rms` (NAN: same as the peak) is smoothed towards by `step`.
func push(peak: float, rms := NAN) -> void:
	_target_peak = maxf(peak, floor_db)
	_target_rms = _target_peak if is_nan(rms) else maxf(rms, floor_db)
	if _target_peak > peak_db:
		peak_db = _target_peak
	max_peak_db = maxf(max_peak_db, peak_db)
	if peak_db > peak_hold_db:
		peak_hold_db = peak_db
		_peak_hold_timer = hold_time


func step(delta: float) -> void:
	if peak_db > _target_peak:
		peak_db = maxf(_target_peak, peak_db - peak_release_db_per_sec * delta)

	var target_lin := db_to_linear(_target_rms)
	var tau := rms_attack_time if target_lin > _rms_lin else rms_release_time
	_rms_lin = lerpf(_rms_lin, target_lin, 1.0 - exp(-delta / maxf(tau, 0.001)))
	# Snap once visually indistinguishable so the meter can settle.
	if absf(_rms_lin - target_lin) < 0.0001:
		_rms_lin = target_lin
	rms_db = maxf(linear_to_db(_rms_lin), floor_db)
	max_rms_db = maxf(max_rms_db, rms_db)

	var peak_hold := _hold(peak_hold_db, _peak_hold_timer, peak_db, delta)
	peak_hold_db = peak_hold.x
	_peak_hold_timer = peak_hold.y
	var rms_hold := _hold(rms_hold_db, _rms_hold_timer, rms_db, delta)
	rms_hold_db = rms_hold.x
	_rms_hold_timer = rms_hold.y


## True once nothing would change on further steps.
func settled() -> bool:
	return peak_db == _target_peak \
		and _rms_lin == db_to_linear(_target_rms) \
		and _peak_hold_timer <= 0.0 and _rms_hold_timer <= 0.0 \
		and peak_hold_db <= peak_db and rms_hold_db <= rms_db


func reset_max() -> void:
	max_peak_db = -INF
	max_rms_db = -INF
	peak_hold_db = -INF
	rms_hold_db = -INF
	_peak_hold_timer = 0.0
	_rms_hold_timer = 0.0


## Returns Vector2(hold_db, timer).
func _hold(hold: float, timer: float, value: float, delta: float) -> Vector2:
	if value > hold:
		return Vector2(value, hold_time)
	if timer > 0.0:
		return Vector2(hold, timer - delta)
	return Vector2(maxf(value, hold - hold_release_db_per_sec * delta), 0.0)
