# ScoreSection.gd
# Project layer of the section tools (spec 025). ScoreText knows bars and notes in section-local
# ticks; this knows tracks, clip placements and clips. It gathers a track's notes in a song span,
# renders them for read_section, and writes parsed section notes back as a diff against what is
# there: unchanged notes are never touched, structural commands (new clips, Make Unique) run as
# they are built, and the caller records the returned commands as one undo step.
class_name ScoreSection extends RefCounted


## Drum blocks use a 1/16 grid, like the clip text grid.
const DRUM_RES := 16
## Placements listed in a shared-clip refusal.
const MAX_LISTED := 4


# --- Bar plan ---------------------------------------------------------------------------------

## Bars `first_bar`..`last_bar` (1-based, inclusive) sized by the signature map.
## Returns {plan (see ScoreText.make_plan), start (song tick of the first bar), end}.
static func bar_plan(project: Project, first_bar: int, last_bar: int) -> Dictionary:
	var map := project.time_signature_map
	var num := project.time_numerator
	var den := project.time_denominator
	var ppq := project.ppq
	var meters: Array = []
	var start := 0
	for bar in range(first_bar, last_bar + 1):
		var seg: Dictionary = _segment_of_bar(map.segments(num, den, ppq), bar)
		meters.append([int(seg.numerator), int(seg.denominator)])
		if bar == first_bar:
			start = int(seg.tick) + (bar - int(seg.bar)) * int(seg.bar_ticks)
	var plan := ScoreText.make_plan(first_bar, meters, ppq)
	return {"plan": plan, "start": start, "end": start + ScoreText.plan_length(plan)}


static func _segment_of_bar(segs: Array, bar: int) -> Dictionary:
	var seg: Dictionary = segs[0]
	for s in segs:
		if int(s.bar) > bar:
			break
		seg = s
	return seg


## `"5-8"`, `"5"` or a number → {first, last}, else {}. A bare number is that one bar.
static func parse_bar_range(value: Variant) -> Dictionary:
	var text := str(int(value)) if (value is int or value is float) else str(value).strip_edges()
	var parts := text.split("-", false)
	if parts.is_empty() or parts.size() > 2:
		return {}
	for p in parts:
		if not p.strip_edges().is_valid_int():
			return {}
	var first := parts[0].strip_edges().to_int()
	var last := parts[parts.size() - 1].strip_edges().to_int()
	if first < 1 or last < first:
		return {}
	return {"first": first, "last": last}


## Empty when every bar of the plan has the same meter, else why a drum grid can't be used.
static func drum_meter_error(plan: Array) -> String:
	for i in range(1, plan.size()):
		var a: Dictionary = plan[i - 1]
		var b: Dictionary = plan[i]
		if int(a.numerator) != int(b.numerator) or int(a.denominator) != int(b.denominator):
			return "the meter changes from %d/%d to %d/%d at bar %d, and a drum grid has one meter: split the section at bar %d" % [
				int(a.numerator), int(a.denominator), int(b.numerator), int(b.denominator), int(b.bar), int(b.bar)]
	return ""


## `bar.beat.tick` of a song tick, counting bars through the signature map.
static func where(project: Project, tick: int) -> String:
	var map := project.time_signature_map
	var segs := map.segments(project.time_numerator, project.time_denominator, project.ppq)
	var seg: Dictionary = segs[map.segment_index_at_tick(tick, project.time_numerator, project.time_denominator, project.ppq)]
	var into := maxi(0, tick - int(seg.tick))
	var rem: int = into % int(seg.bar_ticks)
	return "%d.%d.%03d" % [int(seg.bar) + into / int(seg.bar_ticks), rem / int(seg.beat_ticks) + 1, rem % int(seg.beat_ticks)]


# --- Instrument -------------------------------------------------------------------------------

static func channel_of(project: Project, track: Track) -> Channel:
	var ch := track.get_linked_channel()
	if ch == null and track.default_channel_id >= 0:
		ch = project.get_channel_by_id(track.default_channel_id)
	return ch


