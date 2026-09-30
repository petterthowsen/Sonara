# test_dawproject_import.gd
# Headless tests for DawProjectImporter against the Bitwig fixture, broken files and a synthetic
# file holding one of every item the transfer report must list.
#
# Run: godot --headless --path Godot -s tests/test_dawproject_import.gd -- --test
extends TestBase

const FIXTURE := "res://tests/fixtures/dawproject/sonara_test_01.dawproject"

var _project_script: GDScript
var _device_script: GDScript
var _tmp: String


func suite_name() -> String:
	return "DAWproject import tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_tmp = ProjectSettings.globalize_path("user://dawproject_import")
	DirAccess.make_dir_recursive_absolute(_tmp)
	_test_broken_files()
	_test_fixture_structure()
	_test_fixture_devices()
	_test_fixture_clips()
	_test_fixture_automation()
	_test_pooled_references()
	_test_report_items()
	_test_audio_dir_failure()
	await _test_editor_entry_points()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _register_apricot() -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	registry._devices["nakst.Apricot"] = _device_script.new("nakst.Apricot", "Apricot", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.CLAP)


func _unregister_apricot() -> void:
	root.get_node("AssetService").device_registry._devices.erase("nakst.Apricot")


func _fixture_copy(dir_name: String) -> String:
	var dir := _tmp.path_join(dir_name)
	DirAccess.make_dir_recursive_absolute(dir)
	var dest := dir.path_join("sonara_test_01.dawproject")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(FIXTURE), dest)
	return dest


func _import_fixture(dir_name: String) -> Dictionary:
	return DawProjectImporter.new().import_file(_fixture_copy(dir_name))


func _by_name(list: Array, name: String) -> Dictionary:
	for item in list:
		if item.get("name") == name:
			return item
	return {}


func _build_file(path: String, entries: Dictionary) -> void:
	var zip := ZIPPacker.new()
	zip.open(path)
	for name in entries:
		zip.start_file(name)
		var content: Variant = entries[name]
		zip.write_file(content if content is PackedByteArray else str(content).to_utf8_buffer())
		zip.close_file()
	zip.close()


func _wav_bytes(frames: int) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(frames * 2)
	var out := PackedByteArray()
	out.append_array("RIFF".to_utf8_buffer())
	out.append_array(_u32(36 + data.size()))
	out.append_array("WAVEfmt ".to_utf8_buffer())
	out.append_array(_u32(16))
	out.append_array(PackedByteArray([1, 0, 1, 0]))
	out.append_array(_u32(8000))
	out.append_array(_u32(16000))
	out.append_array(PackedByteArray([2, 0, 16, 0]))
	out.append_array("data".to_utf8_buffer())
	out.append_array(_u32(data.size()))
	out.append_array(data)
	return out


func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, 0, 0])
	b.encode_u32(0, v)
	return b


# ---------------------------------------------------------------------------
# T-012: containers and structure
# ---------------------------------------------------------------------------

func _test_broken_files() -> void:
	var not_zip := _tmp.path_join("notzip.dawproject")
	var f := FileAccess.open(not_zip, FileAccess.WRITE)
	f.store_string("this is not a zip")
	f.close()
	var r: Dictionary = DawProjectImporter.new().import_file(not_zip)
	_assert(not r.ok and r.error != "" and r.project_json.is_empty(), "not a ZIP fails with a message: %s" % r.error)

	var no_xml := _tmp.path_join("noxml.dawproject")
	_build_file(no_xml, {"metadata.xml": "<MetaData/>"})
	r = DawProjectImporter.new().import_file(no_xml)
	_assert(not r.ok and "project.xml" in r.error, "missing project.xml fails: %s" % r.error)

	var bad_xml := _tmp.path_join("badxml.dawproject")
	_build_file(bad_xml, {"project.xml": "<Project><Structure></Project>"})
	r = DawProjectImporter.new().import_file(bad_xml)
	_assert(not r.ok and "XML" in r.error, "malformed XML fails: %s" % r.error)

	var dangling := _tmp.path_join("dangling.dawproject")
	_build_file(dangling, {"project.xml": '<Project version="1.0"><Structure><Track id="a" contentType="audio" name="T"><Channel id="c" destination="nowhere" role="regular"/></Track></Structure></Project>'})
	r = DawProjectImporter.new().import_file(dangling)
	_assert(not r.ok and "nowhere" in r.error, "dangling IDREF fails: %s" % r.error)


