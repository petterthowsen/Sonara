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
			device_names.append(d.device.name)
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


static func _track_kind(t: Track) -> String:
	if t.is_group():
		return "group"
	match t.type:
		Track.TrackType.AUDIO:
			return "audio"
		Track.TrackType.FOLDER:
			return "folder"
		_:
			return "instrument"


static func _channel_kind(c: Channel) -> String:
	match c.channel_type:
		Channel.ChannelType.AUDIO:
			return "audio"
		Channel.ChannelType.BUS:
			return "bus"
		_:
			return "instrument"
