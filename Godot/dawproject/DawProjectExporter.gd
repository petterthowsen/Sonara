class_name DawProjectExporter extends RefCounted

## Writes a `Project` to a `.dawproject` ZIP (`docs/specs/010-dawproject-core`). Reads the live
## project and never changes it. Model objects are typed `Object` on purpose, see `DawEnums`.

const BUILTIN_PREFIX := "sonara."

var _project: Object
var _report := TransferReport.new()
var _w: DawXml.Writer
var _next_id: int = 0
var _files: Dictionary = {}          # zip path -> PackedByteArray
var _embedded: Dictionary = {}       # absolute source path -> zip path (dedupe)
var _channel_info: Dictionary = {}   # channel id -> info Dictionary (see _prepass)
var _track_ids: Dictionary = {}      # track id -> xml id
var _bus_track_ids: Dictionary = {}  # channel id -> xml id of the Track wrapping a bus/master
var _param_ids: Dictionary = {}      # "<device instance id>|<param id>" -> xml id
var _device_params: Dictionary = {}  # device instance id -> Array[int] of automated param ids
var _lane_targets: Dictionary = {}   # AutomationLane -> resolved target Dictionary
var _shared_content: Dictionary = {} # clip id -> xml id of its content (multi-instance clips)
var _content_written: Dictionary = {}# clip id -> true once the content with the id is written
var _tempo_id: String = ""
var _signature_id: String = ""


## `{ok, error, report}`. Awaits the CLAP state refresh first (as Save does), so callers must
## `await` it.
func export_project(project: Object, path: String) -> Dictionary:
	_reset(project)
	await project.refresh_plugin_states()
	_prepass()
	var xml := _build_project_xml()
	var meta := DawXml.Writer.new()
	meta.open("MetaData")
	meta.leaf("Title", {}, project.project_name)
	meta.close()
	var err := _write_zip(path, xml.to_bytes(), meta.to_bytes())
	if err != "":
		return {"ok": false, "error": err, "report": _report}
	return {"ok": true, "error": "", "report": _report}


func _reset(project: Object) -> void:
	_project = project
	_report = TransferReport.new()
	_next_id = 0
	_files.clear()
	_embedded.clear()
	_channel_info.clear()
	_track_ids.clear()
	_bus_track_ids.clear()
	_param_ids.clear()
	_device_params.clear()
	_lane_targets.clear()
	_shared_content.clear()
	_content_written.clear()


func _new_id() -> String:
	var id := "id%d" % _next_id
	_next_id += 1
	return id


# ============================================================================
# PRE-PASS: ids for everything that is referenced before it is written
# ============================================================================

func _is_exported_channel(ch: Object) -> bool:
	return ch != null and ch.aux_bus_index < 0 and ch.aux_pad_note < 0


func _prepass() -> void:
	_tempo_id = _new_id()
	_signature_id = _new_id()
	for ch in _project.channels:
		if not _is_exported_channel(ch):
			continue
		var info := {
			"ch": ch, "id": _new_id(), "volume": _new_id(), "pan": _new_id(), "mute": _new_id(),
			"sends": [], "role": "regular", "paired": null,
		}
		_channel_info[ch.id] = info
	for track in _project.tracks:
		_track_ids[track.id] = _new_id()
		var ch: Object = _project.get_track_mixer_channel(track)
		if ch != null and _channel_info.has(ch.id):
			_channel_info[ch.id]["paired"] = track
	# Routing into a channel decides bus roles; sends decide what "effect" means.
	var routed_into := {}
	var sent_into := {}
	for id in _channel_info:
		var ch: Object = _channel_info[id]["ch"]
		if ch.id != DawEnums.MASTER_CHANNEL_ID and _channel_info.has(ch.output_channel_id) and ch.output_channel_id != ch.id:
			routed_into[ch.output_channel_id] = true
		for s in ch.send_channels:
			if _channel_info.has(s.target_channel_id) and s.target_channel_id != ch.id:
				sent_into[s.target_channel_id] = true
	for id in _channel_info:
		var info: Dictionary = _channel_info[id]
		var ch: Object = info["ch"]
		var paired: Object = info["paired"]
		if ch.id == DawEnums.MASTER_CHANNEL_ID:
			info["role"] = "master"
		elif paired != null:
			var t: int = paired.type
			info["role"] = "submix" if (t == DawEnums.TRACK_FOLDER or t == DawEnums.TRACK_GROUP) else "regular"
		else:
			info["role"] = "effect" if (sent_into.has(id) and not routed_into.has(id)) else "submix"
			_bus_track_ids[id] = _new_id()
		for s in ch.send_channels:
			if _channel_info.has(s.target_channel_id) and s.target_channel_id != ch.id:
				info["sends"].append({"cfg": s, "id": _new_id(), "enable": _new_id(), "volume": _new_id()})
			else:
				info["sends"].append(null)
	_prepass_automation()
	_prepass_shared_clips()


