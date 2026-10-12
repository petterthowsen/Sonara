# test_browser_info_panel.gd
# Headless tests for the Browser info panel, the audition toggle and the preview model's wiring
# (spec 037, part 3). The PreviewPlayer is stubbed, so nothing is sent to the engine.
# Run: godot --headless --path Godot -s tests/test_browser_info_panel.gd -- --test
extends TestBase

const TYPE_AUDIO := 0
const TYPE_DEVICE := 2
const TYPE_PRESET := 5

# Records the calls the Browser makes instead of sending OSC.
const STUB_SOURCE := """
extends "res://browser/PreviewPlayer.gd"

var calls: Array = []

func play(file_path: String, start_s: float = 0.0) -> void:
	calls.append(["play", file_path, start_s])
	path = file_path
	state = State.PLAYING

func stop() -> void:
	calls.append(["stop"])
	state = State.STOPPED

func seek(pos_s: float) -> void:
	calls.append(["seek", pos_s])

func request_info(_file_path: String) -> String:
	return ""
"""

var _asset_script: GDScript
var _panel_script: GDScript
var _browser: Node
var _stub: Node


func suite_name() -> String:
	return "Browser info panel"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_panel_script = load("res://browser/BrowserInfoPanel.gd")
	_browser = (load("res://browser/Browser.tscn") as PackedScene).instantiate()
	root.add_child(_browser)
	await process_frame
	var stub_script := GDScript.new()
	stub_script.source_code = STUB_SOURCE
	stub_script.reload()
	_stub = stub_script.new()
	_browser.add_child(_stub)
	_browser.preview = _stub
	_browser.info_panel.setup(_stub)

	_test_formatting()
	_test_audio_fields()
	_test_preset_and_device_fields()
	_test_panel_hidden_without_selection()
	_test_audition_plays_audio_rows()
	_test_audition_off_and_stop_cases()
	await _test_seek_maps_x_to_seconds()
	_test_panel_play_button_and_click()
	_browser.queue_free()
	await process_frame


