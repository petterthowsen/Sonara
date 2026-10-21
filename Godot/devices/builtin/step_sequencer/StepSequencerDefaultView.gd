## Panel view of the built-in Step Sequencer (spec 039): the pattern and timing controls in a
## column on the left, and to their right a step-number row, the On row, the Pitch lane and a
## Velocity | Chance lane, all sharing the same 16 columns. The layout lives in
## `StepSequencerDefaultView.tscn`; this script wires it to the device. The lanes edit the
## device through `DeviceInstance.set_parameter_real` only. While shown the view subscribes to the device's
## `"note_state"` stream and drives a `StepPlayhead` (playhead column, fired flashes).
class_name StepSequencerDefaultView extends DeviceView

const StepPlayhead := preload("res://devices/builtin/step_sequencer/StepPlayhead.gd")

const DATA_TYPE := "note_state"
const STEPS := 16
const FLASH_MS := 150.0
## App-config key for the Pitch lane's display range (the same for every Step Sequencer).
const RANGE_CONFIG_KEY := "devices/step_sequencer/pitch_range"
## Selectable half-ranges of the Pitch lane, in semitones; the first is the default.
const PITCH_RANGES := [24, 12]

const P_LENGTH := 0
const P_MODE := 1
const P_VELOCITY_SOURCE := 2
const P_RATE := 10
const P_GATE := 11
const P_SWING := 12
const FIELD_ON := 0
const FIELD_PITCH := 1
const FIELD_VELOCITY := 2
const FIELD_CHANCE := 3
const LOWER_FIELDS := [FIELD_VELOCITY, FIELD_CHANCE]

## Injectable for tests: the millisecond clock, and the output latency in ms.
var now_ms_provider: Callable = Callable(self, "_real_now_ms")
var latency_provider: Callable = Callable(self, "_real_latency_ms")
## Injectable for tests: read / write the view's app-config settings.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

@onready var length_slider: CompactSlider = %LengthSlider
@onready var rate_option: OptionButton = %RateOption
@onready var gate_slider: CompactSlider = %GateSlider
@onready var swing_slider: CompactSlider = %SwingSlider
@onready var mode_control: SegmentedControl = %ModeControl
@onready var velocity_source_control: SegmentedControl = %VelocitySourceControl
@onready var number_row: StepNumberRow = %NumberRow
@onready var on_lane: StepLane = %OnLane
@onready var pitch_lane: StepLane = %PitchLane
@onready var lower_lane: StepLane = %LowerLane
@onready var lower_switch: SegmentedControl = %LowerSwitch
@onready var range_control: SegmentedControl = %RangeControl
## Half-range of the Pitch lane in semitones (12 or 24). View-only: the parameter keeps +-24.
var pitch_range := 24
var playhead := StepPlayhead.new()
## 0 = Velocity, 1 = Chance. Lasts as long as the view; not saved.
var lower_choice := 0

@onready var _box: HBoxContainer = %Box
var _subscribed_path := ""
## step -> time (ms) its flash started.
var _flash_start: Dictionary = {}
var _last_step := -1


## Hook the scene's controls to their handlers, then bind if a device arrived before the tree.
func _ready() -> void:
	set_process(false)
	_box.minimum_size_changed.connect(update_minimum_size)
	for pair in [[length_slider, P_LENGTH], [gate_slider, P_GATE], [swing_slider, P_SWING]]:
		var slider: CompactSlider = pair[0]
		var id: int = pair[1]
		slider.value_text_callback = func(v: float) -> String:
			return "%d" % roundi(v) if id == P_LENGTH else "%d %%" % roundi(v)
		slider.value_changed.connect(_on_slider_changed.bind(id))
		slider.reset_requested.connect(_reset.bind(id))
	rate_option.item_selected.connect(_on_rate_selected)
	mode_control.selected_changed.connect(_on_option_selected.bind(P_MODE))
	velocity_source_control.selected_changed.connect(_on_option_selected.bind(P_VELOCITY_SOURCE))
	range_control.selected_changed.connect(_on_range_selected)
	on_lane.value_edited.connect(_on_lane_edited.bind(FIELD_ON))
	pitch_lane.value_text_callback = func(v: float) -> String: return "%+d st" % roundi(v)
	pitch_lane.value_edited.connect(_on_lane_edited.bind(FIELD_PITCH))
	lower_switch.selected_changed.connect(_on_lower_switch)
	lower_lane.value_text_callback = func(v: float) -> String: return "%d %%" % roundi(v)
	lower_lane.value_edited.connect(_on_lane_edited.bind(-1))
	if device != null:
		_setup()


func _get_minimum_size() -> Vector2:
	return _box.get_combined_minimum_size() if _box else Vector2.ZERO


static func step_param(k: int, field: int) -> int:
	return 100 + 10 * k + field


# ============================================================================
# BINDING AND SYNC
# ============================================================================

func _on_bind() -> void:
	if is_node_ready():
		_setup()


