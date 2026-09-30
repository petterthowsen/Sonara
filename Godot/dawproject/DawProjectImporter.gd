class_name DawProjectImporter extends RefCounted

## Reads a `.dawproject` into a `.sonara`-shaped Dictionary (`docs/specs/010-dawproject-core`).
## Pure function of the file: it builds JSON from the models' own `to_json()` defaults and never
## touches the open project or the engine. The editor then runs it through `Project.from_json`.
## Model scripts are loaded at run time and objects typed `Object`, see `DawEnums`.

const BUILTIN_PREFIX := "sonara."
const SIGNATURE_DENOMINATORS: Array[int] = [1, 2, 4, 8, 16, 32]
const GENERIC_DEVICES: Array[String] = ["Equalizer", "Compressor", "NoiseGate", "Limiter"]
const FORMAT_DEVICES: Dictionary = {"Vst2Plugin": "VST2", "Vst3Plugin": "VST3", "AuPlugin": "AU"}

var _report := TransferReport.new()
var _error: String = ""
var _audio_dir_failed: bool = false

var _zip: ZIPReader
var _file_path: String = ""
var _audio_dir: String = ""
var _root: DawXml.El
var _ids: Dictionary = {}            # xml id -> DawXml.El
var _targets: Dictionary = {}        # parameter xml id -> {kind, chan, ...}
var _chans: Dictionary = {}          # channel xml id -> channel state Dictionary
var _project: Dictionary = {}        # the Project JSON being built
var _tracks_json: Array = []
var _channels_json: Array = []
var _clips_json: Array = []
var _markers_json: Array = []
var _track_state: Dictionary = {}    # track xml id -> {json, chan (channel state or null)}
var _next_channel_id: int = 2
var _next_track_id: int = 0
var _next_note_id: int = 1
var _next_clip: int = 1
var _next_instance: int = 1
var _next_marker: int = 1
var _sibling_count: Dictionary = {}  # parent track id (-1 root) -> children so far
var _content_clips: Dictionary = {}  # content El -> clip JSON
var _extracted: Dictionary = {}      # zip path -> absolute path
var _tempo_map: Array = []           # [{tick, bpm}] as written to the project
var _base_tempo: float = 120.0
var _mixer_order: int = 0
var _lane_counter: Dictionary = {}   # sonara track id -> lanes created

var _ChannelScript: GDScript
var _TrackScript: GDScript
var _ClipScript: GDScript
var _InstanceScript: GDScript
var _LaneScript: GDScript
var _DeviceInstanceScript: GDScript
var _TempoMapScript: GDScript


## `{ok, error, project_json, report, audio_dir_failed}`. `audio_dir` overrides where embedded
## audio is extracted (default: `<file name> Audio` next to the file).
func import_file(path: String, audio_dir: String = "") -> Dictionary:
	_reset(path, audio_dir)
	_zip = ZIPReader.new()
	if _zip.open(path) != OK:
		return _result(false, "Not a DAWproject file (cannot open %s as a ZIP archive)" % path.get_file())
	var xml_bytes := _zip.read_file("project.xml") if _zip.get_files().has("project.xml") else PackedByteArray()
	if xml_bytes.is_empty():
		_zip.close()
		return _result(false, "Not a DAWproject file (no project.xml in the archive)")
	var parsed := DawXml.parse(xml_bytes)
	if parsed.root == null:
		_zip.close()
		return _result(false, "project.xml is not valid XML: %s" % parsed.error)
	_root = parsed.root
	if _root.tag != "Project":
		_zip.close()
		return _result(false, "project.xml has root <%s>, expected <Project>" % _root.tag)
	_index_ids(_root)
	_check_references(_root)
	if _error == "":
		_build()
	_zip.close()
	if _error != "":
		return _result(false, _error)
	return _result(true, "")


func _result(ok: bool, error: String) -> Dictionary:
	return {
		"ok": ok, "error": error, "report": _report, "audio_dir_failed": _audio_dir_failed,
		"project_json": _project if ok else {},
	}


func _reset(path: String, audio_dir: String) -> void:
	_report = TransferReport.new()
	_error = ""
	_audio_dir_failed = false
	_file_path = path
	_audio_dir = audio_dir if audio_dir != "" else path.get_base_dir().path_join("%s Audio" % path.get_file().get_basename())
	_ids.clear()
	_targets.clear()
	_chans.clear()
	_tracks_json.clear()
	_channels_json.clear()
	_clips_json.clear()
	_markers_json.clear()
	_track_state.clear()
	_next_channel_id = 2
	_next_track_id = 0
	_next_note_id = 1
	_next_clip = 1
	_next_instance = 1
	_next_marker = 1
	_sibling_count.clear()
	_content_clips.clear()
	_extracted.clear()
	_tempo_map = []
	_mixer_order = 0
	_lane_counter.clear()
	_ChannelScript = load("res://data/Channel.gd")
	_TrackScript = load("res://data/Track.gd")
	_ClipScript = load("res://data/Clip.gd")
	_InstanceScript = load("res://data/ClipInstance.gd")
	_LaneScript = load("res://data/AutomationLane.gd")
	_DeviceInstanceScript = load("res://data/DeviceInstance.gd")
	_TempoMapScript = load("res://data/TempoMap.gd")


func _fail(message: String) -> void:
	if _error == "":
		_error = message


# ============================================================================
# Ids and references
# ============================================================================

func _index_ids(node: DawXml.El) -> void:
	if node.has_attr("id") and not _ids.has(node.get_attr("id")):
		_ids[node.get_attr("id")] = node
	for c in node.children:
		_index_ids(c)