## What the track's instrument says about keys: {ks_map (normalized name -> {key, name}),
## ks_keys (key -> name), ranges ([[lo, hi]...])}. Only an SFZ sampler reports either.
static func instrument_info(project: Project, track: Track) -> Dictionary:
	var info := {"ks_map": {}, "ks_keys": {}, "ranges": []}
	var source := NoteMapResolver.find_auto_source(channel_of(project, track))
	if source == null or not AuxReturnSync.is_sfz(source):
		return info
	info.ks_map = SfzKeyInfoUtil.keyswitch_map(source)
	for entry in info.ks_map.values():
		info.ks_keys[int(entry.key)] = str(entry.name)
	info.ranges = source.playable_ranges
	return info


static func is_drum_track(project: Project, track: Track) -> bool:
	return NoteMapResolver.wants_drum_view(channel_of(project, track)) or AiTool.track_prefers_drums(project, track)


## Length of a keyswitch note: a 1/64.
static func ks_length(ppq: int) -> int:
	return maxi(1, ppq / 16)


# --- Gathering --------------------------------------------------------------------------------

## A track's notes in song span [s, e) as section notes, from every placement overlapping it.
## Returns {notes, loops}. Each note is {pitch, start (section-local), length, velocity (1-127),
## vel_f (0-1), note_ref, clip, instance, ks}. A keyswitch note (its pitch is a key in `ks_keys`,
## key -> name) is {ks: true, name, at (section-local tick of the note it precedes), start, length}:
## it belongs to the section its note starts in, even when it begins just before the span.
## A note belongs to the section its onset *as read* (snapped, ScoreText.snap) falls in, so a downbeat
## played a few ticks early is in this section and a note a few ticks before the end is in the next;
## its `start` may then be slightly negative. Off-grid notes go by their exact onset.
## `loops` lists placements whose loop repeats content inside the span or replays content from it.
static func gather(project: Project, track: Track, s: int, e: int, ks_keys: Dictionary = {}) -> Dictionary:
	var out: Array = []
	var loops: Array[ClipInstance] = []
	var kl := ks_length(project.ppq)
	var total := e - s
	for inst in ClipRangeActions.overlapping(track, s - ScoreText.SNAP_TICKS, e):
		if inst.clip == null:
			continue
		if _loop_hazard(inst, s, e):
			loops.append(inst)
		var run := inst.first_run_range()
		var clip: Clip = inst.clip
		for note in clip.midi_notes:
			if note.start_tick < run.x or note.start_tick >= run.y:
				continue
			var song := inst.clip_to_song_ticks(note.start_tick)
			var pitch := clampi(note.note + inst.transpose, 0, 127)
			var item := {
				"pitch": pitch, "start": song - s, "length": note.duration_ticks,
				"velocity": MidiNoteData.to_midi_velocity(note.velocity), "vel_f": note.velocity,
				"note_ref": note, "clip": clip, "instance": inst, "ks": false,
			}
			if ks_keys.has(pitch):
				var anchor := song + kl if _has_note_at(clip, note.start_tick + kl, ks_keys, inst.transpose) else song
				if anchor < s or anchor >= e:
					continue
				item.ks = true
				item.name = ks_keys[pitch]
				item.at = anchor - s
			elif not _in_section(song - s, total, project.ppq):
				continue
			out.append(item)
	out.sort_custom(func(a, b):
		var ka: int = a.at if a.ks else a.start
		var kb: int = b.at if b.ks else b.start
		if ka != kb:
			return ka < kb
		return int(a.pitch) < int(b.pitch))
	return {"notes": out, "loops": loops}


## Whether a note at section-local `local` belongs to a section of `total` ticks (see gather).
static func _in_section(local: int, total: int, ppq: int) -> bool:
	if local < -ScoreText.SNAP_TICKS or local >= total + ScoreText.SNAP_TICKS:
		return false
	var snapped := ScoreText.snap(local, ppq)
	if snapped < 0:
		return local >= 0 and local < total
	return snapped >= 0 and snapped < total


