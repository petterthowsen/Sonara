## Panel view of the built-in EQ: a toolbar for the analyser mode and dB range, the curve editor
## (`EqCurveEditor`), and the footer of the selected band (selector, solo/enabled toggles, type,
## Freq/Gain/Q compact sliders) plus Output gain. As the Window view it is the full editor with
## the piano strip; the Companion view (`EqBandsCompanionView`) then has the knobs of every band.
##
## Analyser mode, range, resolution, speed and tilt are view state, not parameters: they live in
## the app config (`EqViewState.CONFIG_KEY`) and are the same for every EQ. The view subscribes to
## the device's `"spectrum"` stream while shown (and the analyser isn't off) and unsubscribes when
## hidden. Resolution and speed are engine options (`data/configure`), sent after subscribing and
## whenever they change; tilt is applied only when drawing.
##
## Modulation: while shown, the view follows `ModLive.live_values_changed` for the device and its
## ancestors and hands each band's live Freq/Gain/Q (and the live Output gain) to the editor
## (`EqCurveEditor.set_live`), which draws them over the set curve.
class_name EqDefaultView extends DeviceView

const STRIP_HEIGHT := 78.0
const RESOLUTION_LABELS: Array[String] = ["Low", "Medium", "High", "Max"]
const SPEED_LABELS: Array[String] = ["Fast", "Medium", "Slow"]
## Item ids in the Display menu: resolution, speed and tilt items start at these.
const MENU_RESOLUTION := 0
const MENU_SPEED := 10
const MENU_TILT := 20
## The band fields the modulation display follows, by parameter offset.
const LIVE_FIELDS := {EqResponse.P_FREQ: "freq", EqResponse.P_GAIN: "gain", EqResponse.P_Q: "q"}

var editor: EqCurveEditor = null
## Read and write the view state. Default: the app config (Sonara autoload); tests replace them.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

var _analyser_option: OptionButton = null
var _range_option: OptionButton = null
var _display_menu: MenuButton = null
var _band_option: OptionButton = null
var _solo_button: Button = null
var _enabled_button: Button = null
var _type_option: OptionButton = null
var _freq_slider: CompactSlider = null
var _gain_slider: CompactSlider = null
var _q_slider: CompactSlider = null
var _output_knob: LabeledKnob = null
var _root: VBoxContainer = null
var _footer: HBoxContainer = null
## The band the footer shows: always one (REQ-009). The selector's band; the editor follows.
var _band := -1
## Views subscribed per device path. The engine keeps one subscription per device, not one per
## view, so the panel and window views share it: the last one to unsubscribe cancels it.
static var _subscriber_counts := {}
var _subscribed := false
var _shown := false
## The analyser options last sent to the engine (-1: none since subscribing).
var _sent_resolution := -1
var _sent_speed := -1


func _ready() -> void:
	_build()


## True for the Window view: the same editor, with the piano strip and without the knob row (the
## companion view in the device panel has the knobs).
func _is_window() -> bool:
	return is_type(Device.ViewType.Window)


## The panel width is automatic: the wider of the toolbar and the footer row (its dropdowns,
## toggles, sliders and the output knob) decides, so the device grows horizontally with its
## content. Floors keep the window view and the curve editor usable when content is narrow.
func _get_minimum_size() -> Vector2:
	if _root == null:
		return Vector2(640, 380) if _is_window() else Vector2(420, 250)
	var floor_min := Vector2(640, 380) if _is_window() else Vector2(420, 250)
	var wanted := _root.get_combined_minimum_size()
	return Vector2(maxf(wanted.x, floor_min.x), maxf(wanted.y, floor_min.y))


