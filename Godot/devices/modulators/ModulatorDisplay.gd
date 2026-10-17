## One modulator panel's kind display (spec 033): a `_draw()` shape of the modulator's output
## with a white dot at the engine-reported live position.
##
## Bound to `(device, mod_id)` through `setup`. It redraws on `ModLive.modulator_states_changed`
## for its device and on `modulator_changed` (shape parameters); while live states flow it also
## redraws per frame, interpolating the dot between the last two samples (see INTERP_* above).
## Shapes: an LFO draws one cycle of its wave (S&H a fixed staircase glyph); an envelope draws
## its time-proportional curve; a sidechain draws its output history (spec 044: the engine's
## dense `kind 4` peaks, a 2 s time-stamped buffer scrolled by elapsed time and drawn on a fixed
## 0..1 scale); every other kind draws a ~2 s ring-buffer trace of recent values, with the dot at
## the newest point. A knob shows no shape: it hosts a real `RotaryKnob` bound to its Value
## (the options pane keeps only Polarity). Missing state (old engine, before the first payload) leaves
## the static shape with no dot.
class_name ModulatorDisplay extends Control

## Envelope stage ids as the engine reports them in `kind 2` records.
const STAGE_IDLE := 0
const STAGE_ATTACK := 1
const STAGE_DECAY := 2
const STAGE_SUSTAIN := 3
const STAGE_RELEASE := 4

## Envelope parameter ids by stage (the engine's blocks-of-ten convention).
const ENV_STAGE_PARAM := {
	STAGE_ATTACK: 0,
	STAGE_DECAY: 10,
	STAGE_SUSTAIN: 20,
	STAGE_RELEASE: 30,
}

const LFO_SHAPE_PARAM := 0
const LFO_SUSTAIN_FIXED := 0.25

## Live payloads arrive with the status stream (~20 Hz), which would step the dot. The display
## interpolates instead: each frame blends from the previous sample towards the latest one over
## one payload interval, so the dot glides at frame rate (about one interval behind).
const INTERP_MIN_INTERVAL := 0.02
const INTERP_MAX_INTERVAL := 0.2

## Trace history: 40 samples at ~20 Hz is about 2 s.
const TRACE_SAMPLES := 40

## Sidechain history window in seconds.
const SC_WINDOW := 2.0

## Side of the hosted knob of a `knob` modulator, in pixels.
const KNOB_SIDE := 48

var device = null
var mod_id := -1

## The hosted Value knob's slot (null unless this modulator is a knob).
var _knob_slot: ModParamSlot = null

## Newest live values for the generic trace, oldest first.
var _trace: PackedFloat32Array = PackedFloat32Array()

## Sidechain output points (spec 044): arrival-stamped times (seconds) and 0..1 peaks, oldest
## first, trimmed to `SC_WINDOW`. `_sc_seen` turns on once a `kind 4` record arrived; an old
## engine never sends one and the generic `_trace` stays in use.
var _sc_times := PackedFloat64Array()
var _sc_values := PackedFloat32Array()
var _sc_seen := false
var _sc_last_time := -1.0

## Interpolation: the previous and latest payload snapshots with timestamps. `_interval`
## tracks the observed payload cadence so the blend finishes just as the next sample lands.
var _prev_state: Dictionary = {}
var _last_state: Dictionary = {}
var _last_stage := -1
var _last_time := 0.0
var _interval := 0.05


func setup(p_device, p_mod_id: int) -> void:
	if device == p_device and mod_id == p_mod_id \
			and ModLive.holder().modulator_states_changed.is_connected(_on_states_changed):
		return
	_unbind()
	device = p_device
	mod_id = p_mod_id
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	ModLive.holder().modulator_states_changed.connect(_on_states_changed)
	if device != null:
		device.modulator_changed.connect(_on_modulator_changed)
	tree_exiting.connect(_unbind)
	_build_knob()