func _prepass_automation() -> void:
	for track in _project.tracks:
		var ch: Object = _project.get_track_mixer_channel(track)
		if ch == null or not _channel_info.has(ch.id):
			continue
		var info: Dictionary = _channel_info[ch.id]
		for lane in track.automation_lanes:
			if lane.target == null or lane.points.is_empty():
				continue
			var resolved := _resolve_lane_target(lane, ch, info, track)
			if not resolved.is_empty():
				_lane_targets[lane] = resolved


## Kinds: 0 CHANNEL_VOLUME, 1 CHANNEL_PAN, 2 SEND_AMOUNT, 3 DEVICE_PARAM (AutomationTarget.Kind).
func _resolve_lane_target(lane: Object, ch: Object, info: Dictionary, track: Object) -> Dictionary:
	var target: Object = lane.target
	match target.kind:
		0:
			return {"parameter": info["volume"], "unit": "linear", "kind": "volume", "max": 2.0}
		1:
			return {"parameter": info["pan"], "unit": "normalized", "kind": "pan", "max": 1.0}
		2:
			if target.send_index < 0 or target.send_index >= info["sends"].size() or info["sends"][target.send_index] == null:
				_report.add(TransferReport.UNSUPPORTED_AUTOMATION, track.name, "send to a channel that isn't exported")
				return {}
			return {"parameter": info["sends"][target.send_index]["volume"], "unit": "linear", "kind": "send",
					"max": _send_max(ch, target.send_index, lane)}
		3:
			if target.device_path.size() != 1:
				_report.add(TransferReport.UNSUPPORTED_AUTOMATION, track.name, "nested device parameter")
				return {}
			var idx: int = target.device_path[0]
			if idx < 0 or idx >= ch.devices.size():
				return {}
			var inst: Object = ch.devices[idx]
			var key := "%s|%d" % [inst.id, target.param_id]
			if not _param_ids.has(key):
				_param_ids[key] = _new_id()
				if not _device_params.has(inst.id):
					_device_params[inst.id] = []
				_device_params[inst.id].append(target.param_id)
			return {"parameter": _param_ids[key], "unit": "linear", "kind": "device", "instance": inst, "param_id": target.param_id}
	return {}


## Send volume ceiling: 1 (0 dB) as Bitwig writes it, higher only when the send or its lane is.
func _send_max(ch: Object, send_index: int, lane: Object) -> float:
	var highest := DawUnits.volume_db_to_linear(ch.send_channels[send_index].amount)
	for p in lane.points:
		highest = maxf(highest, DawUnits.volume_db_to_linear(AutomationTarget.normalized_to_db(p.value)))
	return maxf(1.0, ceilf(highest))


func _prepass_shared_clips() -> void:
	var uses := {}
	for track in _project.tracks:
		for inst in track.clip_instances:
			if inst.transpose == 0:
				uses[inst.clip_id] = int(uses.get(inst.clip_id, 0)) + 1
	for clip_id in uses:
		if uses[clip_id] > 1:
			_shared_content[clip_id] = _new_id()


