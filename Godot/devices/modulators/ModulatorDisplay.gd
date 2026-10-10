## One modulator panel's kind display (spec 033): a `_draw()` shape of the modulator's output
## with a white dot at the engine-reported live position.
##
## Bound to `(device, mod_id)` through `setup`. It redraws on `ModLive.modulator_states_changed`
## for its device and on `modulator_changed` (shape parameters); while live states flow it also
## redraws per frame, interpolating the dot between the last two samples (see INTERP_* above).
## Shapes: an LFO draws one cycle of its wave (S&H a fixed staircase glyph); an envelope draws
## its time-proportional curve; every other kind draws a ~2 s ring-buffer trace of recent values,
## with the dot at the newest point. Missing state (old engine, before the first payload) leaves
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

var device = null
var mod_id := -1

## Newest live values for the generic trace, oldest first.
var _trace: PackedFloat32Array = PackedFloat32Array()

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
	if _last_state.is_empty() or not is_visible_in_tree():
		set_process(false)
		return
	queue_redraw()
	# Once the blend has reached the latest sample, coast until the next payload
	# re-enables processing (a stopped stream leaves the dot parked at the sample).
	if _now() - _last_time > _interval * 1.25:
		set_process(false)


func _on_modulator_changed(changed_mod_id: int) -> void:
	if changed_mod_id == mod_id:
		queue_redraw()


# ============================================================================
# DRAW
# ============================================================================

func _draw() -> void:
	var mod = _modulator()
	if mod == null:
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
	return _trace_points(rect)


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
	var state := _live_state()
	if state.is_empty():
		return null
	if _is_lfo():
		# Only the phase is live; the dot sits on the drawn curve at that phase, so it never
		# leaves the wave (and never lerps a discontinuity like a square wave's cycle end).
		var phase: float = clampf(float(state["x"]), 0.0, 1.0)
		var value: float = _lfo_wave(mod, phase)
		return rect.position + Vector2(phase * rect.size.x, (0.5 - 0.5 * value) * rect.size.y)
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


func _bipolar() -> bool:
	return device.is_modulator_kind_bipolar(_kind())
