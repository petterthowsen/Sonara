## Window view of the built-in Sampler: the interactive `SampleDisplay` (play and loop handles,
## playheads) filling the view, bound through the same `SampleDisplayBinder` as the Panel view.
## The controls live in the Companion view (`SamplerDefaultView` with `show_display` off).
class_name SamplerWindowView extends DeviceView

var display: SampleDisplay

var _binder: SampleDisplayBinder = null


func _ready() -> void:
	_build()
	if device != null:
		_binder.bind(device)


func _exit_tree() -> void:
	if _binder != null:
		_binder.release_stream()


func _build() -> void:
	if display != null:
		return
	display = SampleDisplay.new()
	display.name = "SampleDisplay"
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_binder = SampleDisplayBinder.new(display)
	add_child(display)


func _on_bind() -> void:
	if is_node_ready():
		_binder.bind(device)


func _on_unbind() -> void:
	if _binder != null:
		_binder.unbind()


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	if _binder != null:
		_binder.refresh()


func _on_view_shown() -> void:
	if _binder != null:
		_binder.set_shown(true)


func _on_view_hidden() -> void:
	if _binder != null:
		_binder.set_shown(false)


## Feed a `"playheads"` blob to the display (also what the tests call).
func apply_playheads(blob: PackedByteArray, now_ms: int = Time.get_ticks_msec()) -> void:
	if _binder != null:
		_binder.apply_playheads(blob, now_ms)