# ============================================================================
# project.xml
# ============================================================================

func _build_project_xml() -> DawXml.Writer:
	_w = DawXml.Writer.new()
	_w.open("Project", {"version": "1.0"})
	_w.leaf("Application", {"name": "Sonara", "version": _app_version()})
	_w.open("Transport")
	_w.leaf("Tempo", {"max": 999.0, "min": 20.0, "unit": "bpm", "value": float(_project.tempo), "id": _tempo_id, "name": "Tempo"})
	_w.leaf("TimeSignature", {"denominator": int(_project.time_denominator), "numerator": int(_project.time_numerator), "id": _signature_id, "name": "Time Signature"})
	_w.close()
	_write_structure()
	_write_arrangement()
	_w.close()
	return _w


func _app_version() -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	return version if version != "" else "0.1"


func _write_structure() -> void:
	_w.open("Structure")
	for root in _project.get_visual_track_list():
		if root.parent_track_id < 0:
			_write_track(root)
	for id in _bus_track_ids:
		var info: Dictionary = _channel_info[id]
		_w.open("Track", {"contentType": "audio", "loaded": true, "id": _bus_track_ids[id], "name": info["ch"].name, "color": _color(info["ch"].color)})
		_write_channel(info)
		_w.close()
	if _channel_info.has(DawEnums.MASTER_CHANNEL_ID):
		var master: Dictionary = _channel_info[DawEnums.MASTER_CHANNEL_ID]
		_w.open("Track", {"contentType": "audio notes", "loaded": true, "id": _new_id(), "name": "Master"})
		_write_channel(master)
		_w.close()
	_w.close()


func _color(c: Color) -> String:
	return "#" + c.to_html(false)


func _content_type(track: Object) -> String:
	match track.type:
		DawEnums.TRACK_INSTRUMENT:
			return "notes"
		DawEnums.TRACK_AUDIO:
			return "audio"
	return "tracks"


func _write_track(track: Object) -> void:
	_w.open("Track", {
		"contentType": _content_type(track), "loaded": true, "id": _track_ids[track.id],
		"name": track.name, "color": _color(track.color),
	})
	var ch: Object = _project.get_track_mixer_channel(track)
	if ch != null and _channel_info.has(ch.id):
		_write_channel(_channel_info[ch.id])
	for child in _project.get_track_children(track):
		_write_track(child)
	_w.close()


func _write_channel(info: Dictionary) -> void:
	var ch: Object = info["ch"]
	var attrs := {"audioChannels": 2, "role": info["role"], "solo": ch.solo, "id": info["id"]}
	var destination := _destination_of(ch)
	if destination != "":
		attrs["destination"] = destination
	_w.open("Channel", attrs)
	if not ch.devices.is_empty():
		_w.open("Devices")
		for inst in ch.devices:
			_write_device(inst)
		_w.close()
	_w.leaf("Mute", {"value": ch.mute, "id": info["mute"], "name": "Mute"})
	_w.leaf("Pan", {"max": 1.0, "min": 0.0, "unit": "normalized", "value": DawUnits.pan_to_normalized(_pan_position(ch)), "id": info["pan"], "name": "Pan"})
	_report_channel_quirks(ch)
	var sends_written := false
	for i in ch.send_channels.size():
		var s: Variant = info["sends"][i]
		if s == null:
			continue
		if not sends_written:
			_w.open("Sends")
			sends_written = true
		var cfg: Object = s["cfg"]
		var gain := DawUnits.volume_db_to_linear(cfg.amount)
		_w.open("Send", {"destination": _channel_info[cfg.target_channel_id]["id"], "type": "pre" if cfg.pre_fader else "post", "id": s["id"]})
		_w.leaf("Enable", {"value": not cfg.muted, "id": s["enable"]})
		_w.leaf("Volume", {"max": _send_max(ch, i, _lane_for_send(ch, i)), "min": 0.0, "unit": "linear", "value": gain, "id": s["volume"], "name": "Send"})
		_w.close()
	if sends_written:
		_w.close()
	var volume := DawUnits.volume_db_to_linear(ch.volume)
	_w.leaf("Volume", {"max": maxf(2.0, ceilf(volume)), "min": 0.0, "unit": "linear", "value": volume, "id": info["volume"], "name": "Volume"})
	_w.close()


