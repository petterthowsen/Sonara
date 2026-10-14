## Sidechain options: the Source channel menu (spec 036 REQ-006) and the input spectrum on the
## left, the Gain, filter and follower knobs and the Amount slider on the right (spec 044).
##
## The options own the device's `"sidechain"` data stream: `setup` subscribes it and selects this
## modulator with the `mod_id` configure key, `_exit_tree` unsubscribes. A blob is the header
## `[mod_id, sample_rate, low_cut_hz, high_cut_hz]` (little-endian f32; a cut of 0 means the
## filter is bypassed) followed by the engine's `MiniAnalyser` points: the input after Gain
## (gray area) and after the filters (white line), with the cuts as markers. The menu lists "Device In" plus every project channel by name (master included,
## hardware outputs excluded), item metadata = channel id, and rebuilds when channels come or go.
class_name SidechainOptions extends ModulatorOptions

const SOURCE_PARAM := 40
const DATA_TYPE := "sidechain"
## Header floats before the `MiniAnalyser` points: mod_id, sample_rate, low cut, high cut.
const HEADER_BYTES := 16

@onready var source_menu: OptionButton = %SourceMenu
@onready var spectrum: MiniSpectrum = %Spectrum

var _project = null
var _stream_path := ""
## The latest decoded header: `{mod_id, sample_rate, low_cut_hz, high_cut_hz}`, or empty.
var last_header: Dictionary = {}


func setup(mod: Modulator) -> void:
	super.setup(mod)
	var channel = mod.owner().get_channel() if mod.owner() != null else null
	_project = channel.get_project() if channel != null else null
	if _project != null:
		_project.channel_added.connect(_on_channels_changed)
		_project.channel_removed.connect(_on_channels_changed)
	source_menu.item_selected.connect(_on_source_selected)
	_rebuild_source_menu()
	_subscribe_stream(mod)


func sync() -> void:
	super.sync()
	_sync_source_menu()


func _exit_tree() -> void:
	if _project != null:
		if _project.channel_added.is_connected(_on_channels_changed):
			_project.channel_added.disconnect(_on_channels_changed)
		if _project.channel_removed.is_connected(_on_channels_changed):
			_project.channel_removed.disconnect(_on_channels_changed)
	_project = null
	_unsubscribe_stream()


func _on_channels_changed(_channel_or_id) -> void:
	_rebuild_source_menu()


## (Re)fill the menu; the selection follows the stored channel id.
func _rebuild_source_menu() -> void:
	source_menu.clear()
	source_menu.add_item("Device In")
	source_menu.set_item_metadata(0, 0)
	if _project != null:
		for ch in _project.channels:
			if ch.id >= AudioConfig.HARDWARE_OUTPUT_BASE:
				continue
			source_menu.add_item(ch.name)
			source_menu.set_item_metadata(source_menu.item_count - 1, ch.id)
	_sync_source_menu()


func _sync_source_menu() -> void:
	if modulator == null or source_menu == null or source_menu.item_count == 0:
		return
	var param := modulator.get_parameter(SOURCE_PARAM)
	var channel_id := -1
	if param != null:
		channel_id = int(round(param.normalized_to_value(modulator.get_param(SOURCE_PARAM))))
	else:
		channel_id = int(round(modulator.get_param(SOURCE_PARAM) * 999.0))
	var select_index := -1
	for i in source_menu.item_count:
		if int(source_menu.get_item_metadata(i)) == channel_id:
			select_index = i
			break
	if select_index < 0:
		# The stored id no longer exists (channel removed): show it as missing, keep the id.
		source_menu.add_item("(missing channel)")
		source_menu.set_item_metadata(source_menu.item_count - 1, channel_id)
		select_index = source_menu.item_count - 1
	source_menu.select(select_index)


func _on_source_selected(index: int) -> void:
	if modulator == null or modulator.owner() == null:
		return
	var channel_id := int(source_menu.get_item_metadata(index))
	var param := modulator.get_parameter(SOURCE_PARAM)
	# The engine's Source parameter is a channel id in normalized units (linear 0..999).
	var norm := param.value_to_normalized(float(channel_id)) if param != null else float(channel_id) / 999.0
	modulator.owner().set_modulator_param(modulator.mod_id, SOURCE_PARAM, norm)


# ============================================================================
# SPECTRUM STREAM
# ============================================================================

func _subscribe_stream(mod: Modulator) -> void:
	var device = mod.owner()
	if device == null or _stream_path != "":
		return
	_stream_path = device.osc_path()
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)
	AudioEngineOSC.subscribe_device_data(_stream_path, DATA_TYPE)
	# The stream serves the selected modulator only, and the selection is lost with every
	# subscribe, so it is sent right after.
	AudioEngineOSC.configure_device_data(_stream_path, DATA_TYPE, "mod_id", float(mod.mod_id))


func _unsubscribe_stream() -> void:
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _stream_path != "":
		AudioEngineOSC.unsubscribe_device_data(_stream_path, DATA_TYPE)
		_stream_path = ""


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type == DATA_TYPE and osc_path == _stream_path:
		apply_blob(blob)


## Decode one `"sidechain"` blob into the spectrum. Returns false (and changes nothing) when it
## is too short or names another modulator.
func apply_blob(blob: PackedByteArray) -> bool:
	if modulator == null or blob.size() < HEADER_BYTES:
		return false
	if int(round(blob.decode_float(0))) != modulator.mod_id:
		return false
	var points := MiniSpectrum.decode_points(blob, HEADER_BYTES)
	if points.is_empty():
		return false
	last_header = {"mod_id": modulator.mod_id, "sample_rate": blob.decode_float(4),
		"low_cut_hz": blob.decode_float(8), "high_cut_hz": blob.decode_float(12)}
	spectrum.markers = [float(last_header["low_cut_hz"]), float(last_header["high_cut_hz"])]
	spectrum.set_curves(points["a"], points["b"], points["lo_hz"], points["hi_hz"])
	return true