func _build() -> void:
	if editor != null:
		return
	_root = VBoxContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 3)
	add_child(_root)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	_root.add_child(toolbar)
	toolbar.add_child(_caption("Analyser"))
	_analyser_option = OptionButton.new()
	for name in ["Post", "Pre", "Off"]:
		_analyser_option.add_item(name)
	_analyser_option.item_selected.connect(_on_analyser_selected)
	toolbar.add_child(_analyser_option)
	toolbar.add_child(_caption("Range"))
	_range_option = OptionButton.new()
	for range_db in DbGrid.EQ_RANGES:
		_range_option.add_item("±%d dB" % int(range_db))
	_range_option.item_selected.connect(_on_range_selected)
	toolbar.add_child(_range_option)
	_display_menu = MenuButton.new()
	_display_menu.text = "Display"
	_display_menu.flat = false
	_display_menu.tooltip_text = "Analyser resolution, speed and tilt"
	_build_display_menu(_display_menu.get_popup())
	toolbar.add_child(_display_menu)

	editor = EqCurveEditor.new()
	editor.show_piano = _is_window()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.view_state_changed.connect(_on_editor_view_state_changed)
	editor.selection_changed.connect(_on_selection_changed)
	_root.add_child(editor)

	# The footer: band selector, solo/enabled toggles, type dropdown with icons, the three
	# compact sliders of the selected band, then the output knob. No scrolling: the row is as
	# wide as its content and the device grows horizontally with it.
	_footer = HBoxContainer.new()
	_footer.custom_minimum_size.y = STRIP_HEIGHT
	_footer.visible = not _is_window()
	_footer.add_theme_constant_override("separation", 10)
	_root.add_child(_footer)
	_band_option = OptionButton.new()
	_band_option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_band_option.tooltip_text = "Band"
	for band in EqResponse.BAND_COUNT:
		_band_option.add_icon_item(_color_swatch(EqCurveEditor.band_color(band)), str(band + 1))
	_band_option.item_selected.connect(_on_band_selected)
	_footer.add_child(_band_option)
	_solo_button = Button.new()
	_solo_button.toggle_mode = true
	_solo_button.icon = preload("res://assets/icons/volume-2.svg")
	_solo_button.tooltip_text = "Listen to this band only"
	_solo_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_solo_button.toggled.connect(_on_solo_toggled)
	_footer.add_child(_solo_button)
	_enabled_button = Button.new()
	_enabled_button.toggle_mode = true
	_enabled_button.icon = preload("res://assets/icons/power.svg")
	_enabled_button.tooltip_text = "Band on/off"
	_enabled_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_enabled_button.toggled.connect(_on_enabled_toggled)
	_footer.add_child(_enabled_button)
	_type_option = OptionButton.new()
	_type_option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for i in EqResponse.TYPE_NAMES.size():
		_type_option.add_icon_item(null, EqResponse.TYPE_NAMES[i])
	_type_option.item_selected.connect(_on_type_selected)
	_footer.add_child(_type_option)
	_freq_slider = EqKnobs.make_compact("Freq", _on_band_knob_changed.bind(EqResponse.P_FREQ))
	_gain_slider = EqKnobs.make_compact("Gain", _on_band_knob_changed.bind(EqResponse.P_GAIN))
	_q_slider = EqKnobs.make_compact("Q", _on_band_knob_changed.bind(EqResponse.P_Q))
	for slider in [_freq_slider, _gain_slider, _q_slider]:
		slider.custom_minimum_size.x = 90.0
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_footer.add_child(slider)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(spacer)
	_output_knob = EqKnobs.make_knob("Out", _on_param_knob_changed.bind(EqResponse.OUTPUT_GAIN))
	_footer.add_child(_output_knob)

	_apply_state(_read_state())
	_refresh_band_controls()