func _lane_for_send(ch: Object, send_index: int) -> Object:
	var track: Object = _project.get_channel_paired_track(ch)
	if track != null:
		for lane in track.automation_lanes:
			if lane.target != null and lane.target.kind == 2 and lane.target.send_index == send_index:
				return lane
	return _EmptyLane.new()


class _EmptyLane extends RefCounted:
	var points: Array = []


func _destination_of(ch: Object) -> String:
	if ch.id == DawEnums.MASTER_CHANNEL_ID:
		return ""
	var out: int = ch.output_channel_id
	if out >= DawEnums.HARDWARE_OUTPUT_MIN:
		_report.add(TransferReport.HARDWARE_OUTPUT, ch.name)
		out = DawEnums.MASTER_CHANNEL_ID
	if out == ch.id or not _channel_info.has(out):
		# Routed to nothing exportable (an aux return, or no route): fall back to the master.
		out = DawEnums.MASTER_CHANNEL_ID
	if not _channel_info.has(out):
		return ""
	return _channel_info[out]["id"]


func _pan_position(ch: Object) -> float:
	if ch.pan_mode == DawEnums.PAN_DUAL:
		return (ch.pan_left + ch.pan_right) * 0.5
	return ch.pan


func _report_channel_quirks(ch: Object) -> void:
	if ch.pan_mode == DawEnums.PAN_COMBINED or ch.pan_mode == DawEnums.PAN_DUAL:
		_report.add(TransferReport.PAN_MODE, ch.name, "dual" if ch.pan_mode == DawEnums.PAN_DUAL else "combined")
	if ch.phase_invert:
		_report.add(TransferReport.PHASE_INVERT, ch.name)


# ============================================================================
# Devices
# ============================================================================

func _device_role(inst: Object) -> String:
	var dev: Object = inst.device
	if dev.id.ends_with("spectrum_analyzer"):
		return "analyzer"
	return "instrument" if dev.category == DawEnums.CATEGORY_INSTRUMENT else "audioFX"


func _safe_file_name(s: String) -> String:
	var out := ""
	for c in s:
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in "-_."
		out += c if ok else "_"
	return out


func _write_device(inst: Object) -> void:
	var dev: Object = inst.device
	var is_clap: bool = dev.device_type == DawEnums.DEVICE_CLAP
	var attrs := {
		"deviceID": dev.id if is_clap else BUILTIN_PREFIX + dev.id,
		"deviceName": dev.name, "deviceRole": _device_role(inst), "loaded": true,
		"id": _new_id(), "name": inst.get_display_name(),
	}
	var state_path := ""
	var state_bytes := PackedByteArray()
	if is_clap:
		attrs["deviceVendor"] = dev.author
		attrs["pluginVersion"] = dev.version
		if inst.plugin_state.is_empty():
			_report.add(TransferReport.PLUGIN_NO_STATE, inst.get_display_name(), dev.name)
		else:
			state_path = "plugins/%s.clap-preset" % _safe_file_name(inst.id)
			state_bytes = ClapPreset.wrap(dev.id, inst.plugin_state)
	else:
		state_path = "plugins/%s.json" % _safe_file_name(inst.id)
		state_bytes = JSON.stringify(_embed_files_in(inst.to_json()), "\t").to_utf8_buffer()
	_w.open("ClapPlugin" if is_clap else "BuiltinDevice", attrs)
	_w.open("Parameters")
	for param_id in _device_params.get(inst.id, []):
		var param: Object = inst.get_parameter(param_id)
		var real := DawUnits.param_to_real(param, inst.get_parameter_normalized(param_id))
		_w.leaf("RealParameter", {
			"parameterID": param_id, "max": param.max_value if param else 1.0, "min": param.min_value if param else 0.0,
			"unit": "linear", "value": real, "id": _param_ids["%s|%d" % [inst.id, param_id]],
			"name": param.name if param else "Param %d" % param_id,
		})
	_w.close()
	_w.leaf("Enabled", {"value": inst.enabled, "id": _new_id(), "name": "On/Off"})
	if state_path != "":
		_w.leaf("State", {"path": state_path})
		_files[state_path] = state_bytes
	_w.close()


