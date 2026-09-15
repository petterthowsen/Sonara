# AiTool.gd
# Abstract tool: JSON Schema + execute. Never throws to the model.
class_name AiTool extends RefCounted


## OpenRouter function name (snake_case, stable).
func get_name() -> String:
	return ""


## One-line description for the model.
func get_description() -> String:
	return ""


## JSON Schema object (`type`, `properties`, `required`).
func get_parameters() -> Dictionary:
	return {"type": "object", "properties": {}}


## Run the tool. Returns `{ok:true, data:{}}` or `{ok:false, error:"..."}`.
func execute(_args: Dictionary) -> Dictionary:
	return fail("Not implemented")


## OpenRouter `tools[]` item.
func to_openrouter() -> Dictionary:
	return {
		"type": "function",
		"function": {
			"name": get_name(),
			"description": get_description(),
			"parameters": get_parameters(),
		},
	}


## Success payload.
static func ok(data: Dictionary = {}) -> Dictionary:
	return {"ok": true, "data": data}


## Failure payload (never throws).
static func fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Success payload with plain-text model content. `data` is optional structured
## output for tests and the UI; it is never sent to the model when `text` is present.
static func ok_text(text: String, data: Dictionary = {}) -> Dictionary:
	return {"ok": true, "text": text, "data": data}


## Model-facing content for a tool result: text if present, else JSON. Never throws.
static func to_model_content(result: Dictionary) -> String:
	if not result.get("ok", false):
		return "Error: %s" % str(result.get("error", "Unknown error"))
	if result.has("text"):
		return str(result.text)
	return JSON.stringify(result)


## Open project, or a fail dict if none.
static func require_project() -> Variant:
	if Sonara and Sonara.editor and Sonara.editor.project:
		return Sonara.editor.project
	return fail("No project open")


## Legacy argument name -> replacement hint. Tools used to take numeric ids; old saved
## conversations (and a resumed chat) may still call with these. Keep this mapping for one
## release after the names migration ships, then delete it along with this comment.
const _LEGACY_ARG_HINTS := {
	"track_id": "track",
	"channel_id": "channel",
	"output_channel_id": "output",
	"target_channel_id": "target",
	"instance_id": "path",
	"parent_instance_id": "parent",
	"clip_id": "clip",
}


## Fail with a "the replacement is X" hint if `args` uses a removed id argument. Empty
## dict when nothing legacy is present. Call this first thing in every tool's `execute()`.
static func check_legacy_args(args: Dictionary) -> Dictionary:
	for key in _LEGACY_ARG_HINTS:
		if args.has(key):
			return fail("%s is gone; pass %s: \"<name>\"" % [key, _LEGACY_ARG_HINTS[key]])
	return {}


## Up to 5 existing track/channel names that contain `query` (substring under `NameStyle.key`).
static func _near_matches(project: Project, query: String) -> PackedStringArray:
	var q := NameStyle.key(query)
	var out: PackedStringArray = []
	if q.is_empty():
		return out
	var seen: Dictionary = {}
	for t in project.tracks:
		if out.size() >= 5:
			break
		if NameStyle.key(t.name).contains(q) and not seen.has(NameStyle.key(t.name)):
			seen[NameStyle.key(t.name)] = true
			out.append(t.name)
	for c in project.channels:
		if out.size() >= 5:
			break
		if NameStyle.key(c.name).contains(q) and not seen.has(NameStyle.key(c.name)):
			seen[NameStyle.key(c.name)] = true
			out.append(c.name)
	return out


## "No track named 'X'." with up to 5 "did you mean" suggestions, same format as the
## fuzzy asset/device lookup.
static func _not_found(project: Project, noun: String, name: String) -> Dictionary:
	var matches := _near_matches(project, name)
	if matches.is_empty():
		return fail("No %s named '%s'" % [noun, name])
	return fail("No %s named '%s'. Did you mean: %s?" % [noun, name, ", ".join(matches)])