func _setup() -> void:
	if device == null:
		return
	_configure_slider(length_slider, P_LENGTH)
	_configure_slider(gate_slider, P_GATE)
	_configure_slider(swing_slider, P_SWING)
	for pair in [[length_slider, P_LENGTH], [gate_slider, P_GATE], [swing_slider, P_SWING]]:
		if device.get_parameter(pair[1]) != null:
			ModAssign.attach(pair[0], device, pair[1])
	rate_option.clear()
	var rate := device.get_parameter(P_RATE)
	if rate != null:
		for label in rate.enum_values:
			rate_option.add_item(label)
	var mode := device.get_parameter(P_MODE)
	if mode != null and mode.enum_values.size() == 2:
		mode_control.set_items(PackedStringArray(mode.enum_values))
	_configure_lane_defaults()
	var saved: Variant = load_config.call(RANGE_CONFIG_KEY)
	_apply_pitch_range(12 if (saved is int or saved is float) and int(saved) == 12 else 24)
	_refresh()


func _configure_slider(slider: CompactSlider, id: int) -> void:
	var p := device.get_parameter(id)
	if p == null:
		return
	slider.min_value = p.min_value
	slider.max_value = p.max_value
	slider.default_value = p.default_value


## Lane ranges and defaults come from the step parameters (step 1 stands for all 16).
func _configure_lane_defaults() -> void:
	var pitch := device.get_parameter(step_param(0, FIELD_PITCH))
	if pitch != null:
		pitch_lane.min_value = pitch.min_value
		pitch_lane.max_value = pitch.max_value
		pitch_lane.default_value = pitch.default_value
	_configure_lower_lane()


## Show the Pitch lane over +-`half` semitones. Display only; values outside it are drawn clamped.
func _apply_pitch_range(half: int) -> void:
	pitch_range = 12 if half == 12 else 24
	pitch_lane.min_value = -float(pitch_range)
	pitch_lane.max_value = float(pitch_range)
	pitch_lane.guide_values = PackedFloat32Array([-12.0, 12.0]) if pitch_range == 24 \
			else PackedFloat32Array([-6.0, 6.0])
	range_control.set_selected_no_signal(PITCH_RANGES.find(pitch_range))


func _on_range_selected(index: int) -> void:
	_apply_pitch_range(PITCH_RANGES[clampi(index, 0, PITCH_RANGES.size() - 1)])
	save_config.call(RANGE_CONFIG_KEY, pitch_range)


func _load_app_config(key: String) -> Variant:
	var sonara := _autoload("Sonara")
	return sonara.get_config(key, 24) if sonara != null else 24


func _save_app_config(key: String, value: Variant) -> void:
	var sonara := _autoload("Sonara")
	if sonara == null:
		return
	sonara.set_config(key, value)
	sonara.save_config()


func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null


func _configure_lower_lane() -> void:
	var p := device.get_parameter(step_param(0, LOWER_FIELDS[lower_choice])) if device else null
	if p != null:
		lower_lane.min_value = p.min_value
		lower_lane.max_value = p.max_value
		lower_lane.default_value = p.default_value


func _lower_field() -> int:
	return LOWER_FIELDS[lower_choice]


func _read(id: int, fallback: float) -> float:
	return device.get_parameter_real(id) if device != null and device.get_parameter(id) != null else fallback


## Push every parameter into the controls and lanes, without emitting.
func _refresh() -> void:
	if device == null:
		return
	length_slider.set_value_no_signal(_read(P_LENGTH, 16.0))
	gate_slider.set_value_no_signal(_read(P_GATE, 100.0))
	swing_slider.set_value_no_signal(_read(P_SWING, 0.0))
	rate_option.select(roundi(_read(P_RATE, 0.0)))
	mode_control.set_selected_no_signal(roundi(_read(P_MODE, 0.0)))
	velocity_source_control.set_selected_no_signal(roundi(_read(P_VELOCITY_SOURCE, 0.0)))
	lower_switch.set_selected_no_signal(lower_choice)
	var on := PackedFloat32Array()
	var pitch := PackedFloat32Array()
	var lower := PackedFloat32Array()
	var off_mask := 0
	for k in STEPS:
		var is_on := _read(step_param(k, FIELD_ON), 1.0) >= 0.5
		on.append(1.0 if is_on else 0.0)
		if not is_on:
			off_mask |= 1 << k
		pitch.append(_read(step_param(k, FIELD_PITCH), 0.0))
		lower.append(_read(step_param(k, _lower_field()), 100.0))
	on_lane.set_values_no_signal(on)
	pitch_lane.set_values_no_signal(pitch)
	lower_lane.set_values_no_signal(lower)
	_set_off_mask(off_mask)
	_set_length(roundi(_read(P_LENGTH, 16.0)))


func _set_off_mask(mask: int) -> void:
	for lane in [on_lane, pitch_lane, lower_lane]:
		lane.off_mask = mask


func _set_length(n: int) -> void:
	for lane in [on_lane, pitch_lane, lower_lane]:
		lane.length = n
	number_row.length = n


