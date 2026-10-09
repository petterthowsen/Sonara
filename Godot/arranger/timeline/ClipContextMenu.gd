class_name ClipContextMenu extends PopupPanel

static var logger := Log.make("ClipContextMenu")

# Containers
@onready var v_box: VBoxContainer = $VBoxContainer
@onready var header: HBoxContainer = $VBoxContainer/Header

# Data Controls
@onready var label: SmartLineEdit = $VBoxContainer/Header/Label
@onready var mute_toggle: Button = $VBoxContainer/Header/MuteToggle
@onready var loop_toggle: Button = $VBoxContainer/Header/LoopToggle
@onready var reverse_checkbox: CheckButton = $VBoxContainer/ReverseCheckbox
@onready var cut: Button = $VBoxContainer/CutCopy/Cut
@onready var copy: Button = $VBoxContainer/CutCopy/Copy
@onready var split: Button = $VBoxContainer/Split
@onready var merge: Button = $VBoxContainer/Merge
@onready var transpose_down: Button = $VBoxContainer/Transpose/OctaveDown
@onready var transpose_up: Button = $VBoxContainer/Transpose/OctaveUp
@onready var make_unique: Button = $VBoxContainer/MakeUnique
@onready var make_unique_per_track: Button = $VBoxContainer/MakeUniquePerTrack
@onready var delete: Button = $VBoxContainer/Delete

signal delete_requested(instances: Array[ClipInstance])
signal make_unique_requested(instances: Array[ClipInstance])
signal make_unique_per_track_requested(instances: Array[ClipInstance])
signal cut_requested(instances: Array[ClipInstance])
signal copy_requested(instances: Array[ClipInstance])
signal split_requested(instances: Array[ClipInstance])
signal merge_requested(instances: Array[ClipInstance])

const SLIDE_SECONDS := 0.3
const CLIP_GAP := 4.0

## Transpose step of the two octave entries.
const OCTAVE_SEMITONES := 12

var clip_instance: ClipInstance = null
var selected_instances: Array[ClipInstance] = []


## Wire buttons, size the title so the name is readable, and listen for renames.
func _ready() -> void:
	if is_instance_valid(loop_toggle):
		loop_toggle.toggled.connect(_on_loop_toggled)
	if is_instance_valid(reverse_checkbox):
		reverse_checkbox.toggled.connect(_on_reverse_toggled)
	if is_instance_valid(mute_toggle):
		mute_toggle.toggled.connect(_on_mute_toggled)
	if is_instance_valid(split):
		split.pressed.connect(_on_split_pressed)
	if is_instance_valid(merge):
		merge.pressed.connect(_on_merge_pressed)
	if is_instance_valid(transpose_down):
		transpose_down.pressed.connect(_on_transpose_pressed.bind(-OCTAVE_SEMITONES))
	if is_instance_valid(transpose_up):
		transpose_up.pressed.connect(_on_transpose_pressed.bind(OCTAVE_SEMITONES))
	if is_instance_valid(cut):
		cut.pressed.connect(_on_cut_pressed)
	if is_instance_valid(copy):
		copy.pressed.connect(_on_copy_pressed)
	if is_instance_valid(make_unique):
		make_unique.pressed.connect(_on_make_unique_pressed)
	if is_instance_valid(make_unique_per_track):
		make_unique_per_track.pressed.connect(_on_make_unique_per_track_pressed)
	if is_instance_valid(delete):
		delete.pressed.connect(_on_delete_pressed)
	if is_instance_valid(label):
		label.custom_minimum_size = Vector2(96, 32)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_FILL
		if label.label:
			label.label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			if label.label.label_settings:
				label.label.label_settings = label.label.label_settings.duplicate()
				label.label.label_settings.font_size = 16
		if not label.value_changed.is_connected(_on_name_changed):
			label.value_changed.connect(_on_name_changed)
	if is_instance_valid(v_box):
		v_box.custom_minimum_size.x = 192


## Bind the menu to a single clip instance.
func bind_to_clip_instance(inst: ClipInstance) -> void:
	var arr: Array[ClipInstance] = []
	if inst:
		arr = [inst]
	bind_to_instances(arr)


