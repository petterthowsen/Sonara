## Where notes moved to another track end up (spec 048 REQ-040): the PLAN half of Transfer Notes
## and Split Voices. `plan` decides, from song-tick notes and a target track, which existing clip
## instance takes each note, how the instance has to grow, and which new clips are needed. It
## changes nothing; applying a plan (commands and one undo step) is a separate step.
##
## Project and Track are taken untyped on purpose: naming them would compile Project.gd (and its
## autoload references) with this script, which the headless tests load before autoloads exist.
class_name NoteTransfer extends RefCounted

## Larger than any song tick; small enough for the Vector2i windows used below.
const FAR := 1 << 30


## One plan entry per target clip, ordered by start:
##   instance      ClipInstance to put the notes into, or null when a new clip is needed
##   new_start     song tick the instance (or new clip) starts at, bar aligned
##   new_duration  its length in ticks, bar aligned
##   new_clip_offset  the instance's clip_offset after the change (0 for a new clip). Existing
##                 notes keep their song ticks because the content origin (start - offset) stays
##                 put, unless that would need a negative offset: see clip_shift
##   clip_shift    ticks the clip's EXISTING notes must move later when the instance grows to
##                 the left past the start of its content (0 otherwise). The offset is then 0
##   new_content_length  the clip's content length the extension needs (>= the current one)
##   extended      true when new_start/new_duration differ from the instance's
##   looped        the instance loops, so it is never extended
##   notes         the song-tick notes (the same objects `plan` was given), in start order
##   clip_ticks    PackedInt32Array parallel to `notes`: each note's start in the target clip's
##                 own ticks, after clip_shift and after folding into a loop
const KEYS := ["instance", "new_start", "new_duration", "new_clip_offset", "clip_shift",
		"new_content_length", "extended", "looped", "notes", "clip_ticks"]


## Plan the move of `song_notes` (MidiNoteData whose start_tick is a SONG tick) to `target`.
## Notes form runs: notes whose bar spans [bar start of the start, bar end of the end) touch or
## overlap. In each run:
##  1. Every target MIDI instance overlapping the run, earliest first, takes the run's notes that
##     START inside it (a looped instance folds them into its loop region).
##  2. Notes left over go to the earliest overlapping instance that is not looped and can grow
##     over them without running into another instance; it grows (start earlier and/or end
##     later, to whole bars). The next such instance takes whatever is still left.
##  3. What remains becomes new clips, one per group of touching/overlapping bar spans, spanning
##     those bars. A clip that doesn't overlap the run is never stretched towards it.
## An instance that takes covered notes also grows over the bars of any of them that stick out
## past its end (as far as the next instance allows).
static func plan(project, target, song_notes: Array) -> Array:
	var entries: Array = []
	if song_notes.is_empty():
		return entries
	var sorted := song_notes.duplicate()
	sorted.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.start_tick < b.start_tick)
	var instances: Array = []
	for inst in target.clip_instances:
		if inst != null and inst.clip != null and inst.clip.type == 1:  # Clip.ClipType.MIDI
			instances.append(inst)
	instances.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)

	for run: Array in _runs(project, sorted):
		var run_span := _span(project, run)
		var remaining: Array = run.duplicate()
		var taken := {}  # instance -> Array of notes
		var overlapping: Array = []
		for inst in instances:
			if inst.start_ticks < run_span.y and inst.get_end_ticks() > run_span.x:
				overlapping.append(inst)
		# 1. Covered notes.
		for inst in overlapping:
			var mine: Array = []
			var rest: Array = []
			for n: MidiNoteData in remaining:
				if n.start_tick >= inst.start_ticks and n.start_tick < inst.get_end_ticks():
					mine.append(n)
				else:
					rest.append(n)
			if not mine.is_empty():
				taken[inst] = mine
			remaining = rest
		# 2. Notes sticking out go to an instance that can grow over them.
		for inst in overlapping:
			if remaining.is_empty():
				break
			if inst.get_loop_state()[0]:
				continue
			var window := _growth_window(instances, inst)
			var mine: Array = taken.get(inst, [])
			var had := mine.size()
			var rest: Array = []
			for n: MidiNoteData in remaining:
				var bars := _span(project, [n])
				if bars.x >= window.x and bars.y <= window.y:
					mine.append(n)
				else:
					rest.append(n)
			if mine.size() > had:
				taken[inst] = mine
			remaining = rest
		for inst in overlapping:
			if taken.has(inst):
				entries.append(_entry_for_instance(project, instances, inst, taken[inst]))
		# 3. New clips for the rest.
		if not remaining.is_empty():
			for group: Array in _runs(project, remaining):
				entries.append(_entry_for_new_clip(project, group))
	entries.sort_custom(func(a: Dictionary, b: Dictionary): return a.new_start < b.new_start)
	return entries