func _test_fixture_structure() -> void:
	_register_apricot()
	var r := _import_fixture("structure")
	_assert(r.ok, "fixture imports: %s" % r.error)
	var json: Dictionary = r.project_json
	_assert(json.project_name == "sonara_test_01", "empty Title -> file name (got %s)" % json.project_name)
	var project: Object = _project_script.from_json(json)
	_assert(project.tracks.size() == 2, "2 tracks (got %d)" % project.tracks.size())
	var names: Array = project.channels.map(func(c): return c.name)
	_assert("Apricot" in names and "crash_cymbal_crash_01" in names and "Reverb" in names and "Master" in names, "channels: %s" % str(names))
	var apricot: Object = _by_channel(project, "Apricot")
	_assert(absf(apricot.volume + 6.0) < 0.02, "Apricot volume -6 dB (got %.3f)" % apricot.volume)
	var reverb: Object = _by_channel(project, "Reverb")
	_assert(reverb.channel_type == 2 and project.get_channel_paired_track(reverb) == null, "Reverb is a bus with no track")
	_assert(absf(reverb.volume) < 0.001, "Reverb at 0 dB")
	_assert(apricot.output_channel_id == 1 and _by_channel(project, "Master").is_master, "routes to the master")
	_assert(project.tempo_map.points.size() == 3, "3 tempo points")
	var at_3839: Dictionary = project.tempo_map.points[1]
	var at_3840: Dictionary = project.tempo_map.points[2]
	_assert(at_3839.tick == 3839 and at_3839.bpm == 110.0 and at_3840.tick == 3840 and absf(at_3840.bpm - 79.02) < 1e-6, "tempo 110 -> 79.02 jump within one tick")
	_assert(project.tempo == 110.0 and project.time_numerator == 4 and project.time_denominator == 4, "transport tempo and signature")


func _by_channel(project: Object, name: String) -> Object:
	for c in project.channels:
		if c.name == name:
			return c
	return null


# ---------------------------------------------------------------------------
# T-013: routing, sends, devices
# ---------------------------------------------------------------------------

func _test_fixture_devices() -> void:
	_register_apricot()
	var r := _import_fixture("devices")
	var project: Object = _project_script.from_json(r.project_json)
	var apricot: Object = _by_channel(project, "Apricot")
	var reverb: Object = _by_channel(project, "Reverb")
	_assert(apricot.send_channels.size() == 1 and apricot.send_channels[0].target_channel_id == reverb.id, "Apricot has one send to Reverb")
	_assert(absf(apricot.send_channels[0].amount + 22.85) < 0.02 and not apricot.send_channels[0].pre_fader and not apricot.send_channels[0].muted, "send at -22.85 dB, post-fader")
	_assert(_by_channel(project, "crash_cymbal_crash_01").send_channels.is_empty() and reverb.send_channels.is_empty(), "default disabled sends are skipped")
	_assert(apricot.devices.size() == 1, "Apricot device imported")
	var zip := ZIPReader.new()
	zip.open(ProjectSettings.globalize_path(FIXTURE))
	var preset_name := ""
	for name in zip.get_files():
		if name.ends_with(".clap-preset"):
			preset_name = name
	var expected_state: PackedByteArray = ClapPreset.unwrap(zip.read_file(preset_name)).state
	zip.close()
	_assert(apricot.devices[0].plugin_state == expected_state, "plugin_state equals the preset's state bytes")
	_assert(r.report.entries().size() == 1 and r.report.entries()[0].kind == TransferReport.FOREIGN_BUILTIN and r.report.entries()[0].subject == "Reverb", "exactly one report entry: the Reverb BuiltinDevice (got: %s)" % r.report.to_text())
	# Unregistered plugin: a missing-plugin entry instead.
	_unregister_apricot()
	var r2 := _import_fixture("devices2")
	_assert(r2.report.count_of(TransferReport.CLAP_MISSING) == 1, "missing plugin reported")
	_register_apricot()