func _current_off_mask() -> int:
	return on_lane.off_mask


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if device == null or not is_node_ready():
		return
	match param_id:
		P_LENGTH:
			var n := roundi(_read(P_LENGTH, 16.0))
			length_slider.set_value_no_signal(n)
			_set_length(n)
		P_MODE:
			mode_control.set_selected_no_signal(roundi(_read(P_MODE, 0.0)))
		P_VELOCITY_SOURCE:
			velocity_source_control.set_selected_no_signal(roundi(_read(P_VELOCITY_SOURCE, 0.0)))
		P_RATE:
			rate_option.select(roundi(_read(P_RATE, 0.0)))
		P_GATE:
			gate_slider.set_value_no_signal(_read(P_GATE, 100.0))
		P_SWING:
			swing_slider.set_value_no_signal(_read(P_SWING, 0.0))
		_:
			if param_id < 100 or param_id >= step_param(STEPS, 0):
				return
			var k := (param_id - 100) / 10
			var field := (param_id - 100) % 10
			var v := _read(param_id, 0.0)
			match field:
				FIELD_ON:
					on_lane.set_value_no_signal(k, 1.0 if v >= 0.5 else 0.0)
					var mask := _current_off_mask()
					mask = (mask & ~(1 << k)) if v >= 0.5 else (mask | (1 << k))
					_set_off_mask(mask)
				FIELD_PITCH:
					pitch_lane.set_value_no_signal(k, v)
				FIELD_VELOCITY, FIELD_CHANCE:
					if field == _lower_field():
						lower_lane.set_value_no_signal(k, v)


# ============================================================================
# EDITS
# ============================================================================

func _write(param_id: int, value: float) -> void:
	if device != null:
		ParameterActions.set_real(device, param_id, value)


func _reset(param_id: int) -> void:
	var p := device.get_parameter(param_id) if device != null else null
	if p != null:
		ParameterActions.set_real(device, param_id, p.default_value)


## `field` -1 = the Lower lane's current field.
func _on_lane_edited(step: int, value: float, field: int) -> void:
	if field < 0:
		field = _lower_field()
	_write(step_param(step, field), value)


func _on_slider_changed(value: float, param_id: int) -> void:
	_write(param_id, value)


func _on_option_selected(index: int, param_id: int) -> void:
	_write(param_id, float(index))


func _on_rate_selected(index: int) -> void:
	_write(P_RATE, float(index))


func _on_lower_switch(index: int) -> void:
	lower_choice = clampi(index, 0, 1)
	_configure_lower_lane()
	if device == null:
		return
	var lower := PackedFloat32Array()
	for k in STEPS:
		lower.append(_read(step_param(k, _lower_field()), 100.0))
	lower_lane.set_values_no_signal(lower)


# ============================================================================
# LIVE FEEDBACK
# ============================================================================

func _real_now_ms() -> float:
	return float(Time.get_ticks_msec())


func _real_latency_ms() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var cfg: Node = tree.root.get_node_or_null("AudioConfig") if tree != null else null
	if cfg == null:
		return 0.0
	var conf: Variant = cfg.get("config")
	return float(conf.get("latency_ms", 0.0)) if conf is Dictionary else 0.0


func _on_view_shown() -> void:
	if device == null:
		return
	_subscribed_path = device.osc_path()
	AudioEngineOSC.subscribe_device_data(_subscribed_path, DATA_TYPE)
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)


func _on_view_hidden() -> void:
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _subscribed_path != "":
		AudioEngineOSC.unsubscribe_device_data(_subscribed_path, DATA_TYPE)
		_subscribed_path = ""
	_clear_live()


func _clear_live() -> void:
	playhead.clear()
	_flash_start.clear()
	_last_step = -1
	set_process(false)
	if not is_node_ready():
		return
	for lane in [on_lane, pitch_lane, lower_lane]:
		lane.clear_flashes()
	number_row.playhead = -1


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != DATA_TYPE or device == null or osc_path != _subscribed_path or not is_node_ready():
		return
	var state := NoteStrip.decode(blob)
	var now: float = now_ms_provider.call()
	playhead.feed(state, now, float(latency_provider.call()), roundi(_read(P_LENGTH, 16.0)))
	_tick(now)
	set_process(true)


func _process(_delta: float) -> void:
	_tick(float(now_ms_provider.call()))


## Push the displayed step and flash levels into the lanes; stop `_process` when nothing is live.
func _tick(now: float) -> void:
	var step := playhead.step_at(now)
	if step != _last_step:
		_last_step = step
		for lane in [on_lane, pitch_lane, lower_lane]:
			lane.playhead = step
		number_row.playhead = step
	for k in playhead.take_flashes(now):
		_flash_start[k] = now
	var done := []
	for k in _flash_start:
		var level := 1.0 - (now - float(_flash_start[k])) / FLASH_MS
		if level <= 0.0:
			done.append(k)
			level = 0.0
		for lane in [on_lane, pitch_lane, lower_lane]:
			lane.set_flash(k, level)
	for k in done:
		_flash_start.erase(k)
	if not playhead.is_active(now) and _flash_start.is_empty():
		set_process(false)