## The clips of `target` the plan writes into that also appear on another instance (any track).
## Linked instances show the same notes (REQ-043), so the dialog warns about them.
static func linked_targets(project, planned: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in planned:
		var inst = entry.instance
		if inst == null or inst.clip == null or out.has(inst.clip):
			continue
		var count := 0
		for track in project.tracks:
			for other in track.clip_instances:
				if other != null and other.clip == inst.clip:
					count += 1
		if count > 1:
			out.append(inst.clip)
	return out


## Apply `plans` as the notes of one operation (Transfer Notes, Split Voices) and return the
## commands that undo/redo it as ONE step, ready for HistoryUtil.record_many (done here when
## `record` is true). `plans` is an Array of { "track": Track, "entries": plan() result }.
## `source_moves` is { Clip: [MidiNoteData] } of the original notes to take out of their clips.
## Every entry's notes are copied (new ids) into its instance's clip, or into a new clip and
## instance when `instance` is null. An extended instance grows through a
## ClipInstanceTransformCommand (position, duration, clip offset and content length), and its
## existing notes move later by `clip_shift` when it grew past the start of its content.
## Order of the result: create and transform commands, then one ClipNotesStateCommand per
## changed existing clip (new clips need none: the create command keeps their notes).
## The changes are made now; the commands only describe how to undo and redo them.
## Limitation: when `clip_shift` > 0 on a clip that other instances share, their notes shift too.
static func apply(project, source_moves: Dictionary, plans: Array, label: String, record: bool = true) -> Array[Command]:
	# Loaded at run time for the same reason Project is untyped: naming these classes would
	# compile them (and the autoloads they use) when this script loads in a headless test.
	var notes_state: GDScript = load("res://history/commands/ClipNotesStateCommand.gd")
	var create_script: GDScript = load("res://history/commands/ClipInstanceCreateCommand.gd")
	var transform_script: GDScript = load("res://history/commands/ClipInstanceTransformCommand.gd")
	var history: GDScript = load("res://history/HistoryUtil.gd")
	var touched: Array = source_moves.keys()
	for plan_item: Dictionary in plans:
		for entry: Dictionary in plan_item.entries:
			if entry.instance != null and entry.instance.clip != null and not touched.has(entry.instance.clip):
				touched.append(entry.instance.clip)
	var before = notes_state.capture_many(touched)

	for source_clip in source_moves.keys():
		for note_data: MidiNoteData in source_moves[source_clip]:
			source_clip.remove_midi_note(note_data)

	var structural: Array = []
	for plan_item: Dictionary in plans:
		var dest_track = plan_item.track
		for entry: Dictionary in plan_item.entries:
			var inst = entry.instance
			var dest_clip
			if inst == null:
				dest_clip = project.create_clip(project.unique_clip_name("Clip"))
				dest_clip.color = dest_track.get_color()
				dest_clip.content_length_ticks = entry.new_content_length
				var create = create_script.new(dest_track, dest_clip, entry.new_start, entry.new_duration, project, true)
				create.do()
				structural.append(create)
			else:
				dest_clip = inst.clip
				var content_before: int = dest_clip.content_length_ticks  # before the shift grows it
				if entry.clip_shift > 0:
					for existing: MidiNoteData in dest_clip.midi_notes:
						existing.start_tick += entry.clip_shift
						dest_clip.update_midi_note(existing)
				var changed: bool = entry.new_start != inst.start_ticks or entry.new_duration != inst.duration_ticks \
						or entry.new_clip_offset != inst.clip_offset or entry.new_content_length != content_before
				if changed:
					var transform = transform_script.new(label, inst,
							inst.start_ticks, inst.duration_ticks, inst.clip_offset,
							entry.new_start, entry.new_duration, entry.new_clip_offset,
							[], [], content_before, maxi(content_before, entry.new_content_length))
					transform.do()
					structural.append(transform)
			for i in entry.notes.size():
				var source_note: MidiNoteData = entry.notes[i]
				var copy := source_note.duplicate_note()
				copy.start_tick = entry.clip_ticks[i]
				dest_clip.cut_overlapping_notes_at_pitch(copy.note, copy.start_tick,
						copy.start_tick + copy.duration_ticks, dest_clip.allocate_note_id)
				copy.id = dest_clip.allocate_note_id()
				if dest_clip.add_midi_note_data(copy) == null:
					push_warning("[NoteTransfer] Note at pitch %d, tick %d was rejected by clip '%s'" % [copy.note, copy.start_tick, dest_clip.name])

	var cmds: Array[Command] = []
	cmds.append_array(structural)
	for changed_clip in before.keys():
		var after = notes_state.capture_clip_notes(changed_clip)
		if not notes_state.snapshots_equal(before[changed_clip], after):
			cmds.append(notes_state.new(label, changed_clip, before[changed_clip], after))
	if record:
		history.record_many(label, cmds)
	return cmds


# --- internals --------------------------------------------------------------------------------

static func _bar_start(project, tick: int) -> int:
	var map = project.time_signature_map
	var bar: int = map.bar_at_tick(tick, project.time_numerator, project.time_denominator, project.ppq)
	return map.tick_of_bar(bar, project.time_numerator, project.time_denominator, project.ppq)


static func _bar_end(project, tick: int) -> int:
	var start := _bar_start(project, tick)
	if start == tick:
		return tick
	var map = project.time_signature_map
	var bar: int = map.bar_at_tick(tick, project.time_numerator, project.time_denominator, project.ppq)
	return map.tick_of_bar(bar + 1, project.time_numerator, project.time_denominator, project.ppq)


## Bar-aligned span Vector2i(start, end) covering `notes` (song ticks).
static func _span(project, notes: Array) -> Vector2i:
	var lo := FAR
	var hi := 0
	for n: MidiNoteData in notes:
		lo = mini(lo, n.start_tick)
		hi = maxi(hi, n.start_tick + maxi(1, n.duration_ticks))
	return Vector2i(_bar_start(project, lo), _bar_end(project, hi))


## Split start-sorted notes into runs whose bar spans touch or overlap.
static func _runs(project, sorted: Array) -> Array:
	var runs: Array = []
	var current: Array = []
	var current_end := 0
	for n: MidiNoteData in sorted:
		var bars := _span(project, [n])
		if not current.is_empty() and bars.x > current_end:
			runs.append(current)
			current = []
		current.append(n)
		current_end = maxi(current_end, bars.y) if current.size() > 1 else bars.y
	if not current.is_empty():
		runs.append(current)
	return runs


## The song range an instance may grow into: from the end of the instance before it to the start
## of the one after it (0 and effectively infinite at the ends).
static func _growth_window(instances: Array, inst) -> Vector2i:
	var lo := 0
	var hi := FAR
	for other in instances:
		if other == inst:
			continue
		if other.get_end_ticks() <= inst.start_ticks:
			lo = maxi(lo, other.get_end_ticks())
		elif other.start_ticks >= inst.get_end_ticks():
			hi = mini(hi, other.start_ticks)
	return Vector2i(lo, hi)


static func _entry_for_instance(project, instances: Array, inst, notes: Array) -> Dictionary:
	notes = notes.duplicate()
	notes.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.start_tick < b.start_tick)
	var looped: bool = inst.get_loop_state()[0]
	var new_start: int = inst.start_ticks
	var new_end: int = inst.get_end_ticks()
	if not looped:
		var window := _growth_window(instances, inst)
		var bars := _span(project, notes)
		new_start = maxi(window.x, mini(new_start, bars.x))
		new_end = mini(window.y, maxi(new_end, bars.y))
	var clip_shift := 0
	var new_offset: int = inst.clip_offset
	if new_start != inst.start_ticks:
		new_offset = inst.clip_offset - (inst.start_ticks - new_start)
		if new_offset < 0:
			clip_shift = -new_offset
			new_offset = 0
	var clip_ticks := PackedInt32Array()
	for n: MidiNoteData in notes:
		var t: int = inst.song_to_clip_ticks(n.start_tick) + clip_shift
		if looped:
			t = inst.fold_into_loop(t)
		clip_ticks.append(t)
	var content_end := 0
	for i in notes.size():
		content_end = maxi(content_end, clip_ticks[i] + notes[i].duration_ticks)
	return {
		"instance": inst,
		"new_start": new_start,
		"new_duration": new_end - new_start,
		"new_clip_offset": new_offset,
		"clip_shift": clip_shift,
		"new_content_length": maxi(inst.content_end_ticks() + clip_shift, maxi(new_offset + new_end - new_start, content_end)),
		"extended": new_start != inst.start_ticks or new_end != inst.get_end_ticks(),
		"looped": looped,
		"notes": notes,
		"clip_ticks": clip_ticks,
	}


static func _entry_for_new_clip(project, notes: Array) -> Dictionary:
	notes = notes.duplicate()
	notes.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.start_tick < b.start_tick)
	var bars := _span(project, notes)
	var clip_ticks := PackedInt32Array()
	for n: MidiNoteData in notes:
		clip_ticks.append(n.start_tick - bars.x)
	return {
		"instance": null,
		"new_start": bars.x,
		"new_duration": bars.y - bars.x,
		"new_clip_offset": 0,
		"clip_shift": 0,
		"new_content_length": bars.y - bars.x,
		"extended": false,
		"looped": false,
		"notes": notes,
		"clip_ticks": clip_ticks,
	}
