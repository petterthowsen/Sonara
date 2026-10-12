## BrowserInfoPanel.gd
## Info panel at the bottom of the Browser (spec 037): filename, type and size of the selected
## item, for audio also sample rate, channels and duration, and its waveform with a play/stop
## button and a playhead that a click or drag moves. Playback goes through the PreviewPlayer
## model; the panel never sends OSC.
class_name BrowserInfoPanel extends PanelContainer

const CONFIG_KEY := "ui/browser"
const WAVE_HEIGHT := 48.0

@onready var _name_label: Label = $VBox/Header/NameLabel
@onready var _type_label: Label = $VBox/Header/TypeLabel
@onready var _collapse_button: Button = $VBox/Header/CollapseButton
@onready var _body: VBoxContainer = $VBox/Body
@onready var _details_label: Label = $VBox/Body/DetailsLabel
@onready var _audio_row: HBoxContainer = $VBox/Body/AudioRow
@onready var _play_button: Button = $VBox/Body/AudioRow/PlayButton
@onready var _wave_holder: Control = $VBox/Body/AudioRow/WaveHolder

var _wave: WaveformView
var _overlay: Control
var _preview: PreviewPlayer
var _asset: Asset = null
var _collapsed := false
var _seeking := false
var _playhead_color := Color.WHITE
## Duration of the shown audio file in seconds (0 until known).
var _duration_s := 0.0
var _peak_path := ""


func _ready() -> void:
	var bold := FontVariation.new()
	bold.base_font = get_theme_default_font()
	bold.variation_embolden = 1.2
	_name_label.add_theme_font_override(&"font", bold)
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_type_label.add_theme_color_override(&"font_color", UiColors.role(&"text_dim"))
	_details_label.add_theme_color_override(&"font_color", UiColors.role(&"text_dim"))
	_playhead_color = UiColors.role(&"accent_primary")
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_wave_holder.custom_minimum_size = Vector2(0, WAVE_HEIGHT)
	_wave_holder.clip_contents = true
	_wave_holder.mouse_filter = Control.MOUSE_FILTER_STOP
	_wave_holder.gui_input.connect(_on_wave_input)
	_wave_holder.resized.connect(_fit_waveform)
	_wave = WaveformView.new()
	_wave.name = "WaveformView"
	_wave.placeholder_text = ""
	_wave.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wave.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_holder.add_child(_wave)
	_overlay = Control.new()
	_overlay.name = "Playhead"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_playhead)
	_wave_holder.add_child(_overlay)

	_play_button.icon = preload("res://assets/icons/play.svg")
	_play_button.focus_mode = Control.FOCUS_NONE
	_play_button.tooltip_text = "Play / stop the preview"
	_play_button.pressed.connect(_on_play_pressed)
	_collapse_button.flat = true
	_collapse_button.focus_mode = Control.FOCUS_NONE
	_collapse_button.pressed.connect(_on_collapse_pressed)

	var saved: Variant = Sonara.get_config(CONFIG_KEY, {})
	if saved is Dictionary:
		_collapsed = bool(saved.get("info_collapsed", false))
	_apply_collapsed()
	visible = false


## Connect the preview model. The panel follows its state and position.
func setup(preview: PreviewPlayer) -> void:
	_preview = preview
	preview.state_changed.connect(_on_state_changed)
	preview.position_changed.connect(_on_position_changed)
	preview.info_ready.connect(_on_info_ready)


# ============================================================================
# CONTENT
# ============================================================================

## Show `asset`'s info; a non-Asset hides the panel.
func show_asset(asset: Asset) -> void:
	_asset = asset
	_duration_s = 0.0
	_peak_path = ""
	if _wave:
		_wave.data = null
	if asset == null:
		visible = false
		return
	visible = true
	_refresh_text()
	var is_audio := asset.is_audio()
	_audio_row.visible = is_audio
	_update_play_button()
	if is_audio and _preview:
		_preview.request_info(asset.path)
	_overlay.queue_redraw()


func clear_asset() -> void:
	show_asset(null)


## Line 1 (name and type) and line 2 (details) for the current asset.
func _refresh_text() -> void:
	var lines := describe(_asset, _audio_facts())
	_name_label.text = lines.name
	_type_label.text = lines.type
	_details_label.text = lines.details
	_details_label.visible = not lines.details.is_empty()


## What the peak file and decode tell about the shown audio file.
func _audio_facts() -> Dictionary:
	var facts := {"duration_s": _duration_s}
	if _wave and _wave.data and _wave.data.is_ready():
		facts["sample_rate"] = _wave.data.source_sample_rate
		facts["channels"] = _wave.data.channels
	return facts


## Texts of the panel for `asset`: {name, type, details}. `facts` may carry `sample_rate`,
## `channels` and `duration_s` for audio.
static func describe(asset: Asset, facts: Dictionary = {}) -> Dictionary:
	if asset == null:
		return {"name": "", "type": "", "details": ""}
	var parts: Array[String] = []
	var type_text := ""
	var file_name := asset.path.get_file()
	match asset.type:
		Asset.TYPE.Audio, Asset.TYPE.Midi, Asset.TYPE.SoundFont, Asset.TYPE.SFZ:
			type_text = "%s · %s" % [asset.get_file_extension().to_upper(), _type_name(asset)]
		Asset.TYPE.Preset:
			file_name = asset.get_display_name()
			type_text = "Preset"
			var device_label := asset.device_name if not asset.device_name.is_empty() else asset.device_id
			if not device_label.is_empty():
				parts.append(device_label)
			if not asset.author.is_empty():
				parts.append(asset.author)
		Asset.TYPE.Device:
			var device = AssetService.get_device(asset.path)
			file_name = device.name if device else asset.get_display_name()
			type_text = "Device"
			if device:
				if not device.author.is_empty():
					parts.append(device.author)
				parts.append(device.get_browser_group())
	if asset.file_size_bytes > 0:
		parts.append(format_size(asset.file_size_bytes))
	if asset.is_audio():
		if facts.get("sample_rate", 0) > 0:
			parts.append("%s Hz" % _trim_number(float(facts.sample_rate)))
		if facts.get("channels", 0) > 0:
			parts.append(channels_text(int(facts.channels)))
		if facts.get("duration_s", 0.0) > 0.0:
			parts.append(format_duration(float(facts.duration_s)))
	return {"name": file_name, "type": type_text, "details": " · ".join(parts)}