# ---------------------------------------------------------------------------
# T-014: clips, audio, markers
# ---------------------------------------------------------------------------

func _test_fixture_clips() -> void:
	_register_apricot()
	var path := _fixture_copy("clips")
	var r: Dictionary = DawProjectImporter.new().import_file(path)
	_assert(r.ok, "fixture imports for clips: %s" % r.error)
	var project: Object = _project_script.from_json(r.project_json)
	var apricot_track: Object = project.get_channel_paired_track(_by_channel(project, "Apricot"))
	var instances: Array = apricot_track.clip_instances
	_assert(instances.size() == 2, "two MIDI clips on Apricot")
	instances.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	_assert(instances[0].start_ticks == 0 and instances[1].start_ticks == 3840 and instances[0].duration_ticks == 3840, "MIDI clips at ticks 0 and 3840, 4 beats long")
	var clip: Object = project.get_clip(instances[0].clip_id)
	_assert(clip.midi_notes.size() == 4, "4 notes")
	var keys: Array = clip.midi_notes.map(func(n): return n.note)
	keys.sort()
	_assert(keys == [60, 62, 63, 67], "note keys 60 62 63 67")
	_assert(clip.midi_notes.all(func(n): return n.velocity == 100), "velocity 100")
	_assert(project.get_clip(instances[1].clip_id) != clip, "the two clips have separate content")

	var crash_track: Object = project.get_channel_paired_track(_by_channel(project, "crash_cymbal_crash_01"))
	_assert(crash_track.clip_instances.size() == 1, "one audio clip on the crash track")
	var crash: Object = crash_track.clip_instances[0]
	_assert(crash.start_ticks == 3840 and crash.duration_ticks == 1760, "crash at tick 3840, 1760 ticks long (got %d, %d)" % [crash.start_ticks, crash.duration_ticks])
	var crash_clip: Object = project.get_clip(crash.clip_id)
	_assert(absf(crash_clip.recorded_bpm - 110.0) < 0.05, "recorded_bpm 110 (got %.3f)" % crash_clip.recorded_bpm)
	var expected := path.get_base_dir().path_join("sonara_test_01 Audio/audio/crash_cymbal_crash_01.wav")
	_assert(crash_clip.audio_file_path == expected and FileAccess.file_exists(expected), "WAV extracted next to the file and referenced")
	_assert(crash.clip_offset == 0, "no left trim")
	# Markers in a synthetic file are covered below.


func _test_audio_dir_failure() -> void:
	var path := _fixture_copy("failure")
	var r: Dictionary = DawProjectImporter.new().import_file(path, "/proc/no_such_dir/audio")
	_assert(not r.ok and r.audio_dir_failed, "unwritable audio dir sets audio_dir_failed")
	var r2: Dictionary = DawProjectImporter.new().import_file(path, _tmp.path_join("picked"))
	_assert(r2.ok and not r2.audio_dir_failed and FileAccess.file_exists(_tmp.path_join("picked/audio/crash_cymbal_crash_01.wav")), "a writable folder given by the user works")


