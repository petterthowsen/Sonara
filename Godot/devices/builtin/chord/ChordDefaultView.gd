## Panel view of the built-in Chord (spec 027): a keyboard above the generated Simple View, which
## keeps every parameter. A key stands for an interval from the played note (middle C = 0): a
## click toggles it through the voice parameters. Interval 0 is Play Original. Enabled keys use
## the secondary color; while notes are held, the enabled keys light in the primary color, from
## the device's `"note_state"` stream (subscribed while shown, like the Arpeggiator). The page and
## zoom buttons, the keyboard and the Simple View live in `ChordDefaultView.tscn`.
class_name ChordDefaultView extends DeviceView

const Keyboard := preload("res://devices/builtin/chord/ChordKeyboard.gd")
const DATA_TYPE := "note_state"
const P_PLAY_ORIGINAL := 0
const VOICES := 6

@onready var keyboard: Keyboard = %Keyboard
@onready var simple: DeviceView = %Simple
@onready var zoom_out_button: Button = %ZoomOutButton
@onready var zoom_in_button: Button = %ZoomInButton
@onready var page_left_button: Button = %PageLeftButton
@onready var page_right_button: Button = %PageRightButton
@onready var _box: VBoxContainer = %Box

## Input keys held now (from the stream).
var held_inputs := PackedInt32Array()

var _subscribed_path := ""


static func voice_on(k: int) -> int:
	return 10 * k


static func voice_interval(k: int) -> int:
	return 10 * k + 1


## Hook the bar, the keyboard and the Simple View's relays, then bind if a device arrived before
## the tree.
func _ready() -> void:
	page_left_button.pressed.connect(func() -> void: keyboard.set_page(keyboard.page - 1))
	page_right_button.pressed.connect(func() -> void: keyboard.set_page(keyboard.page + 1))
	zoom_out_button.pressed.connect(func() -> void: keyboard.set_visible_octaves(keyboard.visible_octaves - 1))
	zoom_in_button.pressed.connect(func() -> void: keyboard.set_visible_octaves(keyboard.visible_octaves + 1))
	keyboard.key_toggled.connect(_on_key_toggled)
	keyboard.window_changed.connect(_update_buttons)
	simple.header_tabs_changed.connect(func() -> void: header_tabs_changed.emit())
	_box.minimum_size_changed.connect(update_minimum_size)
	update_minimum_size()
	_update_buttons()
	if device != null:
		_setup()


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
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	simple.set_view_type(view_type)
	simple.bind_to_device(device)
	_refresh()


func _on_unbind() -> void:
	if is_instance_valid(simple):
		simple.call("_unbind")


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
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
	if device == null or keyboard == null:
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
	return simple.get_header_tabs() if simple else PackedStringArray()


func get_header_tab() -> int:
	return simple.get_header_tab() if simple else 0


func select_header_tab(index: int) -> void:
	if simple:
		simple.select_header_tab(index)


# ============================================================================
# LIVE FEEDBACK
# ============================================================================

func _on_view_shown() -> void:
	if simple:
		simple.show_view()
	if device == null:
		return
	_subscribed_path = device.osc_path()
	AudioEngineOSC.subscribe_device_data(_subscribed_path, DATA_TYPE)
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)


func _on_view_hidden() -> void:
	if simple:
		simple.hide_view()
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _subscribed_path != "":
		AudioEngineOSC.unsubscribe_device_data(_subscribed_path, DATA_TYPE)
		_subscribed_path = ""
	held_inputs = PackedInt32Array()
	if keyboard:
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
	if keyboard == null:
		return
	var live := {}
	if not held_inputs.is_empty():
		for key in keyboard.enabled:
			live[key] = true
	keyboard.set_live_keys(live)
