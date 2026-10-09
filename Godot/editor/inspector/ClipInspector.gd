# ClipInspector.gd
# Inspector section for any selected clips (ClipInstances): name and colour of the source clip,
# position, length, offset, loop and mute of the instances, plus how many instances share the clip.
# Every edit is one undo step across the whole selection.
class_name ClipInspector extends InspectorSection

enum TimeField { POSITION, LENGTH, OFFSET, LOOP_START, LOOP_LENGTH }

var _type_label: Label
var _name_edit: LineEdit
var _color_button: ColorPickerButton
var _color_reset: Button
var _position_edit: LineEdit
var _length_edit: LineEdit
var _offset_edit: LineEdit
var _loop_toggle: Button
var _loop_start_edit: LineEdit
var _loop_length_edit: LineEdit
var _mute_toggle: Button
var _shared_label: Label
var _make_unique: Button

## Clip colours as they were when the colour picker gesture started (Clip -> Color), empty when no
## gesture is running. The picker applies live; the gesture is recorded when its popup closes.
var _color_gesture: Dictionary = {}


## Any selection of clip instances.
static func handles(selected: Array) -> bool:
	if selected.is_empty():
		return false
	for o in selected:
		if not o is ClipInstance:
			return false
	return true


func _init() -> void:
	title = "Clip"


func _build() -> void:
	_type_label = Label.new()
	add_row("Type", _type_label)

	_name_edit = make_text_field(_commit_name)
	add_row("Name", _name_edit)

	var color_box := HBoxContainer.new()
	_color_button = ColorPickerButton.new()
	_color_button.edit_alpha = false
	_color_button.custom_minimum_size = Vector2(48, 0)
	_color_button.color_changed.connect(_on_color_changed)
	_color_button.popup_closed.connect(_on_color_popup_closed)
	color_box.add_child(_color_button)
	_color_reset = Button.new()
	_color_reset.text = "Reset override"
	_color_reset.tooltip_text = "Clear the colour set on the selected clips themselves"
	_color_reset.pressed.connect(_on_color_reset)
	color_box.add_child(_color_reset)
	add_row("Colour", color_box)

	_position_edit = make_text_field(_commit_time.bind(TimeField.POSITION))
	add_row("Position", _position_edit)
	_length_edit = make_text_field(_commit_time.bind(TimeField.LENGTH))
	add_row("Length", _length_edit)
	_offset_edit = make_text_field(_commit_time.bind(TimeField.OFFSET))
	add_row("Offset", _offset_edit)

	_loop_toggle = make_toggle(_commit_loop_enabled)
	add_row("Loop", _loop_toggle)
	_loop_start_edit = make_text_field(_commit_time.bind(TimeField.LOOP_START))
	add_row("Loop start", _loop_start_edit)
	_loop_length_edit = make_text_field(_commit_time.bind(TimeField.LOOP_LENGTH))
	add_row("Loop length", _loop_length_edit)

	_mute_toggle = make_toggle(_commit_muted)
	add_row("Mute", _mute_toggle)

	var shared_box := HBoxContainer.new()
	_shared_label = Label.new()
	_shared_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shared_box.add_child(_shared_label)
	_make_unique = Button.new()
	_make_unique.text = "Make Unique"
	_make_unique.pressed.connect(_on_make_unique)
	shared_box.add_child(_make_unique)
	add_row("Shared by", shared_box)


func _watch_models() -> void:
	for inst in _instances():
		watch(inst.instance_modified)
		watch(inst.clip_changed, _on_clip_swapped)
	for clip in _clips():
		watch(clip.clip_modified)


## Make Unique retargets an instance to a new clip: watch the new clip.
func _on_clip_swapped(_new_clip: Clip) -> void:
	bind(objects)


func _on_unbound() -> void:
	_color_gesture.clear()