func _check_references(node: DawXml.El) -> void:
	if _error != "":
		return
	for attr in ["destination", "track", "reference"]:
		if node.has_attr(attr) and not _ids.has(node.get_attr(attr)):
			_fail("Unresolved reference %s=\"%s\" on <%s> (line %d)" % [attr, node.get_attr(attr), node.tag, node.line])
			return
	if node.tag == "Target" and node.has_attr("parameter") and not _ids.has(node.get_attr("parameter")):
		_fail("Unresolved reference parameter=\"%s\" on <Target> (line %d)" % [node.get_attr("parameter"), node.line])
		return
	for c in node.children:
		_check_references(c)


# ============================================================================
# Build
# ============================================================================

func _build() -> void:
	_project = load("res://data/Project.gd").new().to_json()
	var master_json: Dictionary = _project["channels"][0]
	_channels_json = [master_json]
	_project["project_name"] = _project_name()
	_project["markers"] = []
	_project["clips"] = []
	_project["tracks"] = []
	_read_transport()
	var structure := _root.child("Structure")
	if structure != null:
		for node in structure.children:
			_structure_node(node, -1, -1)
	_import_routing_and_sends()
	_import_devices()
	var arrangement := _root.child("Arrangement")
	if arrangement != null:
		_read_tempo_and_signature(arrangement)
		_walk_timeline(arrangement, {"track": null, "unit": "beats"})
	_import_scenes()
	if _error != "":
		return
	_project["channels"] = _channels_json
	_project["tracks"] = _tracks_json
	_project["clips"] = _clips_json
	_project["markers"] = _markers_json
	_project["next_channel_id"] = _next_channel_id
	_project["next_track_id"] = _next_track_id
	_project["next_note_id"] = _next_note_id
	_project["next_marker_id"] = _next_marker
	var lanes: Dictionary = _project["ruler_lanes"]
	lanes["tempo"] = not _tempo_map.is_empty()
	lanes["time_signature"] = not _project["time_signature_map"].is_empty()


func _project_name() -> String:
	var meta_bytes := _zip.read_file("metadata.xml") if _zip.get_files().has("metadata.xml") else PackedByteArray()
	if not meta_bytes.is_empty():
		var meta := DawXml.parse(meta_bytes)
		if meta.root != null:
			var title: DawXml.El = meta.root.child("Title")
			if title != null and title.text.strip_edges() != "":
				return title.text.strip_edges()
	return _file_path.get_file().get_basename()


func _color_of(el: DawXml.El, fallback: Variant) -> Variant:
	var c := el.get_attr("color") if el != null else ""
	if c == "":
		return fallback
	return Color.from_string(c, fallback if fallback is Color else Color.WHITE)


func _color_json(c: Color) -> Array:
	return [c.r, c.g, c.b, c.a]


# ============================================================================
# Transport, tempo and signature
# ============================================================================

func _read_transport() -> void:
	var transport := _root.child("Transport")
	_project["time_numerator"] = 4
	_project["time_denominator"] = 4
	if transport == null:
		return
	var tempo := transport.child("Tempo")
	if tempo != null:
		_base_tempo = tempo.get_float("value", 120.0)
		_project["tempo"] = _base_tempo
		_targets[tempo.get_attr("id")] = {"kind": "tempo"}
	var sig := transport.child("TimeSignature")
	if sig != null:
		_project["time_numerator"] = int(sig.get_float("numerator", 4.0))
		_project["time_denominator"] = int(sig.get_float("denominator", 4.0))
		_targets[sig.get_attr("id")] = {"kind": "signature"}


func _read_tempo_and_signature(arrangement: DawXml.El) -> void:
	_project["tempo_map"] = []
	_project["time_signature_map"] = []
	var tempo := arrangement.child("TempoAutomation")
	if tempo != null:
		_tempo_map = _tempo_points(tempo)
		_project["tempo_map"] = _tempo_map
	var sig := arrangement.child("TimeSignatureAutomation")
	if sig != null:
		_project["time_signature_map"] = _signature_changes(sig)


## Points sharing a time keep the last one at that tick (earlier ones move one tick back), and a
## `hold` point repeats its value one tick before the next point (REQ-011).
func _tempo_points(node: DawXml.El) -> Array:
	var unit := node.get_attr("timeUnit", "beats")
	var pts: Array = []
	for p in node.children_named("RealPoint"):
		var tick := _to_ticks(p.get_float("time"), unit, 0)
		pts.append({"tick": tick, "bpm": p.get_float("value", 120.0), "hold": p.get_attr("interpolation", "hold") == "hold"})
	pts.sort_custom(func(a, b): return a["tick"] < b["tick"])
	var expanded: Array = []
	for i in pts.size():
		expanded.append({"tick": pts[i]["tick"], "bpm": pts[i]["bpm"]})
		if pts[i]["hold"] and i + 1 < pts.size() and pts[i + 1]["tick"] - 1 > pts[i]["tick"]:
			expanded.append({"tick": pts[i + 1]["tick"] - 1, "bpm": pts[i]["bpm"]})
	for i in range(expanded.size() - 2, -1, -1):
		if expanded[i]["tick"] >= expanded[i + 1]["tick"]:
			expanded[i]["tick"] = expanded[i + 1]["tick"] - 1
	var out: Array = []
	for p in expanded:
		if p["tick"] >= 0:
			out.append({"tick": p["tick"], "bpm": clampf(p["bpm"], 20.0, 999.0)})
	return out