## Bind the menu to the current selection (title only for a single instance).
func bind_to_instances(instances: Array[ClipInstance]) -> void:
	selected_instances.clear()
	for i in instances:
		if i:
			selected_instances.append(i)

	clip_instance = selected_instances[0] if selected_instances.size() == 1 else null

	# Label visibility and content
	if label:
		label.visible = selected_instances.size() == 1
		if label.visible and clip_instance:
			if label.is_editing:
				label.cancel_editing()
			var clip_name = clip_instance.clip.name if clip_instance.clip else "Clip"
			label.set_value(clip_name)

	# Loop reads on when every selected instance loops
	if loop_toggle:
		var all_loop := not selected_instances.is_empty()
		for inst in selected_instances:
			all_loop = all_loop and inst.loop_enabled
		loop_toggle.set_pressed_no_signal(all_loop)
		loop_toggle.disabled = selected_instances.is_empty()

	# Mute reads on when every selected instance is muted
	if mute_toggle:
		var all_muted := not selected_instances.is_empty()
		for inst in selected_instances:
			all_muted = all_muted and inst.muted
		mute_toggle.set_pressed_no_signal(all_muted)
		mute_toggle.disabled = selected_instances.is_empty()

	# Split needs a single instance with the split position inside it.
	_update_split_enabled()

	# Merge needs at least one MIDI instance.
	if merge:
		merge.disabled = not ClipMergeActions.can_merge(selected_instances)

	# Transpose rewrites note pitches, so it needs MIDI clips only.
	var all_midi := not selected_instances.is_empty()
	for inst in selected_instances:
		all_midi = all_midi and inst.clip != null and inst.clip.type == Clip.ClipType.MIDI
	if transpose_down:
		transpose_down.disabled = not all_midi
	if transpose_up:
		transpose_up.disabled = not all_midi

	# Reverse is an audio-clip feature: shown only when every selected instance is audio.
	if reverse_checkbox:
		var all_audio := not selected_instances.is_empty()
		for inst in selected_instances:
			all_audio = all_audio and inst.clip != null \
					and inst.clip.type == Clip.ClipType.AUDIO
		reverse_checkbox.visible = all_audio
		var all_reverse := all_audio
		for inst in selected_instances:
			all_reverse = all_reverse and inst.reverse_enabled
		reverse_checkbox.set_pressed_no_signal(all_reverse)

	# Enable/disable Make Unique: enable if ANY selected instance shares its clip
	var can_make_unique = false
	if Sonara and Sonara.editor and Sonara.editor.project:
		var proj := Sonara.editor.project
		for inst in selected_instances:
			if inst and inst.clip_id and proj.get_clip_instance_count(inst.clip_id) > 1:
				can_make_unique = true
				break
	if make_unique:
		make_unique.disabled = not can_make_unique

	# Per-track variant: enabled when ANY selected instance's clip is also used on another track.
	var can_per_track := false
	if Sonara and Sonara.editor and Sonara.editor.project:
		for inst in selected_instances:
			if MakeClipUniquePerTrackCommand.is_shared_across_tracks(Sonara.editor.project, inst):
				can_per_track = true
				break
	if make_unique_per_track:
		make_unique_per_track.disabled = not can_per_track


## Commit a clip rename from the menu title.
func _on_name_changed(new_value) -> void:
	if clip_instance == null or clip_instance.clip == null:
		return
	var new_name := str(new_value).strip_edges()
	if new_name.is_empty() or new_name == clip_instance.clip.name:
		return
	HistoryUtil.execute_property("Rename Clip", clip_instance.clip, "set_name", clip_instance.clip.name, new_name)


## Switch looping on or off for the bound instances as one undo step. Switching on loops the
## content each clip shows now.
func _on_loop_toggled(enabled: bool) -> void:
	var cmds: Array[Command] = []
	for inst in selected_instances:
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


## Switch audio playback direction for the bound audio instances as one undo step.
func _on_reverse_toggled(enabled: bool) -> void:
	var cmds: Array[Command] = []
	for inst in selected_instances:
		if inst == null or inst.clip == null or inst.clip.type != Clip.ClipType.AUDIO:
			continue
		if inst.reverse_enabled == enabled:
			continue
		cmds.append(PropertyCommand.new(
			"Reverse Clip" if enabled else "Unreverse Clip", inst,
			"set_reverse_enabled", inst.reverse_enabled, enabled))
	HistoryUtil.execute_many("Reverse Clips" if enabled else "Unreverse Clips", cmds)


## Request Cut for the bound instances.
func _on_cut_pressed() -> void:
	if selected_instances.is_empty():
		return
	cut_requested.emit(selected_instances.duplicate())
	hide()


## Request Copy for the bound instances.
func _on_copy_pressed() -> void:
	if selected_instances.is_empty():
		return
	copy_requested.emit(selected_instances.duplicate())
	hide()


