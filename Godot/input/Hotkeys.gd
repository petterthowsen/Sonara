# Hotkeys.gd
# Applies the bindings stored in Settings ("shortcuts/<action id>") to Godot's InputMap and
# answers "did this event trigger action X?" for every handler. Action ids, defaults, labels
# and contexts live in HotkeyActions; this node holds no defaults of its own.
#
# Handlers use Hotkeys.pressed(event, "edit_copy") instead of reading keys. Matching is exact:
# Space does not match Shift+Space, D does not match Ctrl+D.
extends Node

## Emitted after the InputMap entries of one action were rebuilt.
signal bindings_changed(action_id: String)

## Two presses of the same key within this window count as a double tap.
const DOUBLE_TAP_MS := 400
const SETTING_PREFIX := "shortcuts/"

## Set by the Settings key capture so that the chord being bound doesn't also run its action.
var capturing := false

## Injectable clock (msec), so tests don't need to sleep.
var _now_msec: Callable = Time.get_ticks_msec
## parent action id -> time of its last press, for double taps.
var _last_press: Dictionary = {}
## parent action id -> the event that completed a double tap (must not start a new one).
var _double_consumed: Dictionary = {}


func _ready() -> void:
	for a in HotkeyActions.ACTIONS:
		if not a.has("double_tap_of"):
			_apply(a.id)
	Settings.setting_changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, _value) -> void:
	if not key.begins_with(SETTING_PREFIX):
		return
	var id := key.trim_prefix(SETTING_PREFIX)
	if HotkeyActions.get_action(id).is_empty() or HotkeyActions.is_double_tap(id):
		return
	_apply(id)
	bindings_changed.emit(id)


## Rebuild the InputMap action *id* from its stored chords.
func _apply(id: String) -> void:
	if InputMap.has_action(id):
		InputMap.erase_action(id)
	InputMap.add_action(id)
	var physical: bool = HotkeyActions.get_action(id).get("physical", false)
	for chord in get_chords(id):
		var ev := KeyChord.parse(chord, physical)
		if ev != null:
			InputMap.action_add_event(id, ev)


# ---------------------------------------------------------------------------
# MATCHING
# ---------------------------------------------------------------------------

## True when *event* is a press (or repeat, for allow_echo actions) of action *id*.
func pressed(event: InputEvent, id: String) -> bool:
	if capturing or not event is InputEventKey:
		return false
	var def := HotkeyActions.get_action(id)
	if def.is_empty():
		return false
	if def.has("double_tap_of"):
		return false
	if not event.is_action_pressed(id, def.get("allow_echo", false), true):
		return false
	if _double_consumed.get(id) != event:
		_last_press[id] = _now_msec.call()
	_double_consumed.erase(id)
	return true


## True when *event* is a press or release of action *id*, for handlers that need both.
func matches(event: InputEvent, id: String) -> bool:
	if capturing or not event is InputEventKey:
		return false
	return event.is_action(id, true)


## True when *event* presses the parent of double-tap action *id* a second time within
## DOUBLE_TAP_MS of the first. Call this before pressed() for the same event: the first tap
## always runs the parent action. A completed double tap starts over, so a third tap is a
## new first tap.
func double_tapped(event: InputEvent, id: String) -> bool:
	if capturing or not event is InputEventKey:
		return false
	var parent: String = HotkeyActions.get_action(id).get("double_tap_of", "")
	if parent.is_empty() or not event.is_action_pressed(parent, false, true):
		return false
	if not _last_press.has(parent):
		return false
	if _now_msec.call() - _last_press[parent] > DOUBLE_TAP_MS:
		return false
	_last_press.erase(parent)
	_double_consumed[parent] = event
	return true


# ---------------------------------------------------------------------------
# BINDINGS
# ---------------------------------------------------------------------------

## Chord strings currently bound to *id*. A double-tap action returns its parent's.
func get_chords(id: String) -> Array[String]:
	var def := HotkeyActions.get_action(id)
	if def.is_empty():
		return []
	if def.has("double_tap_of"):
		return get_chords(def.double_tap_of)
	var result: Array[String] = []
	var stored = Settings.get_value(SETTING_PREFIX + id)
	if stored is Array:
		for c in stored:
			result.append(str(c))
	return result


## Label of the primary chord for the UI, "" when unbound. A double tap appends " ×2".
func get_display(id: String) -> String:
	var chords := get_chords(id)
	if chords.is_empty():
		return ""
	var text := KeyChord.display(chords[0], HotkeyActions.get_action(id).get("physical", false))
	return text + " ×2" if HotkeyActions.is_double_tap(id) else text


## Ids of the double-tap actions that follow *parent_id*.
func get_double_taps(parent_id: String) -> Array[String]:
	var result: Array[String] = []
	for a in HotkeyActions.ACTIONS:
		if a.get("double_tap_of", "") == parent_id:
			result.append(a.id)
	return result


## Other actions bound to *chord* whose contexts overlap with *id*'s.
func find_conflicts(id: String, chord: String) -> Array[String]:
	var result: Array[String] = []
	var def := HotkeyActions.get_action(id)
	if def.is_empty() or chord.is_empty():
		return result
	for a in HotkeyActions.ACTIONS:
		if a.id == id or a.has("double_tap_of"):
			continue
		if not HotkeyActions.contexts_overlap(def.context, a.context):
			continue
		if chord in get_chords(a.id):
			result.append(a.id)
	return result