## Embeds every file a device tree loads and points its `loaded_file_path` at the container copy.
func _embed_files_in(json: Dictionary) -> Dictionary:
	var path: String = str(json.get("loaded_file_path", ""))
	if path != "":
		var embedded := _embed_device_file(path, str(json.get("name", path.get_file())))
		if embedded != "":
			json["loaded_file_path"] = embedded
	var children: Array = json.get("children", [])
	for child in children:
		if child is Dictionary:
			_embed_files_in(child)
	return json


## Container path of the embedded copy of `source` ("" when the file is missing). An SFZ brings
## its includes and samples along, laid out relative to their common folder.
func _embed_device_file(source: String, subject: String) -> String:
	if _embedded.has(source):
		return _embedded[source]
	if not FileAccess.file_exists(source):
		_report.add(TransferReport.FILE_MISSING, subject, source.get_file())
		return ""
	var files: PackedStringArray = [source]
	if source.get_extension().to_lower() == "sfz":
		var collected := SfzFiles.collect(source)
		files = collected.files
		for m in collected.missing:
			_report.add(TransferReport.FILE_MISSING, subject, m.get_file())
	var root := _common_dir(files)
	var slot := "files/%d" % _embedded.size()
	var main := ""
	for f in files:
		var rel := f.trim_prefix(root).trim_prefix("/")
		var zip_path := "%s/%s" % [slot, rel]
		_files[zip_path] = FileAccess.get_file_as_bytes(f)
		if f == source:
			main = zip_path
	_embedded[source] = main
	return main


func _common_dir(files: PackedStringArray) -> String:
	var common := files[0].get_base_dir()
	for f in files:
		while not (f.begins_with(common + "/") or common == ""):
			common = common.get_base_dir()
	return common


# ============================================================================
# Arrangement
# ============================================================================

func _write_arrangement() -> void:
	_w.open("Arrangement", {"id": _new_id()})
	_w.open("Lanes", {"timeUnit": "beats", "id": _new_id()})
	for track in _project.tracks:
		_write_track_lanes(track)
	_w.close()
	if not _project.markers.is_empty():
		_w.open("Markers", {"id": _new_id()})
		for m in _project.markers:
			if m.duration_ticks > 0:
				_report.add(TransferReport.MARKER_DURATION, m.name)
			_w.leaf("Marker", {"time": DawUnits.ticks_to_beats(m.start_ticks), "name": m.name, "color": _color(m.color)})
		_w.close()
	_write_tempo_automation()
	_write_signature_automation()
	_w.close()


func _write_tempo_automation() -> void:
	if _project.tempo_map.is_empty():
		return
	_w.open("TempoAutomation", {"unit": "bpm", "timeUnit": "beats", "id": _new_id()})
	_w.leaf("Target", {"parameter": _tempo_id})
	for p in _project.tempo_map.points:
		_w.leaf("RealPoint", {"time": DawUnits.ticks_to_beats(p["tick"]), "value": float(p["bpm"]), "interpolation": "linear"})
	_w.close()


func _write_signature_automation() -> void:
	var sig_map: Object = _project.time_signature_map
	if sig_map.is_empty():
		return
	_w.open("TimeSignatureAutomation", {"timeUnit": "beats", "id": _new_id()})
	_w.leaf("Target", {"parameter": _signature_id})
	for c in sig_map.changes:
		var tick: int = sig_map.tick_of_bar(c["bar"], _project.time_numerator, _project.time_denominator, _project.ppq)
		_w.leaf("TimeSignaturePoint", {"time": DawUnits.ticks_to_beats(tick), "numerator": int(c["numerator"]), "denominator": int(c["denominator"])})
	_w.close()


