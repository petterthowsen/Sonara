## Panel view of the built-in Step Sequencer (spec 039): the pattern and timing controls in a
## column on the left, and to their right a step-number row, the On row, the Pitch lane and a
## Velocity | Chance lane, all sharing the same 16 columns. The lanes edit the device through
## `DeviceInstance.set_parameter_real` only. While shown the view subscribes to the device's
## `"note_state"` stream and drives a `StepPlayhead` (playhead column, fired flashes).
class_name StepSequencerDefaultView extends DeviceView

const StepPlayhead := preload("res://devices/builtin/StepPlayhead.gd")

const DATA_TYPE := "note_state"
const STEPS := 16
const FLASH_MS := 150.0
const LEFT_WIDTH := 130.0
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
const VELOCITY_SOURCE_LABELS := ["In × Step", "Step"]

## Injectable for tests: the millisecond clock, and the output latency in ms.
var now_ms_provider: Callable = Callable(self, "_real_now_ms")
var latency_provider: Callable = Callable(self, "_real_latency_ms")
## Injectable for tests: read / write the view's app-config settings.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

var length_slider: CompactSlider
var rate_option: OptionButton
var gate_slider: CompactSlider
var swing_slider: CompactSlider
var mode_control: SegmentedControl
var velocity_source_control: SegmentedControl
var number_row: _NumberRow
var on_lane: StepLane
var pitch_lane: StepLane
var lower_lane: StepLane
var lower_switch: SegmentedControl
var range_control: SegmentedControl
## Half-range of the Pitch lane in semitones (12 or 24). View-only: the parameter keeps +-24.
var pitch_range := 24
var playhead := StepPlayhead.new()
## 0 = Velocity, 1 = Chance. Lasts as long as the view; not saved.
var lower_choice := 0

var _box: HBoxContainer
var _subscribed_path := ""
## step -> time (ms) its flash started.
var _flash_start: Dictionary = {}
var _last_step := -1


## Step numbers over the lanes' columns (same geometry as `StepLane`), with the playhead column lit.
class _NumberRow extends Control:
	var step_count := STEPS
	var group_size := 4
	var playhead := -1:
		set(p):
			if p != playhead:
				playhead = p
				queue_redraw()
	var length := STEPS:
		set(n):
			length = n
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(StepLane.min_width_for(step_count, group_size), 14.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func column_rect(k: int) -> Rect2:
		var gaps := maxi(ceili(float(step_count) / group_size) - 1, 0)
		var w := maxf((size.x - gaps * StepLane.GROUP_GAP) / step_count, 1.0)
		return Rect2(k * w + (k / group_size) * StepLane.GROUP_GAP, 0.0, w, size.y)

	func _draw() -> void:
		var font := get_theme_default_font()
		var fs := 10
		var base := get_theme_color("font_color", "Label")
		for k in step_count:
			var r := column_rect(k)
			var c := base
			c.a = 1.0 if k == playhead else (0.35 if k >= length else 0.7)
			var text := str(k + 1)
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, Vector2(r.position.x + (r.size.x - w) * 0.5, size.y - 3.0), text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)


func _init() -> void:
	custom_minimum_size = Vector2(200, 100)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	set_process(false)