## True when `clip` has a note that is not a keyswitch starting at clip tick `tick`.
static func _has_note_at(clip: Clip, tick: int, ks_keys: Dictionary, transpose: int) -> bool:
	for n in clip.midi_notes:
		if n.start_tick == tick and not ks_keys.has(clampi(n.note + transpose, 0, 127)):
			return true
	return false


## True when changing the content under [s, e) also changes what a loop plays elsewhere: the
## loop repeats inside the span, or a repeat replays content that lies in the span.
static func _loop_hazard(inst: ClipInstance, s: int, e: int) -> bool:
	if not (inst.loop_enabled and inst.loop_length_ticks > 0):
		return false
	var segs := inst.get_loop_segments(64)
	if segs.size() < 2:
		return false
	var run := inst.first_run_range()
	var c0 := maxi(run.x, inst.song_to_clip_ticks(s))
	var c1 := mini(run.y, inst.song_to_clip_ticks(e))
	for i in range(1, segs.size()):
		var seg: Vector3i = segs[i]
		if inst.start_ticks + seg.x < e and inst.start_ticks + seg.y > s:
			return true
		if seg.z < c1 and seg.z + (seg.y - seg.x) > c0:
			return true
	return false


# --- Shared clips -----------------------------------------------------------------------------

## Placements in the span whose clip is also placed somewhere else (any other placement, on any
## track, in or out of the span) or whose loop repeats it. Each is {instance, others, loops}.
static func shared_placements(project: Project, track: Track, s: int, e: int) -> Array:
	var out: Array = []
	for inst in ClipRangeActions.overlapping(track, s, e):
		if inst.clip == null:
			continue
		var others: Array = AiTool.find_clip_instances(project, inst.clip_id).filter(func(i): return i != inst)
		var looping := _loop_hazard(inst, s, e)
		if not others.is_empty() or looping:
			out.append({"instance": inst, "others": others, "loops": looping})
	return out


## The refusal text for `shared`, naming the other placements and both options.
static func shared_error(project: Project, track: Track, shared: Array, plan: Array) -> String:
	var parts := PackedStringArray()
	for entry in shared:
		var inst: ClipInstance = entry.instance
		var cname := inst.clip.name
		var named := PackedStringArray()
		for other in entry.others:
			if named.size() >= MAX_LISTED:
				named.append("%d more" % (entry.others.size() - MAX_LISTED))
				break
			var tname: String = other.track.name if other.track else "?"
			named.append("%s @ %s" % [tname, where(project, other.start_ticks)])
		if not named.is_empty():
			parts.append("clip \"%s\" is also placed at %s" % [cname, ", ".join(named)])
		if entry.loops:
			parts.append("the placement at %s loops \"%s\", so its repeats play whatever is written" % [where(project, inst.start_ticks), cname])
	var bars := "bar %d" % int(plan[0].bar) if plan.size() == 1 else "bars %d-%d" % [int(plan[0].bar), int(plan[plan.size() - 1].bar)]
	return "%s: %s. Writing %s would change those too. Pass shared_clips \"unique\" to give %s its own copy, or \"all\" to change every placement." % [
		track.name, "; ".join(parts), bars, bars]


# --- Reading ----------------------------------------------------------------------------------