## Signature points to (bar, numerator, denominator); off-bar points move to the next bar.
func _signature_changes(node: DawXml.El) -> Array:
	var unit := node.get_attr("timeUnit", "beats")
	var pts: Array = []
	for p in node.children_named("TimeSignaturePoint"):
		pts.append({"beat": DawUnits.ticks_to_beats(_to_ticks(p.get_float("time"), unit, 0)),
			"num": int(p.get_float("numerator", 4.0)), "den": int(p.get_float("denominator", 4.0))})
	pts.sort_custom(func(a, b): return a["beat"] < b["beat"])
	var out: Array = []
	var num: int = _project["time_numerator"]
	var den: int = _project["time_denominator"]
	var seg_beat := 0.0  # beat where the current signature began
	var seg_bar := 1
	for p in pts:
		if not SIGNATURE_DENOMINATORS.has(p["den"]) or p["num"] < 1 or p["num"] > 32:
			continue
		var bar_beats := float(num) * 4.0 / float(den)
		var bars: float = (p["beat"] - seg_beat) / bar_beats
		var whole := roundi(bars)
		if absf(bars - float(whole)) > 1.0 / 960.0:
			whole = ceili(bars)
			_report.add(TransferReport.SIGNATURE_OFF_BAR)
		var bar := seg_bar + whole
		if bar <= 1:
			_project["time_numerator"] = p["num"]
			_project["time_denominator"] = p["den"]
			num = p["num"]
			den = p["den"]
			continue
		if not out.is_empty() and out.back()["bar"] == bar:
			out.pop_back()
		out.append({"bar": bar, "numerator": p["num"], "denominator": p["den"]})
		seg_beat += float(bar - seg_bar) * bar_beats
		seg_bar = bar
		num = p["num"]
		den = p["den"]
	return out


## Seconds positions convert through the tempo map; beats are direct.
func _to_ticks(value: float, unit: String, _at_tick: int) -> int:
	if unit == "seconds":
		return roundi(_seconds_to_tick(value))
	return DawUnits.beats_to_ticks(value)


func _seconds_to_tick(seconds: float) -> float:
	var map: Object = _TempoMapScript.new()
	for p in _tempo_map:
		map.points.append({"id": 0, "tick": p["tick"], "bpm": p["bpm"]})
	return map.tick_at_seconds(seconds, _base_tempo, 960)


func _bpm_at_tick(tick: int) -> float:
	var map: Object = _TempoMapScript.new()
	for p in _tempo_map:
		map.points.append({"id": 0, "tick": p["tick"], "bpm": p["bpm"]})
	return map.get_bpm_at_tick(float(tick), _base_tempo)


# ============================================================================
# Structure: tracks, folders, channels
# ============================================================================

func _next_sibling_order(parent_id: int) -> int:
	var n: int = _sibling_count.get(parent_id, 0)
	_sibling_count[parent_id] = n + 1
	return n


func _structure_node(node: DawXml.El, parent_track_id: int, group_channel_id: int) -> void:
	if node.tag == "Channel":
		_make_channel(node, node.get_attr("name", "Bus"), Color.WHITE, DawEnums.CHANNEL_BUS, null)
		return
	if node.tag != "Track":
		return
	var ch_el := node.child("Channel")
	var role := ch_el.get_attr("role", "regular") if ch_el != null else "regular"
	if role == "master":
		_bind_master(ch_el)
		return
	var content := node.get_attr("contentType")
	var is_container: bool = "tracks" in content.split(" ") or not node.children_named("Track").is_empty()
	var color: Variant = _color_of(node, null)
	if is_container:
		var t := _make_track(node, DawEnums.TRACK_GROUP if ch_el != null else DawEnums.TRACK_FOLDER, parent_track_id, color)
		var child_group := group_channel_id
		if ch_el != null:
			var state := _make_channel(ch_el, node.get_attr("name", "Group"), color if color != null else Color.WHITE, DawEnums.CHANNEL_GROUP, t)
			_pair_track(t, state, group_channel_id)
			child_group = state["sid"]
		else:
			t["json"]["color_by_channel"] = false
			t["json"]["name_by_channel"] = false
		for child in node.children_named("Track"):
			_structure_node(child, t["json"]["id"], child_group)
		return
	if role == "effect" or role == "submix" or role == "vca":
		if role == "vca":
			_report.add(TransferReport.VCA, node.get_attr("name"))
		_make_channel(ch_el, node.get_attr("name", "Bus"), color if color != null else Color.WHITE, DawEnums.CHANNEL_BUS, null)
		_track_state[node.get_attr("id")] = {"json": null, "chan": _chans[ch_el.get_attr("id")]}
		return
	var is_notes := "notes" in content.split(" ") and (not "audio" in content.split(" ") or _has_instrument(ch_el))
	var t2 := _make_track(node, DawEnums.TRACK_INSTRUMENT if is_notes else DawEnums.TRACK_AUDIO, parent_track_id, color)
	var state2 := _make_channel(ch_el, node.get_attr("name", "Track"), color if color != null else Color.WHITE,
		DawEnums.CHANNEL_INSTRUMENT if is_notes else DawEnums.CHANNEL_AUDIO, t2)
	_pair_track(t2, state2, group_channel_id)


func _has_instrument(ch_el: DawXml.El) -> bool:
	if ch_el == null or ch_el.child("Devices") == null:
		return false
	for d in ch_el.child("Devices").children:
		if d.get_attr("deviceRole") == "instrument":
			return true
	return false


func _make_track(node: DawXml.El, type: int, parent_track_id: int, color: Variant) -> Dictionary:
	var json: Dictionary = _TrackScript.new(_next_track_id).to_json()
	_next_track_id += 1
	json["name"] = node.get_attr("name", "Track")
	json["type"] = ["AUDIO", "INSTRUMENT", "FOLDER", "GROUP"][type]
	json["order"] = _next_sibling_order(parent_track_id)
	json["parent_track_id"] = parent_track_id
	json["default_channel_id"] = -1
	json["child_track_ids"] = []
	json["clip_instances"] = []
	json["automation_lanes"] = []
	if color != null:
		json["color"] = _color_json(color)
	_tracks_json.append(json)
	if parent_track_id >= 0:
		for t in _tracks_json:
			if t["id"] == parent_track_id:
				t["child_track_ids"].append(json["id"])
	var state := {"json": json, "chan": null}
	_track_state[node.get_attr("id")] = state
	return state


