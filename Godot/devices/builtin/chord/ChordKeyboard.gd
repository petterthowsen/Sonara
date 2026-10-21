## ChordKeyboard (no class_name: loaded by preload)
## The Chord view's keyboard: a `NoteStrip` that shows a window of the chord's intervals as keys
## around the root (middle C, 60) and turns clicks into `key_toggled`. Enabled keys use the
## strip's "held" color (accent_secondary); `live` keys (what is sounding) use the "sounding"
## color (accent_primary). Drawing is the strip's; this class only supplies the key range, the
## two key sets and the click.
extends NoteStrip

## A key was clicked. `key` is the MIDI key; the chord interval is `key - ROOT`.
signal key_toggled(key: int)
signal window_changed

## The key standing for the played note itself (interval 0).
const ROOT := 60
## Intervals the Chord can hold: +-24 semitones, so four octaves C2..C6.
const LOW_KEY := ROOT - 24
const HIGH_KEY := ROOT + 24
const TOTAL_OCTAVES := 4
const MAX_VISIBLE := 3

## Enabled intervals' keys.
var enabled: Dictionary = {}
## Keys lit as sounding now.
var live: Dictionary = {}
## Octaves shown at once (1..MAX_VISIBLE) and the first one shown (0 = C2).
var visible_octaves := 2
var page := 1


func _init() -> void:
	super._init()
	custom_minimum_size = Vector2(120, 44)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func set_enabled_keys(keys: Dictionary) -> void:
	enabled = keys
	queue_redraw()


func set_live_keys(keys: Dictionary) -> void:
	live = keys
	queue_redraw()


func max_page() -> int:
	return TOTAL_OCTAVES - visible_octaves


func set_visible_octaves(n: int) -> void:
	visible_octaves = clampi(n, 1, MAX_VISIBLE)
	page = clampi(page, 0, max_page())
	queue_redraw()
	window_changed.emit()


func set_page(p: int) -> void:
	page = clampi(p, 0, max_page())
	queue_redraw()
	window_changed.emit()


func is_key_held(key: int) -> bool:
	return enabled.has(key)


func is_key_sounding(key: int) -> bool:
	return live.has(key)


## First and last key drawn: `visible_octaves` octaves from `page`, plus the closing C.
func key_range() -> Vector2i:
	var first := LOW_KEY + 12 * page
	return Vector2i(first, mini(first + 12 * visible_octaves, HIGH_KEY))


## The key under local x, or -1.
func key_at(x: float) -> int:
	var keys := key_range()
	var count := keys.y - keys.x + 1
	if size.x <= 0.0 or x < 0.0 or x >= size.x:
		return -1
	return keys.x + clampi(int(x / (size.x / float(count))), 0, count - 1)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var key := key_at(event.position.x)
		if key >= 0:
			key_toggled.emit(key)
			accept_event()
