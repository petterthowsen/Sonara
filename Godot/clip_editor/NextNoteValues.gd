## The values a newly drawn note starts with: those of the last note the user touched (clicked,
## dragged, resized or edited in a value lane). Lives on the MidiEditor and is read by the note
## editor's placement, and the toolbar readout shows and edits the velocity.
class_name NextNoteValues extends RefCounted

signal changed

var velocity: float = MidiNoteData.DEFAULT_VELOCITY:
	set(v):
		v = clampf(v, MidiNoteData.MIN_VELOCITY, 1.0)
		if not is_equal_approx(velocity, v):
			velocity = v
			changed.emit()

var release: float = MidiNoteData.DEFAULT_RELEASE:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if not is_equal_approx(release, v):
			release = v
			changed.emit()


## Copy `note`'s velocity and release in (the "last touched note" rule).
func take_from(note: MidiNoteData) -> void:
	if note == null:
		return
	velocity = note.velocity
	release = note.release
