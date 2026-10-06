## The range popup for the assign and distribute batch operations (spec 023, REQ-047): low and
## high values (note names shown for keys), "Single value" for the assign operations, Stretch or
## Gaps (with the slice size) for the distribute ones, and Apply. The layout lives in
## `ZoneBatchDialog.tscn`. Apply is one undo step (`SamplerActions.apply_batch`).
class_name ZoneBatchDialog extends PopupPanel

enum Split { STRETCH, GAPS }

const KEY_OPS := ["assign_note", "distribute_notes"]
const ASSIGN_OPS := ["assign_velocity", "assign_note"]

@onready var title_label: Label = %Title
@onready var lo_spin: SpinBox = %LoSpin
@onready var hi_spin: SpinBox = %HiSpin
@onready var lo_note: Label = %LoNote
@onready var hi_note: Label = %HiNote
@onready var single_check: CheckBox = %SingleCheck
@onready var mode_row: HBoxContainer = %ModeRow
@onready var mode_option: OptionButton = %ModeOption
@onready var slice_row: HBoxContainer = %SliceRow
@onready var slice_spin: SpinBox = %SliceSpin
@onready var apply_button: Button = %Apply
@onready var cancel_button: Button = %Cancel

var device: DeviceInstance = null
var op := ""
var ids: Array = []


func _enter_tree() -> void:
	# The packed scene is visible for editor authoring; instances start hidden.
	hide()


func _ready() -> void:
	lo_spin.value_changed.connect(func(_v: float) -> void: _update_rows())
	hi_spin.value_changed.connect(func(_v: float) -> void: _update_rows())
	single_check.toggled.connect(func(_on: bool) -> void: _update_rows())
	mode_option.item_selected.connect(func(_i: int) -> void: _update_rows())
	apply_button.pressed.connect(apply)
	cancel_button.pressed.connect(hide)


func is_key_op() -> bool:
	return op in KEY_OPS


## Set the dialog up for `p_op` on the zones `p_ids` (list order) without showing it.
func configure(inst: DeviceInstance, p_op: String, p_ids: Array) -> void:
	device = inst
	op = p_op
	ids = p_ids.duplicate()
	title_label.text = SamplerActions.BATCH_LABELS.get(op, op)
	var key := is_key_op()
	var lo := SamplerZone.KEY_MIN if key else SamplerZone.VEL_MIN
	var hi := SamplerZone.KEY_MAX if key else SamplerZone.VEL_MAX
	for spin in [lo_spin, hi_spin]:
		spin.min_value = lo
		spin.max_value = hi
	# Keys start from the selection's span, velocity from the whole range.
	var start_lo := hi
	var start_hi := lo
	var model := inst.multisample if inst else null
	for zone_id in ids:
		var zone := model.get_zone(int(zone_id)) if model else null
		if zone and key:
			start_lo = mini(start_lo, zone.key_lo)
			start_hi = maxi(start_hi, zone.key_hi)
	if not key or start_lo > start_hi:
		start_lo = lo
		start_hi = hi
	lo_spin.set_value_no_signal(start_lo)
	hi_spin.set_value_no_signal(start_hi)
	single_check.set_pressed_no_signal(false)
	single_check.visible = op in ASSIGN_OPS
	mode_row.visible = not op in ASSIGN_OPS
	mode_option.select(Split.STRETCH)
	slice_spin.max_value = hi - lo + 1
	slice_spin.set_value_no_signal(maxi(1, (start_hi - start_lo + 1) / maxi(1, ids.size())))
	_update_rows()


func open_for(inst: DeviceInstance, p_op: String, p_ids: Array, screen_position: Vector2) -> void:
	configure(inst, p_op, p_ids)
	popup(Rect2i(Vector2i(screen_position), Vector2i.ZERO))


func _update_rows() -> void:
	var key := is_key_op()
	lo_note.visible = key
	hi_note.visible = key
	lo_note.text = Midi.midi_to_note_name(int(lo_spin.value))
	hi_note.text = Midi.midi_to_note_name(int(hi_spin.value))
	hi_spin.editable = not (single_check.visible and single_check.button_pressed)
	slice_row.visible = mode_row.visible and mode_option.selected == Split.GAPS


## The `SamplerActions.apply_batch` options the controls describe.
func options() -> Dictionary:
	var lo := int(lo_spin.value)
	var hi := int(hi_spin.value)
	if single_check.visible and single_check.button_pressed:
		hi = lo
	return {
		"lo": lo, "hi": hi,
		"stretch": mode_option.selected != Split.GAPS,
		"slice": int(slice_spin.value),
	}


func apply() -> void:
	if device != null and not ids.is_empty():
		SamplerActions.apply_batch(device, op, ids, options())
	hide()
