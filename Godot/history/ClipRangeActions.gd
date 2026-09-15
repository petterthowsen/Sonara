# ClipRangeActions.gd
# Undoable time-range edits on clip instances: clear, move and copy [start, end) on a set of tracks.
# Instances crossing a range edge are split there, so only the part inside the range is affected.
# Commands are applied as they are built (later steps see the earlier result) and recorded as one step.
class_name ClipRangeActions extends RefCounted


## Instances on `track` overlapping [start, end), by start. `clip_id` limits them to one clip.
static func overlapping(track: Track, start: int, end: int, clip_id: String = "") -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	if track == null:
		return out
	for inst in track.clip_instances:
		if inst == null:
			continue
		if not clip_id.is_empty() and inst.clip_id != clip_id:
			continue
		if inst.start_ticks < end and start < inst.get_end_ticks():
			out.append(inst)
	out.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	return out


## An unplaced copy of the [from, to) part of `inst` (timeline ticks): same clip and overrides,
## clip offset shifted to the cut, fades dropped on cut edges.
static func piece(inst: ClipInstance, from: int, to: int) -> ClipInstance:
	var p := ClipInstance.new("", inst.clip_id)
	p.clip = inst.clip
	p.copy_overrides_from(inst)
	p.start_ticks = from
	p.duration_ticks = to - from
	p.clip_offset = inst.clip_offset + (from - inst.start_ticks)
	if from > inst.start_ticks:
		p.fade_in_ticks = 0
	if to < inst.get_end_ticks():
		p.fade_out_ticks = 0
	return p


## Remove [start, end) from `track`: delete instances inside, trim ones crossing an edge, split one
## spanning the whole range. Applies the commands and returns them (not recorded).
static func clear(track: Track, start: int, end: int, clip_id: String = "") -> Array[Command]:
	var cmds: Array[Command] = []
	if track == null or end <= start:
		return cmds
	for inst in overlapping(track, start, end, clip_id):
		var s := inst.start_ticks
		var e := inst.get_end_ticks()
		if s >= start and e <= end:
			_apply(cmds, ClipInstanceDeleteCommand.new(track, inst))
			continue
		if e > end:
			var tail := piece(inst, end, e)
			_apply(cmds, ClipInstanceCreateCommand.new(track, inst.clip, tail.start_ticks, tail.duration_ticks, null, false, tail))
		if s < start:
			_apply(cmds, ClipInstanceTransformCommand.new(
				"Trim Clip", inst,
				s, inst.duration_ticks, inst.clip_offset,
				s, start - s, inst.clip_offset
			))
		else:
			_apply(cmds, ClipInstanceDeleteCommand.new(track, inst))
	return cmds


## Clear [start, end) on every track as one "Delete Clips" step. Returns how many instances were touched.
static func delete_range(tracks: Array[Track], start: int, end: int, clip_id: String = "") -> int:
	var touched := 0
	var cmds: Array[Command] = []
	for track in tracks:
		touched += overlapping(track, start, end, clip_id).size()
		cmds.append_array(clear(track, start, end, clip_id))
	HistoryUtil.record_many("Delete Clips", cmds)
	return touched


## Move (or copy) the parts of clips inside [start, end) on `tracks` so the range starts at `to`.
## Without `overwrite`, refuses when a piece would land on a clip that stays; with it, clears the
## span under each piece first. One undo step.
## Returns `{pieces: Array[ClipInstance]}` or `{error: String, conflicts: Array[ClipInstance]}`.
static func move_range(
	tracks: Array[Track],
	start: int,
	end: int,
	to: int,
	copy: bool = false,
	overwrite: bool = false,
	clip_id: String = ""
) -> Dictionary:
	var delta := to - start
	var pieces: Array[ClipInstance] = []
	var piece_tracks: Array[Track] = []
	for track in tracks:
		for inst in overlapping(track, start, end, clip_id):
			var p := piece(inst, maxi(start, inst.start_ticks), mini(end, inst.get_end_ticks()))
			p.start_ticks += delta
			pieces.append(p)
			piece_tracks.append(track)
	if pieces.is_empty():
		return {"error": "no clips in range", "conflicts": []}
	var cmds: Array[Command] = []
	if not copy:
		for track in tracks:
			cmds.append_array(clear(track, start, end, clip_id))
	var conflicts: Array[ClipInstance] = []
	for i in pieces.size():
		var p := pieces[i]
		var track := piece_tracks[i]
		if overwrite:
			cmds.append_array(clear(track, p.start_ticks, p.get_end_ticks()))
			continue
		for other in overlapping(track, p.start_ticks, p.get_end_ticks()):
			if not conflicts.has(other):
				conflicts.append(other)
	if not conflicts.is_empty():
		for i in range(cmds.size() - 1, -1, -1):
			cmds[i].undo()
		return {"error": "destination is occupied", "conflicts": conflicts}
	for i in pieces.size():
		var p := pieces[i]
		_apply(cmds, ClipInstanceCreateCommand.new(piece_tracks[i], p.clip, p.start_ticks, p.duration_ticks, null, false, p))
	HistoryUtil.record_many("Copy Clips" if copy else "Move Clips", cmds)
	return {"pieces": pieces}


static func _apply(cmds: Array[Command], cmd: Command) -> void:
	cmd.do()
	cmds.append(cmd)
