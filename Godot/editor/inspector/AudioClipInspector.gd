# AudioClipInspector.gd
# Inspector section for selections made only of audio clip instances: stretch mode and clip tempo
# (per Clip, shared by all its instances), reverse and gain (per instance), and the read-only facts
# about the source file.
#
# Stretch mode is offered as Raw / Repitch / Stretch. Stretch has no pitch-preserving engine yet and
# plays like Repitch; its item is labelled "Stretch (plays as Repitch)" and the selector's tooltip
# says so. Changing the clip tempo goes through `AudioClipTiming.tempo_change_command`, which
# rescales the clip and every instance of it as one undo step. The tempo is disabled in Raw.
#
# Gain is per instance (ClipInstance.gain_offset). A drag on the slider applies live and is
# recorded as one undo step when the mouse is released. Double-click resets to 0 dB.
class_name AudioClipInspector extends InspectorSection

var _mode_select: OptionButton
var _tempo_edit: LineEdit
var _tempo_double: Button
var _tempo_half: Button
var _beats_edit: LineEdit
var _reverse_toggle: Button
var _gain_slider: HorSlider
var _gain_edit: LineEdit
var _file_label: Label
var _path_label: Label
var _format_label: Label
var _rate_label: Label
var _channels_label: Label
var _duration_label: Label

## Gains as they were when the drag started (ClipInstance -> dB), empty when no drag runs.
var _drag_start: Dictionary = {}
## Value changes seen during the current drag. A bare click makes one.
var _drag_changes := 0
## A click without movement waits this long before it is recorded, so the double-click that
## follows can turn it into a reset: the pair is one undo step, not two.
const CLICK_RECORD_DELAY := 0.4
var _pending_click: Dictionary = {}  # ClipInstance -> dB before the click
var _pending_serial := 0


## Every selected object is an audio clip instance.
static func handles(selected: Array) -> bool:
	if selected.is_empty():
		return false
	for o in selected:
		if not (o is ClipInstance and o.clip != null and o.clip.type == Clip.ClipType.AUDIO):
			return false
	return true


func _init() -> void:
	title = "Audio Clip"


func _build() -> void:
	_mode_select = OptionButton.new()
	_mode_select.add_item("Raw", Clip.StretchMode.RAW)
	_mode_select.add_item("Repitch", Clip.StretchMode.REPITCH)
	_mode_select.add_item("Stretch (plays as Repitch)", Clip.StretchMode.STRETCH)
	_mode_select.tooltip_text = "Raw: native speed, ignores the project tempo.\nRepitch: speed follows the tempo, pitch follows speed.\nStretch: pitch-preserving stretching is not available yet; it plays like Repitch."
	_mode_select.item_selected.connect(_on_mode_selected)
	add_row("Mode", _mode_select)

	var tempo_box := HBoxContainer.new()
	_tempo_edit = make_text_field(_commit_tempo_text)
	_tempo_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tempo_edit.tooltip_text = "Tempo of the material in BPM. Changing it rescales the clip and all its instances."
	tempo_box.add_child(_tempo_edit)
	_tempo_half = Button.new()
	_tempo_half.text = "÷2"
	_tempo_half.tooltip_text = "Halve the clip tempo"
	_tempo_half.pressed.connect(func() -> void: _scale_tempo(0.5))
	tempo_box.add_child(_tempo_half)
	_tempo_double = Button.new()
	_tempo_double.text = "×2"
	_tempo_double.tooltip_text = "Double the clip tempo"
	_tempo_double.pressed.connect(func() -> void: _scale_tempo(2.0))
	tempo_box.add_child(_tempo_double)
	add_row("Tempo", tempo_box)

	_beats_edit = make_text_field(_commit_beats_text)
	_beats_edit.tooltip_text = "Length of the whole file in beats. Typing a length sets the clip tempo to beats × 60 / duration."
	add_row("Length (beats)", _beats_edit)

	_reverse_toggle = make_toggle(_commit_reverse)
	add_row("Reverse", _reverse_toggle)

	var gain_box := HBoxContainer.new()
	_gain_slider = HorSlider.new()
	_gain_slider.bidirectional = false
	_gain_slider.min_value = ClipInstance.GAIN_MIN_DB
	_gain_slider.max_value = ClipInstance.GAIN_MAX_DB
	_gain_slider.default_value = 0.0
	_gain_slider.double_click_resets = true
	_gain_slider.custom_minimum_size = Vector2(80, 20)
	_gain_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gain_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gain_slider.tooltip_text = "Clip gain. Double-click or Ctrl-click to reset to 0 dB"
	_gain_slider.drag_started.connect(_on_gain_drag_started)
	_gain_slider.drag_ended.connect(_on_gain_drag_ended)
	_gain_slider.value_changed.connect(_on_gain_slider_changed)
	gain_box.add_child(_gain_slider)
	_gain_edit = make_text_field(_commit_gain_text)
	_gain_edit.custom_minimum_size.x = 56.0
	_gain_edit.size_flags_horizontal = Control.SIZE_SHRINK_END
	_gain_edit.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gain_box.add_child(_gain_edit)
	add_row("Gain", gain_box)

	_file_label = _info_label()
	add_row("File", _file_label)
	_path_label = _info_label()
	add_row("Path", _path_label)
	_format_label = _info_label()
	add_row("Format", _format_label)
	_rate_label = _info_label()
	add_row("Sample rate", _rate_label)
	_channels_label = _info_label()
	add_row("Channels", _channels_label)
	_duration_label = _info_label()
	add_row("Duration", _duration_label)