## A knob modulator hosts its Value (param 0) as a real knob, bound like an options-pane slot.
func _build_knob() -> void:
	if _knob_slot != null and is_instance_valid(_knob_slot):
		_knob_slot.get_parent().queue_free()
		_knob_slot = null
	var mod := _modulator()
	if mod == null or mod.kind != "knob":
		return
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	_knob_slot = ModParamSlot.new()
	_knob_slot.param_id = 0
	_knob_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var knob := RotaryKnob.new()
	knob.custom_minimum_size = Vector2(KNOB_SIDE, KNOB_SIDE)
	knob.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_knob_slot.add_child(knob)
	centre.add_child(_knob_slot)
	_knob_slot.bind(mod)
	_apply_knob_polarity()


## A Bipolar knob reads -1..1 with 0 in the middle of the sweep (the stored value stays 0..1),
## and its value arc starts from the middle.
func _apply_knob_polarity() -> void:
	var knob := _knob_slot.control as RotaryKnob if _knob_slot != null else null
	var mod := _modulator()
	if knob == null or mod == null:
		return
	var bipolar := mod.is_bipolar()
	knob.bipolar = bipolar
	var p := _knob_slot.param
	if bipolar:
		knob.value_text_callback = func(v: float) -> String: return "%+.2f" % (v * 2.0 - 1.0)
	else:
		knob.value_text_callback = func(v: float) -> String: return SimpleUnits.format(p, v, "")
	knob.queue_redraw()


func _unbind() -> void:
	if ModLive.holder().modulator_states_changed.is_connected(_on_states_changed):
		ModLive.holder().modulator_states_changed.disconnect(_on_states_changed)
	if device != null and is_instance_valid(device):
		if device.modulator_changed.is_connected(_on_modulator_changed):
			device.modulator_changed.disconnect(_on_modulator_changed)


func _on_states_changed(p_device) -> void:
	if p_device != device:
		return
	var state := ModLive.modulator_state(device, mod_id)
	if _is_sidechain():
		var history := ModLive.sidechain_history(device, mod_id)
		if not history.is_empty():
			ingest_sidechain(history["peaks"], float(history["point_seconds"]), float(history["time"]))
			queue_redraw()
			set_process(true)
			return
		if state.is_empty():
			_sc_times.clear()
			_sc_values.clear()
			_sc_seen = false
			_sc_last_time = -1.0
	if not state.is_empty() and not _is_lfo() and not _is_envelope():
		_trace.append(float(state["value"]))
		while _trace.size() > TRACE_SAMPLES:
			_trace.remove_at(0)
	_remember_state(state)
	queue_redraw()

## Keep the numeric snapshot pair the dot interpolates between. Stage changes (envelope
## retriggers, idle) snap; a fresh stream after a gap starts with no previous sample.
func _remember_state(state: Dictionary) -> void:
	var now := _now()
	if state.is_empty():
		_prev_state = {}
		_last_state = {}
		_last_stage = -1
		set_process(false)
		return
	if not _last_state.is_empty():
		var raw := now - _last_time
		if raw > 0.01:
			_interval = clampf(lerpf(_interval, raw, 0.3), INTERP_MIN_INTERVAL, INTERP_MAX_INTERVAL)
	_prev_state = _last_state
	_last_state = {
		"x": clampf(float(state.get("x", 0.0)), 0.0, 1.0),
		"value": clampf(float(state["value"]), -1.0, 1.0),
		"stage": int(state.get("stage", -1)),
	}
	_last_stage = int(state.get("stage", -1))
	_last_time = now
	set_process(true)

