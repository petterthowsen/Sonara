# test_dawproject_export.gd
# Headless tests for DawProjectExporter: container, structure, routing, clips, automation and
# devices. Outputs are left in user://dawproject_export/ for validate_dawproject.sh (xmllint).
#
# Project and friends reference autoloads, so they are loaded with load() inside run_tests().
# Run: godot --headless --path Godot -s tests/test_dawproject_export.gd -- --test
extends TestBase

const OUT_DIR := "user://dawproject_export"

var _project_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _lane_script: GDScript
var _target_script: GDScript
var _marker_script: GDScript
var _param_script: GDScript


func suite_name() -> String:
	return "DAWproject export tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_target_script = load("res://data/AutomationTarget.gd")
	_marker_script = load("res://data/SongMarker.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_test_enum_mirrors()
	await _test_structure_and_routing()
	await _test_failure_leaves_no_file()
	await _test_clips()
	await _test_automation()
	await _test_devices()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _out(name: String) -> String:
	return ProjectSettings.globalize_path(OUT_DIR).path_join(name)


## Export and return `{result, entries: {path: bytes}, xml: DawXml.El}`.
func _export(project: Object, name: String) -> Dictionary:
	var path := _out(name)
	var exporter := DawProjectExporter.new()
	var result: Dictionary = await exporter.export_project(project, path)
	var out := {"result": result, "entries": {}, "xml": null}
	if not result.ok:
		return out
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return out
	for f in zip.get_files():
		out.entries[f] = zip.read_file(f)
	zip.close()
	if out.entries.has("project.xml"):
		out.xml = DawXml.parse(out.entries["project.xml"]).root
	return out


func _by_attr(nodes: Array, attr: String, value: String) -> DawXml.El:
	for n in nodes:
		if n.get_attr(attr) == value:
			return n
	return null


func _structure_tracks(xml: DawXml.El) -> Array[DawXml.El]:
	return xml.child("Structure").children_named("Track")


func _find_track(xml: DawXml.El, name: String) -> DawXml.El:
	return _find_track_in(xml.child("Structure"), name)


func _find_track_in(node: DawXml.El, name: String) -> DawXml.El:
	for t in node.children_named("Track"):
		if t.get_attr("name") == name:
			return t
		var hit := _find_track_in(t, name)
		if hit != null:
			return hit
	return null


func _lane_for(xml: DawXml.El, track: DawXml.El) -> DawXml.El:
	for l in xml.child("Arrangement").child("Lanes").children_named("Lanes"):
		if l.get_attr("track") == track.get_attr("id"):
			return l
	return null


func _test_enum_mirrors() -> void:
	var track: GDScript = load("res://data/Track.gd")
	var channel: GDScript = load("res://data/Channel.gd")
	_assert(track.TrackType.AUDIO == DawEnums.TRACK_AUDIO and track.TrackType.INSTRUMENT == DawEnums.TRACK_INSTRUMENT \
		and track.TrackType.FOLDER == DawEnums.TRACK_FOLDER and track.TrackType.GROUP == DawEnums.TRACK_GROUP, "DawEnums track types match Track.TrackType")
	_assert(channel.ChannelType.INSTRUMENT == DawEnums.CHANNEL_INSTRUMENT and channel.ChannelType.AUDIO == DawEnums.CHANNEL_AUDIO \
		and channel.ChannelType.BUS == DawEnums.CHANNEL_BUS and channel.ChannelType.GROUP == DawEnums.CHANNEL_GROUP, "DawEnums channel types match Channel.ChannelType")
	_assert(channel.PanMode.STEREO_COMBINED == DawEnums.PAN_COMBINED and channel.PanMode.STEREO_DUAL == DawEnums.PAN_DUAL \
		and channel.PanMode.STEREO_BALANCE == DawEnums.PAN_BALANCE and channel.PanMode.MONO == DawEnums.PAN_MONO, "DawEnums pan modes match Channel.PanMode")
	var clip: GDScript = load("res://data/Clip.gd")
	_assert(clip.ClipType.AUDIO == DawEnums.CLIP_AUDIO and clip.ClipType.MIDI == DawEnums.CLIP_MIDI, "DawEnums clip types match Clip.ClipType")
	var device: GDScript = load("res://data/Device.gd")
	_assert(device.DeviceType.BuiltIn == DawEnums.DEVICE_BUILTIN and device.DeviceType.CLAP == DawEnums.DEVICE_CLAP \
		and device.DeviceCategory.Instrument == DawEnums.CATEGORY_INSTRUMENT and device.DeviceCategory.Effect == DawEnums.CATEGORY_EFFECT, "DawEnums device enums match Device")


func _device(device_id: String, type: int, category: int = 0) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id.get_slice(".", device_id.get_slice_count(".") - 1), category, type)
		registry._devices[device_id] = device
	return device