func _info_label() -> Label:
	var label := Label.new()
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	return label


func _watch_models() -> void:
	for inst in _instances():
		watch(inst.gain_changed, _on_instance_changed)
		watch(inst.reverse_changed, _on_instance_changed)
		watch(inst.clip_changed, _on_clip_swapped)
		if inst.clip:
			watch(inst.clip.clip_modified)
			watch(inst.clip.audio_source.metadata_changed)


func _on_instance_changed(_value = null) -> void:
	refresh()


func _on_clip_swapped(_new_clip: Clip) -> void:
	bind(objects)


func _on_unbound() -> void:
	_flush_pending_click()
	_drag_start.clear()


func _refresh() -> void:
	var insts := _instances()
	var gains: Array = []
	for inst in insts:
		gains.append(inst.gain_offset)
	var mixed := not all_same(gains)
	_gain_slider.set_value_no_signal(float(gains[0]) if not gains.is_empty() else 0.0)
	if mixed:
		_gain_edit.text = ""
	else:
		_gain_edit.text = format_gain(float(gains[0]))

	var clips: Array = []
	for clip in _clips():
		clips.append(clip)
	_refresh_timing(clips, insts)
	_show_info(_file_label, clips, func(c: Clip) -> String: return c.audio_file_path.get_file())
	_show_info(_path_label, clips, func(c: Clip) -> String: return c.audio_file_path.get_base_dir())
	_show_info(_format_label, clips, func(c: Clip) -> String:
		var ext := c.audio_file_path.get_extension().to_upper()
		return ext if not ext.is_empty() else "—")
	_show_info(_rate_label, clips, func(c: Clip) -> String:
		var rate := _source_rate(c)
		return "%d Hz" % rate if rate > 0 else "—")
	_show_info(_channels_label, clips, func(c: Clip) -> String:
		return _channels_text(c.audio_channels))
	_show_info(_duration_label, clips, func(c: Clip) -> String:
		return "%.2f s" % c.audio_duration_seconds if c.audio_duration_seconds > 0.0 else "—")
	_path_label.tooltip_text = _path_label.text
	_file_label.tooltip_text = _file_label.text