func _build() -> void:
	_box = HBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.add_theme_constant_override("separation", 8)
	add_child(_box)
	_box.minimum_size_changed.connect(update_minimum_size)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = LEFT_WIDTH
	left.add_theme_constant_override("separation", 4)
	_box.add_child(left)
	length_slider = _slider(left, "Length", 1.0, 16.0)
	rate_option = OptionButton.new()
	rate_option.add_theme_font_size_override("font_size", 11)
	rate_option.item_selected.connect(_on_rate_selected)
	_row(left, "Rate", rate_option)
	gate_slider = _slider(left, "Gate", 10.0, 200.0)
	swing_slider = _slider(left, "Swing", 0.0, 75.0)
	mode_control = _segment(left, "Mode", PackedStringArray(["Chord", "Mono"]), P_MODE)
	velocity_source_control = _segment(left, "Velocity", PackedStringArray(VELOCITY_SOURCE_LABELS),
			P_VELOCITY_SOURCE)
	range_control = SegmentedControl.new()
	range_control.set_items(PackedStringArray(["±24", "±12"]))
	range_control.font_size = 10
	range_control.selected_changed.connect(_on_range_selected)
	var range_box := VBoxContainer.new()
	range_box.add_theme_constant_override("separation", 1)
	var range_label := Label.new()
	range_label.text = "Pitch range (st)"
	range_label.add_theme_font_size_override("font_size", 10)
	range_label.modulate = Color(1, 1, 1, 0.6)
	range_box.add_child(range_label)
	range_box.add_child(range_control)
	left.add_child(range_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 3)
	_box.add_child(right)

	number_row = _NumberRow.new()
	right.add_child(number_row)

	on_lane = _lane(StepLane.Mode.TOGGLES, 0.0, 1.0, 0.0, 1.0)
	on_lane.custom_minimum_size.y = 18.0
	on_lane.show_value_tooltip = false
	on_lane.value_edited.connect(_on_lane_edited.bind(FIELD_ON))
	right.add_child(on_lane)

	pitch_lane = _lane(StepLane.Mode.BARS, -24.0, 24.0, 0.0, 0.0)
	pitch_lane.guide_values = PackedFloat32Array([-12.0, 12.0])
	pitch_lane.unit = "st"
	pitch_lane.value_text_callback = func(v: float) -> String: return "%+d st" % roundi(v)
	pitch_lane.custom_minimum_size.y = 100.0
	pitch_lane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pitch_lane.size_flags_stretch_ratio = 130.0
	pitch_lane.value_edited.connect(_on_lane_edited.bind(FIELD_PITCH))
	right.add_child(pitch_lane)

	lower_switch = SegmentedControl.new()
	lower_switch.set_items(PackedStringArray(["Velocity", "Chance"]))
	lower_switch.font_size = 10
	lower_switch.selected_changed.connect(_on_lower_switch)
	right.add_child(lower_switch)

	lower_lane = _lane(StepLane.Mode.BARS, 0.0, 100.0, 0.0, 100.0)
	lower_lane.unit = "%"
	lower_lane.value_text_callback = func(v: float) -> String: return "%d %%" % roundi(v)
	lower_lane.custom_minimum_size.y = 36.0
	lower_lane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lower_lane.size_flags_stretch_ratio = 54.0
	lower_lane.value_edited.connect(_on_lane_edited.bind(-1))
	right.add_child(lower_lane)


func _lane(mode: StepLane.Mode, lo: float, hi: float, origin: float, default_v: float) -> StepLane:
	var lane := StepLane.new()
	lane.mode = mode
	lane.step_count = STEPS
	lane.min_value = lo
	lane.max_value = hi
	lane.origin = origin
	lane.default_value = default_v
	lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lane


func _row(parent: Control, caption: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = 44.0
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(1, 1, 1, 0.6)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)


func _slider(parent: Control, caption: String, lo: float, hi: float) -> CompactSlider:
	var s := CompactSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1.0
	s.text_font_size = 11
	s.custom_minimum_size = Vector2(60, 24)
	s.value_text_callback = func(v: float) -> String:
		return "%d" % roundi(v) if caption == "Length" else "%d %%" % roundi(v)
	var id := {"Length": P_LENGTH, "Gate": P_GATE, "Swing": P_SWING}[caption] as int
	s.value_changed.connect(func(v: float) -> void: _write(id, v))
	s.reset_requested.connect(func() -> void: _reset(id))
	_row(parent, caption, s)
	return s


func _segment(parent: Control, caption: String, labels: PackedStringArray, param_id: int) -> SegmentedControl:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(label)
	var seg := SegmentedControl.new()
	seg.set_items(labels)
	seg.font_size = 10
	seg.selected_changed.connect(func(i: int) -> void: _write(param_id, float(i)))
	box.add_child(seg)
	parent.add_child(box)
	return seg


func _get_minimum_size() -> Vector2:
	return _box.get_combined_minimum_size() if _box else Vector2.ZERO


static func step_param(k: int, field: int) -> int:
	return 100 + 10 * k + field


# ============================================================================
# BINDING AND SYNC
# ============================================================================

func _on_bind() -> void:
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
	if device == null:
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
	for lane in [on_lane, pitch_lane, lower_lane]:
		lane.clear_flashes()
	number_row.playhead = -1


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != DATA_TYPE or device == null or osc_path != _subscribed_path:
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
