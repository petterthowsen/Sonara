## SamplerZone.gd
## One sample in a Sampler multisample (spec 023): file, key and velocity ranges, per-zone playback
## settings and group. Plain data plus the zone's decoded `source` (waveform) and load state.
## SamplerMultisample owns the setters, the OSC and the loading.
class_name SamplerZone extends RefCounted

const KEY_MIN := 0
const KEY_MAX := 127
const VEL_MIN := 1
const VEL_MAX := 127

## Persisted fields with their defaults, in the order of the JSON in design.md.
const NUMERIC_DEFAULTS := {
	"root": 60, "tune": 0.0, "fine": 0.0, "gain": 1.0,
	"start": 0.0, "end": 1.0, "loop_mode": 0, "loop_start": 0.0, "loop_end": 1.0, "crossfade": 0.0,
}

var id: int = 0
var path: String = ""
## File basename without extension (renamable later).
var name: String = ""
var group_id: int = 0
var key_lo: int = KEY_MIN
var key_hi: int = KEY_MAX
var vel_lo: int = VEL_MIN
var vel_hi: int = VEL_MAX
var root: int = 60
## Semitones.
var tune: float = 0.0
## Cents.
var fine: float = 0.0
## Linear gain.
var gain: float = 1.0
## Points are 0-1 over the file, as in single mode.
var start: float = 0.0
var end: float = 1.0
var reverse: bool = false
## 0 = Off, 1 = On, 2 = Ping-Pong.
var loop_mode: int = 0
var loop_start: float = 0.0
var loop_end: float = 1.0
## Fraction of the loop, 0-1.
var crossfade: float = 0.0
var key_fade_lo: int = 0
var key_fade_hi: int = 0
var vel_fade_lo: int = 0
var vel_fade_hi: int = 0

## Runtime only. Created with the zone so the waveform lookup always has a target.
var source: AudioSourceInfo = AudioSourceInfo.new()
## "idle", "loading", "ready" or "failed:{reason}".
var loading_state: String = "idle"
## The AudioFileService request of the current load.
var load_req_id: String = ""


func _init(p_id: int = 0, p_path: String = "") -> void:
	id = p_id
	set_path(p_path)


func set_path(p_path: String) -> void:
	path = p_path
	name = p_path.get_file().get_basename()


func is_missing() -> bool:
	return loading_state.begins_with("failed:")


## Why the file couldn't load, or "".
func missing_reason() -> String:
	return loading_state.trim_prefix("failed:") if is_missing() else ""


## Arguments of `zone/{id}/set` (19, design.md). Tune and fine are folded into semitones.
func to_osc_args() -> Array:
	return [
		key_lo, key_hi, vel_lo, vel_hi, root, tune + fine / 100.0, gain,
		start, end, 1 if reverse else 0, loop_mode, loop_start, loop_end, crossfade,
		key_fade_lo, key_fade_hi, vel_fade_lo, vel_fade_hi, group_id,
	]


## Apply known fields from `values` (a `set_zone_fields` dictionary or a JSON zone), clamping and
## ordering ranges. Returns true when anything changed.
func apply_fields(values: Dictionary) -> bool:
	var before := to_json()
	if values.has("key"):
		_set_range("key", values["key"][0], values["key"][1])
	if values.has("vel"):
		_set_range("vel", values["vel"][0], values["vel"][1])
	if values.has("key_fade"):
		key_fade_lo = clampi(int(values["key_fade"][0]), 0, KEY_MAX)
		key_fade_hi = clampi(int(values["key_fade"][1]), 0, KEY_MAX)
	if values.has("vel_fade"):
		vel_fade_lo = clampi(int(values["vel_fade"][0]), 0, VEL_MAX)
		vel_fade_hi = clampi(int(values["vel_fade"][1]), 0, VEL_MAX)
	# Single-field forms, as the knobs and the zone strip use them.
	if values.has("key_lo") or values.has("key_hi"):
		_set_range("key", values.get("key_lo", key_lo), values.get("key_hi", key_hi))
	if values.has("vel_lo") or values.has("vel_hi"):
		_set_range("vel", values.get("vel_lo", vel_lo), values.get("vel_hi", vel_hi))
	for field in ["key_fade_lo", "key_fade_hi"]:
		if values.has(field):
			set(field, clampi(int(values[field]), 0, KEY_MAX))
	for field in ["vel_fade_lo", "vel_fade_hi"]:
		if values.has(field):
			set(field, clampi(int(values[field]), 0, VEL_MAX))
	if values.has("root"):
		root = clampi(int(values["root"]), KEY_MIN, KEY_MAX)
	if values.has("tune"):
		tune = clampf(float(values["tune"]), -48.0, 48.0)
	if values.has("fine"):
		fine = clampf(float(values["fine"]), -100.0, 100.0)
	if values.has("gain"):
		gain = clampf(float(values["gain"]), 0.0, 4.0)
	if values.has("start"):
		start = clampf(float(values["start"]), 0.0, 1.0)
	if values.has("end"):
		end = clampf(float(values["end"]), 0.0, 1.0)
	if values.has("reverse"):
		reverse = bool(values["reverse"])
	if values.has("loop_mode"):
		loop_mode = clampi(int(values["loop_mode"]), 0, 2)
	if values.has("loop_start"):
		loop_start = clampf(float(values["loop_start"]), 0.0, 1.0)
	if values.has("loop_end"):
		loop_end = clampf(float(values["loop_end"]), 0.0, 1.0)
	if values.has("crossfade"):
		crossfade = clampf(float(values["crossfade"]), 0.0, 1.0)
	if values.has("group") or values.has("group_id"):
		group_id = maxi(0, int(values.get("group", values.get("group_id", group_id))))
	if values.has("name"):
		name = str(values["name"])
	return to_json() != before


func _set_range(which: String, lo, hi) -> void:
	var min_v := KEY_MIN if which == "key" else VEL_MIN
	var max_v := KEY_MAX if which == "key" else VEL_MAX
	lo = clampi(int(lo), min_v, max_v)
	hi = clampi(int(hi), min_v, max_v)
	if lo > hi:
		var t: int = lo
		lo = hi
		hi = t
	set(which + "_lo", lo)
	set(which + "_hi", hi)


func to_json() -> Dictionary:
	return {
		"id": id, "path": path, "name": name, "group": group_id,
		"key": [key_lo, key_hi], "vel": [vel_lo, vel_hi],
		"root": root, "tune": tune, "fine": fine, "gain": gain,
		"start": start, "end": end, "reverse": reverse, "loop_mode": loop_mode,
		"loop_start": loop_start, "loop_end": loop_end, "crossfade": crossfade,
		"key_fade": [key_fade_lo, key_fade_hi], "vel_fade": [vel_fade_lo, vel_fade_hi],
	}


static func from_json(data: Dictionary) -> SamplerZone:
	var zone := SamplerZone.new(int(data.get("id", 0)), str(data.get("path", "")))
	if data.has("name"):
		zone.name = str(data["name"])
	zone.apply_fields(data)
	return zone