## Resolve a track by unique name (`key`, default `track`). A name that belongs only to a
## bus fails with a hint that it is a bus, not a track.
static func resolve_track(project: Project, args: Dictionary, key: String = "track") -> Variant:
	var name := str(args.get(key, "")).strip_edges()
	if name.is_empty():
		return fail("%s is required" % key)
	var found: Dictionary = project.find_by_name(name)
	var track: Track = found.get("track")
	if track:
		return track
	if found.get("channel"):
		return fail("\"%s\" is a bus, not a track" % name)
	return _not_found(project, "track", name)


## Resolve a channel by unique name (`key`, default `channel`). A folder without a mixer
## channel fails with a hint.
static func resolve_channel(project: Project, args: Dictionary, key: String = "channel") -> Variant:
	var name := str(args.get(key, "")).strip_edges()
	if name.is_empty():
		return fail("%s is required" % key)
	var found: Dictionary = project.find_by_name(name)
	var channel: Channel = found.get("channel")
	if channel:
		return channel
	if found.get("track"):
		return fail("\"%s\" is a folder with no mixer channel" % name)
	return _not_found(project, "channel", name)


## Resolve a route target name to a channel id, or fail(...) with near matches.
## "Master" -> 1, "None" -> 0, "Hardware Out" -> 1000, "Hardware Out N" -> 1000 + N,
## anything else is a channel name.
static func resolve_route_target(project: Project, value: String) -> Variant:
	var v := value.strip_edges()
	var key := NameStyle.key(v)
	if key == "master":
		return 1
	if key == "none":
		return 0
	if key == "hardware out":
		return 1000
	if key.begins_with("hardware out "):
		var n_str := key.substr("hardware out ".length()).strip_edges()
		if n_str.is_valid_int():
			return 1000 + n_str.to_int()
	var channel = resolve_channel(project, {"channel": v})
	if channel is Dictionary:
		return channel
	return channel.id


## Compact track row for tool results. `channel` is included only when the linked channel's
## name differs from the track's own name.
static func compact_track(t: Track) -> Dictionary:
	var row := {
		"name": t.name,
		"type": track_kind(t),
		"clip_count": t.clip_instances.size(),
		"color": "#%s" % t.get_color().to_html(false),
	}
	var ch := t.get_linked_channel()
	if ch and not DeviceNaming.names_equal(ch.name, t.name):
		row["channel"] = ch.name
	return row


## Compact mixer row for tool results.
static func compact_channel(project: Project, c: Channel) -> Dictionary:
	var sends: Array = []
	for s in c.send_channels:
		if s is SendConfig:
			sends.append({
				"target": describe_route_target(project, s.target_channel_id),
				"amount_db": s.amount,
				"pre_fader": s.pre_fader,
			})
	var device_names: PackedStringArray = []
	for d in c.devices:
		if d is DeviceInstance and d.device:
			device_names.append(d.get_display_name())
	return {
		"name": c.name,
		"type": channel_kind(c),
		"volume_db": c.volume,
		"pan": c.pan,
		"mute": c.mute,
		"solo": c.solo,
		"output": describe_route_target(project, c.output_channel_id),
		"sends": sends,
		"devices": device_names,
	}


## Compact type string for tools and prompts: group, folder_bus, folder, audio, or instrument.
static func track_kind(t: Track) -> String:
	if t.is_group():
		return "group"
	if t.is_folder_bus():
		return "folder_bus"
	match t.type:
		Track.TrackType.AUDIO:
			return "audio"
		Track.TrackType.FOLDER:
			return "folder"
		_:
			return "instrument"


## Compact mixer type string for tools and prompts: master, group, bus, audio, or instrument.
static func channel_kind(c: Channel) -> String:
	if c.is_master:
		return "master"
	match c.channel_type:
		Channel.ChannelType.AUDIO:
			return "audio"
		Channel.ChannelType.BUS:
			return "bus"
		Channel.ChannelType.GROUP:
			return "group"
		_:
			return "instrument"


