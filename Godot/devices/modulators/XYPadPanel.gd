## The compact interactive XY pad inside an XY pad tile (spec 036): an `XYSlider` bound to both
## slots of an `XYPad`, with the white live dot drawn from the engine's `kind 2` states.
##
## Both slots carry parameter 0 = Position (0..1); the engine reports each slot's value as
## 2·pos − 1, so the dot maps back onto the pad. Dragging the pad writes one
## `modulator/{id}/param/0/value` per slot and never starts the tile's select/drag logic: the
## panel takes the mouse (`MOUSE_FILTER_STOP`) and accepts the slider's passed-through events
## in its own `_gui_input`.
class_name XYPadPanel extends Control

## Live payloads arrive with the status stream (~20 Hz); the dot interpolates between the last
## two samples over the observed payload interval, like `ModulatorDisplay`.
const INTERP_MIN_INTERVAL := 0.02
const INTERP_MAX_INTERVAL := 0.2

var pad: XYPad = null
var _slider: XYSlider = null

## Interpolation state: the previous and latest live positions, with timestamps.
var _prev_pos := Vector2.INF
var _last_pos := Vector2.INF
var _last_time := 0.0
var _interval := 0.05


func setup(p_pad: XYPad) -> void:
	pad = p_pad
	if _slider == null:
		_build()
	if not ModLive.holder().modulator_states_changed.is_connected(_on_states_changed):
		ModLive.holder().modulator_states_changed.connect(_on_states_changed)
	var device = pad.owner()
	if device != null and not device.modulator_changed.is_connected(_on_modulator_changed):
		device.modulator_changed.connect(_on_modulator_changed)
	tree_exiting.connect(_unbind)
	_refresh_from_model()


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_slider = XYSlider.new()
	_slider.x_min = 0.0
	_slider.x_max = 1.0
	_slider.y_min = 0.0
	_slider.y_max = 1.0
	_slider.show_value_labels = false
	_slider.show_axis_lines = false
	_slider.handle_radius = 3.0
	# PASS: the slider handles its own drag, then the panel consumes the event so it never
	# reaches the tile's select/drag `_gui_input`.
	_slider.mouse_filter = Control.MOUSE_FILTER_PASS
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_slider)
	_slider.values_changed.connect(_on_values_changed)


func _get_minimum_size() -> Vector2:
	return _slider.get_combined_minimum_size() if _slider != null else Vector2.ZERO


## XYPadPanel is a plain Control, not a container: the slider must be sized by hand,
## or it keeps its 12×12 minimum and the pad appears 0-size inside the tile.
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _slider != null:
		_slider.position = Vector2.ZERO
		_slider.size = size

func _unbind() -> void:
	if ModLive.holder().modulator_states_changed.is_connected(_on_states_changed):
		ModLive.holder().modulator_states_changed.disconnect(_on_states_changed)
	var device = pad.owner() if pad != null else null
	if device != null and is_instance_valid(device) \
			and device.modulator_changed.is_connected(_on_modulator_changed):
		device.modulator_changed.disconnect(_on_modulator_changed)


## Programmatic move (also the test hook): drives the same path as a drag.
func set_values(x: float, y: float) -> void:
	if _slider != null:
		_slider.set_values(x, y)


func _on_values_changed(x: float, y: float) -> void:
	if pad != null:
		pad.set_position(Vector2(x, y))


## The model moved (either slot): follow without echoing a `values_changed` back.
func _on_modulator_changed(_mod_id: int) -> void:
	_refresh_from_model()


func _refresh_from_model() -> void:
	if pad == null or _slider == null:
		return
	var pos := pad.position()
	_slider.set_values_no_signal(pos.x, pos.y)


# ============================================================================
# LIVE DOT
# ============================================================================

func _on_states_changed(device) -> void:
	if pad == null or device != pad.owner():
		return
	var x_state := ModLive.modulator_state(device, pad.x.mod_id)
	var y_state := ModLive.modulator_state(device, pad.y.mod_id)
	if x_state.is_empty() or y_state.is_empty():
		_prev_pos = Vector2.INF
		_last_pos = Vector2.INF
		set_process(false)
		queue_redraw()
		return
	var now := Time.get_ticks_usec() / 1000000.0
	if _last_pos != Vector2.INF:
		var raw := now - _last_time
		if raw > 0.01:
			_interval = clampf(lerpf(_interval, raw, 0.3), INTERP_MIN_INTERVAL, INTERP_MAX_INTERVAL)
	_prev_pos = _last_pos
	_last_pos = Vector2(_slot_position(x_state), _slot_position(y_state))
	_last_time = now
	set_process(true)
	queue_redraw()


## A slot's engine-reported value (−1..1) back onto the pad's 0..1 axis.
func _slot_position(state: Dictionary) -> float:
	return clampf((float(state["value"]) + 1.0) * 0.5, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _last_pos == Vector2.INF or not is_visible_in_tree():
		set_process(false)
		return
	queue_redraw()
	if Time.get_ticks_usec() / 1000000.0 - _last_time > _interval * 1.25:
		set_process(false)


func _draw() -> void:
	if pad == null or _slider == null or _last_pos == Vector2.INF:
		return
	var t := 1.0
	if _prev_pos != Vector2.INF:
		t = clampf((Time.get_ticks_usec() / 1000000.0 - _last_time) / _interval, 0.0, 1.0)
	var pos := _last_pos if t >= 1.0 else _prev_pos.lerp(_last_pos, t)
	var radius: float = _slider.handle_radius
	var rect := Rect2(_slider.position, _slider.size)
	var point := Vector2(
		remap(pos.x, 0.0, 1.0, radius, rect.size.x - radius),
		remap(pos.y, 0.0, 1.0, rect.size.y - radius, radius))
	draw_circle(rect.position + point, 2.0, Color.WHITE, true, -1.0, true)


# ============================================================================
# INPUT
# ============================================================================

## The slider passes presses through after handling its own drag; accepting here keeps the
## tile's select/drag logic (its own `_gui_input`) out of pad presses entirely.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()