## One track of a section as layout rows for ScoreText.layout.
## ctx: {ppq, key (parsed key Dictionary)}. Returns {has_notes, rows, reason}; `rows` are
## {label, bars} note lines (one per voice), {label, block} for a drum grid, {label, text} for
## an event listing or a comment. `reason` is non-empty when the track isn't shown as note lines.
static func read_track(project: Project, track: Track, s: int, e: int, plan: Array, ctx: Dictionary) -> Dictionary:
	var info := instrument_info(project, track)
	var g := gather(project, track, s, e, info.ks_keys)
	var notes: Array = []
	var switches: Array = []
	for x in g.notes:
		if x.ks:
			switches.append({"name": x.name, "at": x.at})
		else:
			notes.append({"pitch": x.pitch, "start": x.start, "length": x.length, "velocity": x.velocity})
	var out := {"has_notes": not g.notes.is_empty(), "rows": [], "reason": ""}
	var ppq := project.ppq
	var total := ScoreText.plan_length(plan)
	var plain: Array = g.notes.filter(func(x): return not x.ks)
	var reason := ""
	var comment := ""
	if is_drum_track(project, track):
		var meter_err := drum_meter_error(plan)
		if meter_err.is_empty():
			var scratch := _scratch_clip(project, plain, total, false)
			if ClipTextGrid.is_grid_eligible(scratch, ClipTextTime.ticks_per_step(ppq, DRUM_RES)):
				out.rows.append({"label": track.name, "block": ClipTextGrid.serialize(scratch, _grid_opts(project, track, plan))})
				return out
			reason = "off-grid timing"
		else:
			comment = "# %s: %s; shown as notes" % [track.name, meter_err]
	if reason.is_empty():
		var r := ScoreText.render_track(notes, switches, plan, ctx)
		if not r.off_grid:
			if not comment.is_empty():
				out.rows.append({"label": track.name, "text": comment})
			var voices: Array = r.voices
			for vi in voices.size():
				var label := track.name if voices.size() == 1 else "%s.%d" % [track.name, vi + 1]
				out.rows.append({"label": label, "bars": voices[vi]})
			return out
		reason = str(r.reason)
	# Off the grid: the event listing, positions counted from the section start.
	out.reason = reason
	var first: Dictionary = plan[0]
	var eo := {"ppq": ppq, "numerator": int(first.numerator), "denominator": int(first.denominator), "key": ctx.get("key", {})}
	var listing := ClipTextEvents.serialize(_scratch_clip(project, plain, total, true), eo)
	out.rows.append({"label": track.name, "text": "# %s: %s, shown as events (positions count from the section start: 1.1.000 is bar %d)\n%s" % [
		track.name, reason, int(first.bar), listing]})
	return out


## An unpooled clip holding `entries` (gathered notes) in section-local ticks. Ids are the real
## note ids when `real_ids`, else 1..n (so a map back to the entries is easy).
static func _scratch_clip(project: Project, entries: Array, total: int, real_ids: bool) -> Clip:
	var clip := project.create_clip("section")
	clip.content_length_ticks = total
	for i in entries.size():
		var x: Dictionary = entries[i]
		var n := MidiNoteData.new()
		n.id = x.note_ref.id if real_ids else i + 1
		n.note = x.pitch
		n.velocity = x.vel_f
		n.start_tick = maxi(0, int(x.start))
		n.duration_ticks = x.length
		clip.midi_notes.append(n)
	return clip


static func _grid_opts(project: Project, track: Track, plan: Array) -> Dictionary:
	var first: Dictionary = plan[0]
	return {
		"ppq": project.ppq, "numerator": int(first.numerator), "denominator": int(first.denominator),
		"res_denom": DRUM_RES, "bars": plan.size(), "drums": is_drum_track(project, track),
		"key": {}, "drum_names": AiTool.drum_names_for_track(project, track),
	}


# --- Writing ----------------------------------------------------------------------------------

