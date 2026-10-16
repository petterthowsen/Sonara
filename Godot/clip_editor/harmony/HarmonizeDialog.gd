## Options of Harmonize (spec 048, REQ-030): which scale-step intervals to add above and below the
## selected notes, and a velocity offset. The values are remembered (REQ-004). Confirming emits
## `applied`; ClipEditor runs NoteEditor.harmonize_selection with them.
class_name HarmonizeDialog extends ConfirmationDialog

## The user confirmed: signed scale-step counts (HarmonyGenerators.THIRD .. OCTAVE, negative =
## below) and a normalized velocity offset.
signal applied(steps: Array, velocity_offset: float)

## Interval rows: [label, scale steps].
const INTERVALS: Array = [
	["3rd", HarmonyGenerators.THIRD],
	["4th", HarmonyGenerators.FOURTH],
	["5th", HarmonyGenerators.FIFTH],
	["6th", HarmonyGenerators.SIXTH],
	["Octave", HarmonyGenerators.OCTAVE],
]

## Signed step -> CheckBox.
var checks: Dictionary = {}
var velocity_spin: SpinBox


func _init() -> void:
	title = "Harmonize"
	ok_button_text = "Harmonize"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var prompt := Label.new()
	prompt.text = "Add a copy of each selected note, moved by scale steps."
	box.add_child(prompt)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 16)
	box.add_child(grid)
	grid.add_child(Control.new())
	for heading in ["Above", "Below"]:
		var l := Label.new()
		l.text = heading
		grid.add_child(l)
	for row: Array in INTERVALS:
		var name_label := Label.new()
		name_label.text = row[0]
		grid.add_child(name_label)
		for dir in [1, -1]:
			var check := CheckBox.new()
			check.tooltip_text = "%s %s each note, in scale steps" % [row[0], "above" if dir > 0 else "below"]
			check.toggled.connect(func(_on: bool): _sync_ok())
			grid.add_child(check)
			checks[int(row[1]) * dir] = check
	var velocity_row := HBoxContainer.new()
	velocity_row.add_theme_constant_override("separation", 8)
	box.add_child(velocity_row)
	var velocity_label := Label.new()
	velocity_label.text = "Velocity offset"
	velocity_row.add_child(velocity_label)
	velocity_spin = SpinBox.new()
	velocity_spin.min_value = -100
	velocity_spin.max_value = 100
	velocity_spin.step = 1
	velocity_spin.suffix = "%"
	velocity_spin.tooltip_text = "Added to the velocity of every new note."
	velocity_row.add_child(velocity_spin)
	confirmed.connect(_on_confirmed)


## Show the dialog with the remembered options.
func open() -> void:
	var steps := NoteEditor.harmonize_steps()
	for step: int in checks.keys():
		checks[step].set_pressed_no_signal(steps.has(step))
	velocity_spin.set_value_no_signal(roundf(NoteEditor.harmonize_velocity_offset() * 100.0))
	_sync_ok()
	popup_centered()


## The checked intervals as signed scale-step counts, above before below.
func selected_steps() -> Array[int]:
	var out: Array[int] = []
	for row: Array in INTERVALS:
		for dir in [1, -1]:
			var step: int = int(row[1]) * dir
			if checks[step].button_pressed:
				out.append(step)
	return out


func velocity_offset() -> float:
	return velocity_spin.value / 100.0


func _sync_ok() -> void:
	get_ok_button().disabled = selected_steps().is_empty()


func _on_confirmed() -> void:
	var steps := selected_steps()
	if steps.is_empty():
		return
	NoteEditor.store_config(NoteEditor.HARMONIZE_INTERVALS_KEY, steps)
	NoteEditor.store_config(NoteEditor.HARMONIZE_VELOCITY_KEY, velocity_offset())
	applied.emit(steps, velocity_offset())
