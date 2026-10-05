## One dialog for the lane's Set, Randomize and Scale transforms: a prompt and an amount.
class_name NoteValueTransformDialog extends ConfirmationDialog

enum Kind { SET, RANDOMIZE, SCALE }

## The user confirmed: `amount` is a normalized value for Set, a normalized spread for
## Randomize and a percentage for Scale.
signal applied(kind: Kind, amount: float)

@onready var prompt_label: Label = $VBox/PromptLabel
@onready var amount_spin: SpinBox = $VBox/AmountSpinBox

var kind: Kind = Kind.SET
var _percent_display := false


func _ready() -> void:
	confirmed.connect(_on_confirmed)


## Show the dialog for `p_kind` on notes of `descriptor` (units follow the display setting).
func open_for(p_kind: Kind, descriptor: NoteValueDescriptor) -> void:
	kind = p_kind
	_percent_display = NoteValueDescriptors.display_mode() == NoteValueDescriptor.DISPLAY_PERCENT
	var unit_max := 100.0 if _percent_display else 127.0
	var unit_name := "%" if _percent_display else ""
	amount_spin.suffix = unit_name
	match kind:
		Kind.SET:
			title = "Set %s" % descriptor.display_name
			prompt_label.text = "Set the %s of the notes to:" % descriptor.display_name.to_lower()
			amount_spin.min_value = 0.0
			amount_spin.max_value = unit_max
			amount_spin.value = roundf(descriptor.default_value * unit_max)
		Kind.RANDOMIZE:
			title = "Randomize %s" % descriptor.display_name
			prompt_label.text = "Move each note's %s by a random amount up to ±:" % descriptor.display_name.to_lower()
			amount_spin.min_value = 0.0
			amount_spin.max_value = unit_max
			amount_spin.value = roundf(0.1 * unit_max)
		Kind.SCALE:
			title = "Scale %s" % descriptor.display_name
			prompt_label.text = "Scale the spread of the notes' %s around their mean to:" % descriptor.display_name.to_lower()
			amount_spin.min_value = 0.0
			amount_spin.max_value = 400.0
			amount_spin.suffix = "%"
			amount_spin.value = 50.0
	popup_centered()
	amount_spin.get_line_edit().grab_focus.call_deferred()
	amount_spin.get_line_edit().select_all.call_deferred()


## Amount as the signal reports it.
func amount() -> float:
	if kind == Kind.SCALE:
		return amount_spin.value
	return amount_spin.value / (100.0 if _percent_display else 127.0)


func _on_confirmed() -> void:
	applied.emit(kind, amount())