## A small square in the band's colour, as the band selector's item icon.
static func _color_swatch(color: Color) -> ImageTexture:
	var image := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _build_display_menu(popup: PopupMenu) -> void:
	popup.hide_on_checkable_item_selection = false
	popup.add_separator("Resolution")
	for i in RESOLUTION_LABELS.size():
		popup.add_radio_check_item(RESOLUTION_LABELS[i], MENU_RESOLUTION + i)
	popup.add_separator("Speed")
	for i in SPEED_LABELS.size():
		popup.add_radio_check_item(SPEED_LABELS[i], MENU_SPEED + i)
	popup.add_separator("Tilt")
	for i in EqViewState.TILTS.size():
		var tilt := EqViewState.TILTS[i]
		popup.add_radio_check_item("Flat" if tilt == 0.0 else "%s dB/oct" % str(tilt), MENU_TILT + i)
	popup.id_pressed.connect(_on_display_item)


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	return label


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	_build()
	editor.device = device
	var audio_config := _autoload("AudioConfig")
	if audio_config != null and audio_config.config.has("sample_rate"):
		editor.sample_rate = float(audio_config.config["sample_rate"])
	EqKnobs.configure(_output_knob.knob, device, EqResponse.OUTPUT_GAIN, "%+.1f", " dB")
	# REQ-009: the footer always shows a band. Fall back to the first enabled one, else band 1,
	# and let the editor follow so the two stay in sync from the start.
	if editor.selected_band >= 0:
		_band = editor.selected_band
	else:
		_band = _fallback_band()
		editor.select_band(_band)
	_configure_band_knobs()
	_refresh_band_controls()
	_refresh_output()


## The band to show when the editor has none: the first enabled band, else band 1.
func _fallback_band() -> int:
	if device != null:
		for band in EqResponse.BAND_COUNT:
			if device.get_parameter_real(band * EqResponse.BAND_STRIDE + EqResponse.P_ENABLED) >= 0.5:
				return band
	return 0
	_refresh_output()


func _on_unbind() -> void:
	_shown = false
	_sync_subscription()
	_sync_live_feed()
	if editor != null:
		editor.device = null


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if editor == null:
		return
	if param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		if param_id / EqResponse.BAND_STRIDE == _band:
			_refresh_band_controls()
	elif param_id == EqResponse.OUTPUT_GAIN:
		_refresh_output()
	elif param_id == EqResponse.LISTEN_BAND:
		_refresh_band_controls()


func _on_selection_changed(band: int) -> void:
	# REQ-009: an editor selection of -1 never clears the footer's band.
	if band < 0:
		return
	_band = band
	_band_option.select(band)
	_configure_band_knobs()
	_refresh_band_controls()


func _on_band_selected(index: int) -> void:
	_band = index
	# The editor may already sit on this band (then select_band is a no-op without a signal).
	editor.select_band(index)
	_configure_band_knobs()
	_refresh_band_controls()


## Aim the three sliders at the selected band's parameters.
func _configure_band_knobs() -> void:
	if device == null or _band < 0:
		return
	var base := _band * EqResponse.BAND_STRIDE
	EqKnobs.configure_compact(_freq_slider, device, base + EqResponse.P_FREQ, "%.0f", " Hz")
	EqKnobs.configure_compact(_gain_slider, device, base + EqResponse.P_GAIN, "%+.1f", " dB")
	EqKnobs.configure_compact(_q_slider, device, base + EqResponse.P_Q, "%.2f", "")


