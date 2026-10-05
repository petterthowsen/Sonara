## Mini channel strip beside the Drum Machine pad grid: pan, meter with fader, solo and mute for
## the primary pad's return channel (the pad's child channel in the mixer, see AuxReturnSync).
## Edits go through the Channel setters with the same undo as MixerChannel, so the strip and the
## mixer strip are two views of one channel. Disabled when the pad is empty or has no return
## (a Drum Machine nested in another device).
class_name DrumPadStrip extends VBoxContainer

@onready var _pan: PanControl = $Pan
@onready var _meter: Meter = $Meter
@onready var _solo: Button = $SoloMute/Solo
@onready var _mute: Button = $SoloMute/Mute

var channel: Channel = null
var _drum: DeviceInstance = null
var _pad: DeviceInstance = null
var _resolve_queued := false


func _ready() -> void:
	_meter.volume_changed.connect(_on_volume_changed)
	_solo.toggled.connect(_on_solo_toggled)
	_mute.toggled.connect(_on_mute_toggled)
	_refresh()


## Follow `pad` (null for none or an empty pad) of `drum`. The return is looked up deferred: a
## new pad's return channel is created after `child_added` fires.
func bind_pad(drum: DeviceInstance, pad: DeviceInstance) -> void:
	_drum = drum
	_pad = pad
	if not _resolve_queued:
		_resolve_queued = true
		_resolve.call_deferred()


## Drop the pad and channel binding.
func unbind() -> void:
	_drum = null
	_pad = null
	_bind_channel(null)


func _resolve() -> void:
	_resolve_queued = false
	_bind_channel(_return_channel())


## The primary pad's return channel, or null.
func _return_channel() -> Channel:
	if _drum == null or _pad == null or not is_instance_valid(_pad) or _pad.get_parent_device() != _drum:
		return null
	var ch := _drum.get_channel()
	var project := ch.get_project() if ch else null
	if project == null:
		return null
	var ret := project.get_channel_by_id(_pad.return_channel_id)
	return ret if ret and ret.parent_channel_id == ch.id else null


func _bind_channel(ch: Channel) -> void:
	if ch == channel:
		_refresh()
		return
	if channel:
		channel.volume_changed.disconnect(_on_channel_volume_changed)
		channel.mute_changed.disconnect(_on_channel_mute_changed)
		channel.solo_changed.disconnect(_on_channel_solo_changed)
		channel.peak_updated.disconnect(_on_channel_peak_updated)
	channel = ch
	if channel:
		channel.volume_changed.connect(_on_channel_volume_changed)
		channel.mute_changed.connect(_on_channel_mute_changed)
		channel.solo_changed.connect(_on_channel_solo_changed)
		channel.peak_updated.connect(_on_channel_peak_updated)
	if is_node_ready():
		_pan.bind_to_channel(channel)
		_meter.set_peak_levels(0.0, 0.0)
		_meter.set_rms_levels(0.0, 0.0)
		_meter.reset_peak_memory()
	_refresh()


## Match the controls to the channel, or disable them when there is none.
func _refresh() -> void:
	if not is_node_ready():
		return
	var on := channel != null
	_solo.disabled = not on
	_mute.disabled = not on
	for slider: Control in [_pan.get_node("HSlider"), _pan.get_node("DualPanSlider")]:
		slider.mouse_filter = Control.MOUSE_FILTER_PASS if on else Control.MOUSE_FILTER_IGNORE
	_meter.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	modulate.a = 1.0 if on else 0.4
	if on:
		tooltip_text = channel.name
	else:
		tooltip_text = "No pad selected" if _pad == null else "This pad has no channel"
	if on:
		_meter.volume_default_db = channel.get_default_volume()
		_meter.volume_db = channel.volume
		_solo.set_pressed_no_signal(channel.solo)
		_mute.set_pressed_no_signal(channel.mute)
	else:
		_solo.set_pressed_no_signal(false)
		_mute.set_pressed_no_signal(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		unbind()


# ============================================================================
# UI → CHANNEL
# ============================================================================

## Same undo as MixerChannel: a fader drag merges into one step, a reset is its own.
func _on_volume_changed(value: float) -> void:
	if channel == null:
		return
	var kind := _meter.last_edit_kind
	var old_volume := channel.volume
	if kind == ValueEditKind.Kind.RESET:
		value = channel.get_default_volume()
	channel.set_volume(value)
	HistoryUtil.record_property("Set Volume", channel, "set_volume", old_volume, channel.volume, kind != ValueEditKind.Kind.RESET)


func _on_solo_toggled(pressed: bool) -> void:
	if channel:
		HistoryUtil.execute_property("Solo", channel, "set_solo", channel.solo, pressed)


func _on_mute_toggled(pressed: bool) -> void:
	if channel:
		HistoryUtil.execute_property("Mute", channel, "set_mute", channel.mute, pressed)


# ============================================================================
# CHANNEL → UI
# ============================================================================

func _on_channel_volume_changed(db: float) -> void:
	_meter.volume_db = db


func _on_channel_mute_changed(value: bool) -> void:
	_mute.set_pressed_no_signal(value)


func _on_channel_solo_changed(value: bool) -> void:
	_solo.set_pressed_no_signal(value)


func _on_channel_peak_updated(peak_left: float, peak_right: float, rms_left: float, rms_right: float) -> void:
	_meter.set_peak_levels(peak_left, peak_right)
	_meter.set_rms_levels(rms_left, rms_right)