func _pair_track(track_state: Dictionary, chan_state: Dictionary, group_channel_id: int) -> void:
	track_state["chan"] = chan_state
	chan_state["track"] = track_state["json"]
	track_state["json"]["default_channel_id"] = chan_state["sid"]
	track_state["json"]["color_by_channel"] = true
	track_state["json"]["name_by_channel"] = true
	if group_channel_id >= 0:
		chan_state["group"] = group_channel_id


func _make_channel(ch_el: DawXml.El, name: String, color: Color, type: int, _track: Variant) -> Dictionary:
	var sid := _next_channel_id
	_next_channel_id += 1
	var json: Dictionary = _ChannelScript.new(sid).to_json()
	json["name"] = name
	json["color"] = _color_json(color)
	json["channel_type"] = ["INSTRUMENT", "AUDIO", "BUS", "GROUP"][type]
	json["order"] = _mixer_order
	_mixer_order += 1
	json["output_channel_id"] = 1
	json["send_channels"] = []
	json["devices"] = []
	json["child_channel_ids"] = []
	_channels_json.append(json)
	var state := {"el": ch_el, "sid": sid, "json": json, "sends": {}, "device_pos": {}, "track": null, "group": -1}
	_bind_mixer(ch_el, state)
	if ch_el != null:
		_chans[ch_el.get_attr("id")] = state
	return state


func _bind_master(ch_el: DawXml.El) -> void:
	var state := {"el": ch_el, "sid": DawEnums.MASTER_CHANNEL_ID, "json": _channels_json[0], "sends": {}, "device_pos": {}, "track": null, "group": -1}
	_bind_mixer(ch_el, state)
	_chans[ch_el.get_attr("id")] = state


## Volume, pan, mute and solo; registers the parameter ids automation can target.
func _bind_mixer(ch_el: DawXml.El, state: Dictionary) -> void:
	if ch_el == null:
		return
	var json: Dictionary = state["json"]
	var volume := ch_el.child("Volume")
	if volume != null:
		var gain := volume.get_float("value", 1.0)
		if DawUnits.linear_exceeds_max(gain):
			_report.add(TransferReport.VOLUME_CLAMPED, json["name"])
		json["volume"] = DawUnits.linear_to_db(gain)
		_targets[volume.get_attr("id")] = {"kind": "volume", "chan": state}
	var pan := ch_el.child("Pan")
	if pan != null:
		json["pan"] = DawUnits.normalized_to_pan(pan.get_float("value", 0.5))
		_targets[pan.get_attr("id")] = {"kind": "pan", "chan": state}
	var mute := ch_el.child("Mute")
	if mute != null:
		json["mute"] = mute.get_bool("value")
		_targets[mute.get_attr("id")] = {"kind": "mute", "chan": state}
	json["solo"] = ch_el.get_bool("solo")
	if ch_el.get_attr("audioChannels", "2") == "1":
		_report.add(TransferReport.MONO_CHANNEL, json["name"])


func _import_routing_and_sends() -> void:
	for xml_id in _chans:
		var state: Dictionary = _chans[xml_id]
		var ch_el: DawXml.El = state["el"]
		var json: Dictionary = state["json"]
		if state["sid"] == DawEnums.MASTER_CHANNEL_ID:
			continue
		var dest_el: DawXml.El = _ids.get(ch_el.get_attr("destination")) if ch_el.has_attr("destination") else null
		var dest: Variant = _chans.get(dest_el.get_attr("id")) if dest_el != null else null
		json["output_channel_id"] = dest["sid"] if dest != null else DawEnums.MASTER_CHANNEL_ID
		if state["group"] >= 0 and json["output_channel_id"] == state["group"]:
			json["parent_channel_id"] = state["group"]
		var sends := ch_el.child("Sends")
		if sends == null:
			continue
		for send in sends.children_named("Send"):
			var target_el: DawXml.El = _ids.get(send.get_attr("destination"))
			var target: Variant = _chans.get(target_el.get_attr("id")) if target_el != null else null
			if target == null or target["sid"] == state["sid"]:
				continue
			var vol_el := send.child("Volume")
			var gain := vol_el.get_float("value", 0.0) if vol_el != null else 0.0
			var enable_el := send.child("Enable")
			var enabled := enable_el.get_bool("value", true) if enable_el != null else true
			if not enabled and gain == 0.0:
				continue
			if DawUnits.linear_exceeds_max(gain):
				_report.add(TransferReport.SEND_CLAMPED, json["name"])
			json["send_channels"].append({
				"target_channel_id": target["sid"], "name": "Send", "amount": DawUnits.linear_to_db(gain),
				"pre_fader": send.get_attr("type", "post") == "pre", "muted": not enabled,
			})
			var index: int = json["send_channels"].size() - 1
			state["sends"][send.get_attr("id")] = index
			if vol_el != null:
				_targets[vol_el.get_attr("id")] = {"kind": "send", "chan": state, "index": index}
			var pan_el := send.child("Pan")
			if pan_el != null:
				_targets[pan_el.get_attr("id")] = {"kind": "send_pan", "chan": state}
			if enable_el != null:
				_targets[enable_el.get_attr("id")] = {"kind": "send_enable", "chan": state}


# ============================================================================
# Devices
# ============================================================================

func _asset_device(device_id: String) -> Object:
	var loop := Engine.get_main_loop() as SceneTree
	var service: Node = loop.root.get_node_or_null("AssetService") if loop else null
	return service.get_device(device_id) if service != null else null


func _import_devices() -> void:
	for xml_id in _chans:
		var state: Dictionary = _chans[xml_id]
		var devices := (state["el"] as DawXml.El).child("Devices")
		if devices == null:
			continue
		for el in devices.children:
			_import_device(el, state)


