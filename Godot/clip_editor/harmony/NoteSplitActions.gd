## The Transfer Notes / Split Voices machinery shared by the Note Editor and the arranger's clip
## context menu: song-tick copies of notes, distributing voices over target tracks, and recording
## the whole move as one undo step. Works on NoteRefs, so it needs no editor.
class_name NoteSplitActions extends RefCounted


## Copies of `candidates`' notes with SONG-tick starts:
## { "moves": { Clip: [MidiNoteData originals] }, "notes": { original: song-tick copy } }.
static func song_copies(candidates: Array) -> Dictionary:
	var moves := {}
	var copies := {}
	for ref: NoteRef in candidates:
		var ci := ref.instance
		var c := ref.clip
		if ci == null or c == null or copies.has(ref.data):
			continue
		var copy := ref.data.duplicate_note()
		copy.start_tick = ci.clip_to_song_ticks(ref.data.start_tick)
		copies[ref.data] = copy
		if not moves.has(c):
			moves[c] = []
		moves[c].append(ref.data)
	return {"moves": moves, "notes": copies}


## Spread the voices of `pool` (NoteRefs) over `targets`: voice k (counted from the top, per
## clip) goes to the k-th target. Voices without a target, or whose target is the note's own
## track (`source`, or the ref's track when null), stay. One undo step recorded under `label`
## (with `selection_model`'s selection when given). Returns the number of notes moved.
static func split_refs(project: Project, pool: Array, targets: Array, source: Track, label: String,
		selection_model: NoteSelectionModel = null) -> int:
	var ref_of := {}
	var per_clip := {}
	for ref: NoteRef in pool:
		if ref.clip == null:
			continue
		ref_of[ref.data] = ref
		if not per_clip.has(ref.clip):
			var typed: Array[MidiNoteData] = []
			per_clip[ref.clip] = typed
		per_clip[ref.clip].append(ref.data)
	var leaving: Dictionary = {}  # Track -> Array[NoteRef]
	for c in per_clip.keys():
		var ranks := NoteVoices.ranks(per_clip[c])
		for nd: MidiNoteData in per_clip[c]:
			var voice: int = ranks[nd].x
			if voice > targets.size():
				continue
			var dest: Track = targets[voice - 1]
			var own: Track = source if source != null else ref_of[nd].track
			if dest == own:
				continue
			if not leaving.has(dest):
				var typed: Array[NoteRef] = []
				leaving[dest] = typed
			leaving[dest].append(ref_of[nd])
	if leaving.is_empty():
		return 0
	var moves := {}
	var per_target := {}
	for dest: Track in leaving.keys():
		var copies := song_copies(leaving[dest])
		for c in copies.moves.keys():
			if not moves.has(c):
				moves[c] = []
			moves[c].append_array(copies.moves[c])
		per_target[dest] = copies.notes.values()
	return run_transfer(project, label, moves, per_target, selection_model)


## Plan every target, apply it and record ONE undo step (that also restores the selection when
## `selection_model` is given). `per_target`: { Track: Array of song-tick notes }. Returns the
## number of notes moved.
static func run_transfer(project: Project, label: String, source_moves: Dictionary, per_target: Dictionary,
		selection_model: NoteSelectionModel = null) -> int:
	if project == null:
		return 0
	var plans: Array = []
	var count := 0
	for dest: Track in per_target.keys():
		var entries := NoteTransfer.plan(project, dest, per_target[dest])
		if entries.is_empty():
			continue
		plans.append({"track": dest, "entries": entries})
		count += per_target[dest].size()
	if plans.is_empty():
		return 0
	var selection_before := selection_model.capture() if selection_model else {}
	var cmds := NoteTransfer.apply(project, source_moves, plans, label, false)
	var all: Array[Command] = []
	var last: Array[Command] = []
	if selection_model:
		var selection_after := selection_model.capture()
		if not NoteSelectionModel.same_state(selection_before, selection_after):
			all.append(SelectionStateCommand.new(label, selection_model, selection_before, selection_after, true))
			last.append(SelectionStateCommand.new(label, selection_model, selection_before, selection_after, false))
	all.append_array(cmds)
	all.append_array(last)
	HistoryUtil.record_many(label, all)
	return count


## Split Voices for whole MIDI clips (the arranger): every note of the clips of `instances`
## (a shared clip once) is a candidate. Each instance's own track is the source.
static func split_instances(project: Project, instances: Array, targets: Array, label: String = "Split Voices") -> int:
	var pool: Array = []
	var seen := {}
	for inst: ClipInstance in instances:
		if inst == null or inst.clip == null or inst.track == null \
				or inst.clip.type != Clip.ClipType.MIDI or seen.has(inst.clip):
			continue
		seen[inst.clip] = true
		for nd: MidiNoteData in inst.clip.midi_notes:
			pool.append(NoteRef.new(inst, nd, 0))
	return split_refs(project, pool, targets, null, label)