func _write_track_lanes(track: Object) -> void:
	var has_content: bool = (track.has_clips() and not track.clip_instances.is_empty())
	var lanes_to_write: Array = []
	for lane in track.automation_lanes:
		if _lane_targets.has(lane):
			lanes_to_write.append(lane)
	if not has_content and lanes_to_write.is_empty():
		return
	_w.open("Lanes", {"track": _track_ids[track.id], "id": _new_id()})
	if has_content:
		_w.open("Clips", {"id": _new_id()})
		var instances: Array = track.clip_instances.duplicate()
		instances.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
		for inst in instances:
			_write_clip(inst, track)
		_w.close()
	for lane in lanes_to_write:
		_write_points(lane, _lane_targets[lane])
	_w.close()


func _write_clip(inst: Object, track: Object) -> void:
	var clip: Object = inst.clip if inst.clip != null else _project.get_clip(inst.clip_id)
	if clip == null:
		return
	var attrs := {
		"time": DawUnits.ticks_to_beats(inst.start_ticks), "duration": DawUnits.ticks_to_beats(inst.duration_ticks),
		"playStart": DawUnits.ticks_to_beats(inst.clip_offset),
		"fadeTimeUnit": "beats", "fadeInTime": DawUnits.ticks_to_beats(inst.fade_in_ticks),
		"fadeOutTime": DawUnits.ticks_to_beats(inst.fade_out_ticks),
		"enable": not inst.muted, "name": clip.name, "color": _color(inst.get_effective_color()),
	}
	if inst.loop_enabled:
		attrs["loopStart"] = DawUnits.ticks_to_beats(inst.loop_start_ticks)
		attrs["loopEnd"] = DawUnits.ticks_to_beats(inst.loop_start_ticks + inst.loop_length_ticks)
	if inst.gain_offset != 0.0:
		_report.add(TransferReport.CLIP_GAIN_OFFSET, track.name)
	var is_midi: bool = clip.type == DawEnums.CLIP_MIDI
	var transposed: bool = is_midi and inst.transpose != 0
	if transposed:
		_report.add(TransferReport.CLIP_TRANSPOSE, track.name)
	# Later instances of shared content point back at the first one.
	if not transposed and _content_written.has(clip.id):
		attrs["reference"] = _shared_content[clip.id]
		_w.leaf("Clip", attrs)
		return
	var content_id := ""
	if not transposed and _shared_content.has(clip.id):
		content_id = _shared_content[clip.id]
	if is_midi:
		_w.open("Clip", attrs)
		_write_notes(clip, content_id, inst.transpose if transposed else 0)
		_w.close()
	else:
		var audio := _audio_content(clip)
		if audio.is_empty():
			return  # file missing, reported by _audio_content
		_w.open("Clip", attrs)
		_write_warps(clip, audio, content_id)
		_w.close()
	if not transposed and content_id != "":
		_content_written[clip.id] = true


func _write_notes(clip: Object, content_id: String, transpose: int) -> void:
	var attrs := {}
	if content_id != "":
		attrs["id"] = content_id
	_w.open("Notes", attrs)
	var notes: Array = clip.midi_notes.duplicate()
	notes.sort_custom(func(a, b): return a.start_tick < b.start_tick)
	for n in notes:
		_w.leaf("Note", {
			"time": DawUnits.ticks_to_beats(n.start_tick), "duration": DawUnits.ticks_to_beats(n.duration_ticks),
			"channel": 0, "key": clampi(n.note + transpose, 0, 127),
			"vel": DawUnits.velocity_to_normalized(n.velocity),
		})
	_w.close()