func _import_device(el: DawXml.El, state: Dictionary) -> void:
	var subject: String = state["json"]["name"]
	var device_name := el.get_attr("deviceName", el.get_attr("name"))
	if FORMAT_DEVICES.has(el.tag):
		_report.add(TransferReport.PLUGIN_FORMAT, subject, "%s %s" % [FORMAT_DEVICES[el.tag], device_name])
		return
	if el.tag in GENERIC_DEVICES:
		_report.add(TransferReport.GENERIC_DEVICE, subject, el.tag)
		return
	var json: Dictionary = {}
	var device: Object = null
	var position: int = state["json"]["devices"].size()
	if el.tag == "ClapPlugin":
		var clap_id := el.get_attr("deviceID")
		device = _asset_device(clap_id)
		if device == null:
			_report.add(TransferReport.CLAP_MISSING, subject, device_name)
			return
		json = _DeviceInstanceScript.new(device, state["sid"], position).to_json()
		var preset := _read_state_file(el)
		if not preset.is_empty():
			var unwrapped := ClapPreset.unwrap(preset)
			if unwrapped.ok and unwrapped.clap_id == clap_id:
				json["plugin_state"] = Marshalls.raw_to_base64(unwrapped.state)
			else:
				_report.add(TransferReport.STATE_MISMATCH, subject, device_name)
	elif el.tag == "BuiltinDevice" and el.get_attr("deviceID").begins_with(BUILTIN_PREFIX):
		var device_id := el.get_attr("deviceID").substr(BUILTIN_PREFIX.length())
		device = _asset_device(device_id)
		if device == null:
			_report.add(TransferReport.SONARA_DEVICE_MISSING, subject, device_id)
			return
		var text := _read_state_file(el).get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text) if text != "" else null
		if parsed is Dictionary:
			json = parsed
			json["device_id"] = device_id
			_fix_device_tree(json, state["sid"], position)
		else:
			json = _DeviceInstanceScript.new(device, state["sid"], position).to_json()
	else:
		_report.add(TransferReport.FOREIGN_BUILTIN, subject, device_name)
		return
	json["name"] = el.get_attr("name", json.get("name", ""))
	var enabled := el.child("Enabled")
	if enabled != null:
		json["enabled"] = enabled.get_bool("value", true)
		_targets[enabled.get_attr("id")] = {"kind": "device_enabled", "chan": state}
	state["json"]["devices"].append(json)
	state["device_pos"][el.get_attr("id")] = position
	var params := el.child("Parameters")
	if params != null:
		for p in params.children_named("RealParameter"):
			_targets[p.get_attr("id")] = {"kind": "device_param", "chan": state, "position": position,
				"param_id": int(p.get_float("parameterID", -1.0)), "device": device,
				"min": p.get_float("min", 0.0), "max": p.get_float("max", 1.0)}


## Channel id and position follow the import; embedded files are extracted and repointed.
func _fix_device_tree(json: Dictionary, channel_id: int, position: int) -> void:
	json["channel_id"] = channel_id
	json["position"] = position
	var path := str(json.get("loaded_file_path", ""))
	if path.begins_with("files/"):
		var extracted := _extract_slot(path)
		json["loaded_file_path"] = extracted
	var i := 0
	for child in json.get("children", []):
		if child is Dictionary:
			_fix_device_tree(child, channel_id, i)
			i += 1


## Extracts every file of the `files/<n>/` slot holding `zip_path` and returns the extracted
## path of `zip_path` ("" when extraction failed).
func _extract_slot(zip_path: String) -> String:
	var parts := zip_path.split("/")
	if parts.size() < 3:
		return _extract_entry(zip_path)
	var prefix := "%s/%s/" % [parts[0], parts[1]]
	for f in _zip.get_files():
		if f.begins_with(prefix) and not f.ends_with("/"):
			_extract_entry(f)
	return _extract_entry(zip_path)


func _read_state_file(el: DawXml.El) -> PackedByteArray:
	var state := el.child("State")
	if state == null:
		return PackedByteArray()
	var path := state.get_attr("path")
	if state.get_bool("external"):
		return FileAccess.get_file_as_bytes(_resolve_external(path))
	if not _safe_zip_path(path):
		return PackedByteArray()
	return _zip.read_file(path)


func _safe_zip_path(path: String) -> bool:
	return path != "" and not path.is_absolute_path() and not (".." in path.split("/"))


func _resolve_external(path: String) -> String:
	return path if path.is_absolute_path() else _file_path.get_base_dir().path_join(path)


## Extracts one archive entry under the audio folder; returns its absolute path or "".
func _extract_entry(zip_path: String) -> String:
	if _extracted.has(zip_path):
		return _extracted[zip_path]
	if not _safe_zip_path(zip_path) or not _zip.get_files().has(zip_path):
		return ""
	var dest := _audio_dir.path_join(zip_path)
	if DirAccess.make_dir_recursive_absolute(dest.get_base_dir()) != OK:
		_audio_dir_failed = true
		_fail("Cannot create the audio folder %s" % dest.get_base_dir())
		return ""
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		_audio_dir_failed = true
		_fail("Cannot write %s" % dest)
		return ""
	file.store_buffer(_zip.read_file(zip_path))
	file.close()
	_extracted[zip_path] = dest
	return dest


# ============================================================================
# Arrangement
# ============================================================================

## Walks Lanes/Clips/Points/Markers. `scope`: {track: track_state or null, unit: "beats"|"seconds"}.
func _walk_timeline(node: DawXml.El, scope: Dictionary) -> void:
	if _error != "":
		return
	var inner := scope.duplicate()
	if node.has_attr("timeUnit"):
		inner["unit"] = node.get_attr("timeUnit")
	if node.has_attr("track"):
		inner["track"] = _track_state.get(node.get_attr("track"))
		if inner["track"] == null:
			inner["track"] = {"json": null, "chan": null}
	for c in node.children:
		match c.tag:
			"Lanes":
				_walk_timeline(c, inner)
			"Clips":
				var clips_scope := inner.duplicate()
				if c.has_attr("timeUnit"):
					clips_scope["unit"] = c.get_attr("timeUnit")
				for clip in c.children_named("Clip"):
					_import_clip(clip, clips_scope)
			"Points":
				_import_points(c, inner)
			"Markers":
				_import_markers(c, inner)
			"Notes", "Audio", "Warps":
				pass  # loose content outside a Clip: nothing to place
	# TempoAutomation / TimeSignatureAutomation are read up front