## A name argument in the project's naming convention (`bass_line` -> `Bass Line`, see NameStyle).
static func name_arg(args: Dictionary, key: String, default: String = "") -> String:
	return NameStyle.format(str(args.get(key, default)))


## Resolve a clip by unique `clip` name (clip names are unique across the project).
static func resolve_clip(project: Project, args: Dictionary) -> Variant:
	var name := str(args.get("clip", args.get("name", ""))).strip_edges()
	if name.is_empty():
		return fail("clip is required")
	var hits: Array = []
	for clip in project.clips.values():
		if clip is Clip and NameStyle.same(clip.name, name):
			hits.append(clip)
	if hits.size() == 1:
		return hits[0]
	if hits.is_empty():
		var q := NameStyle.key(name)
		var matches: PackedStringArray = []
		for clip in project.clips.values():
			if matches.size() >= 5:
				break
			if clip is Clip and NameStyle.key(clip.name).contains(q):
				matches.append(clip.name)
		if matches.is_empty():
			return fail("No clip named '%s'" % name)
		return fail("No clip named '%s'. Did you mean: %s?" % [name, ", ".join(matches)])
	return fail("Multiple clips named '%s'" % name)


## Every instance of a clip, in track order.
static func find_clip_instances(project: Project, clip_id: String) -> Array:
	var out: Array = []
	for t in project.tracks:
		for inst in t.clip_instances:
			if inst and inst.clip_id == clip_id:
				out.append(inst)
	return out


## Compact clip + placements. Name is the handle; instances are copies of the same clip.
static func compact_clip(project: Project, clip: Clip) -> Dictionary:
	var placements: Array = []
	for inst in find_clip_instances(project, clip.id):
		placements.append(compact_instance(project, inst))
	return {
		"name": clip.name,
		"type": "audio" if clip.type == Clip.ClipType.AUDIO else "midi",
		"note_count": clip.midi_notes.size(),
		"length_ticks": clip.content_length_ticks,
		"instance_count": placements.size(),
		"placements": placements,
	}


## One timeline placement of a clip.
static func compact_instance(project: Project, inst: ClipInstance) -> Dictionary:
	var track_name := inst.track.name if inst.track else ""
	return {
		"track": track_name,
		"start": ClipTextTime.format_bbt(inst.start_ticks, project.ppq, project.time_numerator, project.time_denominator),
		"start_ticks": inst.start_ticks,
		"duration_ticks": inst.duration_ticks,
	}


## Parse `start` as bar.beat.tick, a bar number, or ticks. Defaults to the playhead.
static func resolve_start_ticks(project: Project, args: Dictionary, key: String = "start") -> int:
	if not args.has(key):
		if Sonara and Sonara.editor:
			return Sonara.editor.playhead_ticks
		return 0
	var v = args[key]
	if v is float or v is int:
		var n := int(v)
		if n >= 1 and n <= 512:
			return ClipTextTime.bbt_to_ticks(n, 1, 0, project.ppq, project.time_numerator, project.time_denominator)
		return maxi(0, n)
	var s := str(v).strip_edges()
	if s.is_valid_int():
		var n2 := s.to_int()
		if n2 >= 1 and n2 <= 512:
			return ClipTextTime.bbt_to_ticks(n2, 1, 0, project.ppq, project.time_numerator, project.time_denominator)
		return maxi(0, n2)
	var ticks := ClipTextTime.parse_bbt(s, project.ppq, project.time_numerator, project.time_denominator)
	return ticks if ticks >= 0 else 0


