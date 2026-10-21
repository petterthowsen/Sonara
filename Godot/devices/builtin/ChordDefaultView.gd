## Panel view of the built-in Chord (spec 027): a keyboard above the generated Simple View, which
## keeps every parameter. A key stands for an interval from the played note (middle C = 0): a
## click toggles it through the voice parameters. Interval 0 is Play Original. Enabled keys use
## the secondary color; while notes are held, the enabled keys light in the primary color, from
## the device's `"note_state"` stream (subscribed while shown, like the Arpeggiator).
class_name ChordDefaultView extends DeviceView

const Keyboard := preload("res://devices/builtin/ChordKeyboard.gd")
const DATA_TYPE := "note_state"
const P_PLAY_ORIGINAL := 0
const VOICES := 6
const SIMPLE_VIEW_SCENE := preload("res://devices/simple_view/SimpleView.tscn")

var keyboard: Keyboard
var simple: DeviceView
var zoom_out_button: Button
var zoom_in_button: Button
var page_left_button: Button
var page_right_button: Button
## Input keys held now (from the stream).
var held_inputs := PackedInt32Array()

var _subscribed_path := ""
var _box: VBoxContainer


static func voice_on(k: int) -> int:
	return 10 * k


static func voice_interval(k: int) -> int:
	return 10 * k + 1


func _init() -> void:
	custom_minimum_size = Vector2(200, 100)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.add_theme_constant_override("separation", 4)
	add_child(_box)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	_box.add_child(bar)
	page_left_button = _button(bar, "‹", "Show lower octaves", func() -> void: keyboard.set_page(keyboard.page - 1))
	keyboard = Keyboard.new()
	keyboard.key_toggled.connect(_on_key_toggled)
	keyboard.window_changed.connect(_update_buttons)
	bar.add_child(keyboard)
	page_right_button = _button(bar, "›", "Show higher octaves", func() -> void: keyboard.set_page(keyboard.page + 1))
	zoom_out_button = _button(bar, "−", "Show fewer octaves", func() -> void: keyboard.set_visible_octaves(keyboard.visible_octaves - 1))
	zoom_in_button = _button(bar, "+", "Show more octaves", func() -> void: keyboard.set_visible_octaves(keyboard.visible_octaves + 1))
	simple = SIMPLE_VIEW_SCENE.instantiate() as DeviceView
	simple.size_flags_vertical = Control.SIZE_EXPAND_FILL
	simple.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_child(simple)
	simple.header_tabs_changed.connect(func() -> void: header_tabs_changed.emit())
	_box.minimum_size_changed.connect(update_minimum_size)
	_update_buttons()


func _button(parent: Control, text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(24, 0)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _update_buttons() -> void:
	page_left_button.disabled = keyboard.page <= 0
	page_right_button.disabled = keyboard.page >= keyboard.max_page()
	zoom_out_button.disabled = keyboard.visible_octaves <= 1
	zoom_in_button.disabled = keyboard.visible_octaves >= Keyboard.MAX_VISIBLE


func _get_minimum_size() -> Vector2:
	return _box.get_combined_minimum_size() if _box else Vector2.ZERO


# ============================================================================
# BINDING AND SYNC
# ============================================================================

func _on_bind() -> void:
	simple.set_view_type(view_type)
	simple.bind_to_device(device)
	if not device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.connect(_on_parameter_changed)
	_refresh()


func _on_unbind() -> void:
	if device and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	if is_instance_valid(simple):
		simple.call("_unbind")


func _on_parameter_changed(_param_id: int, _value: float) -> void:
	_refresh()


func _read(id: int, fallback: float) -> float:
	return device.get_parameter_real(id) if device != null and device.get_parameter(id) != null else fallback


## Intervals the chord plays: the original (0) when Play Original is on, plus every on voice.
func enabled_intervals() -> Dictionary:
	var out := {}
	if _read(P_PLAY_ORIGINAL, 1.0) >= 0.5:
		out[0] = true
	for k in range(1, VOICES + 1):
		if _read(voice_on(k), 0.0) >= 0.5:
			out[roundi(_read(voice_interval(k), 0.0))] = true
	return out


func _refresh() -> void:
	if device == null:
		return
	var keys := {}
	for interval in enabled_intervals():
		keys[Keyboard.ROOT + interval] = true
	keyboard.set_enabled_keys(keys)
	_refresh_live()


# ============================================================================
# EDITS
# ============================================================================

func _write(param_id: int, value: float) -> void:
	if device != null:
		ParameterActions.set_real(device, param_id, value)


func _on_key_toggled(key: int) -> void:
	toggle_interval(key - Keyboard.ROOT)


## Toggle one interval: switch off every voice playing it, or switch one on (reusing a voice
## already set to it, else the first free one). Interval 0 also drives Play Original. With all
## six voices in use, a new interval is ignored.
func toggle_interval(interval: int) -> void:
	if device == null:
		return
	var is_on: bool = enabled_intervals().has(interval)
	if is_on:
		if interval == 0:
			_write(P_PLAY_ORIGINAL, 0.0)
		for k in range(1, VOICES + 1):
			if _read(voice_on(k), 0.0) >= 0.5 and roundi(_read(voice_interval(k), 0.0)) == interval:
				_write(voice_on(k), 0.0)
		return
	if interval == 0:
		_write(P_PLAY_ORIGINAL, 1.0)
		return
	var free := -1
	for k in range(1, VOICES + 1):
		if roundi(_read(voice_interval(k), 0.0)) == interval:
			_write(voice_on(k), 1.0)
			return
		if free < 0 and _read(voice_on(k), 0.0) < 0.5:
			free = k
	if free > 0:
		_write(voice_interval(free), float(interval))
		_write(voice_on(free), 1.0)


# ============================================================================
# HEADER TABS
# ============================================================================

func get_header_tabs() -> PackedStringArray:
	return simple.get_header_tabs()


func get_header_tab() -> int:
	return simple.get_header_tab()


func select_header_tab(index: int) -> void:
	simple.select_header_tab(index)


# ============================================================================
# LIVE FEEDBACK
# ============================================================================

func _on_view_shown() -> void:
	simple.show_view()
	if device == null:
		return
	_subscribed_path = device.osc_path()
	AudioEngineOSC.subscribe_device_data(_subscribed_path, DATA_TYPE)
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)


func _on_view_hidden() -> void:
	simple.hide_view()
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _subscribed_path != "":
		AudioEngineOSC.unsubscribe_device_data(_subscribed_path, DATA_TYPE)
		_subscribed_path = ""
	held_inputs = PackedInt32Array()
	keyboard.set_live_keys({})


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != DATA_TYPE or osc_path != _subscribed_path:
		return
	var state := NoteStrip.decode(blob)
	if state.is_empty():
		return
	held_inputs = state["held"]
	_refresh_live()


## While any note is held, the keys it expands to light up: every enabled interval.
func _refresh_live() -> void:
	var live := {}
	if not held_inputs.is_empty():
		for key in keyboard.enabled:
			live[key] = true
	keyboard.set_live_keys(live)
