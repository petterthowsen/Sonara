# AudioClipInspector.gd
# Inspector section for selections made only of audio clip instances: the instance gain and the
# read-only facts about the source file. Phase 3 of spec 029 adds stretch mode and clip tempo here.
#
# Gain is per instance (ClipInstance.gain_offset). A drag on the slider applies live and is
# recorded as one undo step when the mouse is released. Double-click resets to 0 dB.
class_name AudioClipInspector extends InspectorSection

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
		watch(inst.gain_changed, _on_gain_changed)
		watch(inst.clip_changed, _on_clip_swapped)
		if inst.clip:
			watch(inst.clip.clip_modified)
			watch(inst.clip.audio_source.metadata_changed)


func _on_gain_changed(_db: float) -> void:
	refresh()


func _on_clip_swapped(_new_clip: Clip) -> void:
	bind(objects)


func _on_unbound() -> void:
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
	_drag_start.clear()
	for inst in _instances():
		_drag_start[inst] = inst.gain_offset


func _on_gain_slider_changed(db: float) -> void:
	if is_refreshing():
		return
	if _drag_start.is_empty():
		# Ctrl-click or double-click reset: one step right away.
		_commit_gain(db)
		return
	for inst in _drag_start:
		inst.set_gain_offset(db)


func _on_gain_drag_ended() -> void:
	var cmds: Array[Command] = []
	for inst in _drag_start:
		if is_instance_valid(inst) and inst.gain_offset != _drag_start[inst]:
			cmds.append(PropertyCommand.new("Set Clip Gain", inst, "set_gain_offset",
					_drag_start[inst], inst.gain_offset))
	_drag_start.clear()
	HistoryUtil.record_many("Set Clip Gain", cmds)


func _commit_gain_text(text: String) -> void:
	var db := parse_gain(text)
	if not is_nan(db):
		_commit_gain(db)


## Set `db` on every selected instance as one undo step.
func _commit_gain(db: float) -> void:
	var cmds: Array[Command] = []
	for inst in _instances():
		if inst.gain_offset != clampf(db, ClipInstance.GAIN_MIN_DB, ClipInstance.GAIN_MAX_DB):
			cmds.append(PropertyCommand.new("Set Clip Gain", inst, "set_gain_offset",
					inst.gain_offset, db))
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