## `start`/`end` (end exclusive) or `start` + `bars`, falling back to the selected range.
## With `allow_all`, no span at all means the whole timeline (for clip-filtered edits).
## Returns `{start: int, end: int, all: bool}`, or fail(...) — check `.has("error")`.
static func resolve_time_span(project: Project, args: Dictionary, allow_all: bool = false) -> Dictionary:
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var time_range: Dictionary = Sonara.editor.get_time_range() if Sonara and Sonara.editor else {}
	var start: int
	if args.has("start"):
		start = resolve_start_ticks(project, args)
	elif time_range.get("has", false) and time_range.get("has_end", false):
		start = int(time_range.start)
	elif allow_all and not args.has("end") and not args.has("bars"):
		return {"start": 0, "end": 1 << 60, "all": true}
	else:
		return fail("start and end are required (no range is selected)")
	var end: int
	if args.has("end"):
		end = resolve_start_ticks(project, args, "end")
	elif args.has("bars"):
		end = start + int(round(float(args.bars) * tpb))
	elif not args.has("start"):
		end = int(time_range.end)
	else:
		return fail("end or bars is required")
	if end <= start:
		return fail("end must be after start")
	return {"start": start, "end": end, "all": false}


## Tracks named in `tracks` (array or comma-separated string), or every clip-holding track when absent.
## Returns Array[Track], or fail(...).
static func resolve_track_filter(project: Project, args: Dictionary) -> Variant:
	var out: Array[Track] = []
	var raw = args.get("tracks", [])
	var names: Array = []
	if raw is Array:
		names = raw
	elif raw is String:
		names = Array(raw.split(",", false))
	if names.is_empty():
		for t in project.tracks:
			if t.has_clips():
				out.append(t)
		return out
	for n in names:
		var t = resolve_track(project, {"track": str(n)})
		if t is Dictionary:
			return t
		if not t.has_clips():
			return fail("\"%s\" is a folder and holds no clips" % t.name)
		if not out.has(t):
			out.append(t)
	return out


## `"Kick" on Drums 1.1.000–3.1.000`
static func describe_instance(project: Project, inst: ClipInstance) -> String:
	var fmt := func(t: int) -> String:
		return ClipTextTime.format_bbt(t, project.ppq, project.time_numerator, project.time_denominator)
	var cname: String = inst.clip.name if inst.clip else inst.clip_id
	var tname: String = inst.track.name if inst.track else "?"
	return "\"%s\" on %s %s–%s" % [cname, tname, fmt.call(inst.start_ticks), fmt.call(inst.get_end_ticks())]


## Resolve where a new clip instance goes, and refuse if it would overlap.
## With `overwrite: true` in args the overlap check is skipped; the caller clears the span.
## `length` is the requested length in ticks, or -1 to let the range decide (create_clip only).
## Returns `{start: int, length: int, reason: String}`, or fail(...) — check `.has("error")`.
static func resolve_placement(project: Project, track: Track, args: Dictionary, length: int) -> Dictionary:
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var start: int
	var reason: String
	var out_length := length
	if args.has("start"):
		start = resolve_start_ticks(project, args)
		reason = "at %s" % ClipTextTime.format_bbt(start, project.ppq, project.time_numerator, project.time_denominator)
	else:
		var time_range: Dictionary = Sonara.editor.get_time_range() if Sonara and Sonara.editor else {"has": false, "start": 0, "has_end": false, "end": 0}
		if time_range.get("has", false):
			start = int(time_range.start)
			if out_length == -1 and time_range.get("has_end", false) and int(time_range.end) > start:
				out_length = int(time_range.end) - start
			reason = "at range start %s" % ClipTextTime.format_bbt(start, project.ppq, project.time_numerator, project.time_denominator)
		elif track.clip_instances.is_empty():
			start = 0
			reason = "at 1.1.000 (empty track)"
		else:
			var playhead := Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
			start = int(floor(float(playhead) / tpb)) * tpb
			reason = "at playhead bar %d" % (start / tpb + 1)
	if out_length == -1:
		var bars := maxi(1, int(args.get("bars", 1)))
		out_length = bars * tpb
	if not bool(args.get("overwrite", false)) and track.has_clip_overlap(start, out_length):
		return _placement_overlap_error(project, track, start, out_length, tpb)
	return {"start": start, "length": out_length, "reason": reason}