func _refresh_timing(clips: Array, insts: Array[ClipInstance]) -> void:
	var modes: Array = []
	var tempos: Array = []
	var beats: Array = []
	var all_raw := true
	for clip: Clip in clips:
		modes.append(clip.stretch_mode)
		tempos.append(snappedf(clip.recorded_bpm, 0.001))
		beats.append(snappedf(float(clip.content_length_ticks) / float(_ppq()), 0.001))
		all_raw = all_raw and clip.stretch_mode == Clip.StretchMode.RAW
	_mode_select.select(_mode_select.get_item_index(modes[0]) if not modes.is_empty() and all_same(modes) else -1)
	show_text(_tempo_edit, tempos, func(v: float) -> String: return format_number(v))
	show_text(_beats_edit, beats, func(v: float) -> String: return format_number(v))
	_tempo_edit.editable = not all_raw
	_beats_edit.editable = not all_raw
	_tempo_half.disabled = all_raw
	_tempo_double.disabled = all_raw
	var flags: Array = []
	for inst in insts:
		flags.append(inst.reverse_enabled)
	show_toggle(_reverse_toggle, flags)


## Tempo and beat counts without trailing zeros: 120, 87.5, 96.123.
static func format_number(v: float) -> String:
	var text := "%.3f" % v
	return text.rstrip("0").rstrip(".")


func _ppq() -> int:
	var p := get_project()
	return p.ppq if p != null else 960


# ============================================================================
# MODE AND TEMPO
# ============================================================================

func _on_mode_selected(index: int) -> void:
	if is_refreshing():
		return
	var mode := _mode_select.get_item_id(index) as Clip.StretchMode
	var cmds: Array[Command] = []
	for clip in _clips():
		if clip.stretch_mode != mode:
			cmds.append(PropertyCommand.new("Set Stretch Mode", clip, "set_stretch_mode",
					clip.stretch_mode, mode))
	HistoryUtil.execute_many("Set Stretch Mode", cmds)
	refresh()


func _commit_tempo_text(text: String) -> void:
	var t := text.strip_edges().to_lower().trim_suffix("bpm").strip_edges()
	if t.is_valid_float():
		_set_tempo(func(_clip: Clip) -> float: return t.to_float())


func _scale_tempo(factor: float) -> void:
	_set_tempo(func(clip: Clip) -> float: return clip.recorded_bpm * factor)


## Beats typed for the whole file: tempo = beats × 60 / duration for each selected clip.
func _commit_beats_text(text: String) -> void:
	var t := text.strip_edges()
	if not t.is_valid_float() or t.to_float() <= 0.0:
		return
	var beats := t.to_float()
	_set_tempo(func(clip: Clip) -> float:
		var seconds := _duration_seconds(clip)
		return beats * 60.0 / seconds if seconds > 0.0 else clip.recorded_bpm)


static func _duration_seconds(clip: Clip) -> float:
	if clip.audio_duration_seconds > 0.0:
		return clip.audio_duration_seconds
	if clip.audio_sample_rate > 0 and clip.audio_frames > 0:
		return float(clip.audio_frames) / float(clip.audio_sample_rate)
	return 0.0


## Set each selected clip's tempo to `tempo_for.call(clip)` as one undo step.
func _set_tempo(tempo_for: Callable) -> void:
	var proj := get_project()
	if proj == null:
		return
	var cmds: Array[Command] = []
	for clip in _clips():
		var cmd := AudioClipTiming.tempo_change_command(proj, clip, tempo_for.call(clip))
		if cmd != null:
			cmds.append(cmd)
	HistoryUtil.execute_many("Set Clip Tempo", cmds)


func _commit_reverse(enabled: bool) -> void:
	var cmds: Array[Command] = []
	for inst in _instances():
		if inst.reverse_enabled != enabled:
			cmds.append(PropertyCommand.new("Reverse Clip" if enabled else "Unreverse Clip", inst,
					"set_reverse_enabled", inst.reverse_enabled, enabled))
	HistoryUtil.execute_many("Reverse Clips" if enabled else "Unreverse Clips", cmds)


func _show_info(label: Label, clips: Array, format: Callable) -> void:
	var texts: Array = []
	for clip in clips:
		texts.append(format.call(clip))
	label.text = str(texts[0]) if not texts.is_empty() and all_same(texts) else MIXED_TEXT


## The file's own sample rate once its peak data is loaded, else the playback rate.
static func _source_rate(clip: Clip) -> int:
	var data: WaveformData = clip.audio_source.data
	if data != null and data.source_sample_rate > 0:
		return data.source_sample_rate
	return clip.audio_sample_rate


