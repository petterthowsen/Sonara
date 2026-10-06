## Window view of the built-in Sampler: the `MultisampleEditor` (group bar, sample list, zone map;
## multisample mode only) above the interactive `SampleDisplay` (play and loop handles,
## playheads), bound through the same `SampleDisplayBinder` as the Panel view. In single-sample
## mode the editor is hidden and the display fills the view (REQ-040). The controls live in the
## Companion view (`SamplerDefaultView` with `show_display` off). Layout: `SamplerWindowView.tscn`.
class_name SamplerWindowView extends DeviceView

@onready var display: SampleDisplay = %SampleDisplay
@onready var editor: MultisampleEditor = %MultisampleEditor

var _binder: SampleDisplayBinder = null
var _model: SamplerMultisample = null


func _ready() -> void:
	_binder = SampleDisplayBinder.new(display)
	# Inside a device lane panel the display takes file drops itself.
	display.add_to_group(DeviceDropTarget.OWN_DROPS_GROUP)
	if device != null:
		_setup()


func _exit_tree() -> void:
	if _binder != null:
		_binder.release_stream()


func _on_bind() -> void:
	if is_node_ready():
		_setup()


func _setup() -> void:
	_binder.bind(device)
	editor.bind(device)
	_unbind_model()
	_model = device.ensure_multisample()
	_model.mode_changed.connect(_update_mode)
	_update_mode()


func _on_unbind() -> void:
	if _binder != null:
		_binder.unbind()
	if editor != null:
		editor.unbind()
	_unbind_model()


func _unbind_model() -> void:
	if _model != null and _model.mode_changed.is_connected(_update_mode):
		_model.mode_changed.disconnect(_update_mode)
	_model = null


## The editor shows only in multisample mode.
func _update_mode() -> void:
	editor.visible = _model != null and _model.active


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
