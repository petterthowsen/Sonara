## Spec 053: the metronome's configuration popup. The step grid edits the pattern of the time
## signature at the playhead; the sound row edits the global `metronome/*` settings. It only calls
## `Metronome` setters (the model sends OSC) and redraws from the model's signals.
class_name MetronomePopup extends PopupPanel

## Colour index 0 (Off) is the lane's own off colour; 1 to 4 are the theme roles.
const LEVEL_ROLES: Array[StringName] = [
	&"metronome_level_1", &"metronome_level_2", &"metronome_level_3", &"metronome_level_4",
]
const LEVEL_NAMES: Array[String] = ["Off", "1", "2", "3", "4"]
## Preview level for a sound change (REQ-024).
const SOUND_AUDITION_LEVEL := 4

@onready var _signature_label: Label = %SignatureLabel
@onready var _resolution_option: OptionButton = %ResolutionOption
@onready var _reset_button: Button = %ResetButton
@onready var _lane: StepLane = %StepLane
@onready var _hint_label: Label = %HintLabel
@onready var _sound_option: OptionButton = %SoundOption
@onready var _knobs := {
	Metronome.KEY_TUNE: %TuneKnob,
	Metronome.KEY_DECAY: %DecayKnob,
	Metronome.KEY_TONE: %ToneKnob,
	Metronome.KEY_LEVEL: %LevelKnob,
	Metronome.KEY_EMPHASIS_VOLUME: %AccentVolumeKnob,
	Metronome.KEY_EMPHASIS_PITCH: %AccentPitchKnob,
}

var _metronome: Metronome
## The signature being edited (the playhead's).
var _num := 4
var _den := 4
var _playing := false
## `get_state()` taken when a lane drag starts, for the undo record.
var _edit_start_state: Dictionary = {}
var _refreshing := false


func _ready() -> void:
	for i in Metronome.SOUND_LABELS.size():
		_sound_option.add_item(Metronome.SOUND_LABELS[i], i)
	_configure_knob(Metronome.KEY_TUNE, 200.0, 4000.0, 0.0, true, func(v): return "%d Hz" % roundi(v))
	_configure_knob(Metronome.KEY_DECAY, 0.02, 0.5, 0.0, true, func(v): return "%d ms" % roundi(v * 1000.0))
	_configure_knob(Metronome.KEY_TONE, 0.0, 1.0, 0.0, false, func(v): return "%d%%" % roundi(v * 100.0))
	_configure_knob(Metronome.KEY_LEVEL, -60.0, 6.0, 0.0, false, func(v): return "%.1f dB" % v)
	_configure_knob(Metronome.KEY_EMPHASIS_VOLUME, 0.0, 24.0, 0.5, false, func(v): return "%.1f dB" % v)
	_configure_knob(Metronome.KEY_EMPHASIS_PITCH, 0.0, 24.0, 1.0, false, func(v): return "%d st" % roundi(v))
	_lane.value_text_callback = func(v): return LEVEL_NAMES[clampi(roundi(v), 0, 4)]
	_lane.value_edited.connect(_on_step_edited)
	_lane.edit_started.connect(_on_edit_started)
	_lane.edit_ended.connect(_on_edit_ended)
	_resolution_option.item_selected.connect(_on_resolution_selected)
	_reset_button.pressed.connect(_on_reset_pressed)
	_sound_option.item_selected.connect(_on_sound_selected)
	_apply_level_colors()
	if _metronome != null:
		_refresh_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_level_colors()


## Bind the model the popup edits. Call once, before or after the popup is in the tree.
func setup(metronome: Metronome) -> void:
	if _metronome != null:
		_metronome.changed.disconnect(_refresh_pattern)
		_metronome.setting_changed.disconnect(_on_setting_changed)
	_metronome = metronome
	_metronome.changed.connect(_refresh_pattern)
	_metronome.setting_changed.connect(_on_setting_changed)
	if is_node_ready():
		_refresh_all()


## Edit another signature's pattern.
func set_signature(num: int, den: int) -> void:
	if num == _num and den == _den:
		return
	_num = num
	_den = den
	if _metronome != null and is_node_ready():
		_refresh_pattern()


func get_signature() -> Vector2i:
	return Vector2i(_num, _den)


## Follow the transport: the signature at `tick`, and while playing the step under it. The popup
## also uses `playing` to decide whether an edit plays a preview click (REQ-024).
func follow_playhead(project: Project, tick: int, playing: bool) -> void:
	_playing = playing
	var map := project.time_signature_map
	var index := map.segment_index_at_tick(tick, project.time_numerator, project.time_denominator, project.ppq)
	var segment: Dictionary = map.segments(project.time_numerator, project.time_denominator, project.ppq)[index]
	set_signature(int(segment["numerator"]), int(segment["denominator"]))
	if not is_node_ready() or _metronome == null:
		return
	if playing and _metronome.is_editable(_num, _den):
		var into := maxi(tick - int(segment["tick"]), 0) % int(segment["bar_ticks"])
		_lane.playhead = Metronome.step_index_at(into, _metronome.resolution_of(_num, _den), project.ppq, _lane.step_count)
	else:
		_lane.playhead = -1