## Write parsed score text for one track into song span [s, e).
## line: a ScoreText.parse line, {kind: "notes", notes, keyswitches} or {kind: "grid", text}.
## opts: {plan, shared ("", "unique" or "all"), marker_names? (unused)}.
## Returns {ok: true, cmds (already applied), added, changed, removed, warnings, created,
## copied} or {ok: false, error, cmds} (cmds applied before the failure: the caller undoes them).
static func write(project: Project, track: Track, s: int, e: int, line: Dictionary, opts: Dictionary) -> Dictionary:
	var plan: Array = opts.plan
	var ppq := project.ppq
	var total := ScoreText.plan_length(plan)
	var info := instrument_info(project, track)
	var cmds: Array[Command] = []
	var warnings := PackedStringArray()
	var created: Array = []
	var copied: Array = []

	# Shared clips: refuse, or copy first, or write through.
	var shared := shared_placements(project, track, s, e)
	if not shared.is_empty():
		var mode := str(opts.get("shared", ""))
		if mode.is_empty():
			return _fail(shared_error(project, track, shared, plan), cmds)
		for entry in shared:
			var inst: ClipInstance = entry.instance
			if mode == "unique" and AiTool.find_clip_instances(project, inst.clip_id).size() > 1:
				var from_name := inst.clip.name
				var cmd := MakeClipUniqueCommand.new(project, inst)
				cmd.do()
				cmds.append(cmd)
				copied.append({"from": from_name, "to": inst.clip.name, "at": where(project, inst.start_ticks)})
			if entry.loops:
				warnings.append("%s: the placement at %s loops, so its repeats play the written notes too" % [track.name, where(project, inst.start_ticks)])

	var g := gather(project, track, s, e, info.ks_keys)
	var plain_existing: Array = []
	var ks_existing: Array = []
	for x in g.notes:
		(ks_existing if x.ks else plain_existing).append(x)

	# Written notes.
	var written: Array = []
	var written_ks: Array = []
	if str(line.get("kind", "notes")) == "grid":
		var grid := _grid_notes(project, track, plain_existing, str(line.text), plan)
		if grid.has("error"):
			return _fail(str(grid.error), cmds)
		written = grid.notes
	else:
		for n in line.notes:
			written.append({"pitch": int(n.pitch), "start": int(n.start), "length": int(n.length),
					"velocity": int(n.velocity), "held": bool(n.get("held", false))})
		for k in line.keyswitches:
			if int(k.key) < 0:
				return _fail("%s: this track's instrument reports no keyswitches, so `ks:%s` can't be placed" % [track.name, k.name], cmds)
			written_ks.append({"pitch": int(k.key), "name": str(k.name), "at": int(k.at)})

	# Plain notes: diff by pitch, onset and length as the reader shows them.
	var diff := _diff(plain_existing, written, ppq, total)
	var placements := ClipRangeActions.overlapping(track, s, e)
	var kl := ks_length(ppq)

	# Keyswitches: exact (pitch, start, length). A keyswitch sits 1/64 before its note, ending at the
	# note's onset, or starts at the onset when the placement has no room before it.
	var ks_added: Array = []
	var ks_removed: Array = []
	var ks_used := {}
	var ks_index := {}
	for i in ks_existing.size():
		var x: Dictionary = ks_existing[i]
		ks_index["%d:%d:%d" % [x.pitch, x.start, x.length]] = i
	for k in written_ks:
		var host := _placement_at(placements, s + int(k.at))
		var start := _ks_start(int(k.at), kl, s, host)
		k["start"] = start
		var key := "%d:%d:%d" % [k.pitch, start, kl]
		if host != null and ks_index.has(key) and not ks_used.has(ks_index[key]):
			ks_used[ks_index[key]] = true
		else:
			ks_added.append(k)
	for i in ks_existing.size():
		if not ks_used.has(i):
			ks_removed.append(ks_existing[i])

	# Clips for added notes no placement covers.
	var adds: Array = []
	for w in diff.added:
		adds.append({"pitch": w.pitch, "start": w.start, "length": w.length, "vel_f": w.get("vel_f", MidiNoteData.from_midi_velocity(w.velocity)),
				"held": w.get("held", false), "ks": false, "onset": w.start})
	for k in ks_added:
		adds.append({"pitch": k.pitch, "start": k.start, "length": kl, "vel_f": MidiNoteData.DEFAULT_VELOCITY,
				"held": false, "ks": true, "name": k.name, "onset": k.at})
	var free := _free_intervals(placements, s, e)
	var needed := {}
	for a in adds:
		if _placement_at(placements, s + int(a.onset)) == null:
			var fi := _interval_at(free, s + int(a.onset))
			if fi >= 0:
				needed[fi] = true
	var fis: Array = needed.keys()
	fis.sort()
	for fi in fis:
		var iv: Vector2i = free[fi]
		var clip_name := _new_clip_name(project, track, iv.x, iv.y, plan, s)
		var clip := project.create_clip(clip_name)
		clip.color = track.get_color()
		clip.content_length_ticks = iv.y - iv.x
		var cmd := ClipInstanceCreateCommand.new(track, clip, iv.x, iv.y - iv.x, project, true)
		cmd.do()
		cmds.append(cmd)
		created.append({"name": clip_name, "from": iv.x, "to": iv.y})
	if not fis.is_empty():
		placements = ClipRangeActions.overlapping(track, s, e)

	# Route the adds to placements.
	var routed: Array = []
	for a in adds:
		var host := _placement_at(placements, s + int(a.onset))
		var start := _ks_start(int(a.onset), kl, s, host) if a.ks else int(a.start)
		var song := s + start
		var bar := int(plan[ScoreText.bar_index_at(plan, int(a.onset))].bar)
		var what := "keyswitch %s" % a.name if a.ks else Midi.midi_to_note_name(int(a.pitch))
		if host == null:
			warnings.append("%s bar %d: %s is not under any clip and was not written" % [track.name, bar, what])
			continue
		var run := host.first_run_range()
		if host.loop_enabled and host.loop_length_ticks > 0 and s + int(a.onset) - host.start_ticks >= run.y - run.x:
			warnings.append("%s bar %d: %s falls in a repeat of the looping clip at %s and was not written" % [track.name, bar, what, where(project, host.start_ticks)])
			continue
		var stored := int(a.pitch) - host.transpose
		if stored < 0 or stored > 127:
			warnings.append("%s bar %d: %s is out of range once the clip's transpose (%+d) is removed and was not written" % [track.name, bar, what, host.transpose])
			continue
		var length := int(a.length)
		var end := song + length
		if end > host.get_end_ticks():
			end = host.get_end_ticks()
			warnings.append("%s bar %d: %s runs past the end of its clip and was shortened" % [track.name, bar, what])
		if end <= song:
			warnings.append("%s bar %d: %s starts at the end of its clip and was not written" % [track.name, bar, what])
			continue
		routed.append({"bar": bar, "clip": host.clip, "pitch": stored, "tick": host.song_to_clip_ticks(song), "length": end - song, "vel_f": a.vel_f})

	# Removals (once per note), changes.
	var removals: Array = []
	var seen := {}
	for x in diff.removed + ks_removed:
		if not seen.has(x.note_ref):
			seen[x.note_ref] = true
			removals.append(x)
	var changes: Array = diff.changes
	warnings.append_array(_range_warnings(track.name, written, plan, info))
	if diff.off_grid > 0:
		warnings.append("%s: %d existing notes were off the 1/32 grid and were replaced" % [track.name, diff.off_grid])

	# Snapshot, mutate, record per clip.
	var touched: Array = []
	for x in removals:
		if not touched.has(x.clip):
			touched.append(x.clip)
	for c in changes:
		if not touched.has(c.entry.clip):
			touched.append(c.entry.clip)
	for r in routed:
		if not touched.has(r.clip):
			touched.append(r.clip)
	var before := ClipNotesStateCommand.capture_many(touched)
	for x in removals:
		x.clip.remove_midi_note(x.note_ref)
	for c in changes:
		var n: MidiNoteData = c.entry.note_ref
		if c.vel >= 0.0:
			n.velocity = c.vel
		if c.length > 0:
			n.duration_ticks = c.length
		if c.entry.clip.is_synced_to_engine():
			c.entry.clip.update_midi_note(n)
		else:
			c.entry.clip.extend_content_length(n.start_tick + n.duration_ticks)
	var added := 0
	routed.sort_custom(func(a, b): return int(a.tick) < int(b.tick))
	for r in routed:
		var clip: Clip = r.clip
		if clip.add_midi_note(clip.allocate_note_id(), int(r.pitch), float(r.vel_f), int(r.tick), int(r.length)) != null:
			added += 1
		else:
			warnings.append("%s bar %d: %s overlaps a note of the same pitch that stays, so it was not written" % [
				track.name, int(r.bar), Midi.midi_to_note_name(int(r.pitch))])
	for clip in touched:
		var after := ClipNotesStateCommand.capture_clip_notes(clip)
		if not ClipNotesStateCommand.snapshots_equal(before[clip], after):
			cmds.append(ClipNotesStateCommand.new("Write Section", clip, before[clip], after))
	return {
		"ok": true, "cmds": cmds, "added": added, "changed": changes.size(), "removed": removals.size(),
		"warnings": warnings, "created": created, "copied": copied,
	}