func _add_device(ch: Object, device: Object) -> Object:
	var inst: Object = _device_instance_script.new(device, ch.id, ch.devices.size())
	ch.add_device(inst)
	return inst


# ---------------------------------------------------------------------------
# T-007
# ---------------------------------------------------------------------------

func _test_structure_and_routing() -> void:
	var project: Object = _project_script.new()
	project.project_name = "My Song"
	project.tempo = 137.5
	project.time_numerator = 7
	project.time_denominator = 8
	var folder: Object = project.create_folder_track("Drums").track
	var group: Object = project.create_group_track("Kit").track
	var kick: Dictionary = project.create_instrument_track("Kick")
	var snare: Dictionary = project.create_audio_track("Snare")
	project.place_track(group, folder.id)
	project.place_track(kick.track, group.id)
	project.place_track(snare.track, group.id)
	var fx: Object = project.create_bus_channel("Reverb")
	var sub: Object = project.create_bus_channel("Sub")
	kick.channel.set_volume(-6.0)
	kick.channel.set_pan(-0.5)
	kick.channel.mute = true
	kick.channel.solo = true
	kick.channel.add_send(fx.id, -12.0, true)
	snare.channel.output_channel_id = sub.id
	var before: Dictionary = project.to_json()

	var exported := await _export(project, "structure.dawproject")
	_assert(exported.result.ok, "export succeeds: %s" % exported.result.error)
	_assert(exported.entries.has("project.xml") and exported.entries.has("metadata.xml"), "both container entries present")
	_assert(not FileAccess.file_exists(_out("structure.dawproject.partial")), "no .partial left behind")
	var xml: DawXml.El = exported.xml
	_assert(xml != null and xml.tag == "Project" and xml.get_attr("version") == "1.0", "root is Project 1.0")
	_assert(xml.child("Application").get_attr("name") == "Sonara", "Application name is Sonara")
	var meta: DawXml.El = DawXml.parse(exported.entries["metadata.xml"]).root
	_assert(meta.child("Title").text == "My Song", "Title is the project name")
	var transport: DawXml.El = xml.child("Transport")
	_assert(transport.child("Tempo").get_float("value") == 137.5 and transport.child("Tempo").get_attr("unit") == "bpm", "tempo 137.5 bpm")
	_assert(transport.child("TimeSignature").get_attr("numerator") == "7" and transport.child("TimeSignature").get_attr("denominator") == "8", "time signature 7/8")

	# Nesting: folder -> group -> two tracks.
	var top: Array[DawXml.El] = _structure_tracks(xml)
	var f_el := _by_attr(top, "name", "Drums")
	_assert(f_el != null and f_el.get_attr("contentType") == "tracks", "folder is a tracks Track")
	var g_el := _by_attr(f_el.children_named("Track"), "name", "Kit")
	_assert(g_el != null and g_el.get_attr("contentType") == "tracks", "group nests in the folder")
	_assert(g_el.child("Channel") != null and g_el.child("Channel").get_attr("role") == "submix", "group channel is a submix")
	_assert(g_el.children_named("Track").size() == 2, "group holds two tracks")
	var k_el := _by_attr(g_el.children_named("Track"), "name", "Kick")
	var s_el := _by_attr(g_el.children_named("Track"), "name", "Snare")
	_assert(k_el.get_attr("contentType") == "notes" and s_el.get_attr("contentType") == "audio", "content types notes/audio")

	# Channel values and roles.
	var k_ch: DawXml.El = k_el.child("Channel")
	_assert(absf(k_ch.child("Volume").get_float("value") - 0.501187) < 1e-5, "volume -6 dB -> 0.501187")
	_assert(k_ch.child("Pan").get_float("value") == 0.25, "pan -0.5 -> 0.25")
	_assert(k_ch.child("Mute").get_bool("value") and k_ch.get_bool("solo"), "mute and solo")
	_assert(k_ch.get_attr("role") == "regular", "track channel is regular")
	var fx_track := _find_track(xml, "Reverb")
	var sub_track := _find_track(xml, "Sub")
	_assert(fx_track != null and fx_track.child("Channel").get_attr("role") == "effect", "send-only bus is an effect")
	_assert(sub_track != null and sub_track.child("Channel").get_attr("role") == "submix", "routed-into bus is a submix")
	_assert(fx_track.get_attr("contentType") == "audio", "bus is an audio Track")
	var master_el: DawXml.El = _structure_tracks(xml).back()
	_assert(master_el.child("Channel").get_attr("role") == "master" and not master_el.child("Channel").has_attr("destination"), "master written last with role master")
	var master_id: String = master_el.child("Channel").get_attr("id")
	_assert(fx_track.child("Channel").get_attr("destination") == master_id, "bus routes to master")
	_assert(s_el.child("Channel").get_attr("destination") == sub_track.child("Channel").get_attr("id"), "snare routes to the Sub bus")

	# Send.
	var send: DawXml.El = k_ch.child("Sends").child("Send")
	_assert(send.get_attr("destination") == fx_track.child("Channel").get_attr("id"), "send destination is the bus channel")
	_assert(send.get_attr("type") == "pre", "pre-fader send")
	_assert(absf(send.child("Volume").get_float("value") - DawUnits.db_to_linear(-12.0)) < 1e-5 and send.child("Volume").get_float("max") == 1.0, "send volume linear, max 1")
	_assert(send.child("Enable").get_bool("value"), "send enabled")

	# Project untouched.
	_assert(project.to_json() == before, "export leaves project.to_json() unchanged")