func _refresh() -> void:
	var insts := _instances()
	var proj := get_project()

	var types: Array = []
	for inst in insts:
		types.append("—" if inst.clip == null else ("Audio" if inst.clip.type == Clip.ClipType.AUDIO else "MIDI"))
	_type_label.text = types[0] if all_same(types) and not types.is_empty() else MIXED_TEXT

	show_text(_name_edit, _clips().map(func(c: Clip) -> String: return c.name))

	var clips := _clips()
	if not clips.is_empty() and _color_gesture.is_empty():
		_color_button.set_pick_color(clips[0].color)
	_color_button.tooltip_text = "Colours differ" if not all_same(clips.map(func(c: Clip) -> Color: return c.color)) else ""
	_color_reset.visible = insts.any(func(i: ClipInstance) -> bool: return i.color_override.a > 0.0)

	var loops: Array = insts.map(func(i: ClipInstance) -> bool: return i.loop_enabled)
	show_toggle(_loop_toggle, loops)
	show_toggle(_mute_toggle, insts.map(func(i: ClipInstance) -> bool: return i.muted))
	_loop_start_edit.editable = loops.has(true)
	_loop_length_edit.editable = loops.has(true)

	if proj != null:
		_show_time(_position_edit, insts, TimeField.POSITION, proj)
		_show_time(_length_edit, insts, TimeField.LENGTH, proj)
		_show_time(_offset_edit, insts, TimeField.OFFSET, proj)
		_show_time(_loop_start_edit, insts, TimeField.LOOP_START, proj)
		_show_time(_loop_length_edit, insts, TimeField.LOOP_LENGTH, proj)

	var shared_counts: Array = []
	var any_shared := false
	for clip in clips:
		var n := proj.get_clip_instance_count(clip.id) if proj != null else 1
		shared_counts.append(n)
		any_shared = any_shared or n > 1
	if shared_counts.is_empty() or not all_same(shared_counts):
		_shared_label.text = MIXED_TEXT
	elif shared_counts[0] > 1:
		_shared_label.text = "%d instances" % shared_counts[0]
	else:
		_shared_label.text = "Unique"
	_make_unique.disabled = not any_shared


func _show_time(edit: LineEdit, insts: Array, field: TimeField, proj: Project) -> void:
	var values: Array = insts.map(func(i: ClipInstance) -> int: return _time_value(i, field))
	show_text(edit, values, func(ticks: int) -> String: return _format_time(proj, ticks, field, insts[0]))


# ============================================================================
# TIME FIELDS
# ============================================================================

static func _time_value(inst: ClipInstance, field: TimeField) -> int:
	match field:
		TimeField.POSITION: return inst.start_ticks
		TimeField.LENGTH: return inst.duration_ticks
		TimeField.OFFSET: return inst.clip_offset
		TimeField.LOOP_START: return inst.loop_start_ticks
		_: return inst.loop_length_ticks


static func _format_time(proj: Project, ticks: int, field: TimeField, inst: ClipInstance) -> String:
	if field == TimeField.POSITION:
		return InspectorBbt.format_position(proj, ticks)
	return InspectorBbt.format_duration(proj, ticks, inst.start_ticks)


## Typed text for one time field: applies to every selected instance as one undo step.
func _commit_time(text: String, field: TimeField) -> void:
	var proj := get_project()
	if proj == null:
		return
	var insts := _instances()
	if insts.is_empty():
		return
	var ticks := InspectorBbt.parse_position(proj, text) if field == TimeField.POSITION \
			else InspectorBbt.parse_duration(proj, text, insts[0].start_ticks)
	var needs_positive := field == TimeField.LENGTH or field == TimeField.LOOP_LENGTH
	if ticks < (1 if needs_positive else 0):
		return
	var cmds: Array[Command] = []
	for inst in insts:
		var cmd := _transform_command(inst, field, ticks)
		if cmd != null:
			cmds.append(cmd)
	HistoryUtil.execute_many("Edit Clips", cmds)


## Command that sets one time field of `inst` to `ticks`, or null when nothing would change.
func _transform_command(inst: ClipInstance, field: TimeField, ticks: int) -> ClipInstanceTransformCommand:
	var start := inst.start_ticks
	var duration := inst.duration_ticks
	var offset := inst.clip_offset
	var old_loop := inst.get_loop_state()
	var new_loop := old_loop.duplicate()
	var label := "Edit Clip"
	match field:
		TimeField.POSITION:
			start = maxi(0, ticks)
			label = "Move Clip"
		TimeField.LENGTH:
			duration = _clamp_length(inst, ticks)
			label = "Resize Clip"
		TimeField.OFFSET:
			offset = _clamp_offset(inst, ticks)
			label = "Set Clip Offset"
		TimeField.LOOP_START:
			new_loop[1] = ticks
			label = "Set Loop Start"
		TimeField.LOOP_LENGTH:
			new_loop[2] = ticks
			label = "Set Loop Length"
	if start == inst.start_ticks and duration == inst.duration_ticks and offset == inst.clip_offset \
			and new_loop == old_loop:
		return null
	return ClipInstanceTransformCommand.new(label, inst,
			inst.start_ticks, inst.duration_ticks, inst.clip_offset,
			start, duration, offset, old_loop, new_loop)