## Show the selected band's state: selector, solo/enabled toggles, type icons in the band's
## colour and the sliders. A disabled band dims its strip, but every control stays interactive
## (REQ-009).
func _refresh_band_controls() -> void:
	if _band_option == null:
		return
	if device == null or _band < 0:
		for control in [_band_option, _solo_button, _enabled_button, _type_option, _freq_slider, _gain_slider, _q_slider]:
			control.modulate.a = 0.25
		return
	var base := _band * EqResponse.BAND_STRIDE
	var enabled := device.get_parameter_real(base + EqResponse.P_ENABLED) >= 0.5
	var type := int(device.get_parameter_real(base + EqResponse.P_TYPE))
	var soloed := int(device.get_parameter_real(EqResponse.LISTEN_BAND)) == _band + 1
	_band_option.select(_band)
	_solo_button.set_pressed_no_signal(soloed)
	_enabled_button.set_pressed_no_signal(enabled)
	for i in EqResponse.TYPE_NAMES.size():
		_type_option.set_item_icon(i, EqTypeIcon.texture(i, EqCurveEditor.band_color(_band)))
	_type_option.select(type)
	_freq_slider.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_FREQ))
	_gain_slider.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_GAIN))
	_q_slider.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_Q))
	var strip_alpha := 1.0 if enabled else 0.55
	for control in [_band_option, _solo_button, _enabled_button, _type_option, _freq_slider, _gain_slider, _q_slider]:
		control.modulate.a = strip_alpha
	# After the strip dim: a gain-less type dims the gain slider further and ignores the mouse.
	EqKnobs.dim_value_control(_gain_slider, type)


func _refresh_output() -> void:
	if device != null:
		_output_knob.knob.set_value_no_signal(device.get_parameter_real(EqResponse.OUTPUT_GAIN))


func _on_band_knob_changed(value: float, offset: int) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(_band * EqResponse.BAND_STRIDE + offset, value)


func _on_type_selected(index: int) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(_band * EqResponse.BAND_STRIDE + EqResponse.P_TYPE, float(index))


## Solo the selected band (`LISTEN_BAND = band + 1`); pressing it while soloed goes back to Off.
func _on_solo_toggled(pressed: bool) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(EqResponse.LISTEN_BAND, float(_band + 1) if pressed else 0.0)


func _on_enabled_toggled(pressed: bool) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(_band * EqResponse.BAND_STRIDE + EqResponse.P_ENABLED, 1.0 if pressed else 0.0)


func _on_param_knob_changed(value: float, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, value)


# ============================================================================
# VIEW STATE AND ANALYSER
# ============================================================================

func _read_state() -> EqViewState:
	var data: Variant = load_config.call(EqViewState.CONFIG_KEY)
	return EqViewState.from_dict(data)


## Show `state` in the editor and the toolbar.
func _apply_state(state: EqViewState) -> void:
	editor.state = state
	_analyser_option.select(state.analyser)
	_range_option.select(maxi(DbGrid.EQ_RANGES.find(state.range_db), 0))
	_refresh_display_menu()
	_sync_subscription()


## Tick the current resolution, speed and tilt in the Display menu.
func _refresh_display_menu() -> void:
	var popup := _display_menu.get_popup()
	var state := editor.state
	for i in RESOLUTION_LABELS.size():
		popup.set_item_checked(popup.get_item_index(MENU_RESOLUTION + i), i == state.resolution)
	for i in SPEED_LABELS.size():
		popup.set_item_checked(popup.get_item_index(MENU_SPEED + i), i == state.speed)
	for i in EqViewState.TILTS.size():
		popup.set_item_checked(popup.get_item_index(MENU_TILT + i), is_equal_approx(EqViewState.TILTS[i], state.tilt_db))


func _on_display_item(id: int) -> void:
	if id >= MENU_TILT:
		editor.set_tilt_db(EqViewState.TILTS[id - MENU_TILT])
	elif id >= MENU_SPEED:
		editor.set_speed(id - MENU_SPEED)
	else:
		editor.set_resolution(id - MENU_RESOLUTION)


func _on_analyser_selected(index: int) -> void:
	editor.set_analyser_mode(index)


func _on_range_selected(index: int) -> void:
	editor.set_range_db(DbGrid.EQ_RANGES[index])


func _on_editor_view_state_changed() -> void:
	save_config.call(EqViewState.CONFIG_KEY, editor.state.to_dict())
	_refresh_display_menu()
	_sync_subscription()
	_send_analyser_options()


