## Companion view of the built-in EQ, shown in the device panel while the window view (the full
## analyser) is open: one vertical strip per band: on/off and solo toggles, the band type and (for cuts) slope
## dropdowns, and Freq, Gain and Q knobs showing their values. It holds the exact-entry and automation targets the
## panel view has no room for (it shows only the selected band). Each strip is an `EqBandStrip.tscn`
## instance in the scene's `Row`.
class_name EqBandsCompanionView extends DeviceView

const StripScene := preload("res://devices/builtin/eq/EqBandStrip.tscn")
## Preloaded rather than named, so the type resolves before the class cache knows `EqBandStrip`.
const Strip := preload("res://devices/builtin/eq/EqBandStrip.gd")

## One strip per band, in band order; filled in `_ready`.
var _items: Array[Strip] = []
@onready var _row: HBoxContainer = %Row


## Instantiate the band strips and hook them up, then bind if a device arrived before the tree.
func _ready() -> void:
	_row.minimum_size_changed.connect(update_minimum_size)
	for band in EqResponse.BAND_COUNT:
		var strip: Strip = StripScene.instantiate()
		strip.show_band(band)
		strip.toggle.toggled.connect(_on_toggled.bind(band))
		strip.solo.toggled.connect(_on_solo_toggled.bind(band))
		strip.type.item_selected.connect(_on_type_selected.bind(band))
		strip.slope.item_selected.connect(_on_slope_selected.bind(band))
		var base := band * EqResponse.BAND_STRIDE
		strip.freq.knob.value_changed.connect(_on_knob_changed.bind(base + EqResponse.P_FREQ))
		strip.gain.knob.value_changed.connect(_on_knob_changed.bind(base + EqResponse.P_GAIN))
		strip.q.knob.value_changed.connect(_on_knob_changed.bind(base + EqResponse.P_Q))
		_row.add_child(strip)
		_items.append(strip)
	update_minimum_size()
	if device != null:
		_setup()


## The strips' own size, so the device panel grows to fit them instead of the row overflowing it.
func _get_minimum_size() -> Vector2:
	return _row.get_combined_minimum_size() if _row != null else Vector2.ZERO


func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the strips and the device.
func _setup() -> void:
	for band in EqResponse.BAND_COUNT:
		var base := band * EqResponse.BAND_STRIDE
		EqKnobs.configure(_items[band].freq.knob, device, base + EqResponse.P_FREQ, "%.0f", " Hz")
		EqKnobs.configure(_items[band].gain.knob, device, base + EqResponse.P_GAIN, "%+.1f", " dB")
		EqKnobs.configure(_items[band].q.knob, device, base + EqResponse.P_Q, "%.2f", "")
		_refresh_band(band)


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if not is_node_ready() or device == null:
		return
	if param_id == EqResponse.LISTEN_BAND:
		_refresh_solo()
	elif param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		_refresh_band(param_id / EqResponse.BAND_STRIDE)


func _refresh_band(band: int) -> void:
	if device == null:
		return
	var item := _items[band]
	var base := band * EqResponse.BAND_STRIDE
	var enabled := device.get_parameter_real(base + EqResponse.P_ENABLED) >= 0.5
	var type := int(device.get_parameter_real(base + EqResponse.P_TYPE))
	item.toggle.set_pressed_no_signal(enabled)
	item.type.select(type)
	item.slope.select(clampi(int(device.get_parameter_real(base + EqResponse.P_SLOPE)), 0, EqResponse.SLOPE_NAMES.size() - 1))
	# Only the cuts have a slope; for other types the box stays but is disabled.
	item.slope.disabled = not EqResponse.type_is_cut(type)
	item.freq.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_FREQ))
	item.gain.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_GAIN))
	item.q.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_Q))
	# A disabled band stays editable (set it up, then switch it on), only dimmed.
	item.modulate.a = 1.0 if enabled else 0.55
	EqKnobs.dim_value_control(item.gain, type)
	_refresh_solo()


## The listen band is one device-level parameter for all bands: every strip's solo button
## reflects it whenever it changes.
func _refresh_solo() -> void:
	if device == null:
		return
	var listen := int(device.get_parameter_real(EqResponse.LISTEN_BAND))
	for band in EqResponse.BAND_COUNT:
		_items[band].solo.set_pressed_no_signal(listen == band + 1)


func _on_toggled(pressed: bool, band: int) -> void:
	if device != null:
		ParameterActions.set_real(device, band * EqResponse.BAND_STRIDE + EqResponse.P_ENABLED, 1.0 if pressed else 0.0)


## Solo a band (`LISTEN_BAND = band + 1`); pressing it while soloed goes back to Off.
func _on_solo_toggled(pressed: bool, band: int) -> void:
	if device != null:
		ParameterActions.set_real(device, EqResponse.LISTEN_BAND, float(band + 1) if pressed else 0.0)


func _on_type_selected(index: int, band: int) -> void:
	if device != null:
		ParameterActions.set_real(device, band * EqResponse.BAND_STRIDE + EqResponse.P_TYPE, float(index))


func _on_slope_selected(index: int, band: int) -> void:
	if device != null:
		ParameterActions.set_real(device, band * EqResponse.BAND_STRIDE + EqResponse.P_SLOPE, float(index))


func _on_knob_changed(value: float, param_id: int) -> void:
	if device != null:
		ParameterActions.set_real(device, param_id, value)