func _test_pooled_references() -> void:
	var xml := '''<Project version="1.0">
  <Transport><Tempo unit="bpm" value="120" id="t"/><TimeSignature numerator="4" denominator="4" id="s"/></Transport>
  <Structure>
    <Track id="k" name="Lead" contentType="notes"><Channel id="kc" role="regular" destination="mc"><Volume unit="linear" value="1" id="kv"/></Channel></Track>
    <Track id="m" name="Master" contentType="audio notes"><Channel id="mc" role="master"/></Track>
  </Structure>
  <Arrangement id="a"><Lanes timeUnit="beats" id="l"><Lanes track="k" id="kl"><Clips id="ks">
    <Clip time="0" duration="4" name="Riff"><Notes id="shared"><Note time="0" duration="1" channel="0" key="60" vel="0.5"/></Notes></Clip>
    <Clip time="4" duration="4" reference="shared"/>
    <Clip time="8" duration="2" playStart="1" reference="shared" enable="false"/>
  </Clips></Lanes></Lanes>
  <Markers id="mk"><Marker time="2" name="Verse" color="#ff8800"/></Markers></Arrangement>
</Project>'''
	var path := _tmp.path_join("pooled.dawproject")
	_build_file(path, {"project.xml": xml, "metadata.xml": "<MetaData><Title>Pooled</Title></MetaData>"})
	var r: Dictionary = DawProjectImporter.new().import_file(path)
	_assert(r.ok, "pooled file imports: %s" % r.error)
	_assert(r.project_json.project_name == "Pooled", "Title becomes the project name")
	var project: Object = _project_script.from_json(r.project_json)
	_assert(project.clips.size() == 1, "two references + original -> one pooled clip (got %d)" % project.clips.size())
	var track: Object = project.tracks[0]
	_assert(track.clip_instances.size() == 3, "three instances")
	_assert(track.clip_instances[2].muted and track.clip_instances[2].clip_offset == 960, "enable=false -> muted, playStart -> clip_offset")
	_assert(project.markers.size() == 1 and project.markers[0].name == "Verse" and project.markers[0].start_ticks == 1920 and project.markers[0].duration_ticks == 0, "marker imported with duration 0")
	_assert(project.markers[0].color.to_html(false) == "ff8800", "marker color")


# ---------------------------------------------------------------------------
# T-015: automation and the report
# ---------------------------------------------------------------------------

func _test_fixture_automation() -> void:
	_register_apricot()
	var r := _import_fixture("automation")
	var project: Object = _project_script.from_json(r.project_json)
	var apricot: Object = project.get_channel_paired_track(_by_channel(project, "Apricot"))
	_assert(apricot.automation_lanes.size() == 1, "Apricot has one lane")
	var lane: Object = apricot.automation_lanes[0]
	_assert(str(lane.target) == "channel/send/0", "send level lane targets channel/send/0 (got %s)" % str(lane.target))
	var first: Object = lane.points[0]
	var last: Object = lane.points[lane.points.size() - 1]
	_assert(first.tick == 0 and first.value == 0.0 and last.tick == 7680 and absf(last.value - 60.0 / 72.0) < 1e-4, "send lane 0 -> 0 dB over ticks 0-7680")
	_assert(lane.points.size() > 2, "gain ramp becomes several dB points (%d)" % lane.points.size())
	# Linear-gain truth at the midpoint: 0.5 gain = -6 dB.
	var mid: float = lane.get_value_at_tick(3840)
	_assert(absf(AutomationTarget.normalized_to_db(mid) - DawUnits.linear_to_db(0.5)) < 1.0, "midpoint within 1 dB of the gain ramp (%.2f dB)" % AutomationTarget.normalized_to_db(mid))
	var crash: Object = project.get_channel_paired_track(_by_channel(project, "crash_cymbal_crash_01"))
	_assert(crash.automation_lanes.size() == 1 and str(crash.automation_lanes[0].target) == "channel/volume", "crash volume lane")
	var cl: Object = crash.automation_lanes[0]
	_assert(cl.points[0].tick == 3840 and absf(AutomationTarget.normalized_to_db(cl.points[0].value) + 6.0) < 0.05, "crash lane starts at -6 dB on tick 3840")
	_assert(cl.points[cl.points.size() - 1].tick == 7680 and cl.points[cl.points.size() - 1].value == 0.0, "crash lane ends at -60 dB on tick 7680")


