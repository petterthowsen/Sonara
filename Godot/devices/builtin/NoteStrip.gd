## NoteStrip
## A slim keyboard strip for the note effects' `note_state` stream (spec 027 REQ-039): the keys
## held at the effect's input are lit, and the key it is sounding right now is brighter, so an
## arpeggio's highlight walks across the keys.
##
## `set_state` takes the decoded blob. The strip draws only; the view owns the subscription.
class_name NoteStrip extends Control

## Blob byte meaning "none".
const NONE := 0xFF
## Keys drawn: a piano's range, A0 to C8.
const FIRST_KEY := 21
const LAST_KEY := 108

var held: PackedInt32Array = PackedInt32Array()
var sounding_key: int = -1
var step: int = -1
var branch: int = -1


func _init() -> void:
	custom_minimum_size = Vector2(120, 22)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Decode the engine's `note_state` blob: `u8 step, u8 key, u8 branch, u8 held_count, held keys`.
## Returns {} for a malformed blob. 0xFF fields come back as -1.
static func decode(blob: PackedByteArray) -> Dictionary:
	if blob.size() < 4:
		return {}
	var count := blob[3]
	if blob.size() < 4 + count:
		return {}
	var keys := PackedInt32Array()
	for i in count:
		keys.append(blob[4 + i])
	return {
		"step": -1 if blob[0] == NONE else blob[0],
		"key": -1 if blob[1] == NONE else blob[1],
		"branch": -1 if blob[2] == NONE else blob[2],
		"held": keys,
	}


## Show a decoded blob. False (and no change) for an empty one.
func set_state(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	held = state["held"]
	sounding_key = state["key"]
	step = state["step"]
	branch = state["branch"]
	queue_redraw()
	return true


func is_key_sounding(key: int) -> bool:
	return key == sounding_key


func is_key_held(key: int) -> bool:
	return held.has(key)


## Forget everything (the effect has gone quiet or the view was hidden).
func clear() -> void:
	held = PackedInt32Array()
	sounding_key = -1
	step = -1
	branch = -1
	queue_redraw()


func _draw() -> void:
	var count := LAST_KEY - FIRST_KEY + 1
	var key_width := size.x / float(count)
	draw_rect(Rect2(Vector2.ZERO, size), UiColors.role(&"well"))
	for key in range(FIRST_KEY, LAST_KEY + 1):
		var x := float(key - FIRST_KEY) * key_width
		var black := [1, 3, 6, 8, 10].has(key % 12)
		var color := UiColors.role(&"border") if black else UiColors.role(&"control_bg")
		var rect := Rect2(x, 0.0, maxf(key_width - 1.0, 1.0), size.y * (0.6 if black else 1.0))
		if is_key_sounding(key):
			color = UiColors.role(&"accent_primary")
			rect = Rect2(x, 0.0, maxf(key_width - 1.0, 1.0), size.y)
		elif is_key_held(key):
			color = UiColors.role(&"accent_secondary")
		draw_rect(rect, color)