## Open below `anchor`, like the Load popup.
func popup_below(anchor: Control) -> void:
	var origin := Vector2i(anchor.get_screen_position() + Vector2(0, anchor.size.y))
	popup(Rect2i(origin, Vector2i.ZERO))


# ============================================================================
# REFRESH
# ============================================================================

func _refresh_all() -> void:
	_refreshing = true
	_sound_option.select(clampi(int(_metronome.get_param(Metronome.KEY_SOUND)), 0, _sound_option.item_count - 1))
	for key in _knobs:
		_knobs[key].knob.set_value_no_signal(float(_metronome.get_param(key)))
		_knobs[key].refresh_value_text()
	_refreshing = false
	_refresh_pattern()


func _refresh_pattern() -> void:
	_refreshing = true
	var editable := _metronome.is_editable(_num, _den)
	var res := _metronome.resolution_of(_num, _den)
	var levels := _metronome.levels_of(_num, _den)
	_signature_label.text = "Pattern for %d/%d" % [_num, _den]
	_resolution_option.clear()
	for allowed in Metronome.allowed_resolutions(_num, _den):
		_resolution_option.add_item("1/%d" % allowed, allowed)
	if editable:
		_resolution_option.select(_resolution_option.get_item_index(res))
	else:
		_resolution_option.add_item("1/%d" % res, res)
		_resolution_option.select(0)
	_resolution_option.disabled = not editable
	_reset_button.disabled = not _metronome.is_edited(_num, _den)
	_hint_label.visible = not editable
	if _lane.step_count != levels.size():
		_lane.step_count = levels.size()
	_lane.group_size = Metronome.group_size(_den, res)
	var values := PackedFloat32Array()
	for level in levels:
		values.append(float(level))
	_lane.set_values_no_signal(values)
	_lane.mouse_filter = Control.MOUSE_FILTER_STOP if editable else Control.MOUSE_FILTER_IGNORE
	_refreshing = false
	# The grid can be wider now: let the popup grow or shrink to it.
	if visible:
		reset_size()


func _on_setting_changed(key: String) -> void:
	if key == Metronome.KEY_SOUND:
		_sound_option.select(clampi(int(_metronome.get_param(key)), 0, _sound_option.item_count - 1))
	elif _knobs.has(key):
		_knobs[key].knob.set_value_no_signal(float(_metronome.get_param(key)))
		_knobs[key].refresh_value_text()


func _apply_level_colors() -> void:
	var colors := PackedColorArray([_lane.bar_off_color])
	for role in LEVEL_ROLES:
		colors.append(UiColors.role(role))
	_lane.level_colors = colors


func _configure_knob(key: String, min_v: float, max_v: float, step: float, log_scale: bool, text_fn: Callable) -> void:
	var labeled: LabeledKnob = _knobs[key]
	var knob := labeled.knob
	knob.min_value = min_v
	knob.max_value = max_v
	knob.step = step
	knob.logarithmic = log_scale
	knob.value_default = float(Settings.get_setting(key).default)
	knob.value_text_callback = text_fn
	labeled.refresh_value_text()
	knob.value_changed.connect(_on_knob_changed.bind(key))


# ============================================================================
# EDITS (the model sends OSC)
# ============================================================================

func _on_step_edited(step: int, value: float) -> void:
	if _refreshing:
		return
	var level := roundi(value)
	_metronome.set_step(_num, _den, step, level)
	if level > 0:
		_audition(level)


func _on_edit_started() -> void:
	_edit_start_state = _metronome.get_state()


func _on_edit_ended() -> void:
	HistoryUtil.record_property("Edit Metronome", _metronome, "set_state", _edit_start_state, _metronome.get_state())


func _on_resolution_selected(index: int) -> void:
	if _refreshing:
		return
	_record_edit(func(): _metronome.set_resolution(_num, _den, _resolution_option.get_item_id(index)))


func _on_reset_pressed() -> void:
	_record_edit(func(): _metronome.reset_pattern(_num, _den))


## Run `edit` (one model call) and record it for undo.
func _record_edit(edit: Callable) -> void:
	var before := _metronome.get_state()
	edit.call()
	HistoryUtil.record_property("Edit Metronome", _metronome, "set_state", before, _metronome.get_state(), false)


func _on_sound_selected(index: int) -> void:
	if _refreshing:
		return
	_metronome.set_param(Metronome.KEY_SOUND, _sound_option.get_item_id(index))
	_audition(SOUND_AUDITION_LEVEL)


func _on_knob_changed(value: float, key: String) -> void:
	if _refreshing:
		return
	_metronome.set_param(key, value)
	_audition(SOUND_AUDITION_LEVEL)


## One preview click, only while the transport is stopped (REQ-024). The model rate-limits it.
func _audition(level: int) -> void:
	if not _playing:
		_metronome.audition(level)