## `Error: Bars 1–3 on "Drums" are occupied by "X" (1.1.000–3.1.000). Next free bar: 3.`
static func _placement_overlap_error(project: Project, track: Track, start: int, length: int, tpb: int) -> Dictionary:
	var end := start + length
	var overlapping: Array = []
	for inst in track.clip_instances:
		if inst == null:
			continue
		if start < inst.start_ticks + inst.duration_ticks and inst.start_ticks < end:
			overlapping.append(inst)
	overlapping.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	var bar_start := int(start / tpb) + 1
	var bar_end := int(floor(float(end - 1) / tpb)) + 1
	var names: PackedStringArray = []
	var last_end := 0
	for inst in overlapping:
		last_end = maxi(last_end, inst.start_ticks + inst.duration_ticks)
		if names.size() < 3:
			var cname: String = inst.clip.name if inst.clip else inst.clip_id
			names.append("\"%s\" (%s–%s)" % [
				cname,
				ClipTextTime.format_bbt(inst.start_ticks, project.ppq, project.time_numerator, project.time_denominator),
				ClipTextTime.format_bbt(inst.start_ticks + inst.duration_ticks, project.ppq, project.time_numerator, project.time_denominator),
			])
	var candidate_bar := int(ceil(float(last_end) / tpb))
	while track.has_clip_overlap(candidate_bar * tpb, length):
		candidate_bar += 1
	var bars_text := "Bar %d" % bar_start if bar_start == bar_end else "Bars %d–%d" % [bar_start, bar_end]
	return fail("%s on \"%s\" are occupied by %s. Next free bar: %d, or pass overwrite: true." % [bars_text, track.name, ", ".join(names), candidate_bar + 1])


## Shared serialize/apply options from a project + optional tool args.
static func clip_text_opts(project: Project, args: Dictionary = {}, track: Track = null) -> Dictionary:
	var o := {
		"ppq": project.ppq,
		"numerator": project.time_numerator,
		"denominator": project.time_denominator,
		"tempo": project.tempo,
	}
	var key := str(args.get("key", "")).strip_edges()
	if not key.is_empty():
		o["key"] = key
	var res := str(args.get("res", "")).strip_edges()
	if not res.is_empty():
		o["res"] = res
	var kind := str(args.get("format", args.get("kind", ""))).strip_edges().to_lower()
	if not kind.is_empty() and kind != "auto":
		o["kind"] = kind
	if track:
		o["prefer_drums"] = track_prefers_drums(project, track)
		o["drum_names"] = drum_names_for_track(project, track)
	return o


## True when the track looks percussive (drum machine or name).
static func track_prefers_drums(project: Project, track: Track) -> bool:
	if track == null:
		return false
	var n := track.name.to_lower()
	if n.contains("drum") or n.contains("kit") or n.contains("perc"):
		return true
	if project == null:
		return false
	var ch := track.get_linked_channel()
	if ch == null and track.default_channel_id >= 0:
		ch = project.get_channel_by_id(track.default_channel_id)
	if ch == null:
		return false
	for d in ch.devices:
		if d and d.device and d.device.device_id == "sonara.builtin.drum_machine":
			return true
	return false


## Drum machine pad names for a track, if any.
static func drum_names_for_track(project: Project, track: Track) -> Dictionary:
	var names := {}
	if project == null or track == null:
		return names
	var ch := track.get_linked_channel()
	if ch == null and track.default_channel_id >= 0:
		ch = project.get_channel_by_id(track.default_channel_id)
	if ch == null:
		return names
	for d in ch.devices:
		if d == null or d.device == null:
			continue
		if d.device.device_id != "sonara.builtin.drum_machine":
			continue
		var used: Dictionary = {}
		for child in d.children:
			if child == null or child.slot_note < 0:
				continue
			var label := child.get_display_name() if child else ""
			if _generic_drum_label(label) or used.has(label.to_upper()):
				label = ClipTextKey.drum_label(child.slot_note)
			if used.has(label.to_upper()):
				label = "%s %s" % [label, ClipTextKey.pitch_name(child.slot_note)]
			used[label.to_upper()] = true
			names[child.slot_note] = label
	return names