static func _fail(message: String, cmds: Array[Command]) -> Dictionary:
	return {"ok": false, "error": message, "cmds": cmds}


## Start (section-local) of the keyswitch for a note at `at`: 1/64 earlier when the placement has
## room before the note, else the onset itself.
static func _ks_start(at: int, ks_len: int, s: int, host: ClipInstance) -> int:
	if host != null and s + at - ks_len < host.start_ticks:
		return at
	return at - ks_len


static func _placement_at(placements: Array, song: int) -> ClipInstance:
	for p in placements:
		if song >= p.start_ticks and song < p.get_end_ticks():
			return p
	return null


## Stretches of [s, e) no placement covers.
static func _free_intervals(placements: Array, s: int, e: int) -> Array:
	var out: Array = []
	var cursor := s
	for p in placements:
		if p.start_ticks > cursor:
			out.append(Vector2i(cursor, mini(p.start_ticks, e)))
		cursor = maxi(cursor, p.get_end_ticks())
		if cursor >= e:
			break
	if cursor < e:
		out.append(Vector2i(cursor, e))
	return out


static func _interval_at(free: Array, song: int) -> int:
	for i in free.size():
		if song >= free[i].x and song < free[i].y:
			return i
	return -1


## `<Marker> <Track>` for the ruler marker over the run's start, else `<Track> <first>-<last>`.
static func _new_clip_name(project: Project, track: Track, from: int, to: int, plan: Array, s: int) -> String:
	for m in project.markers:
		var inside: bool = from >= m.start_ticks and (from < m.start_ticks + m.duration_ticks or from == m.start_ticks)
		if inside:
			return project.unique_clip_name("%s %s" % [m.name, track.name])
	var first := int(plan[ScoreText.bar_index_at(plan, from - s)].bar)
	var last := int(plan[ScoreText.bar_index_at(plan, to - 1 - s)].bar)
	# Always `N-M`, even for one bar: unique_clip_name would read a lone trailing number as a counter.
	return project.unique_clip_name("%s %d-%d" % [track.name, first, last])


