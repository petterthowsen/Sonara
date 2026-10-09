# MakeClipUniqueCommand.gd
# Undoable "Make Unique" — duplicates a shared Clip and retargets one instance.
class_name MakeClipUniqueCommand extends Command

## Project that owns the clip pool.
var project: Project = null

## Instance that should point at the unique clip.
var instance: ClipInstance = null

## Original shared clip (restored on undo).
var original_clip: Clip = null

## Newly created unique clip (created on first do).
var unique_clip: Clip = null


## Create a make-unique command for one clip instance.
func _init(p_project: Project = null, p_instance: ClipInstance = null) -> void:
	name = "Make Clip Unique"
	project = p_project
	instance = p_instance
	if instance != null:
		original_clip = instance.clip


## Duplicate the clip (once) and retarget the instance.
func do() -> void:
	if project == null or instance == null or original_clip == null:
		return
	if unique_clip == null:
		unique_clip = _duplicate_clip(original_clip)
		project.add_clip(unique_clip)
	elif not project.clips.has(unique_clip.id):
		project.add_clip(unique_clip)
	instance.set_clip(unique_clip)
	_resync_instance()


## Point the instance back at the original shared clip.
func undo() -> void:
	if project == null or instance == null or original_clip == null:
		return
	instance.set_clip(original_clip)
	_resync_instance()
	if unique_clip != null and project.get_clip_instance_count(unique_clip.id) == 0:
		project.remove_clip(unique_clip.id)


## Deep-copy clip content into a new Clip with fresh note IDs.
func _duplicate_clip(source: Clip) -> Clip:
	var new_name := project.unique_clip_name(source.name)
	var new_clip: Clip = project.create_clip(new_name, source.type)
	new_clip.color = source.color
	new_clip.content_length_ticks = source.content_length_ticks
	if source.type == Clip.ClipType.MIDI:
		for note in source.midi_notes:
			var nn := MidiNoteData.new()
			nn.id = project.allocate_note_id()
			nn.copy_values_from(note)
			nn.start_tick = note.start_tick
			nn.duration_ticks = note.duration_ticks
			new_clip.midi_notes.append(nn)
		for ev in source.midi_events:
			var nev := MidiEvent.new()
			nev.type = ev.type
			nev.tick = ev.tick
			nev.note = ev.note
			nev.velocity = ev.velocity
			nev.cc_number = ev.cc_number
			nev.cc_value = ev.cc_value
			nev.program = ev.program
			nev.pitch_bend = ev.pitch_bend
			nev.aftertouch = ev.aftertouch
			new_clip.midi_events.append(nev)
	else:
		new_clip.audio_file_path = source.audio_file_path
		new_clip.set_recorded_bpm(source.recorded_bpm)
		# Metadata plus the shared peak data (WaveformRegistry keeps one copy per file).
		new_clip.audio_source.share_from(source.audio_source)
		new_clip.apply_load_state(Clip.LoadState.UNLOADED, "", "")
		new_clip.load_progress = 0.0
	return new_clip


## Resync the instance on the engine after retargeting the clip.
func _resync_instance() -> void:
	if instance.track and instance.track.is_engine_connected():
		instance.track._clear_clip_instance_from_engine(instance)
		instance.track._sync_clip_instance_to_engine(instance)