func _import_markers(node: DawXml.El, scope: Dictionary) -> void:
	var unit := node.get_attr("timeUnit", scope["unit"])
	for m in node.children_named("Marker"):
		_markers_json.append({
			"id": _next_marker, "name": m.get_attr("name", "Marker"),
			"start_ticks": _to_ticks(m.get_float("time"), unit, 0), "duration_ticks": 0,
			"color": (_color_of(m, Color.DODGER_BLUE) as Color).to_html(false),
		})
		_next_marker += 1


func _import_scenes() -> void:
	var scenes := _root.child("Scenes")
	if scenes == null:
		return
	for scene in scenes.children_named("Scene"):
		var found: Array = []
		_find_all(scene, "Clip", found)
		if not found.is_empty():
			_report.add(TransferReport.SCENE_CLIP, scene.get_attr("name", "Scene"))


func _find_all(node: DawXml.El, tag: String, out: Array) -> void:
	for c in node.children:
		if c.tag == tag:
			out.append(c)
		_find_all(c, tag, out)


# ============================================================================
# Clips
# ============================================================================

## Follows `reference` to the shared content timeline, else the clip's own child timeline.
func _content_of(clip: DawXml.El) -> DawXml.El:
	if clip.has_attr("reference"):
		return _ids.get(clip.get_attr("reference"))
	for c in clip.children:
		if c.tag in ["Notes", "Warps", "Audio", "Clips", "Lanes", "Points"]:
			return c
	return null


## Ticks for a length `value` in `unit` starting at `at_tick` (beats are direct, seconds go
## through the tempo there).
func _delta_ticks(value: float, unit: String, at_tick: int) -> int:
	if unit == "seconds":
		return roundi(value * _bpm_at_tick(at_tick) / 60.0 * 960.0)
	return DawUnits.beats_to_ticks(value)


func _import_clip(clip: DawXml.El, scope: Dictionary) -> void:
	_place_clip(clip, {"track": scope["track"], "unit": scope["unit"], "base": 0, "window": null, "muted": false, "name": ""})


func _place_clip(clip: DawXml.El, ctx: Dictionary) -> void:
	if _error != "" or ctx["track"] == null:
		return
	var track_state: Dictionary = ctx["track"]
	if track_state["json"] == null:
		var bus: Variant = track_state["chan"]
		_report.add(TransferReport.BUS_CLIP, bus["json"]["name"] if bus != null else "")
		return
	var content := _content_of(clip)
	if content == null:
		return
	var unit: String = ctx["unit"]
	var time := clip.get_float("time")
	var start := _to_ticks(time, unit, 0)
	var content_unit := clip.get_attr("contentTimeUnit", unit)
	var length: int
	if clip.has_attr("duration"):
		length = _to_ticks(time + clip.get_float("duration"), unit, 0) - start
	else:
		length = _delta_ticks(clip.get_float("playStop") - clip.get_float("playStart"), content_unit, ctx["base"] + start)
	var visible_start := start
	var visible_end := start + length
	if ctx["window"] != null:
		visible_start = maxi(start, ctx["window"][0])
		visible_end = mini(start + length, ctx["window"][1])
		if visible_end <= visible_start:
			return
	var track_json: Dictionary = track_state["json"]
	var p := {
		"clip": clip, "ctx": ctx, "track": track_json, "unit": unit, "content_unit": content_unit,
		"name": clip.get_attr("name", ctx["name"]),
		"start": start, "length": length,
		"trim": visible_start - start,
		"song_start": ctx["base"] + visible_start,
		"song_length": visible_end - visible_start,
		"play_start": clip.get_float("playStart"),
		"muted": ctx["muted"] or not clip.get_bool("enable", true),
	}
	match content.tag:
		"Notes":
			_place_midi(p, content)
		"Warps":
			_place_warped_audio(p, content)
		"Audio":
			_place_bare_audio(p, content)
		"Clips":
			_place_nested(p, content)
		"Lanes":
			var notes := content.child("Notes")
			if content.child("Points") != null:
				_report.add(TransferReport.CLIP_AUTOMATION, track_json["name"])
			if notes != null:
				_place_midi(p, notes)
		"Points":
			_report.add(TransferReport.CLIP_AUTOMATION, track_json["name"])


func _new_clip_json(type: String, name: String, clip_el: DawXml.El) -> Dictionary:
	var json: Dictionary = _ClipScript.new("clip_imp_%d" % _next_clip).to_json()
	_next_clip += 1
	json["type"] = type
	json["name"] = name if name != "" else "Clip"
	json["midi_notes"] = []
	json["midi_events"] = []
	var color: Variant = _color_of(clip_el, null)
	if color != null:
		json["color"] = _color_json(color)
	_clips_json.append(json)
	return json


