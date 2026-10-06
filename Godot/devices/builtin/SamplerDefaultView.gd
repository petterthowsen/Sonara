## Panel view of the built-in Sampler: an interactive `SampleDisplay` (play and loop points,
## live playheads) over rows of controls grouped as Playback, Pitch, Loop, Filter and Amp.
##
## The controls are built in `_build` and bound to parameters by name, so the layout doesn't
## depend on parameter ids. Everything goes through `DeviceInstance` (never OSC directly). Dragging
## a display point applies live and records one undo step when the drag ends.
##
## The display's source, points and playheads are handled by a `SampleDisplayBinder`, shared with
## the Window view. With `show_display` off (the Companion view) there is no display and no binder.
##
## Multisample mode (spec 023): the per-zone controls (`ZONE_FIELDS`) show and edit the focused
## zone through `SamplerActions.set_zone_fields` (mergeable undo) and carry a "Sample" badge, Key
## Track is hidden (zones always key-track), and the Companion view shows a `ZoneStrip` where the
## Panel view has its display.
class_name SamplerDefaultView extends DeviceView

static var logger := Log.make("SamplerView")

const ENVELOPE_HEIGHT := 56.0
const GROUP_TITLE_COLOR := Color(0.62, 0.62, 0.68)
const DIMMED := 0.4
## Knobs: [parameter name, caption]. The format comes from `_knob_text`.
const KNOBS_PLAYBACK := [["Speed", "Speed"], ["Voices", "Voices"], ["Velocity", "Vel"]]
const KNOBS_PITCH := [["Root", "Root"], ["Tune", "Tune"], ["Fine", "Fine"]]
const KNOBS_FILTER := [["Cutoff", "Cutoff"], ["Resonance", "Res"], ["Filter Key Track", "Key"]]
const KNOBS_AMP := [["Attack", "A"], ["Decay", "D"], ["Sustain", "S"], ["Release", "R"], ["Volume", "Vol"]]
const TIME_KNOBS := ["Attack", "Decay", "Release"]
## Parameters that edit the focused zone in multisample mode → the zone field (REQ-022).
const ZONE_FIELDS := {
	"Root": "root", "Tune": "tune", "Fine": "fine",
	"Reverse": "reverse", "Loop Mode": "loop_mode", "Crossfade": "crossfade",
}
## Groups whose controls all edit the focused zone get the "Sample" badge.
const ZONE_GROUPS := ["Pitch", "Loop"]
const ZONE_ACCENT := Color(0.95, 0.66, 0.3)
const ZONE_TOOLTIP := "Edits the focused sample (multisample mode)"
const ZONE_STRIP_SCENE := preload("res://devices/builtin/sampler/ZoneStrip.tscn")

## False for the Companion view: every control, but no waveform.
@export var show_display := true

var display: SampleDisplay
var envelope_control: EnvelopeControl
## Companion view only: the focused zone's ranges, gain and fades in multisample mode.
var zone_strip: ZoneStrip

var _knobs: Dictionary[String, LabeledKnob] = {}
var _segments: Dictionary[String, SegmentedControl] = {}
var _checks: Dictionary[String, CheckBox] = {}
var _envelope: Envelope = null
var _syncing := false
var _built := false
var _binder: SampleDisplayBinder = null
var _model: SamplerMultisample = null
var _badges: Array[Badge] = []


func _ready() -> void:
	_build()
	if device != null:
		_setup()


func _exit_tree() -> void:
	if _binder != null:
		_binder.release_stream()


# ============================================================================
# BUILD
# ============================================================================

