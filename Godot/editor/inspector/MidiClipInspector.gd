# MidiClipInspector.gd
# Inspector section for selections made only of MIDI clip instances: the velocity distribution of
# their notes (histogram with median and mean markers, min / median / mean / max readout) and a
# range slider that rewrites the velocities.
#
# The slider's handles are the new lowest and highest velocity. Dragging a handle remaps every
# note linearly from the range it had when the drag began, so the whole distribution is scaled or
# squashed; dragging the fill moves both handles, which shifts everything and squashes against
# 1 or 127 instead of clipping notes onto one value. The edit is destructive: it rewrites the
# velocities of the source clips (every instance of a shared clip changes). A drag applies live
# and is one undo step (`ClipNotesStateCommand`) recorded on release.
class_name MidiClipInspector extends InspectorSection

var _distribution: VelocityDistribution
var _range_slider: HDualSlider
var _stats_label: Label

## Velocity (7-bit) of each note before the drag (MidiNoteData -> float), empty when no drag runs.
var _drag_origin: Dictionary = {}
var _drag_before: Dictionary = {}
var _drag_src_lo := 1.0
var _drag_src_hi := 127.0


## Every selected object is a MIDI clip instance.
static func handles(selected: Array) -> bool:
	if selected.is_empty():
		return false
	for o in selected:
		if not (o is ClipInstance and o.clip != null and o.clip.type == Clip.ClipType.MIDI):
			return false
	return true


func _init() -> void:
	title = "Velocity"


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	_distribution = VelocityDistribution.new()
	box.add_child(_distribution)
	_range_slider = HDualSlider.new()
	_range_slider.min_value = VelocityRemap.MIN_V
	_range_slider.max_value = VelocityRemap.MAX_V
	_range_slider.custom_minimum_size.y = 16.0
	_range_slider.tooltip_text = "Drag a handle to scale the velocities into a new range.\nDrag between the handles to shift them all (squashing at 1 and 127)."
	_range_slider.drag_started.connect(_on_drag_started)
	_range_slider.values_changed.connect(_on_range_changed)
	_range_slider.drag_ended.connect(_on_drag_ended)
	box.add_child(_range_slider)
	_stats_label = Label.new()
	_stats_label.add_theme_color_override(&"font_color", UiColors.role(&"text_dim"))
	_stats_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_stats_label)
	add_row("Range", box)


func _watch_models() -> void:
	for clip in _clips():
		watch(clip.clip_modified, _on_clip_modified)


## During a drag every note update emits clip_modified: refresh once per slider step instead.
func _on_clip_modified() -> void:
	if _drag_origin.is_empty():
		refresh()


func _on_unbound() -> void:
	_drag_origin.clear()
	_drag_before.clear()


func _refresh() -> void:
	var values := _velocities()
	_distribution.set_values(values)
	var s := VelocityRemap.stats(values)
	_range_slider.mouse_filter = Control.MOUSE_FILTER_STOP if not values.is_empty() else Control.MOUSE_FILTER_IGNORE
	if values.is_empty():
		_stats_label.text = "No notes"
		_range_slider.set_values_no_signal(VelocityRemap.MIN_V, VelocityRemap.MAX_V)
		return
	_stats_label.text = "Min %d  Med %d  Avg %d  Max %d" % [
			roundi(s["min"]), roundi(s["median"]), roundi(s["mean"]), roundi(s["max"])]
	# A drag owns the handles; they would otherwise snap back to the live min / max.
	if _drag_origin.is_empty():
		_range_slider.set_values_no_signal(s["min"], s["max"])


func _on_drag_started() -> void:
	_drag_origin.clear()
	var values: Array = []
	for note: MidiNoteData in _notes():
		_drag_origin[note] = VelocityRemap.to_v7(note.velocity)
		values.append(_drag_origin[note])
	if values.is_empty():
		return
	var s := VelocityRemap.stats(values)
	_drag_src_lo = s["min"]
	_drag_src_hi = s["max"]
	_drag_before = ClipNotesStateCommand.capture_many(_clips())


func _on_range_changed(a: float, b: float) -> void:
	if _drag_origin.is_empty():
		return
	var lo := minf(a, b)
	var hi := maxf(a, b)
	var touched: Dictionary = {}
	for note: MidiNoteData in _drag_origin:
		var v7 := VelocityRemap.remap(_drag_origin[note], _drag_src_lo, _drag_src_hi, lo, hi)
		var velocity := VelocityRemap.to_normalized(v7)
		if is_equal_approx(note.velocity, velocity):
			continue
		note.velocity = velocity
		touched[note] = true
	for clip in _clips():
		for note: MidiNoteData in clip.midi_notes:
			if touched.has(note):
				clip.update_midi_note(note)
	refresh()


func _on_drag_ended() -> void:
	if _drag_origin.is_empty():
		return
	var before := _drag_before
	_drag_origin = {}
	_drag_before = {}
	ClipNotesStateCommand.commit_many("Adjust Velocity", before)
	refresh()


func _clips() -> Array[Clip]:
	var out: Array[Clip] = []
	for o in objects:
		var inst := o as ClipInstance
		if inst != null and inst.clip != null and not out.has(inst.clip):
			out.append(inst.clip)
	return out


func _notes() -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	for clip in _clips():
		out.append_array(clip.midi_notes)
	return out


## 7-bit velocities of every note in the selected clips.
func _velocities() -> Array:
	return _notes().map(func(n: MidiNoteData) -> float: return VelocityRemap.to_v7(n.velocity))