## Blend the previous snapshot into the latest one as the next payload approaches.
func _live_state() -> Dictionary:
	if _last_state.is_empty():
		return {}
	if _prev_state.is_empty() or int(_prev_state.get("stage", -1)) != _last_stage:
		return _last_state
	var t := clampf((_now() - _last_time) / _interval, 0.0, 1.0)
	var out := {
		"x": _last_state["x"],
		"value": lerpf(float(_prev_state["value"]), float(_last_state["value"]), t),
		"stage": _last_stage,
	}
	if _is_lfo():
		# Unwrap the phase across cycle boundaries, then wrap modulo one cycle: the dot runs
		# forward and re-enters from the left edge instead of clamping at the right edge.
		var px := float(_prev_state["x"])
		var lx := float(_last_state["x"])
		if lx - px < -0.5:
			px -= 1.0
		elif lx - px > 0.5:
			px += 1.0
		var phase := fmod(lerpf(px, lx, t), 1.0)
		out["x"] = phase if phase >= 0.0 else phase + 1.0
		# The dot rides the drawn curve at the interpolated phase; the value is not
		# interpolated (lerping a square wave's end-of-cycle value looked wrong).
		out["value"] = _last_state["value"]
	return out

func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func _process(_delta: float) -> void:
	if _sc_seen and is_visible_in_tree():
		_trim_sidechain(_now())
		queue_redraw()
		if _sc_times.is_empty():
			set_process(false)
		return
	if _last_state.is_empty() or not is_visible_in_tree():
		set_process(false)
		return
	queue_redraw()
	# Once the blend has reached the latest sample, coast until the next payload
	# re-enables processing (a stopped stream leaves the dot parked at the sample).
	if _now() - _last_time > _interval * 1.25:
		set_process(false)


## Append a sidechain history: `peaks` (oldest first, 0..1) spaced `point_seconds` apart, the
## newest stamped `time` (seconds, the payload's arrival). A repeated `time` is ignored.
func ingest_sidechain(peaks: PackedFloat32Array, point_seconds: float, time: float) -> void:
	_sc_seen = true
	if peaks.is_empty() or is_equal_approx(time, _sc_last_time):
		return
	_sc_last_time = time
	var n := peaks.size()
	for i in n:
		_sc_times.append(time - float(n - 1 - i) * point_seconds)
		_sc_values.append(peaks[i])
	_trim_sidechain(maxf(time, _now()))


func _trim_sidechain(now: float) -> void:
	var drop := 0
	while drop < _sc_times.size() and _sc_times[drop] < now - SC_WINDOW - _interval:
		drop += 1
	if drop > 0:
		_sc_times = _sc_times.slice(drop)
		_sc_values = _sc_values.slice(drop)