static func _generic_drum_label(label: String) -> bool:
	var s := label.strip_edges().to_lower()
	return s.is_empty() or s in ["sampler", "sfz", "audio", "device", "plugin"]


## Resolve a device by `path` (`Channel/Device/Child`), optionally scoped by `channel` name
## when the path is relative (doesn't start with a channel name).
static func resolve_device(project: Project, args: Dictionary) -> Variant:
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return fail("path is required")
	var segs := DeviceNaming.split_path(path)
	if segs.is_empty():
		return fail("path is required")
	var channel: Channel = null
	var rest: PackedStringArray = segs
	if args.has("channel"):
		var ch_v = resolve_channel(project, args)
		if ch_v is Dictionary:
			return ch_v
		channel = ch_v
		if DeviceNaming.names_equal(segs[0], channel.name):
			rest = DeviceNaming.skip_first(segs)
	else:
		var hits: Array = []
		for c in project.channels:
			if DeviceNaming.names_equal(c.name, segs[0]):
				hits.append(c)
		if hits.is_empty():
			return _not_found(project, "channel", segs[0])
		if hits.size() > 1:
			return fail("Multiple channels named '%s'" % segs[0])
		channel = hits[0]
		rest = DeviceNaming.skip_first(segs)
	var walked = DeviceNaming.walk_named(channel.devices, rest)
	if walked is Dictionary:
		return fail(str(walked.get("error", "Device not found")))
	return walked


## Container parent from a `parent` path; null means channel root.
static func resolve_optional_parent(project: Project, args: Dictionary) -> Variant:
	var parent_path := str(args.get("parent", "")).strip_edges()
	if parent_path.is_empty():
		return null
	var nested := {"path": parent_path}
	if args.has("channel"):
		nested["channel"] = args.channel
	var parent_v = resolve_device(project, nested)
	if parent_v is Dictionary:
		return parent_v
	var parent: DeviceInstance = parent_v
	if not parent.is_container():
		return fail("Parent is not a container device")
	return parent


## Compact device row for tool results (nested children, no parameters).
static func compact_device(project: Project, inst: DeviceInstance) -> Dictionary:
	var kids: Array = []
	for child in inst.children:
		if child is DeviceInstance:
			kids.append(compact_device(project, child))
	var category := ""
	if inst.device:
		category = Device.DeviceCategory.keys()[inst.device.category]
	var row := {
		"path": inst.address_path(project),
		"name": inst.get_display_name(),
		"device_id": inst.device.device_id if inst.device else "",
		"category": category,
		"position": inst.position,
	}
	if not inst.enabled:
		row["bypass"] = true
	if not inst.loaded_file_path.is_empty():
		row["loaded_file"] = relative_asset_path(inst.loaded_file_path)
	if not kids.is_empty():
		row["children"] = kids
	if inst.slot_note >= 0:
		row["slot_note"] = inst.slot_note
	return row


## Library-relative form of an absolute asset path, for display to the model.
static func relative_asset_path(path: String) -> String:
	if AssetService == null:
		return path
	return AssetPaths.to_relative(path, AssetService.get_roots())


## `Master`, `None`, `Hardware Out` / `Hardware Out N`, or the channel's name.
static func describe_route_target(project: Project, channel_id: int) -> String:
	if channel_id == 0:
		return "None"
	if channel_id == 1:
		return "Master"
	if channel_id == 1000:
		return "Hardware Out"
	if channel_id > 1000:
		return "Hardware Out %d" % (channel_id - 1000)
	var c := project.get_channel_by_id(channel_id)
	return c.name if c else str(channel_id)
