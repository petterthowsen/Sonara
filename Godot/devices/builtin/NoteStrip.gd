## NoteStrip
## A slim keyboard strip for the note effects' `note_state` stream (spec 027 REQ-039): the keys
## held at the effect's input are lit, and the key it is sounding right now is brighter, so an
## arpeggio's highlight walks across the keys.
##
## `set_state` takes the decoded blob. The strip draws only; the view owns the subscription.
class_name NoteStrip extends Control

## Blob byte meaning "none".
const NONE := 0xFF
## Keys drawn while nothing is held: C2 to C5 (middle C is C3).
const IDLE_RANGE := Vector2i(36, 72)
## Fewest keys drawn, so a single note still gets a readable strip.
const MIN_SPAN := 12

var held: PackedInt32Array = PackedInt32Array()
var sounding_key: int = -1
var step: int = -1
var branch: int = -1
## Octave layers the effect plays above the held keys (the Arpeggiator's Octaves), so the strip
## covers every key it can sound.
var octaves: int = 1:
	set(value):
		octaves = maxi(value, 1)
		queue_redraw()


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


## First and last key drawn (inclusive): the held keys across `octaves` layers and the sounding
## key, widened out to the C at or below the lowest and the C at or above the highest. `IDLE_RANGE`
## when there is nothing to show.
func key_range() -> Vector2i:
	var lowest := 127
	var highest := 0
	for key in held:
		lowest = mini(lowest, key)
		highest = maxi(highest, key + 12 * (octaves - 1))
	if sounding_key >= 0:
		lowest = mini(lowest, sounding_key)
		highest = maxi(highest, sounding_key)
	if lowest > highest:
		return IDLE_RANGE
	var first := lowest - lowest % 12
	var last := highest if highest % 12 == 0 else highest - highest % 12 + 12
	last = maxi(last, first + MIN_SPAN)
	if last > 127:
		last = 127
		first = mini(first, last - MIN_SPAN)
	return Vector2i(first, last)


func _draw() -> void:
	var keys := key_range()
	var first_key := keys.x
	var count := keys.y - first_key + 1
	var key_width := size.x / float(count)
	draw_rect(Rect2(Vector2.ZERO, size), UiColors.role(&"well"))
	for key in range(first_key, keys.y + 1):
		var x := float(key - first_key) * key_width
		var black := [1, 3, 6, 8, 10].has(key % 12)
		var color := UiColors.role(&"border") if black else UiColors.role(&"control_bg")
		var rect := Rect2(x, 0.0, maxf(key_width - 1.0, 1.0), size.y * (0.6 if black else 1.0))
		if is_key_sounding(key):
			color = UiColors.role(&"accent_primary")
			rect = Rect2(x, 0.0, maxf(key_width - 1.0, 1.0), size.y)
		elif is_key_held(key):
			color = UiColors.role(&"accent_secondary")
		draw_rect(rect, color)