## The sidechain line across `rect` at time `now`: the window scrolls by elapsed time and ends
## one payload interval behind `now` (like the dot), on a fixed 0..1 scale. Each pixel column
## keeps the maximum of its points, so a short peak survives the decimation.
func sidechain_points(rect: Rect2, now: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _sc_times.is_empty() or rect.size.x <= 0.0:
		return out
	var t_right := now - _interval
	var per_second := rect.size.x / SC_WINDOW
	var column_max := {}
	for i in _sc_times.size():
		if _sc_times[i] > t_right:
			break
		var x := rect.end.x - (t_right - _sc_times[i]) * per_second
		if x < rect.position.x:
			continue
		var column := int(floor(x - rect.position.x))
		column_max[column] = maxf(column_max.get(column, 0.0), _sc_values[i])
	var columns: Array = column_max.keys()
	columns.sort()
	for column in columns:
		out.append(Vector2(rect.position.x + float(column) + 0.5,
			rect.position.y + (1.0 - clampf(column_max[column], 0.0, 1.0)) * rect.size.y))
	return out


## The dot at the newest drawn point: right edge, at that point's value.
func _sidechain_dot(rect: Rect2, now: float) -> Variant:
	var t_right := now - _interval
	var newest := -1
	for i in range(_sc_times.size() - 1, -1, -1):
		if _sc_times[i] <= t_right:
			newest = i
			break
	if newest < 0:
		return null
	return Vector2(rect.end.x, rect.position.y + (1.0 - clampf(_sc_values[newest], 0.0, 1.0)) * rect.size.y)


func _on_modulator_changed(changed_mod_id: int) -> void:
	if changed_mod_id == mod_id:
		if _knob_slot != null:
			_knob_slot.refresh()
			_apply_knob_polarity()
		queue_redraw()


# ============================================================================
# DRAW
# ============================================================================

func _draw() -> void:
	var mod = _modulator()
	if mod == null or _is_knob():
		return
	var line := UiColors.role(&"accent_primary")
	var rect := Rect2(Vector2(3, 3), size - Vector2(6, 6))
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var points := _shape_points(mod, rect)
	if points.size() >= 2:
		draw_polyline(points, line, 1.5, true)
	elif points.size() == 1:
		draw_circle(points[0], 1.0, line, true, -1.0, true)
	var dot: Variant = _dot(mod, rect)
	if dot != null:
		draw_circle(dot, 2.5, Color.WHITE, true, -1.0, true)


## The kind's shape as points across `rect` (one when the shape is a single point).
func _shape_points(mod: Modulator, rect: Rect2) -> PackedVector2Array:
	if _is_lfo():
		return _lfo_points(mod, rect)
	if _is_envelope():
		return _envelope_points(mod, rect)
	if _is_knob():
		return _knob_points(mod, rect)
	if _is_sidechain() and _sc_seen:
		return sidechain_points(rect, _now())
	return _trace_points(rect)


## A knob draws as an arc glyph: from the start of the sweep up to its Value, or centred on the
## middle of the sweep when the knob is Bipolar (REQ-002). No trace ring — the value is static.
func _knob_points(mod: Modulator, rect: Rect2) -> PackedVector2Array:
	var value := clampf(mod.get_param(0), 0.0, 1.0)
	var from := 0.5 if mod.is_bipolar() else 0.0
	var lo := minf(from, value)
	var hi := maxf(from, value)
	if hi - lo < 0.004:
		hi = lo + 0.004
	var out := PackedVector2Array()
	var steps := 32
	for i in range(steps + 1):
		var t := lerpf(lo, hi, float(i) / float(steps))
		out.append(_knob_point_at(rect, t))
	return out


## A point on the knob's arc: the sweep runs 270° from the bottom-left (t = 0) clockwise past
## the top (t = 0.5) to the bottom-right (t = 1), like the device knobs.
func _knob_point_at(rect: Rect2, t: float) -> Vector2:
	var centre := rect.get_center()
	var radius := minf(rect.size.x, rect.size.y) * 0.5
	var angle := deg_to_rad(135.0 + 270.0 * clampf(t, 0.0, 1.0))
	return centre + Vector2(cos(angle), sin(angle)) * radius


func _lfo_points(mod: Modulator, rect: Rect2) -> PackedVector2Array:
	var steps := 48
	var out := PackedVector2Array()
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		out.append(rect.position + Vector2(t * rect.size.x, (0.5 - 0.5 * _lfo_wave(mod, t)) * rect.size.y))
	return out


func _lfo_wave(mod: Modulator, t: float) -> float:
	var param = mod.get_parameter(LFO_SHAPE_PARAM)
	var shape := "sine"
	if param != null and not param.enum_values.is_empty():
		var n := maxi(1, param.enum_values.size())
		var index := clampi(int(round(mod.get_param(LFO_SHAPE_PARAM) * float(n - 1))), 0, n - 1)
		shape = String(param.enum_values[index]).to_lower()
	if shape.contains("tri"):
		return 1.0 - 4.0 * absf(t - 0.5)
	if shape.contains("saw"):
		return 2.0 * t - 1.0
	if shape.contains("square"):
		return 1.0 if t < 0.5 else -1.0
	if shape.contains("s&h") or shape.contains("sample"):
		return _sah_glyph(t)
	return sin(TAU * t)


## Fixed staircase glyph for S&H: its values are random, so only the shape is drawn.
func _sah_glyph(t: float) -> float:
	var steps := [0.5, -0.25, 0.75, -0.6, 0.3, -0.85, 0.15, -0.45]
	return steps[clampi(int(t * steps.size()), 0, steps.size() - 1)]


func _envelope_points(mod: Modulator, rect: Rect2) -> PackedVector2Array:
	var times := {}
	for stage in [STAGE_ATTACK, STAGE_DECAY, STAGE_SUSTAIN, STAGE_RELEASE]:
		var param = mod.get_parameter(ENV_STAGE_PARAM[stage])
		if param != null:
			times[stage] = maxf(param.normalized_to_value(mod.get_param(ENV_STAGE_PARAM[stage])), 0.001)
	var sustain: float = mod.get_param(ENV_STAGE_PARAM[STAGE_SUSTAIN]) if mod.get_parameter(ENV_STAGE_PARAM[STAGE_SUSTAIN]) != null else 0.0
	var attack: float = times.get(STAGE_ATTACK, 0.0)
	var decay: float = times.get(STAGE_DECAY, 0.0)
	var release: float = times.get(STAGE_RELEASE, 0.0)
	var out := PackedVector2Array()
	if mod.kind == "ad":
		# Attack and decay only, time-proportional across the full width.
		var total := maxf(attack + decay, 0.001)
		var split := attack / total
		var w := rect.size.x
		out.append(rect.position + Vector2(0, rect.size.y))
		out.append(rect.position + Vector2(split * w, 0))
		out.append(rect.position + Vector2(w, rect.size.y))
		return out
	# ADSR: attack/decay/release proportional to their times, sustain a fixed width.
	var proportional := maxf(attack + decay + release, 0.001)
	var sustain_w := LFO_SUSTAIN_FIXED * rect.size.x
	var var_w := rect.size.x - sustain_w
	var x_attack := attack / proportional * var_w
	var x_decay := decay / proportional * var_w
	var x_release := release / proportional * var_w
	out.append(rect.position + Vector2(0, rect.size.y))
	out.append(rect.position + Vector2(x_attack, 0))
	out.append(rect.position + Vector2(x_attack + x_decay, (1.0 - sustain) * rect.size.y))
	out.append(rect.position + Vector2(x_attack + x_decay + sustain_w, (1.0 - sustain) * rect.size.y))
	out.append(rect.position + Vector2(rect.size.x, rect.size.y))
	return out


func _trace_points(rect: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _trace.size() < 2:
		return out
	var lo := -1.0 if _bipolar() else 0.0
	var hi := 1.0
	var span := hi - lo
	for i in _trace.size():
		var t := float(i) / float(maxi(_trace.size() - 1, 1))
		var y := (1.0 - (clampf(_trace[i], lo, hi) - lo) / span) * rect.size.y
		out.append(rect.position + Vector2(t * rect.size.x, y))
	return out


# ============================================================================
# DOT
# ============================================================================

## The white dot's position in local coordinates, or null when there is no live state.
func dot_position() -> Variant:
	var mod = _modulator()
	if mod == null:
		return null
	return _dot(mod, Rect2(Vector2(3, 3), size - Vector2(6, 6)))


## `true` when a live state is on screen (the verify hook for "no dot when idle").
func has_dot() -> bool:
	return dot_position() != null


func _dot(mod: Modulator, rect: Rect2) -> Variant:
	if _is_sidechain() and _sc_seen:
		return _sidechain_dot(rect, _now())
	var state := _live_state()
	if state.is_empty():
		return null
	if _is_lfo():
		# Only the phase is live; the dot sits on the drawn curve at that phase, so it never
		# leaves the wave (and never lerps a discontinuity like a square wave's cycle end).
		var phase: float = clampf(float(state["x"]), 0.0, 1.0)
		var value: float = _lfo_wave(mod, phase)
		return rect.position + Vector2(phase * rect.size.x, (0.5 - 0.5 * value) * rect.size.y)
	if _is_knob():
		# The dot rides the arc at the live value: the engine reports a knob's output
		# (0..1 unipolar, −1..1 bipolar), remapped onto the 0..1 sweep.
		var live: float = float(state["value"])
		var t := clampf((live + 1.0) * 0.5, 0.0, 1.0) if mod.is_bipolar() else clampf(live, 0.0, 1.0)
		return _knob_point_at(rect, t)
	if _is_envelope():
		return _envelope_dot(mod, rect, state)
	# Generic kinds: the dot rides the newest trace value, interpolated like the rest.
	if _trace.is_empty():
		return null
	var lo := -1.0 if _bipolar() else 0.0
	var y := (1.0 - (clampf(float(state["value"]), lo, 1.0) - lo)) * rect.size.y
	return rect.position + Vector2(rect.size.x, y)


func _envelope_dot(mod: Modulator, rect: Rect2, state: Dictionary) -> Variant:
	var stage := int(state["stage"])
	var level: float = clampf(float(state["value"]), 0.0, 1.0)
	if stage == STAGE_IDLE:
		return null
	var times := {}
	for s in [STAGE_ATTACK, STAGE_DECAY, STAGE_SUSTAIN, STAGE_RELEASE]:
		var param = mod.get_parameter(ENV_STAGE_PARAM[s])
		if param != null:
			times[s] = maxf(param.normalized_to_value(mod.get_param(ENV_STAGE_PARAM[s])), 0.001)
	var sustain: float = mod.get_param(ENV_STAGE_PARAM[STAGE_SUSTAIN]) if mod.get_parameter(ENV_STAGE_PARAM[STAGE_SUSTAIN]) != null else 0.0
	var attack: float = times.get(STAGE_ATTACK, 0.0)
	var decay: float = times.get(STAGE_DECAY, 0.0)
	var release: float = times.get(STAGE_RELEASE, 0.0)
	var y: float
	var frac: float
	if stage == STAGE_ATTACK:
		y = level
		frac = level
	elif stage == STAGE_DECAY:
		y = level
		if mod.kind == "ad":
			frac = 1.0 - level
		else:
			frac = (1.0 - level) / maxf(1.0 - sustain, 0.001)
	elif stage == STAGE_SUSTAIN:
		y = sustain
		frac = 0.5
	elif stage == STAGE_RELEASE:
		y = level
		frac = 1.0 - level / maxf(sustain, 0.001)
	else:
		return null
	var x := 0.0
	if mod.kind == "ad":
		var total := maxf(attack + decay, 0.001)
		if stage == STAGE_ATTACK:
			x = attack / total * rect.size.x * level
		else:
			x = (attack + (1.0 - level) * decay) / total * rect.size.x
	else:
		var proportional := maxf(attack + decay + release, 0.001)
		var sustain_w := LFO_SUSTAIN_FIXED * rect.size.x
		var var_w := rect.size.x - sustain_w
		var x_attack := attack / proportional * var_w
		var x_decay := decay / proportional * var_w
		var x_release := release / proportional * var_w
		match stage:
			STAGE_ATTACK:
				x = x_attack * frac
			STAGE_DECAY:
				x = x_attack + x_decay * frac
			STAGE_SUSTAIN:
				x = x_attack + x_decay + sustain_w * frac
			STAGE_RELEASE:
				x = x_attack + x_decay + sustain_w + x_release * frac
	return rect.position + Vector2(x, (1.0 - y) * rect.size.y)


# ============================================================================
# HELPERS
# ============================================================================

func _modulator() -> Modulator:
	if device == null or not is_instance_valid(device) or mod_id < 0:
		return null
	return device.get_modulator(mod_id)


func _kind() -> String:
	var mod = _modulator()
	return mod.kind if mod != null else ""


func _is_lfo() -> bool:
	return _kind() == "lfo"


func _is_envelope() -> bool:
	return _kind() == "adsr" or _kind() == "ad"


func _is_sidechain() -> bool:
	return _kind() == "sidechain"


func _is_knob() -> bool:
	return _kind() == "knob"


func _bipolar() -> bool:
	# Per instance (spec 036 D1): a knob's Polarity is its own parameter, the other kinds read
	# their kind table through `is_bipolar`.
	var mod = _modulator()
	return mod.is_bipolar() if mod != null else false
