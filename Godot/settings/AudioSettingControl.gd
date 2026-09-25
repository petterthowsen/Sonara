# AudioSettingControl.gd
# Settings control for the audio output settings (engine-stability-plan Phase 7): one scene
# serves "audio/output_device", "audio/sample_rate" and "audio/buffer_size". The options come
# from the engine's device list (AudioConfig), and a line below shows what the engine actually
# runs, which can differ from the setting (missing device, unsupported rate, PipeWire quantum).
# Implements the custom control interface documented in SettingRow.gd.
extends VBoxContainer

signal value_edited(value)

const WARNING_COLOR := Color(1.0, 0.72, 0.3)

var _setting
var _value
## Option index -> setting value.
var _values: Array = []
var _option: OptionButton
var _info: Label
var _warning: Label


func setup(setting, value) -> void:
	_setting = setting
	_value = value
	_build()
	AudioConfig.devices_changed.connect(_refresh)
	AudioConfig.config_changed.connect(_refresh)
	Settings.setting_changed.connect(_on_setting_changed)
	if _setting.key == AudioConfig.DEVICE_KEY:
		AudioConfig.request_devices()
	AudioConfig.request_config()
	_refresh()


func set_value(value) -> void:
	_value = value
	_refresh()


func get_value():
	return _value


func _exit_tree() -> void:
	if AudioConfig.devices_changed.is_connected(_refresh):
		AudioConfig.devices_changed.disconnect(_refresh)
	if AudioConfig.config_changed.is_connected(_refresh):
		AudioConfig.config_changed.disconnect(_refresh)
	if Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.disconnect(_on_setting_changed)


func _build() -> void:
	custom_minimum_size.x = 320
	_option = OptionButton.new()
	_option.fit_to_longest_item = false
	_option.item_selected.connect(_on_item_selected)
	add_child(_option)
	_info = _make_label()
	_warning = _make_label()
	_warning.add_theme_color_override("font_color", WARNING_COLOR)


func _make_label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	label.visible = false
	add_child(label)
	return label


func _on_item_selected(index: int) -> void:
	if index < 0 or index >= _values.size():
		return
	_value = _values[index]
	value_edited.emit(_value)
	_refresh()


func _on_setting_changed(key: String, _new_value) -> void:
	# Rates and buffer sizes depend on the device; buffer latencies on the rate.
	if key != _setting.key and key in AudioConfig.KEYS:
		_refresh()


## Rebuild the options and the info lines from the setting value and AudioConfig.
func _refresh() -> void:
	if _option == null:
		return
	var entries: Array = _entries()
	_option.clear()
	_values.clear()
	for entry in entries:
		_option.add_item(entry[1])
		_values.append(entry[0])
	var index := _values.find(_value)
	if index >= 0:
		_option.select(index)
	_set_label(_info, _info_text())
	_set_label(_warning, _warning_text())


## [value, label] pairs for the option list.
func _entries() -> Array:
	var entries: Array = []
	var device_name := str(Settings.get_value(AudioConfig.DEVICE_KEY))
	match _setting.key:
		AudioConfig.DEVICE_KEY:
			var default_device := AudioConfig.find_device("")
			var default_label := "System default"
			if not default_device.is_empty():
				default_label += " (%s)" % default_device.name
			entries.append(["", default_label])
			for device in AudioConfig.devices:
				entries.append([device.name, _device_label(device)])
			var current := str(_value)
			if not current.is_empty() and AudioConfig.find_device(current).is_empty():
				var suffix := " (not found)" if AudioConfig.devices_loaded else ""
				entries.append([current, current + suffix])
		AudioConfig.RATE_KEY:
			for rate in AudioConfig.rates_for(device_name, int(_value)):
				entries.append([rate, "%d Hz" % rate])
		AudioConfig.BUFFER_KEY:
			var rate := maxi(1, int(Settings.get_value(AudioConfig.RATE_KEY)))
			for size in AudioConfig.buffer_sizes_for(device_name, int(_value)):
				entries.append([size, "%d frames (%.1f ms)" % [size, size * 1000.0 / rate]])
	return entries


static func _device_label(device: Dictionary) -> String:
	var label: String = device.name
	var channels := int(device.get("channels", 0))
	if channels > 2:
		label += " — %d channels" % channels
	if (device.get("rates", []) as Array).is_empty():
		label += " (busy or unsupported)"
	return label


## What the engine runs, for this setting.
func _info_text() -> String:
	var config: Dictionary = AudioConfig.config
	if config.is_empty():
		return "Waiting for the audio engine…"
	if not AudioConfig.has_config():
		return "No audio output is open."
	match _setting.key:
		AudioConfig.DEVICE_KEY:
			var pairs := int(config.output_pairs)
			return "Running: %s, %d Hz, %d frames (%.1f ms), %d output pair%s" % [
				config.device, config.sample_rate, config.buffer_size, config.latency_ms,
				pairs, "" if pairs == 1 else "s"]
		AudioConfig.RATE_KEY:
			if int(config.sample_rate) != int(_value):
				return "Running at %d Hz." % config.sample_rate
		AudioConfig.BUFFER_KEY:
			var parts: Array[String] = []
			if int(config.buffer_size) != int(_value):
				parts.append("Running with %d frames." % config.buffer_size)
			if int(config.graph_quantum) > 0:
				parts.append("PipeWire quantum: %d frames at %d Hz." % [config.graph_quantum, config.graph_rate])
			return " ".join(parts)
	return ""


## Problems to point out: the engine's notice on the device row, graph conflicts on the buffer row.
func _warning_text() -> String:
	var config: Dictionary = AudioConfig.config
	if config.is_empty():
		return ""
	match _setting.key:
		AudioConfig.DEVICE_KEY:
			return str(config.get("notice", ""))
		AudioConfig.BUFFER_KEY:
			return str(config.get("mismatch", ""))
	return ""


static func _set_label(label: Label, text: String) -> void:
	label.text = text
	label.visible = not text.is_empty()