## Delete the bound instances.
func _on_delete_pressed() -> void:
	if selected_instances.is_empty():
		return
	delete_requested.emit(selected_instances.duplicate())
	hide()


## Request Merge for the bound instances.
func _on_merge_pressed() -> void:
	if selected_instances.is_empty():
		return
	merge_requested.emit(selected_instances.duplicate())
	hide()


## Transpose the selected MIDI clips by `semitones` as one undo step. The edit is destructive:
## it rewrites the source clips' note pitches, so every instance of a shared clip moves.
func _on_transpose_pressed(semitones: int) -> void:
	var clips := _midi_clips_of(selected_instances)
	if clips.is_empty():
		return
	var before := ClipNotesStateCommand.capture_many(clips)
	var pinned := 0
	for clip: Clip in clips:
		for note: MidiNoteData in clip.midi_notes:
			var moved := note.note + semitones
			var shifted := clampi(moved, 0, 127)
			if shifted == note.note:
				continue
			if shifted != moved:
				pinned += 1
			note.note = shifted
			clip.update_midi_note(note)
	if pinned > 0:
		logger.warn("Transpose: %d note(s) stopped at the 0-127 pitch range" % pinned)
	ClipNotesStateCommand.commit_many("Transpose %s %s an Octave" % [
		"Clips" if clips.size() > 1 else "Clip",
		"Up" if semitones > 0 else "Down",
	], before)
	hide()


## The distinct MIDI source clips of `instances`, in selection order.
static func _midi_clips_of(instances: Array[ClipInstance]) -> Array[Clip]:
	var clips: Array[Clip] = []
	for inst in instances:
		if inst == null or inst.clip == null or inst.clip.type != Clip.ClipType.MIDI:
			continue
		if not clips.has(inst.clip):
			clips.append(inst.clip)
	return clips


## Request Make Unique Per Track for the bound instances.
func _on_make_unique_per_track_pressed() -> void:
	if selected_instances.is_empty():
		return
	make_unique_per_track_requested.emit(selected_instances.duplicate())
	hide()


## Request Make Unique for the bound instances.
func _on_make_unique_pressed() -> void:
	if selected_instances.is_empty():
		return
	make_unique_requested.emit(selected_instances.duplicate())
	hide()


## Where a split lands, in song ticks. Set by the caller before popup; -1 means "not set".
var split_tick: int = -1:
	set(value):
		split_tick = value
		_update_split_enabled()


func _update_split_enabled() -> void:
	if not split:
		return
	var ok := clip_instance != null and split_tick > clip_instance.start_ticks \
			and split_tick < clip_instance.get_end_ticks()
	split.disabled = not ok


## Request a split of the bound instance at `split_tick`.
func _on_split_pressed() -> void:
	if clip_instance == null:
		return
	split_requested.emit([clip_instance] as Array[ClipInstance])
	hide()


## Mute or unmute the bound instances as one undo step.
func _on_mute_toggled(enabled: bool) -> void:
	var cmds: Array[Command] = []
	for inst in selected_instances:
		if inst.muted == enabled:
			continue
		cmds.append(PropertyCommand.new(
			"Mute Clip" if enabled else "Unmute Clip", inst, "set_muted", inst.muted, enabled))
	HistoryUtil.execute_many("Mute Clips" if enabled else "Unmute Clips", cmds)


## Show the menu docked to the clip: below it when there is room under `clip_rect` inside
## `bounds` (all in popup coordinates), otherwise above. The window slides in from `from_pos`.
func popup_docked(clip_rect: Rect2, bounds: Rect2, from_x: float, from_y: float) -> void:
	var menu_size := Vector2(get_contents_minimum_size())
	menu_size.x = maxf(menu_size.x, 192.0)
	var below := clip_rect.end.y + CLIP_GAP + menu_size.y <= bounds.end.y
	var target_y := clip_rect.end.y + CLIP_GAP if below else clip_rect.position.y - CLIP_GAP - menu_size.y
	target_y = clampf(target_y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - menu_size.y))
	var x := clampf(from_x - 8.0, bounds.position.x, maxf(bounds.position.x, bounds.end.x - menu_size.x))
	var start_y := from_y
	popup(Rect2i(Vector2i(int(x), int(start_y)), Vector2i(menu_size)))
	var tween := create_tween()
	tween.tween_property(self, "position:y", int(target_y), SLIDE_SECONDS) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