func _test_report_items() -> void:
	_unregister_apricot()
	var xml := '''<Project version="1.0">
  <Transport><Tempo unit="bpm" value="120" id="t"/><TimeSignature numerator="4" denominator="4" id="s"/></Transport>
  <Structure>
    <Track id="lead" name="Lead" contentType="notes"><Channel id="leadc" role="regular" destination="mc">
      <Devices>
        <Vst3Plugin deviceName="Serum" deviceRole="instrument" id="d1"/>
        <ClapPlugin deviceID="missing.plugin" deviceName="Missing" deviceRole="audioFX" id="d2"/>
        <Equalizer deviceName="EQ" deviceRole="audioFX" id="d3"/>
        <BuiltinDevice deviceID="abc-123" deviceName="Chorus" deviceRole="audioFX" id="d4"/>
      </Devices>
      <Mute value="false" id="leadmute"/><Volume unit="linear" value="1" id="leadvol"/></Channel></Track>
    <Track id="loop" name="Loop" contentType="audio"><Channel id="loopc" role="regular" destination="mc"><Volume unit="linear" value="1" id="loopvol"/></Channel></Track>
    <Track id="fx" name="FX" contentType="audio"><Channel id="fxc" role="effect" destination="mc"/></Track>
    <Track id="vca" name="VCA" contentType="audio"><Channel id="vcac" role="vca"/></Track>
    <Track id="mono" name="Mono" contentType="audio"><Channel id="monoc" role="regular" audioChannels="1" destination="mc"/></Track>
    <Track id="m" name="Master" contentType="audio notes"><Channel id="mc" role="master"/></Track>
  </Structure>
  <Arrangement id="a"><Lanes timeUnit="beats" id="l">
    <Lanes track="lead" id="ll">
      <Clips id="lclips">
        <Clip time="0" duration="4"><Notes id="n1">
          <Note time="0" duration="1" channel="2" key="60" vel="0.5" rel="0.5"/>
          <Note time="1" duration="1" channel="0" key="62" vel="0.5" rel="0.9"/>
          <Note time="2" duration="1" channel="0" key="64" vel="0.5" rel="0.5"><Points id="ne"><Target expression="timbre"/><RealPoint time="0" value="0.5"/></Points></Note>
        </Notes></Clip>
        <Clip time="4" duration="4"><Points id="clipauto"><Target parameter="leadvol"/><RealPoint time="0" value="1" interpolation="linear"/></Points></Clip>
      </Clips>
      <Points id="exp"><Target expression="pitchBend" channel="0"/><RealPoint time="0" value="0.5"/></Points>
      <Points id="muteauto"><Target parameter="leadmute"/><RealPoint time="0" value="1" interpolation="hold"/></Points>
    </Lanes>
    <Lanes track="loop" id="lp"><Clips id="lpc">
      <Clip time="0" duration="4"><Warps id="w1" contentTimeUnit="seconds" timeUnit="beats">
        <Audio channels="1" sampleRate="8000" duration="2" id="au"><File path="audio/a.wav"/></Audio>
        <Warp time="0" contentTime="0"/><Warp time="2" contentTime="1.5"/><Warp time="4" contentTime="2"/>
      </Warps></Clip>
      <Clip time="4" duration="4" fadeTimeUnit="beats" fadeInTime="-0.5" reference="w1"/>
    </Clips></Lanes>
    <Lanes track="fx" id="fl"><Clips id="fc"><Clip time="0" duration="4"><Notes id="n2"><Note time="0" duration="1" channel="0" key="60" vel="0.5"/></Notes></Clip></Clips></Lanes>
  </Lanes>
  <TimeSignatureAutomation timeUnit="beats" id="tsa"><Target parameter="s"/><TimeSignaturePoint time="5.5" numerator="3" denominator="4"/></TimeSignatureAutomation>
  </Arrangement>
  <Scenes><Scene id="sc" name="Scene 1"><Lanes id="scl"><ClipSlot track="lead" id="slot"><Clip time="0" duration="4"><Notes id="n3"/></Clip></ClipSlot></Lanes></Scene>
  <Scene id="sc2" name="Scene 2"><Lanes id="scl2"><ClipSlot track="lead" id="slot2" hasStop="true"/></Lanes></Scene></Scenes>
</Project>'''
	var path := _tmp.path_join("report.dawproject")
	_build_file(path, {"project.xml": xml, "audio/a.wav": _wav_bytes(16000)})
	var r: Dictionary = DawProjectImporter.new().import_file(path)
	_assert(r.ok, "synthetic file imports: %s" % r.error)
	var report: TransferReport = r.report
	for kind in [
		TransferReport.PLUGIN_FORMAT, TransferReport.CLAP_MISSING, TransferReport.GENERIC_DEVICE, TransferReport.FOREIGN_BUILTIN,
		TransferReport.WARP_APPROXIMATED, TransferReport.NOTE_CHANNEL, TransferReport.NOTE_RELEASE, TransferReport.NOTE_EXPRESSION,
		TransferReport.CLIP_AUTOMATION, TransferReport.EXPRESSION_AUTOMATION, TransferReport.UNSUPPORTED_AUTOMATION,
		TransferReport.CROSSFADE, TransferReport.VCA, TransferReport.SCENE_CLIP, TransferReport.MONO_CHANNEL,
		TransferReport.BUS_CLIP, TransferReport.SIGNATURE_OFF_BAR,
	]:
		_assert(report.count_of(kind) >= 1, "report lists %s" % kind)
	_assert(report.count_of(TransferReport.SCENE_CLIP) == 1, "only the scene holding a clip is reported")
	# The rest still imports.
	var project: Object = _project_script.from_json(r.project_json)
	_assert(_by_channel(project, "Lead") != null and _by_channel(project, "Loop") != null and _by_channel(project, "Mono") != null, "tracks still import")
	var lead: Object = project.get_channel_paired_track(_by_channel(project, "Lead"))
	_assert(lead.clip_instances.size() == 1, "clip-automation clip is dropped, the notes clip stays")
	var loop_track: Object = project.get_channel_paired_track(_by_channel(project, "Loop"))
	_assert(loop_track.clip_instances.size() == 2, "both audio clips imported")
	_assert(project.time_signature_map.changes.size() == 1 and project.time_signature_map.changes[0].bar == 3, "off-bar signature moved to bar 3")
	# Crossfade: second clip starts 0.5 beat early with a 0.5 beat fade-in.
	var second: Object = loop_track.clip_instances[1]
	_assert(second.start_ticks == 3840 - 480 and second.fade_in_ticks == 480, "crossfade -> earlier start and ordinary fade-in")