func _asset(type: int, path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = type
	asset.path = path
	asset.name = path.get_file()
	return asset


func _test_formatting() -> void:
	_assert(_panel_script.format_size(512) == "512 B", "bytes")
	_assert(_panel_script.format_size(1536) == "1.5 KB", "kilobytes")
	_assert(_panel_script.format_size(5 * 1024 * 1024) == "5.0 MB", "megabytes")
	_assert(_panel_script.format_duration(0.5) == "0.50 s", "short durations in seconds")
	_assert(_panel_script.format_duration(83.2) == "1:23.2", "long durations as m:ss")
	_assert(_panel_script.channels_text(1) == "Mono" and _panel_script.channels_text(2) == "Stereo", "mono and stereo")
	_assert(_panel_script.channels_text(6) == "6 ch", "other channel counts")


func _test_audio_fields() -> void:
	var asset := _asset(TYPE_AUDIO, "/samples/drums/kick.wav")
	asset.file_size_bytes = 1536
	var lines: Dictionary = _panel_script.describe(asset, {"sample_rate": 48000, "channels": 2, "duration_s": 0.5})
	_assert(lines.name == "kick.wav", "the name line is the file name")
	_assert(lines.type == "WAV · Audio", "the type line has extension and asset type: %s" % lines.type)
	_assert(lines.details == "1.5 KB · 48000 Hz · Stereo · 0.50 s", "audio details: %s" % lines.details)
	var no_facts: Dictionary = _panel_script.describe(asset)
	_assert(no_facts.details == "1.5 KB", "unknown audio facts are left out: %s" % no_facts.details)

	_browser.info_panel.show_asset(asset)
	_assert(_browser.info_panel.visible, "the panel shows for a selected asset")
	_assert(_browser.info_panel._name_label.text == "kick.wav", "the panel's name label")
	_assert(_browser.info_panel._audio_row.visible, "audio assets get the waveform row")


func _test_preset_and_device_fields() -> void:
	var preset := _asset(TYPE_PRESET, "/p/Pads/warm.sonpreset")
	preset.name = "Warm Pad"
	preset.device_id = "x.synth"
	preset.device_name = "Synth"
	preset.author = "Peter"
	preset.file_size_bytes = 2048
	var lines: Dictionary = _panel_script.describe(preset)
	_assert(lines.name == "Warm Pad" and lines.type == "Preset", "preset name and type")
	_assert(lines.details == "Synth · Peter · 2.0 KB", "preset details are device, author, size: %s" % lines.details)
	_browser.info_panel.show_asset(preset)
	_assert(not _browser.info_panel._audio_row.visible, "presets have no waveform row")

	var registry = root.get_node("AssetService").device_registry
	var device := Device.new("test.panel.device", "Panel Device", Device.DeviceCategory.Effect, Device.DeviceType.BuiltIn)
	device.author = "Acme"
	registry._devices["test.panel.device"] = device
	var asset := _asset(TYPE_DEVICE, "test.panel.device")
	var device_lines: Dictionary = _panel_script.describe(asset)
	_assert(device_lines.name == "Panel Device", "device name: %s" % device_lines.name)
	_assert(device_lines.details.begins_with("Acme · "), "device details start with the vendor: %s" % device_lines.details)
	_assert(device_lines.details.length() > "Acme · ".length(), "device details carry the category")
	registry._devices.erase("test.panel.device")


func _test_panel_hidden_without_selection() -> void:
	_browser.info_panel.clear_asset()
	_assert(not _browser.info_panel.visible, "the panel hides when nothing is selected")


## Select content-tree row `path` of the Samples tab the way a click does.
func _select_row(path: String) -> void:
	var tree: Tree = _browser._content_trees[TYPE_AUDIO]
	var item: TreeItem = tree.get_root().get_first_child()
	while item:
		var asset: Variant = item.get_metadata(0)
		if asset is Object and asset.path == path:
			# A click on a SELECT_MULTI tree emits multi_selected (never item_selected); select()
			# alone emits nothing, so send what the click sends.
			item.select(0)
			tree.multi_selected.emit(item, 0, true)
			return
		item = item.get_next()
	_assert(false, "row %s exists" % path)


func _load_samples() -> void:
	_browser._audio_assets.assign([
		_asset(TYPE_AUDIO, "/t/kick.wav"),
		_asset(TYPE_AUDIO, "/t/snare.wav"),
	])
	_browser._midi_assets.assign([_asset(1, "/t/loop.mid")])
	_browser._search_filter = ""
	_browser._selected_folder.clear()
	_browser._selected_content.clear()
	_browser._populate_tab_for(TYPE_AUDIO)


func _test_audition_plays_audio_rows() -> void:
	_load_samples()
	_stub.calls.clear()
	_select_row("/t/kick.wav")
	_assert(_stub.calls == [["stop"]], "with audition off, selecting only stops: %s" % [_stub.calls])
	_assert(_browser.info_panel.visible, "selecting a row fills the info panel")

	_browser.audition_toggle.button_pressed = true
	_assert(_browser._audition_enabled, "the toggle turns audition on")
	_stub.calls.clear()
	_select_row("/t/snare.wav")
	_assert(_stub.calls == [["play", "/t/snare.wav", 0.0]], "with audition on, selecting an audio row plays it: %s" % [_stub.calls])


func _test_audition_off_and_stop_cases() -> void:
	_stub.calls.clear()
	_select_row("/t/loop.mid")
	_assert(_stub.calls == [["stop"]], "a non-audio row stops the preview: %s" % [_stub.calls])

	_stub.calls.clear()
	_browser._select_folder(TYPE_AUDIO, "")
	_browser._on_folder_selected(TYPE_AUDIO)
	_assert(_stub.calls.has(["stop"]), "picking a folder stops the preview")
	_assert(not _browser.info_panel.visible, "picking a folder hides the info panel")

	_stub.calls.clear()
	_browser._switch_tab(TYPE_DEVICE)
	_assert(_stub.calls.has(["stop"]), "switching tabs stops the preview")
	_assert(not _browser.audition_toggle.visible, "the audition toggle only shows on the Samples tab")
	_browser._switch_tab(TYPE_AUDIO)
	_assert(_browser.audition_toggle.visible, "the audition toggle shows on the Samples tab")

	_stub.calls.clear()
	_browser.audition_toggle.button_pressed = false
	_assert(_stub.calls.has(["stop"]), "turning audition off stops the preview")
	_assert(not _browser._audition_enabled, "audition is off")


func _test_seek_maps_x_to_seconds() -> void:
	var panel: Node = _browser.info_panel
	panel.show_asset(_asset(TYPE_AUDIO, "/t/kick.wav"))
	await process_frame
	await process_frame
	panel._duration_s = 10.0
	var width: float = panel._wave_holder.size.x
	_assert(width > 0.0, "the waveform has a width")
	_assert(is_equal_approx(panel.seek_x_to_seconds(width * 0.25), 2.5), "a quarter across is a quarter of the duration")
	_assert(panel.seek_x_to_seconds(-20.0) == 0.0, "left of the waveform clamps to the start")
	_assert(panel.seek_x_to_seconds(width + 50.0) == 10.0, "right of the waveform clamps to the end")
	panel._duration_s = 0.0
	_assert(panel.seek_x_to_seconds(width * 0.5) == 0.0, "an unknown duration seeks to 0")


func _test_panel_play_button_and_click() -> void:
	var panel: Node = _browser.info_panel
	panel.show_asset(_asset(TYPE_AUDIO, "/t/kick.wav"))
	panel._duration_s = 10.0
	var width: float = panel._wave_holder.size.x

	# Stopped: a press on the waveform plays from that point.
	_stub.state = 0
	_stub.path = ""
	_stub.calls.clear()
	panel._seek_to(width * 0.5, true)
	_assert(_stub.calls == [["play", "/t/kick.wav", 5.0]], "a click while stopped plays from that point: %s" % [_stub.calls])

	# Playing: a click or drag seeks.
	_stub.calls.clear()
	panel._seek_to(width * 0.2, true)
	panel._seek_to(width * 0.3, false)
	var seeks_ok: bool = _stub.calls.size() == 2 and _stub.calls[0][0] == "seek" and _stub.calls[1][0] == "seek" \
		and is_equal_approx(_stub.calls[0][1], 2.0) and is_equal_approx(_stub.calls[1][1], 3.0)
	_assert(seeks_ok, "a click or drag while playing seeks: %s" % [_stub.calls])

	# The play button toggles.
	_stub.calls.clear()
	panel._on_play_pressed()
	_assert(_stub.calls == [["stop"]], "the play button stops a playing preview: %s" % [_stub.calls])
	_stub.calls.clear()
	panel._on_play_pressed()
	_assert(_stub.calls == [["play", "/t/kick.wav", 0.0]], "the play button plays a stopped preview: %s" % [_stub.calls])