## Embeds the clip's audio file once per source and returns `{path, duration, sample_rate, channels}`,
## or an empty Dictionary when the file can't be read.
func _audio_content(clip: Object) -> Dictionary:
	var source: String = clip.audio_file_path
	if source == "" or not FileAccess.file_exists(source):
		_report.add(TransferReport.FILE_MISSING, clip.name, source.get_file())
		return {}
	if not _embedded.has(source):
		var zip_path := "audio/" + source.get_file()
		var n := 2
		while _files.has(zip_path):
			zip_path = "audio/%s-%d.%s" % [source.get_file().get_basename(), n, source.get_extension()]
			n += 1
		_files[zip_path] = FileAccess.get_file_as_bytes(source)
		_embedded[source] = zip_path
	var duration: float = clip.audio_duration_seconds
	if duration <= 0.0:
		duration = DawUnits.ticks_to_beats(clip.content_length_ticks) * 60.0 / maxf(1.0, clip.recorded_bpm)
	var data: Variant = clip.audio_source.data
	var rate: int = clip.audio_sample_rate
	if data != null and "source_sample_rate" in data and data.source_sample_rate > 0:
		rate = data.source_sample_rate
	return {"path": _embedded[source], "duration": duration, "sample_rate": rate, "channels": clip.audio_channels}


func _write_warps(clip: Object, audio: Dictionary, content_id: String) -> void:
	var beats: float = audio["duration"] * maxf(1.0, clip.recorded_bpm) / 60.0
	var attrs := {"contentTimeUnit": "seconds", "timeUnit": "beats"}
	if content_id != "":
		attrs["id"] = content_id
	_w.open("Warps", attrs)
	_w.open("Audio", {"algorithm": "raw", "channels": int(audio["channels"]), "sampleRate": int(audio["sample_rate"]), "duration": audio["duration"], "id": _new_id()})
	_w.leaf("File", {"path": audio["path"]})
	_w.close()
	_w.leaf("Warp", {"time": 0.0, "contentTime": 0.0})
	_w.leaf("Warp", {"time": beats, "contentTime": audio["duration"]})
	_w.close()


func _write_points(lane: Object, target: Dictionary) -> void:
	var map: Callable
	var tolerance: float
	match target["kind"]:
		"volume", "send":
			map = func(n: float) -> float: return DawUnits.volume_db_to_linear(AutomationTarget.normalized_to_db(n))
			tolerance = 0.01 * float(target["max"])
		"pan":
			map = func(n: float) -> float: return n
			tolerance = 0.01
		_:
			var param: Object = target["instance"].get_parameter(target["param_id"])
			map = func(n: float) -> float: return DawUnits.param_to_real(param, n)
			tolerance = 0.01 * (absf(param.max_value - param.min_value) if param != null else 1.0)
	var points := DawUnits.resample(DawUnits.points_from_lane(lane), map, tolerance)
	_w.open("Points", {"unit": target["unit"], "id": _new_id()})
	_w.leaf("Target", {"parameter": target["parameter"]})
	for p in points:
		_w.leaf("RealPoint", {"time": DawUnits.ticks_to_beats(p["tick"]), "value": float(p["value"]), "interpolation": "hold" if p["step"] else "linear"})
	_w.close()


# ============================================================================
# ZIP
# ============================================================================

## Writes through `<path>.partial` and renames on success. Returns an error message or "".
func _write_zip(path: String, project_xml: PackedByteArray, metadata_xml: PackedByteArray) -> String:
	var partial := path + ".partial"
	var zip := ZIPPacker.new()
	var err := zip.open(partial)
	if err != OK:
		return "Cannot write %s: %s" % [path, error_string(err)]
	var entries: Dictionary = {"project.xml": project_xml, "metadata.xml": metadata_xml}
	entries.merge(_files)
	for name in entries:
		err = zip.start_file(name)
		if err == OK:
			err = zip.write_file(entries[name])
		if err == OK:
			err = zip.close_file()
		if err != OK:
			zip.close()
			DirAccess.remove_absolute(partial)
			return "Cannot write %s: %s" % [path, error_string(err)]
	zip.close()
	err = DirAccess.rename_absolute(partial, path)
	if err != OK:
		DirAccess.remove_absolute(partial)
		return "Cannot write %s: %s" % [path, error_string(err)]
	return ""