func _add_instance(p: Dictionary, clip_json: Dictionary, offset_ticks: int) -> void:
	var clip_el: DawXml.El = p["clip"]
	var inst: Dictionary = _InstanceScript.new("inst_imp_%d" % _next_instance, clip_json["id"]).to_json()
	_next_instance += 1
	var start: int = p["song_start"]
	var length: int = p["song_length"]
	var fade_unit := clip_el.get_attr("fadeTimeUnit", p["unit"])
	var fade_in := _delta_ticks(clip_el.get_float("fadeInTime"), fade_unit, start)
	var fade_out := _delta_ticks(clip_el.get_float("fadeOutTime"), fade_unit, start)
	if fade_in < 0:
		_report.add(TransferReport.CROSSFADE, p["track"]["name"])
		start += fade_in
		length -= fade_in
		fade_in = -fade_in
	if fade_out < 0:
		_report.add(TransferReport.CROSSFADE, p["track"]["name"])
		length -= fade_out
		fade_out = -fade_out
	inst["start_ticks"] = maxi(0, start)
	inst["duration_ticks"] = maxi(1, length)
	inst["clip_offset"] = maxi(0, offset_ticks + p["trim"])
	inst["muted"] = p["muted"]
	inst["fade_in_ticks"] = fade_in
	inst["fade_out_ticks"] = fade_out
	if clip_el.has_attr("loopStart") and clip_el.has_attr("loopEnd"):
		var loop_start := _delta_ticks(clip_el.get_float("loopStart"), p["content_unit"], start)
		var loop_end := _delta_ticks(clip_el.get_float("loopEnd"), p["content_unit"], start)
		inst["loop_enabled"] = true
		inst["loop_start_ticks"] = loop_start
		inst["loop_length_ticks"] = maxi(1, loop_end - loop_start)
	p["track"]["clip_instances"].append(inst)
	clip_json["content_length_ticks"] = maxi(int(clip_json["content_length_ticks"]), int(inst["clip_offset"]) + int(inst["duration_ticks"]))


# ---- MIDI ---------------------------------------------------------------

func _place_midi(p: Dictionary, notes: DawXml.El) -> void:
	var clip_json: Dictionary
	if _content_clips.has(notes):
		clip_json = _content_clips[notes]
	else:
		clip_json = _new_clip_json("MIDI", p["name"] if p["name"] != "" else p["track"]["name"], p["clip"])
		clip_json["content_length_ticks"] = 0
		_import_notes(clip_json, notes, p)
		_content_clips[notes] = clip_json
	var offset := _delta_ticks(p["play_start"], p["content_unit"], p["song_start"])
	_add_instance(p, clip_json, offset)


func _import_notes(clip_json: Dictionary, notes: DawXml.El, p: Dictionary) -> void:
	var unit := notes.get_attr("timeUnit", p["content_unit"])
	var subject: String = p["track"]["name"]
	var end_tick := 0
	for n in notes.children_named("Note"):
		var start := _to_ticks(n.get_float("time"), unit, 0)
		var duration := maxi(1, _to_ticks(n.get_float("time") + n.get_float("duration"), unit, 0) - start)
		var channel := int(n.get_float("channel"))
		if channel != 0:
			_report.add(TransferReport.NOTE_CHANNEL, subject, str(channel))
		if n.has_attr("rel") and absf(n.get_float("rel") - n.get_float("vel", 0.787402)) > 1e-4:
			_report.add(TransferReport.NOTE_RELEASE, subject)
		if not n.children.is_empty():
			_report.add(TransferReport.NOTE_EXPRESSION, subject)
		clip_json["midi_notes"].append({
			"id": _next_note_id, "note": clampi(int(n.get_float("key")), 0, 127),
			"velocity": DawUnits.normalized_to_velocity(n.get_float("vel", 100.0 / 127.0)),
			"start_tick": start, "duration_ticks": duration,
		})
		_next_note_id += 1
		end_tick = maxi(end_tick, start + duration)
	clip_json["content_length_ticks"] = end_tick


# ---- Audio --------------------------------------------------------------

## Absolute path of an `Audio` element's file, extracted from the archive when embedded.
## Returns "" (and reports) when it can't be found.
func _audio_file(audio: DawXml.El, subject: String) -> String:
	var file := audio.child("File")
	if file == null:
		return ""
	var path := file.get_attr("path")
	if file.get_bool("external"):
		var resolved := _resolve_external(path)
		if not FileAccess.file_exists(resolved):
			_report.add(TransferReport.AUDIO_MISSING, subject, path.get_file())
			return ""
		return resolved
	var extracted := _extract_entry(path)
	if extracted == "" and _error == "":
		_report.add(TransferReport.AUDIO_MISSING, subject, path.get_file())
	return extracted


func _new_audio_clip(p: Dictionary, audio: DawXml.El, path: String, recorded_bpm: float) -> Dictionary:
	var json := _new_clip_json("AUDIO", p["name"] if p["name"] != "" else p["track"]["name"], p["clip"])
	var duration := audio.get_float("duration")
	var rate := int(audio.get_float("sampleRate", 44100.0))
	json["audio_file_path"] = path
	json["audio_sample_rate"] = rate
	json["audio_channels"] = int(audio.get_float("channels", 2.0))
	json["audio_frames"] = roundi(duration * float(rate))
	json["audio_duration_seconds"] = duration
	json["recorded_bpm"] = recorded_bpm
	json["content_length_ticks"] = 0
	return json


func _place_warped_audio(p: Dictionary, warps: DawXml.El) -> void:
	var audio := warps.child("Audio")
	var warp_els := warps.children_named("Warp")
	if audio == null or warp_els.size() < 2:
		return
	var subject: String = p["track"]["name"]
	var first := warp_els[0]
	var last := warp_els[warp_els.size() - 1]
	var d_beats := last.get_float("time") - first.get_float("time")
	var d_seconds := last.get_float("contentTime") - first.get_float("contentTime")
	if d_beats <= 0.0 or d_seconds <= 0.0:
		return
	if warp_els.size() > 2:
		_report.add(TransferReport.WARP_APPROXIMATED, subject)
	var bpm := 60.0 * d_beats / d_seconds
	var clip_json: Dictionary
	if _content_clips.has(warps):
		clip_json = _content_clips[warps]
	else:
		var path := _audio_file(audio, subject)
		if path == "":
			return
		clip_json = _new_audio_clip(p, audio, path, bpm)
		_content_clips[warps] = clip_json
	# Beat at which the file's second 0 would sit on the warps timeline.
	var origin_beats := first.get_float("time") - first.get_float("contentTime") * bpm / 60.0
	var offset := DawUnits.beats_to_ticks(p["play_start"] - origin_beats)
	_add_instance(p, clip_json, offset)