func _build() -> void:
	if _built:
		return
	_built = true
	if show_display:
		display = SampleDisplay.new()
		display.name = "SampleDisplay"
		display.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_binder = SampleDisplayBinder.new(display)
		add_child(display)
		# The display takes file drops itself; no device-lane insert target over it.
		display.add_to_group(DeviceDropTarget.OWN_DROPS_GROUP)
	else:
		zone_strip = ZONE_STRIP_SCENE.instantiate()
		zone_strip.visible = false
		add_child(zone_strip)

	var top := _row()
	top.add_child(_group("Playback", [
		_stack([_segment("Play Mode", ["One-shot", "Gated"]), _check("Reverse")]),
		_knob_row(KNOBS_PLAYBACK),
	]))
	top.add_child(_group("Pitch", [_knob_row(KNOBS_PITCH), _check("Key Track")]))
	top.add_child(_group("Loop", [
		_stack([_segment("Loop Mode", ["Off", "On", "Ping-Pong"])]),
		_knob_row([["Crossfade", "Xfade"]]),
	]))
	add_child(top)

	var bottom := _row()
	var filter := VBoxContainer.new()
	filter.add_child(_segment("Filter Type", ["Off", "LP12", "LP24", "BP12", "BP24", "HP12", "HP24"]))
	filter.add_child(_knob_row(KNOBS_FILTER))
	bottom.add_child(_group("Filter", [filter]))
	envelope_control = (load("res://components/EnvelopeControl.tscn") as PackedScene).instantiate()
	envelope_control.custom_minimum_size = Vector2(110, ENVELOPE_HEIGHT)
	envelope_control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bottom.add_child(_group("Amp", [envelope_control, _knob_row(KNOBS_AMP)]))
	add_child(bottom)
	_setup_envelope()


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	return row