## Match written notes to existing ones. A written note matches an existing note of the same
## pitch whose snapped (as read) onset and length equal it; a held one matches on pitch and onset.
## A written note with `src` (a drum grid result) is the existing note it was copied from.
## Returns {changes: [{entry, vel (-1 = keep), length (-1 = keep)}], removed, added, off_grid}.
static func _diff(existing: Array, written: Array, ppq: int, total: int) -> Dictionary:
	var used := {}
	var by_exact := {}
	var by_onset := {}
	var off_grid := 0
	for i in existing.size():
		var x: Dictionary = existing[i]
		x["_i"] = i
		var sn := ScoreText.snap_note(int(x.start), int(x.length), ppq, total)
		if sn.x < 0:
			off_grid += 1
			continue
		var k1 := "%d:%d:%d" % [x.pitch, sn.x, sn.y]
		var k2 := "%d:%d" % [x.pitch, sn.x]
		if not by_exact.has(k1):
			by_exact[k1] = []
		by_exact[k1].append(i)
		if not by_onset.has(k2):
			by_onset[k2] = []
		by_onset[k2].append(i)
	var changes: Array = []
	var added: Array = []
	for w in written:
		var hit := -1
		if w.has("src"):
			if w.src != null:
				hit = int(w.src._i)
		elif bool(w.get("held", false)):
			hit = _take(by_onset, "%d:%d" % [w.pitch, w.start], used)
		else:
			hit = _take(by_exact, "%d:%d:%d" % [w.pitch, w.start, w.length], used)
		if hit < 0:
			added.append(w)
			continue
		used[hit] = true
		var x: Dictionary = existing[hit]
		var vel := -1.0
		var length := -1
		if w.has("src"):
			if w.vel_f != x.vel_f:
				vel = w.vel_f
			if w.length != x.length:
				length = w.length
		else:
			if w.velocity != x.velocity:
				vel = MidiNoteData.from_midi_velocity(w.velocity)
			if not bool(w.get("held", false)) and int(x.start) + int(x.length) > total:
				length = w.length
		if vel >= 0.0 or length > 0:
			changes.append({"entry": x, "vel": vel, "length": length})
	var removed: Array = []
	for i in existing.size():
		if not used.has(i):
			removed.append(existing[i])
	return {"changes": changes, "removed": removed, "added": added, "off_grid": off_grid}