## Subscribe while shown and the analyser is on; unsubscribe otherwise.
func _sync_subscription() -> void:
	var want := _shown and device != null and editor != null and editor.state.analyser != EqViewState.Analyser.OFF
	if want == _subscribed:
		return
	_sent_resolution = -1
	_sent_speed = -1
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	var path: String = device.osc_path()
	var count: int = _subscriber_counts.get(path, 0)
	if want:
		_subscriber_counts[path] = count + 1
		if count == 0:
			osc.subscribe_device_data(path, "spectrum")
		if not osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.connect(_on_spectrum_received)
	else:
		_subscriber_counts[path] = maxi(count - 1, 0)
		if count <= 1:
			_subscriber_counts.erase(path)
			osc.unsubscribe_device_data(path, "spectrum")
		if osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.disconnect(_on_spectrum_received)
	_subscribed = want
	_send_analyser_options()


## Send resolution and speed to the engine when subscribed and they changed since the last send.
## The engine ignores a resolution it already has, so a second view resending is harmless.
func _send_analyser_options() -> void:
	if not _subscribed or device == null:
		return
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	var path: String = device.osc_path()
	if editor.state.resolution != _sent_resolution:
		_sent_resolution = editor.state.resolution
		osc.configure_device_data(path, "spectrum", "resolution", float(_sent_resolution))
	if editor.state.speed != _sent_speed:
		_sent_speed = editor.state.speed
		osc.configure_device_data(path, "spectrum", "speed", float(_sent_speed))


func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()
	_sync_live_feed()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	_sync_live_feed()
	if editor != null:
		editor.end_interaction()
		editor.clear_analyser()


# ============================================================================
# MODULATION
# ============================================================================

## Follow the live modulation values while shown (`DeviceView.show_view` already subscribes the
## device's stream); hidden, drop the listener and the editor's live state.
func _sync_live_feed() -> void:
	var live := ModLive.holder()
	var want := _shown and device != null
	if want and not live.live_values_changed.is_connected(_on_live_values_changed):
		live.live_values_changed.connect(_on_live_values_changed)
	elif not want and live.live_values_changed.is_connected(_on_live_values_changed):
		live.live_values_changed.disconnect(_on_live_values_changed)
	if want:
		_refresh_live()
	elif editor != null:
		editor.clear_live()


## Live values reach this EQ from its own stream or an ancestor's (a container's modulator).
func _on_live_values_changed(reporter) -> void:
	var walk = device
	while walk != null:
		if walk == reporter:
			_refresh_live()
			return
		walk = walk.get_parent_device()


## Read every band's live Freq/Gain/Q and the live Output gain into the editor.
func _refresh_live() -> void:
	if device == null or editor == null:
		return
	var values: Array = []
	for band in EqResponse.BAND_COUNT:
		var live := {}
		for offset: int in LIVE_FIELDS:
			var real := _live_real(band * EqResponse.BAND_STRIDE + offset)
			if not is_nan(real):
				live[LIVE_FIELDS[offset]] = real
		values.append(live)
	editor.set_live(values, _live_real(EqResponse.OUTPUT_GAIN))


## The live value of `param_id` in real units, NAN when nothing modulates it.
func _live_real(param_id: int) -> float:
	var normalized := ModLive.live_value(device, param_id)
	var param = device.get_parameter(param_id)
	if normalized < 0.0 or param == null:
		return NAN
	return param.normalized_to_value(normalized)


func _on_spectrum_received(osc_path: String, frame: PackedFloat32Array) -> void:
	if device != null and osc_path == device.osc_path() and editor != null:
		editor.on_spectrum_frame(frame)


# ============================================================================
# APP CONFIG (Sonara autoload, looked up by name so the script also loads without it)
# ============================================================================

func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null


func _load_app_config(key: String) -> Variant:
	var sonara := _autoload("Sonara")
	return sonara.get_config(key, {}) if sonara != null else {}


func _save_app_config(key: String, value: Variant) -> void:
	var sonara := _autoload("Sonara")
	if sonara == null:
		return
	sonara.set_config(key, value)
	sonara.save_config()