static func _type_name(asset: Asset) -> String:
	return Asset.TYPE.keys()[asset.type] if asset.type != Asset.TYPE.SFZ else "SFZ instrument"


static func channels_text(channels: int) -> String:
	match channels:
		1:
			return "Mono"
		2:
			return "Stereo"
	return "%d ch" % channels


## 1536 -> "1.5 KB".
static func format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	if bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	return "%.2f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))


## 0.5 -> "0.50 s", 83.2 -> "1:23.2".
static func format_duration(seconds: float) -> String:
	if seconds < 60.0:
		return "%.2f s" % seconds
	var minutes := int(seconds / 60.0)
	return "%d:%04.1f" % [minutes, seconds - minutes * 60.0]


static func _trim_number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else "%.1f" % value


# ============================================================================
# WAVEFORM AND SEEKING
# ============================================================================

func _on_info_ready(path: String, peak_path: String, duration_s: float) -> void:
	if _asset == null or _asset.path != path:
		return
	_peak_path = peak_path
	if duration_s > 0.0:
		_duration_s = duration_s
	var data := WaveformRegistry.get_or_load(peak_path)
	_wave.data = data
	if data and not data.is_ready():
		data.loaded.connect(_on_wave_loaded, CONNECT_ONE_SHOT)
	_on_wave_loaded()


func _on_wave_loaded(_ok := true) -> void:
	if _duration_s <= 0.0 and _wave.data and _wave.data.is_ready() and _wave.data.source_sample_rate > 0:
		_duration_s = float(_wave.data.frames) / float(_wave.data.source_sample_rate)
	_fit_waveform()
	_refresh_text()
	_overlay.queue_redraw()


## Show the whole file across the width of the waveform.
func _fit_waveform() -> void:
	if _wave == null or not _wave.is_data_ready() or _wave_holder.size.x <= 0.0:
		return
	_wave.start_frame = 0.0
	_wave.frames_per_pixel = float(_wave.data.frames) / _wave_holder.size.x


## Seconds at local x of the waveform; clamped to the file.
func seek_x_to_seconds(x: float) -> float:
	var width := _wave_holder.size.x
	if width <= 0.0 or _duration_s <= 0.0:
		return 0.0
	return clampf(x / width, 0.0, 1.0) * _duration_s


func _on_wave_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_seeking = event.pressed
		if event.pressed:
			_seek_to(event.position.x, true)
		_wave_holder.accept_event()
	elif event is InputEventMouseMotion and _seeking:
		_seek_to(event.position.x, false)
		_wave_holder.accept_event()


## A press while stopped plays from that point; otherwise (and while dragging) it seeks.
func _seek_to(x: float, pressed: bool) -> void:
	if _asset == null or _preview == null or _duration_s <= 0.0:
		return
	var pos := seek_x_to_seconds(x)
	if _preview.is_playing_path(_asset.path):
		_preview.seek(pos)
	elif pressed:
		_preview.play(_asset.path, pos)


func _draw_playhead() -> void:
	if _asset == null or _preview == null or _duration_s <= 0.0 or _preview.path != _asset.path:
		return
	if _preview.state == PreviewPlayer.State.FAILED:
		return
	var x := clampf(_preview.position_s / _duration_s, 0.0, 1.0) * _overlay.size.x
	if _preview.state == PreviewPlayer.State.STOPPED and _preview.position_s <= 0.0:
		return
	_overlay.draw_line(Vector2(x, 0), Vector2(x, _overlay.size.y), _playhead_color, 1.5)


# ============================================================================
# PLAYBACK BUTTON
# ============================================================================

func _on_play_pressed() -> void:
	if _asset == null or _preview == null:
		return
	_preview.toggle(_asset.path)


func _on_state_changed(_path: String, _state: int) -> void:
	_update_play_button()
	_overlay.queue_redraw()


func _on_position_changed(_pos_s: float, duration_s: float) -> void:
	if _duration_s <= 0.0 and duration_s > 0.0 and _asset and _preview.path == _asset.path:
		_duration_s = duration_s
	_overlay.queue_redraw()


func _update_play_button() -> void:
	var playing: bool = _asset != null and _preview != null and _preview.is_playing_path(_asset.path)
	_play_button.icon = preload("res://assets/icons/square.svg") if playing else preload("res://assets/icons/play.svg")
	_play_button.set_pressed_no_signal(playing)


# ============================================================================
# COLLAPSING
# ============================================================================

func _on_collapse_pressed() -> void:
	_collapsed = not _collapsed
	_apply_collapsed()
	var saved: Variant = Sonara.get_config(CONFIG_KEY, {})
	var data: Dictionary = saved if saved is Dictionary else {}
	data["info_collapsed"] = _collapsed
	Sonara.set_config(CONFIG_KEY, data)
	Sonara.save_config()


func _apply_collapsed() -> void:
	_body.visible = not _collapsed
	_collapse_button.icon = preload("res://assets/icons/chevron-right.svg") if _collapsed else preload("res://assets/icons/chevron-down.svg")
	_collapse_button.tooltip_text = "Show details" if _collapsed else "Hide details"