## Audio that doesn't loop can't play past the end of its file.
func _clamp_length(inst: ClipInstance, ticks: int) -> int:
	if _limited_by_source(inst):
		return clampi(ticks, 1, maxi(1, inst.content_end_ticks() - inst.clip_offset))
	return maxi(1, ticks)


func _clamp_offset(inst: ClipInstance, ticks: int) -> int:
	if _limited_by_source(inst):
		return clampi(ticks, 0, maxi(0, inst.content_end_ticks() - 1))
	return maxi(0, ticks)


static func _limited_by_source(inst: ClipInstance) -> bool:
	return inst.clip != null and inst.clip.type == Clip.ClipType.AUDIO and not inst.loop_enabled


# ============================================================================
# OTHER EDITS
# ============================================================================

func _commit_name(text: String) -> void:
	var new_name := text.strip_edges()
	if new_name.is_empty():
		return
	var cmds: Array[Command] = []
	for clip in _clips():
		if clip.name != new_name:
			cmds.append(PropertyCommand.new("Rename Clip", clip, "set_name", clip.name, new_name))
	HistoryUtil.execute_many("Rename Clips", cmds)


## Switch looping for the selection. Switching on loops the content each clip shows now.
func _commit_loop_enabled(enabled: bool) -> void:
	var cmds: Array[Command] = []
	for inst in _instances():
		var old_state := inst.get_loop_state()
		var region := Vector2i(inst.loop_start_ticks, inst.loop_length_ticks)
		if enabled and not inst.loop_enabled:
			region = inst.default_loop_region()
		var new_state := [enabled, region.x, region.y]
		if new_state == old_state:
			continue
		cmds.append(ClipInstanceTransformCommand.new(
				"Loop Clip" if enabled else "Unloop Clip", inst,
				inst.start_ticks, inst.duration_ticks, inst.clip_offset,
				inst.start_ticks, inst.duration_ticks, inst.clip_offset,
				old_state, new_state))
	HistoryUtil.execute_many("Loop Clips" if enabled else "Unloop Clips", cmds)


func _commit_muted(muted: bool) -> void:
	var cmds: Array[Command] = []
	for inst in _instances():
		if inst.muted != muted:
			cmds.append(PropertyCommand.new("Mute Clip" if muted else "Unmute Clip", inst,
					"set_muted", inst.muted, muted))
	HistoryUtil.execute_many("Mute Clips" if muted else "Unmute Clips", cmds)


func _on_color_changed(new_color: Color) -> void:
	if is_refreshing():
		return
	if _color_gesture.is_empty():
		for clip in _clips():
			_color_gesture[clip] = clip.color
	for clip in _color_gesture:
		clip.set_color(new_color)


## The picker applied the colour live; the closing popup is one undo step.
func _on_color_popup_closed() -> void:
	var cmds: Array[Command] = []
	for clip: Clip in _color_gesture:
		var old_color: Color = _color_gesture[clip]
		if clip.color != old_color:
			cmds.append(PropertyCommand.new("Set Clip Colour", clip, "set_color", old_color, clip.color))
	_color_gesture.clear()
	HistoryUtil.record_many("Set Clip Colours", cmds)


func _on_color_reset() -> void:
	var cmds: Array[Command] = []
	for inst in _instances():
		if inst.color_override.a > 0.0:
			cmds.append(PropertyCommand.new("Reset Clip Colour", inst,
					"set_color_override", inst.color_override, Color.TRANSPARENT))
	HistoryUtil.execute_many("Reset Clip Colours", cmds)


## Give each selected instance of a shared clip its own copy (same as the clip context menu).
func _on_make_unique() -> void:
	var proj := get_project()
	if proj == null:
		return
	var cmds: Array[Command] = []
	for inst in _instances():
		if inst.clip != null and proj.get_clip_instance_count(inst.clip.id) > 1:
			cmds.append(MakeClipUniqueCommand.new(proj, inst))
	HistoryUtil.execute_many("Make Clips Unique", cmds)


# ============================================================================
# SELECTION
# ============================================================================

func _instances() -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	for o in objects:
		if o is ClipInstance:
			out.append(o)
	return out


## The distinct source clips of the selected instances.
func _clips() -> Array[Clip]:
	var out: Array[Clip] = []
	for inst in _instances():
		if inst.clip != null and not out.has(inst.clip):
			out.append(inst.clip)
	return out
