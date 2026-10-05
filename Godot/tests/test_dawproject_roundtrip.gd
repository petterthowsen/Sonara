# test_dawproject_roundtrip.gd
# Builds one project using every core-subset feature, exports it, imports the result and compares
# field by field within the REQ-014 to REQ-022 tolerances (REQ-025).
#
# Run: godot --headless --path Godot -s tests/test_dawproject_roundtrip.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _clip_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _lane_script: GDScript
var _target_script: GDScript
var _param_script: GDScript
var _add_cmd: GDScript
var _tmp: String
var _blob := PackedByteArray()


func suite_name() -> String:
	return "DAWproject round trip"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_clip_script = load("res://data/Clip.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_target_script = load("res://data/AutomationTarget.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_tmp = ProjectSettings.globalize_path("user://dawproject_roundtrip")
	DirAccess.make_dir_recursive_absolute(_tmp)
	for i in 300:
		_blob.append((i * 7) % 256)
	await _test_round_trip()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _device(device_id: String, type: int, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id.get_slice(".", device_id.get_slice_count(".") - 1), category, type)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _instance(ch: Object, device: Object) -> Object:
	var inst: Object = _device_instance_script.new(device, ch.id, ch.devices.size())
	ch.add_device(inst)
	return inst


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


func _by_name(list: Array, name: String) -> Object:
	for item in list:
		if item.name == name:
			return item
	return null


func _lane_of(track: Object, kind: int) -> Object:
	for lane in track.automation_lanes:
		if lane.target.kind == kind:
			return lane
	return null


func _notes_of(clip: Object) -> Array:
	var out: Array = []
	for n in clip.midi_notes:
		# Velocity to 1e-9: the XML text parse can differ from the float in its last bit.
		out.append([n.note, n.start_tick, n.duration_ticks, roundi(n.velocity * 1e9), roundi(n.release * 1e9)])
	out.sort()
	return out


func _lane_value_at(lane: Object, tick: int) -> float:
	var pts: Array = lane.points
	if tick <= pts[0].tick:
		return pts[0].value
	for i in range(1, pts.size()):
		if tick <= pts[i].tick:
			if pts[i - 1].curve == 1:
				return pts[i - 1].value
			return AutomationCurve.evaluate(pts[i - 1], pts[i], tick)
	return pts.back().value


# ---------------------------------------------------------------------------
# the round trip
# ---------------------------------------------------------------------------

func _test_round_trip() -> void:
	var clap_dev := _device("rt.clap.Synth", DawEnums.DEVICE_CLAP, DawEnums.CATEGORY_INSTRUMENT)
	var cutoff: Object = _param_script.new(3, "Cutoff")
	cutoff.min_value = 20.0
	cutoff.max_value = 20000.0
	clap_dev.add_parameter(cutoff)
	var poly := _device("polysynth", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_INSTRUMENT)
	var delay := _device("delay", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_EFFECT)
	var sampler_dev := _device("sampler", DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_INSTRUMENT)
	var drum_dev := _device(DRUM_ID, DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_INSTRUMENT, true)
	_device(CHAIN_ID, DawEnums.DEVICE_BUILTIN, DawEnums.CATEGORY_EFFECT, true)

	var project: Object = _project_script.new()
	project.project_name = "Round Trip"
	project.tempo = 100.0
	project.time_numerator = 4
	project.time_denominator = 4
	project.tempo_map.add_point(0, 100.0)
	project.tempo_map.add_point(3840, 100.0)
	project.tempo_map.add_point(7680, 150.0)
	project.time_signature_map.add_change(5, 7, 8)
	project.time_signature_map.add_change(9, 4, 4)

	# Folder -> group -> two tracks, plus a bus, a routed bus and a send.
	var folder: Object = project.create_folder_track("Drums").track
	var group: Object = project.create_group_track("Kit").track
	var lead: Dictionary = project.create_instrument_track("Lead")
	var loop: Dictionary = project.create_audio_track("Loop")
	project.place_track(group, folder.id)
	project.place_track(lead.track, group.id)
	project.place_track(loop.track, group.id)
	var perc: Dictionary = project.create_instrument_track("Perc")
	var bass: Dictionary = project.create_instrument_track("Bass")
	var reverb: Object = project.create_bus_channel("Reverb")
	var sub: Object = project.create_bus_channel("Sub")
	lead.channel.set_volume(-6.0)
	lead.channel.set_pan(-0.5)
	lead.channel.mute = true
	lead.channel.solo = true
	lead.channel.add_send(reverb.id, -12.0, true)
	bass.channel.output_channel_id = sub.id
	lead.track.color = Color("33aa66")

	# Clips: pooled (3 instances), transposed, audio at 120 BPM in a 100 BPM project.
	var riff: Object = project.create_clip("Riff", _clip_script.ClipType.MIDI)
	riff.content_length_ticks = 3840
	for i in 4:
		riff.add_midi_note(project.allocate_note_id(), 60 + i, MidiNoteData.from_midi_velocity(90 + i), i * 960, 480 + i * 10)
	lead.track.create_clip_instance(riff, 0, 3840)
	lead.track.create_clip_instance(riff, 3840, 3840)
	lead.track.create_clip_instance(riff, 7680, 3840)
	var transposed: Object = lead.track.create_clip_instance(riff, 11520, 3840)
	transposed.transpose = 2
	var wav := _tmp.path_join("loop.wav")
	_write_wav(wav, 16000)  # 2.0 s
	var audio: Object = project.create_clip("Loop", _clip_script.ClipType.AUDIO)
	audio.audio_file_path = wav
	audio.recorded_bpm = 120.0
	audio.set_audio_metadata(8000, 1, 16000, 2.0)
	var audio_2: Object = project.create_clip("Loop 2", _clip_script.ClipType.AUDIO)
	audio_2.audio_file_path = wav
	audio_2.recorded_bpm = 120.0
	audio_2.set_audio_metadata(8000, 1, 16000, 2.0)
	var loop_inst: Object = loop.track.create_clip_instance(audio, 960, 3840)
	loop.track.create_clip_instance(audio_2, 5760, 3840)

	# Markers.
	var marker: Object = project.create_marker(1920, 0, "Verse")
	marker.color = Color("ff8800")
	project.add_marker(marker)

	# Automation: volume with a curved and a step point, pan, send.
	var vol: Object = _lane_script.new("lane0", _target_script.channel_volume())
	vol.add_point(0, 0.5)
	vol.add_point(3840, 0.9, 0, 0.6)
	vol.add_point(7680, 0.3, 1)
	vol.add_point(8640, 0.7)
	lead.track.add_automation_lane(vol)
	var pan: Object = _lane_script.new("lane1", _target_script.channel_pan())
	pan.add_point(0, 0.5)
	pan.add_point(3840, 1.0)
	lead.track.add_automation_lane(pan)
	var send: Object = _lane_script.new("lane2", _target_script.send_amount(0))
	send.add_point(0, 0.2)
	send.add_point(3840, 0.8)
	lead.track.add_automation_lane(send)

	# Devices: CLAP with state, polysynth -> delay, drum machine with two sampler pads.
	var clap: Object = _instance(perc.channel, clap_dev)
	clap.plugin_state = _blob
	clap.parameter_values[3] = 0.25
	var dev_lane: Object = _lane_script.new("lane3", _target_script.device_param([0], 3))
	dev_lane.add_point(0, 0.0)
	dev_lane.add_point(3840, 1.0)
	perc.track.add_automation_lane(dev_lane)
	_instance(bass.channel, poly)
	_instance(bass.channel, delay)
	var drums: Dictionary = project.create_instrument_track("Pads")
	var drum: Object = _instance(drums.channel, drum_dev)
	var pad_names := ["kick.wav", "snare.wav"]
	for i in 2:
		var pad_path := _tmp.path_join(pad_names[i])
		_write_wav(pad_path, 400 * (i + 1))
		var pad: Object = _device_instance_script.new(sampler_dev, drums.channel.id, -1)
		pad.slot_note = 36 + i
		pad.loaded_file_path = pad_path
		_add_cmd.new(drums.channel, pad, -1, drum).do()

	# --- export, import -------------------------------------------------
	var path := _tmp.path_join("roundtrip.dawproject")
	var exported: Dictionary = await DawProjectExporter.new().export_project(project, path)
	_assert(exported.ok, "export succeeds: %s" % exported.error)
	var imported: Dictionary = DawProjectImporter.new().import_file(path)
	_assert(imported.ok, "import succeeds: %s" % imported.error)
	if not exported.ok or not imported.ok:
		return
	var got: Object = _project_script.from_json(imported.project_json)
	_assert(got != null, "imported JSON builds a project")
	if got == null:
		return

	# Transport and maps (REQ-010..012).
	_assert(got.project_name == "Round Trip", "name comes back from Title")
	_assert(got.tempo_map.to_json() == project.tempo_map.to_json() or _tempo_points_match(got, project), "tempo map points match")
	var sigs: Array = got.time_signature_map.to_json()
	_assert(sigs.size() == 2 and int(sigs[0].get("bar", -1)) == 5 and int(sigs[0].get("numerator", 0)) == 7 and int(sigs[1].get("bar", -1)) == 9, "signature changes 4/4 -> 7/8 at bar 5 -> 4/4 at bar 9")

	# Structure (REQ-013).
	var g_folder: Object = _by_name(got.tracks, "Drums")
	var g_group: Object = _by_name(got.tracks, "Kit")
	var g_lead: Object = _by_name(got.tracks, "Lead")
	var g_loop: Object = _by_name(got.tracks, "Loop")
	_assert(g_folder != null and g_group != null and g_lead != null and g_loop != null, "all tracks come back")
	if g_folder == null or g_group == null or g_lead == null or g_loop == null:
		return
	_assert(g_folder.type == folder.type and g_group.type == group.type and g_lead.type == lead.track.type and g_loop.type == loop.track.type, "track types match")
	_assert(g_group.parent_track_id == g_folder.id and g_lead.parent_track_id == g_group.id and g_loop.parent_track_id == g_group.id, "nesting matches")
	var want_children: Array = project.get_track_children(group).map(func(t): return t.name)
	var got_children: Array = got.get_track_children(g_group).map(func(t): return t.name)
	_assert(want_children == got_children, "group children keep their order (%s vs %s)" % [str(want_children), str(got_children)])
	_assert(g_lead.color.is_equal_approx(lead.track.color) or g_lead.color.to_html(false) == lead.track.color.to_html(false), "track color matches")

	# Channels, routing, sends (REQ-014, REQ-015).
	var g_lead_ch: Object = got.get_channel_by_id(g_lead.default_channel_id)
	_assert(absf(g_lead_ch.volume - (-6.0)) < 0.01, "volume -6 dB (got %f)" % g_lead_ch.volume)
	_assert(absf(g_lead_ch.pan - (-0.5)) < 0.001, "pan -0.5 (got %f)" % g_lead_ch.pan)
	_assert(g_lead_ch.mute and g_lead_ch.solo, "mute and solo")
	var g_reverb: Object = _by_name(got.channels, "Reverb")
	var g_sub: Object = _by_name(got.channels, "Sub")
	_assert(g_reverb != null and g_reverb.is_bus and g_sub != null and g_sub.is_bus, "buses come back as bus channels")
	_assert(g_lead_ch.send_channels.size() == 1 and g_lead_ch.send_channels[0].target_channel_id == g_reverb.id, "send targets the Reverb bus")
	_assert(absf(g_lead_ch.send_channels[0].amount - (-12.0)) < 0.01 and g_lead_ch.send_channels[0].pre_fader, "send -12 dB, pre-fader")
	var g_bass: Object = _by_name(got.tracks, "Bass")
	_assert(got.get_channel_by_id(g_bass.default_channel_id).output_channel_id == g_sub.id, "Bass routes to Sub")
	_assert(g_sub.output_channel_id == 1 and g_reverb.output_channel_id == 1, "buses route to master")

	# Clips (REQ-016, REQ-017).
	var g_instances: Array = g_lead.clip_instances
	_assert(g_instances.size() == 4, "four clip instances on Lead (got %d)" % g_instances.size())
	if g_instances.size() == 4:
		g_instances.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
		_assert(g_instances[0].clip_id == g_instances[1].clip_id and g_instances[1].clip_id == g_instances[2].clip_id, "three instances share one clip id")
		_assert(g_instances[3].clip_id != g_instances[0].clip_id, "the transposed instance has its own clip")
		var shared: Object = got.get_clip(g_instances[0].clip_id)
		_assert(_notes_of(shared) == _notes_of(riff), "notes: key, start, duration and velocity exact")
		var expected_transposed := _notes_of(riff).map(func(n): return [n[0] + 2, n[1], n[2], n[3], n[4]])
		_assert(_notes_of(got.get_clip(g_instances[3].clip_id)) == expected_transposed, "transposed instance holds transposed notes")
		_assert(g_instances[1].start_ticks == 3840 and g_instances[1].duration_ticks == 3840, "instance position and length")

	# Audio (REQ-018).
	_assert(g_loop.clip_instances.size() == 2, "two audio instances")
	if g_loop.clip_instances.size() == 2:
		var a_inst: Object = g_loop.clip_instances[0]
		var a_clip: Object = got.get_clip(a_inst.clip_id)
		_assert(a_inst.start_ticks == loop_inst.start_ticks and a_inst.duration_ticks == loop_inst.duration_ticks, "audio position and length match")
		_assert(a_inst.clip_offset == loop_inst.clip_offset, "audio trim matches")
		_assert(absf(a_clip.recorded_bpm - 120.0) < 0.01, "recorded BPM 120 (stretch ratio kept, got %f)" % a_clip.recorded_bpm)
		_assert(FileAccess.file_exists(a_clip.audio_file_path), "audio file extracted: %s" % a_clip.audio_file_path)
		_assert(g_loop.clip_instances[0].clip.audio_file_path == g_loop.clip_instances[1].clip.audio_file_path, "one extracted copy for both clips")

	# Markers (REQ-020).
	_assert(got.markers.size() == 1 and got.markers[0].name == "Verse" and got.markers[0].start_ticks == 1920 \
		and got.markers[0].color.to_html(false) == "ff8800", "marker name, start and color")

	# Automation (REQ-019).
	var g_vol: Object = _lane_of(g_lead, vol.target.kind)
	var g_pan: Object = _lane_of(g_lead, pan.target.kind)
	var g_send: Object = _lane_of(g_lead, send.target.kind)
	_assert(g_vol != null and g_pan != null and g_send != null, "volume, pan and send lanes come back")
	if g_vol != null:
		for tick in [0, 1920, 3840, 5760, 7679, 8640]:
			var want := _lane_value_at(vol, tick)
			var have := _lane_value_at(g_vol, tick)
			_assert(absf(want - have) < 0.02, "volume lane at tick %d within tolerance (%f vs %f)" % [tick, want, have])
		var step := false
		for p in g_vol.points:
			if p.curve == 1:
				step = true
		_assert(step, "the STEP point comes back as a step")
	if g_pan != null:
		_assert(absf(_lane_value_at(g_pan, 1920) - 0.75) < 0.005, "pan lane midpoint")
	if g_send != null:
		_assert(absf(_lane_value_at(g_send, 1920) - 0.5) < 0.02, "send lane midpoint")
	var g_perc: Object = _by_name(got.tracks, "Perc")
	var g_dev_lane: Object = _lane_of(g_perc, dev_lane.target.kind)
	_assert(g_dev_lane != null and g_dev_lane.target.param_id == 3, "device parameter lane targets param 3")

	# Devices (REQ-021, REQ-022).
	var perc_ch: Object = got.get_channel_by_id(g_perc.default_channel_id)
	_assert(perc_ch.devices.size() == 1 and perc_ch.devices[0].plugin_state == _blob, "CLAP state bytes identical")
	var bass_ch: Object = got.get_channel_by_id(g_bass.default_channel_id)
	_assert(bass_ch.devices.size() == 2 and bass_ch.devices[0].device.device_id == "polysynth" and bass_ch.devices[1].device.device_id == "delay", "polysynth -> delay chain")
	var g_pads: Object = _by_name(got.tracks, "Pads")
	var pads_ch: Object = got.get_channel_by_id(g_pads.default_channel_id)
	_assert(pads_ch.devices.size() == 1 and pads_ch.devices[0].children.size() == drum.children.size(), "drum machine keeps its pad chains")
	var notes: Array = []
	var files: Array = []
	for slot in pads_ch.devices[0].children:
		notes.append(slot.slot_note)
		for inner in slot.children:
			files.append(inner.loaded_file_path)
	notes.sort()
	_assert(notes == [36, 37], "pad notes 36 and 37")
	_assert(files.size() == 2 and FileAccess.file_exists(files[0]) and FileAccess.file_exists(files[1]), "sampler WAVs extracted next to the import")

	# Report: only the transpose is reported.
	_assert(exported.report.count_of(TransferReport.CLIP_TRANSPOSE) == 1, "export report lists the transpose")


func _tempo_points_match(a: Object, b: Object) -> bool:
	var pa: Array = a.tempo_map.to_json()
	var pb: Array = b.tempo_map.to_json()
	if pa.size() != pb.size():
		return false
	for i in pa.size():
		if int(pa[i].get("tick", -1)) != int(pb[i].get("tick", -2)) or absf(float(pa[i].get("bpm", 0)) - float(pb[i].get("bpm", 1))) > 0.001:
			return false
	return true