func _place_bare_audio(p: Dictionary, audio: DawXml.El) -> void:
	var subject: String = p["track"]["name"]
	var path_needed := not _content_clips.has(audio)
	var clip_json: Dictionary
	var stretch_bpm: float
	if p["content_unit"] == "seconds":
		var play_start: float = p["play_start"]
		var play_stop: float = p["clip"].get_float("playStop", audio.get_float("duration"))
		var seconds: float = play_stop - play_start
		if seconds <= 0.0:
			return
		stretch_bpm = 60.0 * DawUnits.ticks_to_beats(p["length"]) / seconds
	else:
		stretch_bpm = _bpm_at_tick(p["song_start"])
	if path_needed:
		var path := _audio_file(audio, subject)
		if path == "":
			return
		clip_json = _new_audio_clip(p, audio, path, stretch_bpm)
		_content_clips[audio] = clip_json
	else:
		clip_json = _content_clips[audio]
	var offset := DawUnits.beats_to_ticks(p["play_start"] * clip_json["recorded_bpm"] / 60.0) if p["content_unit"] == "seconds" else DawUnits.beats_to_ticks(p["play_start"])
	_add_instance(p, clip_json, offset)


# ---- Nested clips -------------------------------------------------------

## A clip holding more clips (Bitwig wraps every audio event this way) becomes its children,
## shifted to song time and trimmed to the outer clip's window.
func _place_nested(p: Dictionary, clips: DawXml.El) -> void:
	var clip: DawXml.El = p["clip"]
	var play_start := _delta_ticks(p["play_start"], p["content_unit"], p["song_start"])
	var window_end: int = play_start + p["length"]
	if clip.has_attr("loopStart") and clip.has_attr("loopEnd"):
		var loop_end := _delta_ticks(clip.get_float("loopEnd"), p["content_unit"], p["song_start"])
		if loop_end < window_end:
			_report.add(TransferReport.NESTED_LOOP, p["track"]["name"])
			window_end = loop_end
	var ctx: Dictionary = p["ctx"]
	var inner := {
		"track": ctx["track"], "unit": p["content_unit"],
		"base": ctx["base"] + p["start"] - play_start,
		"window": [play_start, window_end],
		"muted": p["muted"], "name": p["name"],
	}
	for inner_clip in clips.children_named("Clip"):
		_place_clip(inner_clip, inner)


# ============================================================================
# Automation
# ============================================================================

const UNSUPPORTED_KINDS: Dictionary = {
	"mute": "mute", "send_pan": "send pan", "send_enable": "send mute", "device_enabled": "device bypass",
}


func _import_points(node: DawXml.El, scope: Dictionary) -> void:
	var target_el := node.child("Target")
	if target_el == null:
		return
	var track_state: Variant = scope["track"]
	var scope_name := ""
	if track_state != null and track_state["json"] != null:
		scope_name = track_state["json"]["name"]
	if target_el.has_attr("expression"):
		_report.add(TransferReport.EXPRESSION_AUTOMATION, scope_name, target_el.get_attr("expression"))
		return
	var target: Variant = _targets.get(target_el.get_attr("parameter"))
	if target == null or target["kind"] in ["tempo", "signature"]:
		return
	var kind: String = target["kind"]
	var chan: Dictionary = target["chan"]
	var subject: String = chan["json"]["name"]
	if UNSUPPORTED_KINDS.has(kind):
		_report.add(TransferReport.UNSUPPORTED_AUTOMATION, subject, UNSUPPORTED_KINDS[kind])
		return
	var track_json: Variant = chan["track"]
	if track_json == null:
		_report.add(TransferReport.UNSUPPORTED_AUTOMATION, subject, "automation on a bus")
		return
	var sonara_target := ""
	var map: Callable
	match kind:
		"volume", "send":
			sonara_target = "channel/volume" if kind == "volume" else "channel/send/%d" % target["index"]
			if node.get_attr("unit", "linear") == "decibel":
				map = func(v: float) -> float: return AutomationTarget.db_to_normalized(v)
			else:
				map = func(v: float) -> float: return AutomationTarget.db_to_normalized(DawUnits.linear_to_db(v))
		"pan":
			sonara_target = "channel/pan"
			map = func(v: float) -> float: return clampf(v, 0.0, 1.0)
		"device_param":
			sonara_target = "device/%d/param/%d" % [target["position"], target["param_id"]]
			var param: Object = target["device"].get_parameter(target["param_id"]) if target["device"] != null else null
			var lo: float = target["min"]
			var hi: float = target["max"]
			map = func(v: float) -> float: return DawUnits.real_to_param(param, v, lo, hi)
		_:
			return
	var unit := node.get_attr("timeUnit", scope["unit"])
	var source: Array = []
	for rp in node.children_named("RealPoint"):
		source.append({"tick": _to_ticks(rp.get_float("time"), unit, 0), "value": rp.get_float("value"),
			"step": rp.get_attr("interpolation", "hold") == "hold", "tension": 0.0})
	if source.is_empty():
		return
	source.sort_custom(func(a, b): return a["tick"] < b["tick"])
	var points := DawUnits.resample(source, map, 0.01)
	for i in range(points.size() - 2, -1, -1):
		if points[i]["tick"] >= points[i + 1]["tick"]:
			points[i]["tick"] = points[i + 1]["tick"] - 1
	var lane_number: int = _lane_counter.get(track_json["id"], 0)
	_lane_counter[track_json["id"]] = lane_number + 1
	var lane: Dictionary = _LaneScript.new("lane%d" % lane_number).to_json()
	lane["target"] = sonara_target
	lane["points"] = []
	var point_id := 1
	for pt in points:
		if pt["tick"] < 0:
			continue
		lane["points"].append({"id": point_id, "tick": pt["tick"], "value": clampf(pt["value"], 0.0, 1.0),
			"curve": "step" if pt["step"] else "linear", "tension": 0.0})
		point_id += 1
	track_json["automation_lanes"].append(lane)