## A titled group; `children` sit side by side under the title.
func _group(title: String, children: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", GROUP_TITLE_COLOR)
	header.add_child(label)
	if title in ZONE_GROUPS:
		var badge := Badge.new()
		badge.text = "Sample"
		badge.font_size = 8
		badge.color = ZONE_ACCENT
		badge.tooltip_text = ZONE_TOOLTIP
		badge.visible = false
		header.add_child(badge)
		_badges.append(badge)
	box.add_child(header)
	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	for child in children:
		inner.add_child(child)
	box.add_child(inner)
	return box


func _stack(children: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	for child in children:
		box.add_child(child)
	return box


func _knob_row(entries: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	for entry in entries:
		var knob := LabeledKnob.new()
		knob.text = entry[1]
		knob.label_width = 40.0
		knob.knob_size = Vector2(30, 30)
		knob.label.add_theme_font_size_override("font_size", 10)
		knob.knob.value_changed.connect(_on_knob_changed.bind(entry[0]))
		knob.knob.reset_requested.connect(_on_knob_reset.bind(entry[0]))
		row.add_child(knob)
		_knobs[entry[0]] = knob
	return row


func _segment(param_name: String, labels: Array) -> SegmentedControl:
	var segment := SegmentedControl.new()
	segment.set_items(PackedStringArray(labels))
	segment.font_size = 10
	segment.selected_changed.connect(_on_segment_selected.bind(param_name))
	_segments[param_name] = segment
	return segment


func _check(param_name: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = param_name
	check.add_theme_font_size_override("font_size", 10)
	check.toggled.connect(_on_check_toggled.bind(param_name))
	_checks[param_name] = check
	return check


func _setup_envelope() -> void:
	_envelope = envelope_control.envelope
	if _envelope == null:
		_envelope = Envelope.new()
		envelope_control.envelope = _envelope
	_envelope.min_attack = 0.001
	_envelope.max_attack = 2.0
	_envelope.min_decay = 0.001
	_envelope.max_decay = 2.0
	_envelope.min_release = 0.001
	_envelope.max_release = 2.0
	_envelope.set_adsr(0.001, 0.001, 1.0, 0.01)
	_envelope.attack_changed.connect(_on_envelope_changed.bind("Attack"))
	_envelope.decay_changed.connect(_on_envelope_changed.bind("Decay"))
	_envelope.sustain_changed.connect(_on_envelope_changed.bind("Sustain"))
	_envelope.release_changed.connect(_on_envelope_changed.bind("Release"))


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	_configure_knobs()
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		ModAssign.attach(_knobs[knob_name].knob, device, id)
	if _binder != null:
		_binder.bind(device)
	if zone_strip != null:
		zone_strip.bind(device)
	_bind_model()
	_refresh()


func _on_unbind() -> void:
	if _binder != null:
		_binder.unbind()
	if zone_strip != null:
		zone_strip.unbind()
	_unbind_model()


func _bind_model() -> void:
	_unbind_model()
	_model = device.ensure_multisample()
	_model.mode_changed.connect(_refresh)
	_model.focus_changed.connect(_on_model_focus_changed)
	_model.zone_changed.connect(_on_model_zone_changed)
	_model.zones_changed.connect(_refresh)


func _unbind_model() -> void:
	if _model == null:
		return
	_model.mode_changed.disconnect(_refresh)
	_model.focus_changed.disconnect(_on_model_focus_changed)
	_model.zone_changed.disconnect(_on_model_zone_changed)
	_model.zones_changed.disconnect(_refresh)
	_model = null


func _on_model_focus_changed(_zone_id: int) -> void:
	_refresh()


func _on_model_zone_changed(zone_id: int) -> void:
	if _model != null and zone_id == _model.focused_zone_id:
		_refresh()


func multisample_active() -> bool:
	return _model != null and _model.active


## The zone the per-zone controls edit, or null outside multisample mode.
func focused_zone() -> SamplerZone:
	return _model.focused_zone() if multisample_active() else null


## Point each knob at its parameter's range, curve and text.
func _configure_knobs() -> void:
	for knob_name in _knobs:
		var param := device.get_parameter(device.get_parameter_id_by_name(knob_name))
		var knob: RotaryKnob = _knobs[knob_name].knob
		if param == null:
			continue
		knob.min_value = param.min_value
		knob.max_value = param.max_value
		knob.logarithmic = param.is_logarithmic or knob_name in TIME_KNOBS
		knob.value_default = param.default_value
		knob.step = 1.0 if knob_name in ["Root", "Voices"] else 0.0
		knob.value_text_callback = _knob_text.bind(knob_name)


## The knob's readout for `value` (real units).
static func _knob_text(value: float, param_name: String) -> String:
	match param_name:
		"Speed", "Crossfade", "Resonance", "Filter Key Track":
			return "%d%%" % roundi(value)
		"Velocity", "Sustain":
			return "%d%%" % roundi(value * 100.0)
		"Tune":
			return "%+.1f st" % value
		"Fine":
			return "%+d ct" % roundi(value)
		"Root":
			return Midi.midi_to_note_name(roundi(value))
		"Voices":
			return "%d" % roundi(value)
		"Cutoff":
			return "%.2f kHz" % (value / 1000.0) if value >= 1000.0 else "%d Hz" % roundi(value)
		"Volume":
			return "-inf dB" if value <= 0.0001 else "%+.1f dB" % (20.0 * log(value) / log(10.0))
		"Attack", "Decay", "Release":
			return "%.1f ms" % (value * 1000.0) if value < 1.0 else "%.2f s" % value
	return "%.2f" % value


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	if is_node_ready():
		_refresh()


## Copy every parameter onto the controls and the display, without echoing back.
func _refresh() -> void:
	if device == null or not is_node_ready():
		return
	_syncing = true
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		if id >= 0:
			_knobs[knob_name].knob.set_value_no_signal(device.get_parameter_real(id))
	for param_name in _segments:
		var id := device.get_parameter_id_by_name(param_name)
		if id >= 0:
			_segments[param_name].set_selected_no_signal(int(device.get_parameter_real(id)))
	for param_name in _checks:
		var id := device.get_parameter_id_by_name(param_name)
		if id >= 0:
			_checks[param_name].set_pressed_no_signal(device.get_parameter_real(id) >= 0.5)
	_envelope.set_adsr(
		_real("Attack", 0.001), _real("Decay", 0.001), _real("Sustain", 1.0), _real("Release", 0.01))
	_refresh_zone_controls()
	_syncing = false
	if _binder != null:
		_binder.refresh()
	_update_enabled()


## Multisample mode: the per-zone controls show the focused zone, marked as such. Single mode: everything back to the parameters (already copied by `_refresh`).
func _refresh_zone_controls() -> void:
	var multi := multisample_active()
	var zone := focused_zone()
	for badge in _badges:
		badge.visible = multi
	var reverse := _checks["Reverse"]
	if multi:
		reverse.add_theme_color_override("font_color", ZONE_ACCENT)
		reverse.tooltip_text = ZONE_TOOLTIP
	else:
		reverse.remove_theme_color_override("font_color")
		reverse.tooltip_text = ""
	if zone_strip != null:
		zone_strip.visible = multi
	if zone == null:
		return
	for param_name in ZONE_FIELDS:
		var value := zone_value(zone, param_name)
		if _knobs.has(param_name):
			_knobs[param_name].knob.set_value_no_signal(value)
		elif _segments.has(param_name):
			_segments[param_name].set_selected_no_signal(int(value))
		elif _checks.has(param_name):
			_checks[param_name].set_pressed_no_signal(value >= 0.5)


## A zone field in the units of the parameter that shows it (Crossfade in %, booleans as 0/1).
static func zone_value(zone: SamplerZone, param_name: String) -> float:
	var v: Variant = zone.get(ZONE_FIELDS[param_name])
	if v is bool:
		return 1.0 if v else 0.0
	if param_name == "Crossfade":
		return float(v) * 100.0
	return float(v)


## The zone field value for a control value in parameter units.
static func zone_field_value(param_name: String, value: float) -> Variant:
	match param_name:
		"Reverse":
			return value >= 0.5
		"Crossfade":
			return value / 100.0
		"Root", "Loop Mode":
			return roundi(value)
	return value


func _real(param_name: String, fallback: float) -> float:
	var id := device.get_parameter_id_by_name(param_name)
	return device.get_parameter_real(id) if id >= 0 else fallback


## Crossfade only applies to Loop On; the filter knobs only when a filter type is chosen.
func _update_enabled() -> void:
	var zone := focused_zone()
	var loop_mode := zone.loop_mode if zone else int(_real("Loop Mode", 0.0))
	_set_enabled(_knobs["Crossfade"], loop_mode == SampleDisplay.LoopMode.ON)
	var filter_on := int(_real("Filter Type", 0.0)) != 0
	for knob_name in ["Cutoff", "Resonance", "Filter Key Track"]:
		_set_enabled(_knobs[knob_name], filter_on)


func _set_enabled(knob: LabeledKnob, enabled: bool) -> void:
	knob.modulate.a = 1.0 if enabled else DIMMED
	knob.knob.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE


# ============================================================================
# CONTROL HANDLERS
# ============================================================================

func _on_knob_changed(value: float, param_name: String) -> void:
	_set_real(param_name, value)


func _on_knob_reset(param_name: String) -> void:
	if device == null:
		return
	if multisample_active() and ZONE_FIELDS.has(param_name):
		var field: String = ZONE_FIELDS[param_name]
		_set_zone_field(param_name, zone_value_default(field, param_name))
		return
	var param := device.get_parameter(device.get_parameter_id_by_name(param_name))
	if param != null:
		device.set_parameter_real(param.id, param.default_value)


func _on_segment_selected(index: int, param_name: String) -> void:
	_set_real(param_name, float(index))


func _on_check_toggled(pressed: bool, param_name: String) -> void:
	_set_real(param_name, 1.0 if pressed else 0.0)


func _set_real(param_name: String, value: float) -> void:
	if _syncing or device == null:
		return
	if multisample_active() and ZONE_FIELDS.has(param_name):
		_set_zone_field(param_name, value)
		return
	var id := device.get_parameter_id_by_name(param_name)
	if id >= 0:
		device.set_parameter_real(id, value)


## Edit the focused zone from a control (`value` in parameter units). Mergeable undo.
func _set_zone_field(param_name: String, value: float) -> void:
	var zone := focused_zone()
	if zone == null:
		return
	SamplerActions.set_zone_fields(device, zone.id, {ZONE_FIELDS[param_name]: zone_field_value(param_name, value)})


## A zone field's default, in the units of the parameter that shows it.
static func zone_value_default(field: String, param_name: String) -> float:
	var v: Variant = SamplerZone.NUMERIC_DEFAULTS.get(field, 0.0)
	return float(v) * 100.0 if param_name == "Crossfade" else float(v)


## Apply an envelope stage to the device and record a mergeable undo step.
func _on_envelope_changed(value: float, param_name: String) -> void:
	var param_id := device.get_parameter_id_by_name(param_name) if device != null else -1
	if _syncing or param_id < 0:
		return
	var old_value := device.get_parameter_normalized(param_id)
	device.set_parameter_real(param_id, value)
	var new_value := device.get_parameter_normalized(param_id)
	if absf(new_value - old_value) < 0.0001:
		return
	var cmd := PropertyCommand.new("Set Parameter", device, "", [param_id, old_value], [param_id, new_value])
	cmd.set_callable(func(id, v): device.set_parameter_normalized(id, v)).set_unpack_array(true).set_mergeable(true)
	HistoryUtil.record(cmd)


# ============================================================================
# DISPLAY
# ============================================================================

func _on_view_shown() -> void:
	if _binder != null:
		_binder.set_shown(true)


func _on_view_hidden() -> void:
	if _binder != null:
		_binder.set_shown(false)


## Feed a `"playheads"` blob to the display (also what the tests call).
func apply_playheads(blob: PackedByteArray, now_ms: int = Time.get_ticks_msec()) -> void:
	if _binder != null:
		_binder.apply_playheads(blob, now_ms)
