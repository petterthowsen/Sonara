@tool
## One per-note value a value lane can show and edit (velocity, release, later chance, ...).
## Authored as a .tres in value_lanes/descriptors/ so a new value needs no lane code.
class_name NoteValueDescriptor extends Resource

enum Anchor { START, END }

const DISPLAY_SETTING := "clip_editor/note_value_display"
const DISPLAY_MIDI := "0–127"
const DISPLAY_PERCENT := "Percent"

## Short id used in the persisted lane list ("vel").
@export var key := ""
@export var display_name := ""
## MidiNoteData property this lane edits ("velocity").
@export var property := ""
@export var min_value := 0.0
@export var max_value := 1.0
@export var default_value := 0.5
## Where the stem sits on the note: its start or its end.
@export var anchor: Anchor = Anchor.START


func get_value(note: Object) -> float:
	return note.get(property)


## Assigns through the note's clamping setter and returns the stored value.
func set_value(note: Object, v: float) -> float:
	note.set(property, clampf(v, min_value, max_value))
	return note.get(property)


func clamp_value(v: float) -> float:
	return clampf(v, min_value, max_value)


## Text for `v` in `display_mode` (DISPLAY_MIDI or DISPLAY_PERCENT).
func format(v: float, display_mode: String = DISPLAY_MIDI) -> String:
	if display_mode == DISPLAY_PERCENT:
		return "%d%%" % roundi(v * 100.0)
	return str(roundi(v * 127.0))


## Parse text typed in `display_mode` back to a normalized value. Returns NAN when invalid.
func parse(text: String, display_mode: String = DISPLAY_MIDI) -> float:
	var t := text.strip_edges().trim_suffix("%").strip_edges()
	if not t.is_valid_float():
		return NAN
	var n := t.to_float()
	var v := n / 100.0 if display_mode == DISPLAY_PERCENT else n / 127.0
	return clamp_value(v)


## Label for the top and bottom of the lane's scale.
func format_extreme(v: float, display_mode: String = DISPLAY_MIDI) -> String:
	return format(v, display_mode)
