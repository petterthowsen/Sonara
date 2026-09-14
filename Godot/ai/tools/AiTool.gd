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


## True when this tool must not mutate the project.
func is_read_only() -> bool:
	return true


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


## Open project, or a fail dict if none.
static func require_project() -> Variant:
	if Sonara and Sonara.editor and Sonara.editor.project:
		return Sonara.editor.project
	return fail("No project open")


## Resolve a track by id, or by unique name if `id` is missing.
static func resolve_track(project: Project, args: Dictionary, id_key: String = "track_id") -> Variant:
	if args.has(id_key):
		var t := project.get_track_by_id(int(args[id_key]))
		return t if t else fail("Track not found: %s" % args[id_key])
	var name := str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return fail("track_id is required")
	var hits: Array = []
	for t in project.tracks:
		if t.name.to_lower() == name.to_lower():
			hits.append(t)
	if hits.size() == 1:
		return hits[0]
	if hits.is_empty():
		return fail("No track named '%s'" % name)
	return fail("Multiple tracks named '%s'; use track_id" % name)


## Resolve a channel by id, or by unique name.
static func resolve_channel(project: Project, args: Dictionary, id_key: String = "channel_id") -> Variant:
	if args.has(id_key):
		var c := project.get_channel_by_id(int(args[id_key]))
		return c if c else fail("Channel not found: %s" % args[id_key])
	var name := str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return fail("channel_id is required")
	var hits: Array = []
	for c in project.channels:
		if c.name.to_lower() == name.to_lower():
			hits.append(c)
	if hits.size() == 1:
		return hits[0]
	if hits.is_empty():
		return fail("No channel named '%s'" % name)
	return fail("Multiple channels named '%s'; use channel_id" % name)


## Compact track row for tool results.
static func compact_track(t: Track) -> Dictionary:
	return {
		"id": t.id,
		"name": t.name,
		"type": _track_kind(t),
		"channel_id": t.default_channel_id,
		"clip_count": t.clip_instances.size(),
		"color": "#%s" % t.get_color().to_html(false),
	}


## Compact mixer row for tool results.
static func compact_channel(c: Channel) -> Dictionary:
	var sends: Array = []
	for s in c.send_channels:
		if s is SendConfig:
			sends.append({
				"target_channel_id": s.target_channel_id,
				"amount_db": s.amount,
				"pre_fader": s.pre_fader,
			})
	var device_names: PackedStringArray = []
	for d in c.devices:
		if d is DeviceInstance and d.device:
			device_names.append(d.get_display_name())
	return {
		"id": c.id,
		"name": c.name,
		"type": "master" if c.is_master else _channel_kind(c),
		"volume_db": c.volume,
		"pan": c.pan,
		"mute": c.mute,
		"solo": c.solo,
		"output_channel_id": c.output_channel_id,
		"sends": sends,
		"devices": device_names,
	}


## Compact type string for tools: group, folder_bus, folder, audio, or instrument.
static func _track_kind(t: Track) -> String:
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


## Compact mixer type string: group, bus, audio, or instrument.
static func _channel_kind(c: Channel) -> String:
	match c.channel_type:
		Channel.ChannelType.AUDIO:
			return "audio"
		Channel.ChannelType.BUS:
			return "bus"
		Channel.ChannelType.GROUP:
			return "group"
		_:
			return "instrument"


## Resolve a clip by `clip_id` or unique `name` / `clip`.
static func resolve_clip(project: Project, args: Dictionary) -> Variant:
	var cid := str(args.get("clip_id", "")).strip_edges()
	if not cid.is_empty() and project.clips.has(cid):
		return project.clips[cid]
	var name := str(args.get("clip", args.get("name", ""))).strip_edges()
	if name.is_empty():
		return fail("clip name or clip_id is required")
	if project.clips.has(name):
		return project.clips[name]
	var hits: Array = []
	for clip in project.clips.values():
		if clip is Clip and clip.name.to_lower() == name.to_lower():
			hits.append(clip)
	if hits.size() == 1:
		return hits[0]
	if hits.is_empty():
		return fail("No clip named '%s'" % name)
	return fail("Multiple clips named '%s'; use clip_id" % name)


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
		"clip_id": clip.id,
		"type": "audio" if clip.type == Clip.ClipType.AUDIO else "midi",
		"note_count": clip.midi_notes.size(),
		"length_ticks": clip.content_length_ticks,
		"instance_count": placements.size(),
		"placements": placements,
	}


## One timeline placement of a clip.
static func compact_instance(project: Project, inst: ClipInstance) -> Dictionary:
	var track_id := inst.track.id if inst.track else -1
	var track_name := inst.track.name if inst.track else ""
	return {
		"instance_id": inst.id,
		"track_id": track_id,
		"track": track_name,
		"start": ClipTextTime.format_bbt(inst.start_ticks, project.ppq, project.time_numerator),
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
			return ClipTextTime.bbt_to_ticks(n, 1, 0, project.ppq, project.time_numerator)
		return maxi(0, n)
	var s := str(v).strip_edges()
	if s.is_valid_int():
		var n2 := s.to_int()
		if n2 >= 1 and n2 <= 512:
			return ClipTextTime.bbt_to_ticks(n2, 1, 0, project.ppq, project.time_numerator)
		return maxi(0, n2)
	var ticks := ClipTextTime.parse_bbt(s, project.ppq, project.time_numerator)
	return ticks if ticks >= 0 else 0


## Shared serialize/apply options from a project + optional tool args.
static func clip_text_opts(project: Project, args: Dictionary = {}, track: Track = null) -> Dictionary:
	var o := {
		"ppq": project.ppq,
		"numerator": project.time_numerator,
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


## Resolve a device by `instance_id` or `path` (`Channel/Device/Child`).
static func resolve_device(project: Project, args: Dictionary) -> Variant:
	var iid := str(args.get("instance_id", "")).strip_edges()
	if not iid.is_empty():
		var found := project.find_device_instance(iid)
		if found:
			return found
		return fail("Device not found: %s" % iid)
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return fail("path or instance_id is required")
	var segs := DeviceNaming.split_path(path)
	if segs.is_empty():
		return fail("path or instance_id is required")
	var channel: Channel = null
	var rest: PackedStringArray = segs
	if args.has("channel_id"):
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
			return fail("No channel named '%s'" % segs[0])
		if hits.size() > 1:
			return fail("Multiple channels named '%s'; use channel_id" % segs[0])
		channel = hits[0]
		rest = DeviceNaming.skip_first(segs)
	var walked = DeviceNaming.walk_named(channel.devices, rest)
	if walked is Dictionary:
		return fail(str(walked.get("error", "Device not found")))
	return walked


## Container parent from `parent` path or `parent_instance_id`; null means channel root.
static func resolve_optional_parent(project: Project, args: Dictionary) -> Variant:
	var parent_id := str(args.get("parent_instance_id", "")).strip_edges()
	var parent_path := str(args.get("parent", "")).strip_edges()
	if parent_id.is_empty() and parent_path.is_empty():
		return null
	var nested := {}
	if not parent_id.is_empty():
		nested["instance_id"] = parent_id
	if not parent_path.is_empty():
		nested["path"] = parent_path
	if args.has("channel_id"):
		nested["channel_id"] = args.channel_id
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
		"instance_id": inst.id,
		"name": inst.get_display_name(),
		"device_id": inst.device.device_id if inst.device else "",
		"category": category,
		"bypass": not inst.enabled,
		"loaded_file": inst.loaded_file_path,
		"position": inst.position,
		"children": kids,
	}
	if inst.slot_note >= 0:
		row["slot_note"] = inst.slot_note
	return row
