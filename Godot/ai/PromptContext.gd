# PromptContext.gd
# Registry of `{variable}` providers for the system prompt.
class_name PromptContext extends RefCounted


const TABLE_CAP := 24

var _vars: Dictionary = {}


## Register built-in project / editor variables.
func _init() -> void:
	register("project_name", _project_name)
	register("tempo", _tempo)
	register("bpm", _tempo)
	register("time_signature", _time_signature)
	register("ppq", _ppq)
	register("sample_rate", _sample_rate)
	register("playhead", _playhead)
	register("tracks", _tracks)
	register("channels", _channels)
	register("mixer", _channels)
	register("selection", _selection)
	register("devices", _devices)
	register("date", _date)


## Add or replace a `{name}` provider. `fn` returns a markdown string.
func register(name: String, fn: Callable) -> void:
	_vars[name] = fn


## True when `name` has a registered provider.
func has_variable(name: String) -> bool:
	return _vars.has(name)


## Evaluate one variable; empty string if the callable fails.
func get_value(name: String) -> String:
	if not _vars.has(name):
		return ""
	var fn: Callable = _vars[name]
	if not fn.is_valid():
		return ""
	var result = fn.call()
	return str(result) if result != null else ""


func _editor() -> Editor:
	return Sonara.editor if Sonara else null


func _project() -> Project:
	var ed := _editor()
	return ed.project if ed else null


func _project_name() -> String:
	var p := _project()
	return p.project_name if p else "Untitled"


func _tempo() -> String:
	var p := _project()
	return str(int(p.tempo)) if p else "?"


func _time_signature() -> String:
	var p := _project()
	if p == null:
		return "?"
	return "%d/%d" % [p.time_numerator, p.time_denominator]


func _ppq() -> String:
	var p := _project()
	return str(p.ppq) if p else "?"


func _sample_rate() -> String:
	var p := _project()
	return str(p.sample_rate) if p else "?"


func _playhead() -> String:
	var ed := _editor()
	if ed == null or ed.project == null:
		return "1:1:000 (0)"
	var bbt: Dictionary = ed.ticks_to_bbt(ed.playhead_ticks)
	return "%d:%d:%03d (%d)" % [bbt.bar, bbt.beat, bbt.tick, ed.playhead_ticks]


func _tracks() -> String:
	var p := _project()
	if p == null:
		return "_No project open._"
	var lines: PackedStringArray = ["| id | name | type | channel | clips |", "|---|---|---|---|---|"]
	var extra := 0
	for i in range(p.tracks.size()):
		if i >= TABLE_CAP:
			extra = p.tracks.size() - TABLE_CAP
			break
		var t: Track = p.tracks[i]
		lines.append("| %d | %s | %s | %s | %d |" % [
			t.id, _md_cell(t.name), _track_kind(t),
			str(t.default_channel_id) if t.default_channel_id >= 0 else "—",
			t.clip_instances.size()
		])
	if extra > 0:
		lines.append("_%d more tracks omitted._" % extra)
	return "\n".join(lines)


func _channels() -> String:
	var p := _project()
	if p == null:
		return "_No project open._"
	var lines: PackedStringArray = [
		"| id | name | type | vol | pan | mute | solo | route | sends |",
		"|---|---|---|---|---|---|---|---|---|"
	]
	var extra := 0
	for i in range(p.channels.size()):
		if i >= TABLE_CAP:
			extra = p.channels.size() - TABLE_CAP
			break
		var c: Channel = p.channels[i]
		var sends: PackedStringArray = []
		for s in c.send_channels:
			if s is SendConfig:
				sends.append("%d@%.1fdB" % [s.target_channel_id, s.amount])
		lines.append("| %d | %s | %s | %.1f | %.2f | %s | %s | %d | %s |" % [
			c.id, _md_cell(c.name), _channel_kind(c), c.volume, c.pan,
			"Y" if c.mute else "", "Y" if c.solo else "",
			c.output_channel_id, ", ".join(sends) if not sends.is_empty() else "—"
		])
	if extra > 0:
		lines.append("_%d more channels omitted._" % extra)
	return "\n".join(lines)


func _selection() -> String:
	var ed := _editor()
	if ed == null:
		return "_No selection._"
	var bits: PackedStringArray = []
	if ed.focused_track:
		bits.append("track %d `%s`" % [ed.focused_track.id, ed.focused_track.name])
	if ed.focused_channel:
		bits.append("channel %d `%s`" % [ed.focused_channel.id, ed.focused_channel.name])
	if ed.arranger and ed.arranger.timeline:
		var clips: Array = ed.arranger.timeline.get_selected_clip_instances()
		if not clips.is_empty():
			var clip_bits: PackedStringArray = []
			for inst in clips:
				if inst is ClipInstance:
					clip_bits.append("%s@%d" % [inst.clip_id, inst.start_ticks])
				if clip_bits.size() >= 8:
					break
			bits.append("clips: " + ", ".join(clip_bits))
	return "; ".join(bits) if not bits.is_empty() else "_Nothing focused._"


func _devices() -> String:
	var ed := _editor()
	if ed == null or ed.focused_channel == null:
		return "_No focused channel._"
	var ch: Channel = ed.focused_channel
	if ch.devices.is_empty():
		return "_No devices on channel %d._" % ch.id
	var lines: PackedStringArray = ["| pos | name | id | category | bypass |", "|---|---|---|---|---|"]
	for d in ch.devices:
		if not d is DeviceInstance or d.device == null:
			continue
		lines.append("| %d | %s | `%s` | %s | %s |" % [
			d.position, _md_cell(d.device.name), d.device.device_id,
			Device.DeviceCategory.keys()[d.device.category],
			"Y" if not d.enabled else ""
		])
	return "\n".join(lines)


func _date() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]


func _track_kind(t: Track) -> String:
	if t.is_group():
		return "group"
	match t.type:
		Track.TrackType.AUDIO:
			return "audio"
		Track.TrackType.FOLDER:
			return "folder"
		_:
			return "instrument"


func _channel_kind(c: Channel) -> String:
	if c.is_master:
		return "master"
	match c.channel_type:
		Channel.ChannelType.AUDIO:
			return "audio"
		Channel.ChannelType.BUS:
			return "bus"
		_:
			return "instrument"


func _md_cell(text: String) -> String:
	return text.replace("|", "/").replace("\n", " ")