func _test_editor_entry_points() -> void:
	var editor: Control = load("res://editor/Editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	editor.close_project() # the editor starts with an Untitled project
	var menu: PopupMenu = editor.main_menu.file
	var import_idx := _menu_index(menu, "Import DAWproject")
	var export_idx := _menu_index(menu, "Export DAWproject")
	_assert(import_idx >= 0 and export_idx >= 0, "File menu has Import and Export DAWproject items")
	_assert(not menu.is_item_disabled(import_idx), "import is enabled without a project")
	_assert(menu.is_item_disabled(export_idx), "export is disabled without a project")

	var result: Dictionary = await editor.import_dawproject(_fixture_copy("editor"))
	_assert(result.ok and editor.project != null and editor.project_path == "", "import opens an unsaved project")
	_assert(not menu.is_item_disabled(export_idx), "export is enabled once a project is open")
	var opened: Object = editor.project
	var before: String = JSON.stringify(opened.to_json())

	var broken := _tmp.path_join("broken.dawproject")
	var f := FileAccess.open(broken, FileAccess.WRITE)
	f.store_string("not a zip")
	f.close()
	var bad: Dictionary = await editor.import_dawproject(broken)
	_assert(not bad.ok and editor.project == opened and JSON.stringify(opened.to_json()) == before, "a broken file leaves the open project unchanged")

	var out := _tmp.path_join("editor_export.dawproject")
	_assert(await editor.export_dawproject(out) and FileAccess.file_exists(out), "export_dawproject writes the file")
	editor.queue_free()
	await process_frame


func _menu_index(menu: PopupMenu, prefix: String) -> int:
	for i in menu.item_count:
		if menu.get_item_text(i).begins_with(prefix):
			return i
	return -1
