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
@onready var scale_half: Button = $VBoxContainer/TimeScale/ScaleHalf
@onready var scale_double: Button = $VBoxContainer/TimeScale/ScaleDouble
@onready var make_legato: Button = $VBoxContainer/Legato/MakeLegato
@onready var merge_same: Button = $VBoxContainer/Legato/MergeSame
@onready var split_to_tracks: Button = $VBoxContainer/SplitToTracks
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
	if is_instance_valid(scale_half):
		scale_half.pressed.connect(_on_scale_pressed.bind(0.5))
	if is_instance_valid(scale_double):
		scale_double.pressed.connect(_on_scale_pressed.bind(2.0))
	if is_instance_valid(make_legato):
		make_legato.pressed.connect(_on_legato_pressed.bind(true, false))
	if is_instance_valid(merge_same):
		merge_same.pressed.connect(_on_legato_pressed.bind(false, true))
	if is_instance_valid(split_to_tracks):
		split_to_tracks.pressed.connect(_on_split_to_tracks_pressed)
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

	# Legato, Merge Same and Split to Tracks edit the notes of MIDI clips.
	if make_legato:
		make_legato.disabled = not all_midi
	if merge_same:
		merge_same.disabled = not all_midi
	if split_to_tracks:
		var targets := split_target_tracks()
		var ok := all_midi and not targets.is_empty()
		for inst in selected_instances:
			ok = ok and (targets.size() > 1 or inst.track not in targets)
		split_to_tracks.disabled = not ok

	# Scaling rewrites note timing too, so it needs MIDI clips only.
	if scale_half:
		scale_half.disabled = not all_midi
	if scale_double:
		scale_double.disabled = not all_midi

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
	HistoryUtil.execute(ClipRenameCommand.new(clip_instance.clip, new_name))


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
	ContextMenuPopup.close(self)


## Request Copy for the bound instances.
func _on_copy_pressed() -> void:
	if selected_instances.is_empty():
		return
	copy_requested.emit(selected_instances.duplicate())
	ContextMenuPopup.close(self)


## Delete the bound instances.
func _on_delete_pressed() -> void:
	if selected_instances.is_empty():
		return
	delete_requested.emit(selected_instances.duplicate())
	ContextMenuPopup.close(self)


## Request Merge for the bound instances.
func _on_merge_pressed() -> void:
	if selected_instances.is_empty():
		return
	merge_requested.emit(selected_instances.duplicate())
	ContextMenuPopup.close(self)


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
	ContextMenuPopup.close(self)


## Scale the selected MIDI clips' time axis by `factor` (0.5 or 2.0) as one undo step. Like
## Transpose it edits the source clip, so every instance of a shared clip scales with it.
func _on_scale_pressed(factor: float) -> void:
	var tracks: Array = []
	if Sonara and Sonara.editor and Sonara.editor.project:
		tracks = Sonara.editor.project.tracks
	if scale_selected(factor, tracks):
		ContextMenuPopup.close(self)


## Scale the bound MIDI clips by `factor`, along with every instance of them on `tracks` (the
## project's tracks; the bound instances alone when empty). Returns false when nothing applies.
func scale_selected(factor: float, tracks: Array) -> bool:
	var clips := _midi_clips_of(selected_instances)
	if clips.is_empty():
		return false
	var pool: Array = selected_instances.duplicate()
	for track in tracks:
		for inst in track.clip_instances:
			if not pool.has(inst):
				pool.append(inst)
	ClipScaleActions.scale_clips("Scale Clip %s" % ("Half" if factor < 1.0 else "Double"),
			clips, pool, factor)
	return true


## Make Legato or Merge Same Notes on every note of the selected MIDI clips as one undo step. The
## edit is destructive like Transpose: every instance of a shared clip changes.
func _on_legato_pressed(legato: bool, merge: bool) -> void:
	if legato_selected(legato, merge) > 0:
		ContextMenuPopup.close(self)


## Run the legato / merge tool on the bound MIDI clips. Returns the number of notes changed.
func legato_selected(legato: bool, merge: bool) -> int:
	return NoteLegato.apply_to_clips(_midi_clips_of(selected_instances), legato, merge,
			"Make Legato" if legato else "Merge Same Notes")


## The arranger's selected tracks that can receive notes, in arranger order.
func split_target_tracks() -> Array[Track]:
	var out: Array[Track] = []
	if not (Sonara and Sonara.editor and Sonara.editor.project):
		return out
	for t in Sonara.editor.project.get_visual_track_list():
		if t in Sonara.editor.selected_tracks and t.is_note_editor_track():
			out.append(t)
	return out


## Split Voices for the selected MIDI clips onto the selected tracks (see NoteSplitActions).
func _on_split_to_tracks_pressed() -> void:
	if split_selected(split_target_tracks()) > 0:
		ContextMenuPopup.close(self)


## Spread the voices of every note of the bound MIDI clips over `targets` as one undo step.
## Returns the number of notes moved to other tracks.
func split_selected(targets: Array[Track]) -> int:
	if not (Sonara and Sonara.editor and Sonara.editor.project):
		return 0
	return NoteSplitActions.split_instances(Sonara.editor.project, selected_instances, targets)


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
	ContextMenuPopup.close(self)


## Request Make Unique for the bound instances.
func _on_make_unique_pressed() -> void:
	if selected_instances.is_empty():
		return
	make_unique_requested.emit(selected_instances.duplicate())
	ContextMenuPopup.close(self)


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
	ContextMenuPopup.close(self)


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
## `bounds` (all in popup coordinates), otherwise above. It lines up with the click at `from_x`.
func popup_docked(clip_rect: Rect2, bounds: Rect2, from_x: float) -> void:
	var anchor := Rect2(from_x - 8.0, clip_rect.position.y, 0.0, clip_rect.size.y)
	var menu_width := maxf(float(get_contents_minimum_size().x), 192.0)
	min_size = Vector2i(int(menu_width), min_size.y)
	ContextMenuPopup.popup_anchored(self, anchor, false, false, bounds)