static func _channels_text(channels: int) -> String:
	match channels:
		1:
			return "Mono"
		2:
			return "Stereo"
		_:
			return "%d" % channels


# ============================================================================
# GAIN
# ============================================================================

## "-inf" at the floor of the range, otherwise dB with one decimal.
static func format_gain(db: float) -> String:
	if db <= ClipInstance.GAIN_MIN_DB:
		return "-inf"
	return "%.1f dB" % db


## Parse typed gain: "-inf", "3", "-6.5 dB". NAN when it is not a number.
static func parse_gain(text: String) -> float:
	var t := text.strip_edges().to_lower().trim_suffix("db").strip_edges()
	if t == "-inf" or t == "-∞" or t == "inf":
		return ClipInstance.GAIN_MIN_DB
	if t.is_valid_float():
		return clampf(t.to_float(), ClipInstance.GAIN_MIN_DB, ClipInstance.GAIN_MAX_DB)
	return NAN


func _on_gain_drag_started() -> void:
	_flush_pending_click()
	_drag_start.clear()
	_drag_changes = 0
	for inst in _instances():
		_drag_start[inst] = inst.gain_offset


func _on_gain_slider_changed(db: float) -> void:
	if is_refreshing():
		return
	if _drag_start.is_empty():
		# Ctrl-click or double-click reset: one step right away. It also swallows the click that
		# started the double-click, which moved the value and is still waiting to be recorded.
		if not _pending_click.is_empty():
			_commit_gain_from(db, _pending_click)
			_pending_click.clear()
		else:
			_commit_gain(db)
		return
	_drag_changes += 1
	for inst in _drag_start:
		inst.set_gain_offset(db)


func _on_gain_drag_ended() -> void:
	var start := _drag_start.duplicate()
	_drag_start.clear()
	if _drag_changes <= 1 and not start.is_empty():
		# A click, maybe the first half of a double-click: record it shortly, unless a reset follows.
		_pending_click = start
		_pending_serial += 1
		var serial := _pending_serial
		get_tree().create_timer(CLICK_RECORD_DELAY).timeout.connect(func() -> void:
			if serial == _pending_serial:
				_flush_pending_click())
		return
	_record_gain_drag(start)


func _record_gain_drag(start: Dictionary) -> void:
	var cmds: Array[Command] = []
	for inst in start:
		if is_instance_valid(inst) and inst.gain_offset != start[inst]:
			cmds.append(PropertyCommand.new("Set Clip Gain", inst, "set_gain_offset",
					start[inst], inst.gain_offset))
	HistoryUtil.record_many("Set Clip Gain", cmds)


## Record a click that was waiting for a possible double-click.
func _flush_pending_click() -> void:
	if _pending_click.is_empty():
		return
	var start := _pending_click
	_pending_click = {}
	_record_gain_drag(start)


func _commit_gain_text(text: String) -> void:
	var db := parse_gain(text)
	if not is_nan(db):
		_commit_gain(db)


## Set `db` on every selected instance as one undo step.
func _commit_gain(db: float) -> void:
	var from: Dictionary = {}
	for inst in _instances():
		from[inst] = inst.gain_offset
	_commit_gain_from(db, from)


## Set `db` as one undo step whose undo restores `from` (ClipInstance -> dB).
func _commit_gain_from(db: float, from: Dictionary) -> void:
	var cmds: Array[Command] = []
	var target := clampf(db, ClipInstance.GAIN_MIN_DB, ClipInstance.GAIN_MAX_DB)
	for inst in from:
		if is_instance_valid(inst) and (inst.gain_offset != target or from[inst] != target):
			cmds.append(PropertyCommand.new("Set Clip Gain", inst, "set_gain_offset",
					from[inst], target))
	HistoryUtil.execute_many("Set Clip Gain", cmds)


func _instances() -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	for o in objects:
		if o is ClipInstance:
			out.append(o)
	return out


func _clips() -> Array[Clip]:
	var out: Array[Clip] = []
	for inst in _instances():
		if inst.clip != null and not out.has(inst.clip):
			out.append(inst.clip)
	return out