## First unused index under `key`, marked used; -1 if none.
static func _take(index: Dictionary, key: String, used: Dictionary) -> int:
	if not index.has(key):
		return -1
	for i in index[key]:
		if not used.has(i):
			used[i] = true
			return i
	return -1


## Apply a drum block to a scratch clip of the current notes. Returns {notes} (each with `src`,
## the entry it was copied from, or none for a new hit) or {error}.
static func _grid_notes(project: Project, track: Track, existing: Array, text: String, plan: Array) -> Dictionary:
	var ppq := project.ppq
	var total := ScoreText.plan_length(plan)
	var meter_err := drum_meter_error(plan)
	if not meter_err.is_empty():
		return {"error": "%s has a drum block but %s" % [track.name, meter_err]}
	var scratch := _scratch_clip(project, existing, total, false)
	var o := _grid_opts(project, track, plan)
	var parsed := ClipTextGrid.parse(text, o)
	if parsed.has("error"):
		return {"error": "%s: %s" % [track.name, parsed.error]}
	var step := ClipTextTime.ticks_per_step(ppq, DRUM_RES)
	if int(parsed.steps) * step > total:
		return {"error": "%s: the drum block has %d steps, but the section has %d" % [track.name, int(parsed.steps), total / step]}
	ClipTextGrid.apply(scratch, null, parsed, o)
	var out: Array = []
	for n in scratch.midi_notes:
		var w := {"pitch": n.note, "start": n.start_tick, "length": n.duration_ticks,
				"velocity": MidiNoteData.to_midi_velocity(n.velocity), "vel_f": n.velocity}
		if n.id >= 1 and n.id <= existing.size():
			w["src"] = existing[n.id - 1]
		out.append(w)
	return {"notes": out}


## One warning per pitch written outside every playable range of the instrument.
static func _range_warnings(label: String, written: Array, plan: Array, info: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var ranges: Array = info.ranges
	if ranges.is_empty():
		return out
	var bars_by_pitch := {}
	for w in written:
		var p: int = w.pitch
		var inside := false
		for r in ranges:
			if p >= r[0] and p <= r[1]:
				inside = true
				break
		if inside:
			continue
		var bar := int(plan[ScoreText.bar_index_at(plan, int(w.start))].bar)
		if not bars_by_pitch.has(p):
			bars_by_pitch[p] = []
		if not bars_by_pitch[p].has(bar):
			bars_by_pitch[p].append(bar)
	if bars_by_pitch.is_empty():
		return out
	var range_text := PackedStringArray()
	for r in ranges:
		range_text.append(Midi.midi_to_note_name(r[0]) if r[0] == r[1] else "%s-%s" % [Midi.midi_to_note_name(r[0]), Midi.midi_to_note_name(r[1])])
	for p in bars_by_pitch:
		var bars := PackedStringArray()
		for b in bars_by_pitch[p]:
			bars.append(str(b))
		var hint := ""
		if (info.ks_keys as Dictionary).has(p):
			hint = "; it is the %s keyswitch, so write ks:%s" % [info.ks_keys[p], info.ks_keys[p]]
		out.append("%s bar%s %s: %s is outside the playable keys (%s), so it is silent%s" % [
			label, "s" if bars.size() > 1 else "", ", ".join(bars), Midi.midi_to_note_name(p), ", ".join(range_text), hint])
	return out