func _test_failure_leaves_no_file() -> void:
	var project: Object = _project_script.new()
	var exporter := DawProjectExporter.new()
	var path := "/proc/nonexistent_dir/x.dawproject"
	var result: Dictionary = await exporter.export_project(project, path)
	_assert(not result.ok and result.error.contains(path), "unwritable target returns an error naming the path")
	_assert(not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".partial"), "no file left behind")


# ---------------------------------------------------------------------------
# T-008
# ---------------------------------------------------------------------------

## A tiny valid 16-bit mono WAV of `frames` frames at 8 kHz.
func _write_wav(path: String, frames: int) -> void:
	var data := PackedByteArray()
	data.resize(frames * 2)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_utf8_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_utf8_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(8000)
	f.store_32(16000)
	f.store_16(2)
	f.store_16(16)
	f.store_buffer("data".to_utf8_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()


func _make_midi_clip(project: Object, name: String) -> Object:
	var clip: Object = project.create_clip(name, _clip_script.ClipType.MIDI)
	clip.content_length_ticks = 3840
	for i in 4:
		var n: Object = clip.add_midi_note(project.allocate_note_id(), 60 + i, MidiNoteData.from_midi_velocity(100), i * 960, 960)
		if i == 1:
			n.release = 0.2
	return clip


func _test_clips() -> void:
	var project: Object = _project_script.new()
	var lead: Dictionary = project.create_instrument_track("Lead")
	var loop_track: Dictionary = project.create_audio_track("Loop")
	var midi_clip: Object = _make_midi_clip(project, "Riff")
	var t: Object = lead.track
	t.create_clip_instance(midi_clip, 0, 3840)
	t.create_clip_instance(midi_clip, 3840, 3840)
	t.create_clip_instance(midi_clip, 7680, 3840)
	var transposed: Object = t.create_clip_instance(midi_clip, 11520, 3840)
	transposed.transpose = 2
	transposed.gain_offset = -3.0
	var other_clip: Object = _make_midi_clip(project, "Riff 2")
	var muted: Object = t.create_clip_instance(other_clip, 15360, 1920)
	muted.muted = true
	muted.clip_offset = 960
	muted.loop_enabled = true
	muted.loop_start_ticks = 0
	muted.loop_length_ticks = 960
	muted.transpose = 0

	var wav := "user://dawproject_export/loop.wav"
	_write_wav(wav, 16000)  # 2.0 s
	var wav_abs := ProjectSettings.globalize_path(wav)
	var audio_clip: Object = project.create_clip("Loop", _clip_script.ClipType.AUDIO)
	audio_clip.audio_file_path = wav_abs
	audio_clip.recorded_bpm = 120.0
	audio_clip.set_audio_metadata(8000, 1, 16000, 2.0)
	var audio_clip_2: Object = project.create_clip("Loop 2", _clip_script.ClipType.AUDIO)
	audio_clip_2.audio_file_path = wav_abs
	audio_clip_2.recorded_bpm = 120.0
	audio_clip_2.set_audio_metadata(8000, 1, 16000, 2.0)
	loop_track.track.create_clip_instance(audio_clip, 0, 3840)
	loop_track.track.create_clip_instance(audio_clip_2, 3840, 3840)

	var marker: Object = project.create_marker(1920, 960, "Verse")
	marker.color = Color("ff8800")
	var plain: Object = project.create_marker(0, 0, "Intro")
	plain.duration_ticks = 0
	project.add_marker(marker)
	project.add_marker(plain)

	var exported := await _export(project, "clips.dawproject")
	_assert(exported.result.ok, "clip export succeeds: %s" % exported.result.error)
	var xml: DawXml.El = exported.xml
	var lead_el := _find_track(xml, "Lead")
	var clips: DawXml.El = _lane_for(xml, lead_el).child("Clips")
	var clip_els := clips.children_named("Clip")
	_assert(clip_els.size() == 5, "five clip instances on Lead (got %d)" % clip_els.size())
	var with_id := 0
	var refs := 0
	for c in clip_els:
		if c.has_attr("reference"):
			refs += 1
		elif c.child("Notes") != null and c.child("Notes").has_attr("id"):
			with_id += 1
	_assert(with_id == 1 and refs == 2, "three shared instances: one Notes id and two references (id %d, refs %d)" % [with_id, refs])
	var first_notes: DawXml.El = clip_els[0].child("Notes")
	_assert(clip_els[1].get_attr("reference") == first_notes.get_attr("id"), "references point at the Notes id")
	_assert(first_notes.children_named("Note").size() == 4, "4 notes")
	var note0: DawXml.El = first_notes.children_named("Note")[0]
	_assert(note0.get_attr("key") == "60" and note0.get_float("time") == 0.0 and note0.get_float("duration") == 1.0 and note0.get_attr("channel") == "0", "note key/time/duration/channel")
	_assert(absf(note0.get_float("vel") - 100.0 / 127.0) < 1e-5, "velocity 100 -> 0.787402")
	_assert(not note0.has_attr("rel"), "a default release is not written")
	_assert(absf(first_notes.children_named("Note")[1].get_float("rel") - 0.2) < 1e-6, "a non-default release is written as rel")
	var tr_el: DawXml.El = clip_els[3]
	_assert(not tr_el.has_attr("reference") and tr_el.child("Notes") != null and not tr_el.child("Notes").has_attr("id"), "transposed instance writes inline notes")
	_assert(tr_el.child("Notes").children_named("Note")[0].get_attr("key") == "62", "notes transposed by 2")
	var mu_el: DawXml.El = clip_els[4]
	_assert(not mu_el.get_bool("enable", true), "muted instance has enable=false")
	_assert(mu_el.get_float("playStart") == 1.0 and mu_el.get_float("loopStart") == 0.0 and mu_el.get_float("loopEnd") == 1.0, "left trim and loop region")
	_assert(exported.result.report.count_of(TransferReport.CLIP_TRANSPOSE) == 1, "one transpose report entry")
	_assert(exported.result.report.count_of(TransferReport.CLIP_GAIN_OFFSET) == 1, "one gain offset report entry")

	# Audio: one copy of the file; warps at 120 BPM.
	var wavs := 0
	for f in exported.entries:
		if f.ends_with(".wav"):
			wavs += 1
	_assert(wavs == 1, "one WAV copy in the ZIP for two clips (got %d)" % wavs)
	var loop_el := _find_track(xml, "Loop")
	var audio_clips: Array[DawXml.El] = _lane_for(xml, loop_el).child("Clips").children_named("Clip")
	var warps: DawXml.El = audio_clips[0].child("Warps")
	_assert(warps.get_attr("contentTimeUnit") == "seconds" and warps.get_attr("timeUnit") == "beats", "Warps units")
	var warp_els := warps.children_named("Warp")
	_assert(warp_els.size() == 2 and warp_els[0].get_float("time") == 0.0 and warp_els[0].get_float("contentTime") == 0.0, "first warp (0, 0)")
	_assert(absf(warp_els[1].get_float("time") - 4.0) < 1e-6 and absf(warp_els[1].get_float("contentTime") - 2.0) < 1e-6, "second warp (B, B x 0.5) = (4, 2)")
	var audio_el: DawXml.El = warps.child("Audio")
	_assert(audio_el.get_attr("sampleRate") == "8000" and audio_el.get_float("duration") == 2.0 and audio_el.get_attr("channels") == "1", "Audio attributes")
	_assert(exported.entries.has(audio_el.child("File").get_attr("path")), "Audio File path exists in the ZIP")

	# Markers.
	var markers: DawXml.El = xml.child("Arrangement").child("Markers")
	_assert(markers.children_named("Marker").size() == 2, "two markers")
	var verse := _by_attr(markers.children_named("Marker"), "name", "Verse")
	_assert(verse.get_float("time") == 2.0 and verse.get_attr("color").to_lower() == "#ff8800", "marker time and color")
	_assert(exported.result.report.count_of(TransferReport.MARKER_DURATION) == 1, "marker with a duration is reported (Intro has none)")


# ---------------------------------------------------------------------------
# T-009
# ---------------------------------------------------------------------------

func _test_automation() -> void:
	var project: Object = _project_script.new()
	project.tempo_map.add_point(0, 100.0)
	project.tempo_map.add_point(3840, 100.0)
	project.tempo_map.add_point(7680, 150.0)
	project.time_signature_map.add_change(5, 7, 8)
	var a: Dictionary = project.create_instrument_track("Synth")
	var bus: Object = project.create_bus_channel("Verb")
	a.channel.add_send(bus.id, 0.0)
	var vol: Object = _lane_script.new("lane0", _target_script.channel_volume())
	vol.add_point(0, 0.0)
	vol.add_point(3840, 60.0 / 72.0)  # 0 dB
	vol.add_point(7680, 0.5, 1)       # STEP point
	vol.add_point(8640, 0.9)
	a.track.add_automation_lane(vol)
	var pan: Object = _lane_script.new("lane1", _target_script.channel_pan())
	pan.add_point(0, 0.5)
	pan.add_point(3840, 1.0)
	a.track.add_automation_lane(pan)
	var send: Object = _lane_script.new("lane2", _target_script.send_amount(0))
	send.add_point(0, 0.0)
	send.add_point(3840, 60.0 / 72.0)
	a.track.add_automation_lane(send)

	var exported := await _export(project, "automation.dawproject")
	_assert(exported.result.ok, "automation export succeeds: %s" % exported.result.error)
	var xml: DawXml.El = exported.xml
	var arrangement: DawXml.El = xml.child("Arrangement")
	var tempo: DawXml.El = arrangement.child("TempoAutomation")
	var tp := tempo.children_named("RealPoint")
	_assert(tp.size() == 3, "3-point tempo map -> 3 RealPoints")
	_assert(tp[2].get_float("time") == 8.0 and tp[2].get_float("value") == 150.0, "last tempo point at beat 8, 150 bpm")
	_assert(tempo.child("Target").get_attr("parameter") == xml.child("Transport").child("Tempo").get_attr("id"), "tempo target is the Tempo parameter")
	var sig: DawXml.El = arrangement.child("TimeSignatureAutomation")
	var sp := sig.children_named("TimeSignaturePoint")
	_assert(sp.size() == 1 and sp[0].get_float("time") == 16.0 and sp[0].get_attr("numerator") == "7" and sp[0].get_attr("denominator") == "8", "7/8 at bar 5 -> beat 16")

	var synth_el := _find_track(xml, "Synth")
	var lanes := _lane_for(xml, synth_el)
	var by_target := {}
	for pts in lanes.children_named("Points"):
		by_target[pts.child("Target").get_attr("parameter")] = pts
	var ch_el: DawXml.El = synth_el.child("Channel")
	var vol_pts: DawXml.El = by_target[ch_el.child("Volume").get_attr("id")]
	_assert(vol_pts.get_attr("unit") == "linear", "volume lane in linear unit")
	var vps := vol_pts.children_named("RealPoint")
	_assert(vps[0].get_float("value") == 0.0, "-60 dB lane start -> gain 0")
	_assert(vps.size() > 4, "curved dB->gain ramp gains extra points (got %d)" % vps.size())
	var found_hold := false
	for p in vps:
		if p.get_attr("interpolation") == "hold":
			found_hold = true
			_assert(absf(p.get_float("time") - 8.0) < 1e-6, "hold point at the STEP tick")
	_assert(found_hold, "STEP point -> hold")
	var pan_pts: DawXml.El = by_target[ch_el.child("Pan").get_attr("id")]
	_assert(pan_pts.get_attr("unit") == "normalized" and pan_pts.children_named("RealPoint").size() == 2, "pan lane: normalized, straight line = 2 points")
	var send_pts: DawXml.El = by_target[ch_el.child("Sends").child("Send").child("Volume").get_attr("id")]
	_assert(send_pts != null, "send lane targets the send Volume id")


# ---------------------------------------------------------------------------
# T-010
# ---------------------------------------------------------------------------

func _test_devices() -> void:
	var project: Object = _project_script.new()
	var clap_dev := _device("test.clap.Synth", DawEnums.DEVICE_CLAP, DawEnums.CATEGORY_INSTRUMENT)
	var cutoff: Object = _param_script.new(3, "Cutoff")
	cutoff.min_value = 20.0
	cutoff.max_value = 20000.0
	clap_dev.add_parameter(cutoff)
	var a: Dictionary = project.create_instrument_track("Pad")
	var clap: Object = _add_device(a.channel, clap_dev)
	var blob := PackedByteArray()
	for i in 300:
		blob.append((i * 5) % 256)
	clap.plugin_state = blob
	clap.set_parameter_normalized(3, 0.5)
	var no_state_dev := _device("test.clap.Fx", DawEnums.DEVICE_CLAP, DawEnums.CATEGORY_EFFECT)
	_add_device(a.channel, no_state_dev)
	var lane: Object = _lane_script.new("lane0", _target_script.device_param([0], 3))
	lane.add_point(0, 0.0)
	lane.add_point(3840, 1.0)
	a.track.add_automation_lane(lane)

	var poly := _device("polysynth", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_INSTRUMENT)
	var delay := _device("delay", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_EFFECT)
	var b: Dictionary = project.create_instrument_track("Bass")
	var poly_inst: Object = _add_device(b.channel, poly)
	var mod = load("res://data/Modulator.gd").new()
	mod.mod_id = 0
	mod.kind = "adsr"
	mod.name = "Filter Env"
	mod.routes = {"param/31": 0.5}
	poly_inst.modulators.append(mod)
	_add_device(b.channel, delay)
	var sampler_dev := _device("sampler", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_INSTRUMENT)
	var c: Dictionary = project.create_instrument_track("Perc")
	var sampler: Object = _add_device(c.channel, sampler_dev)
	var pad_wav := ProjectSettings.globalize_path("user://dawproject_export/pad.wav")
	_write_wav("user://dawproject_export/pad.wav", 800)
	sampler.loaded_file_path = pad_wav

	var exported := await _export(project, "devices.dawproject")
	_assert(exported.result.ok, "device export succeeds: %s" % exported.result.error)
	var xml: DawXml.El = exported.xml
	var pad_ch: DawXml.El = _find_track(xml, "Pad").child("Channel")
	var devices: Array = pad_ch.child("Devices").children
	var clap_el: DawXml.El = devices[0]
	_assert(clap_el.tag == "ClapPlugin" and clap_el.get_attr("deviceID") == "test.clap.Synth" and clap_el.get_attr("deviceRole") == "instrument", "ClapPlugin with id and instrument role")
	var preset_path: String = clap_el.child("State").get_attr("path")
	_assert(exported.entries.has(preset_path) and preset_path.ends_with(".clap-preset"), "State file present")
	var unwrapped: Dictionary = ClapPreset.unwrap(exported.entries[preset_path])
	_assert(unwrapped.ok and unwrapped.clap_id == "test.clap.Synth" and unwrapped.state == blob, "preset unwraps to the same state bytes")
	var rp := clap_el.child("Parameters").children_named("RealParameter")
	_assert(rp.size() == 1 and rp[0].get_attr("parameterID") == "3" and rp[0].get_float("min") == 20.0 and rp[0].get_float("max") == 20000.0, "automated param listed with its range")
	_assert(absf(rp[0].get_float("value") - cutoff.normalized_to_value(0.5)) < 1e-2, "param value in real units")
	_assert(clap_el.child("Enabled").get_bool("value"), "Enabled")
	var fx_el: DawXml.El = devices[1]
	_assert(fx_el.child("State") == null and exported.result.report.count_of(TransferReport.PLUGIN_NO_STATE) == 1, "plugin without state: no State file, one report entry")
	# Automation lane targets the RealParameter id.
	var pad_lane := _lane_for(xml, _find_track(xml, "Pad"))
	_assert(pad_lane.child("Points").child("Target").get_attr("parameter") == rp[0].get_attr("id"), "device lane targets the RealParameter id")

	var bass_devs: Array = _find_track(xml, "Bass").child("Channel").child("Devices").children
	_assert(bass_devs.size() == 2 and bass_devs[0].tag == "BuiltinDevice" and bass_devs[0].get_attr("deviceID") == "sonara.polysynth", "polysynth -> BuiltinDevice sonara.polysynth")
	_assert(bass_devs[1].get_attr("deviceID") == "sonara.delay" and bass_devs[1].get_attr("deviceRole") == "audioFX", "delay -> sonara.delay audioFX")
	_assert(exported.result.report.count_of(TransferReport.MODULATORS) == 1, "a device with modulators gets one report entry")
	var state_json = JSON.parse_string(exported.entries[bass_devs[0].child("State").get_attr("path")].get_string_from_utf8())
	_assert(state_json is Dictionary and state_json.get("device_id") == "polysynth", "builtin state re-parses as device JSON")

	var perc_dev: DawXml.El = _find_track(xml, "Perc").child("Channel").child("Devices").children[0]
	var perc_json = JSON.parse_string(exported.entries[perc_dev.child("State").get_attr("path")].get_string_from_utf8())
	var embedded_path: String = perc_json.get("loaded_file_path", "")
	_assert(embedded_path.begins_with("files/") and exported.entries.has(embedded_path), "sampler WAV embedded under files/ and JSON points at it")
