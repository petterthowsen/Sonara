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

## Emitted when the help context (or the held modifier mask) changes. *ctx* is a context or
## state id from HotkeyActions; *modifiers* is a mask of the held KEY_MASK_CTRL/SHIFT/ALT/META.
signal help_context_changed(ctx: String, modifiers: int)

## Emitted when the transient help-bar hint changes ("" = none, show the computed text).
signal hint_changed(text: String)

## Emitted when a help-bar condition (see set_condition) turns on or off.
signal conditions_changed()

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

const META_KEY := "hotkey_context"
const MOD_MASK := KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_MASK_ALT | KEY_MASK_META
## Mouse motion is re-resolved at most this often.
const RESOLVE_INTERVAL_MSEC := 50

## Current help context and held modifiers, as last emitted.
var help_context := "global"
var help_modifiers := 0
## Interaction state stack, oldest first: { "owner": Object, "state": String }.
var _states: Array[Dictionary] = []
var _hints: Array[Dictionary] = []
var _conditions := {}
var _held_mods := 0
var _motion_dirty := false
var _last_resolve_msec := 0


func _ready() -> void:
	for a in HotkeyActions.ACTIONS:
		if not a.has("double_tap_of"):
			_apply(a.id)
	Settings.setting_changed.connect(_on_setting_changed)
	if not Utils.is_test_mode():
		get_viewport().gui_focus_changed.connect(func(_c): resolve_help_context())
	set_process(not Utils.is_test_mode())


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


# ---------------------------------------------------------------------------
# CONDITIONS
# ---------------------------------------------------------------------------

## Turn a help-bar condition ("clip_selection", "note_selection") on or off. Actions that
## declare `requires` only show in the bar while their condition is on.
func set_condition(name: String, on: bool) -> void:
	if _conditions.get(name, false) == on:
		return
	_conditions[name] = on
	conditions_changed.emit()


func has_condition(name: String) -> bool:
	return _conditions.get(name, false)


# ---------------------------------------------------------------------------
# TRANSIENT HINT
# ---------------------------------------------------------------------------

## Show a one-off line in the help bar ("Drop to add sampler zone") until clear_hint(owner).
## One hint per owner; the newest one is shown.
func show_hint(text: String, owner: Object) -> void:
	_remove_hint(owner)
	_hints.append({"owner": owner, "text": text})
	hint_changed.emit(current_hint())


func clear_hint(owner: Object) -> void:
	if _remove_hint(owner):
		hint_changed.emit(current_hint())


## The newest hint whose owner is still alive, or "".
func current_hint() -> String:
	for i in range(_hints.size() - 1, -1, -1):
		if is_instance_valid(_hints[i].owner):
			return _hints[i].text
		_hints.remove_at(i)
	return ""


func _remove_hint(owner: Object) -> bool:
	for i in range(_hints.size() - 1, -1, -1):
		if _hints[i].owner == owner:
			_hints.remove_at(i)
			return true
	return false


# ---------------------------------------------------------------------------
# HELP CONTEXT (what is the pointer over / what is going on right now)
# ---------------------------------------------------------------------------

## Mark *control* and its descendants as belonging to context *ctx*. Call once in `_ready`.
func set_context(control: Node, ctx: String) -> void:
	if not HotkeyActions.CONTEXTS.has(ctx):
		push_warning("Hotkeys.set_context: unknown context '%s'" % ctx)
	control.set_meta(META_KEY, ctx)


## Start an interaction state (a drag, box select, ...). It wins over hover until
## end_state(owner). One entry per owner: beginning again replaces the previous state.
func begin_state(owner: Object, state: String) -> void:
	if not HotkeyActions.STATES.has(state):
		push_warning("Hotkeys.begin_state: unknown state '%s'" % state)
		return
	_remove_state(owner)
	_states.append({"owner": owner, "state": state})
	resolve_help_context()


## End the state *owner* started. Unknown owners are ignored.
func end_state(owner: Object) -> void:
	if _remove_state(owner):
		resolve_help_context()


func _remove_state(owner: Object) -> bool:
	for i in range(_states.size() - 1, -1, -1):
		if _states[i].owner == owner:
			_states.remove_at(i)
			return true
	return false


## The context for *hovered*, applying the overrides: text focus, then the newest live
## interaction state, then the nearest ancestor of *hovered* that declared a context.
## Pure apart from pruning states whose owner was freed.
func _resolve_for(hovered: Control, focus_owner: Control = null) -> String:
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return "text"
	for i in range(_states.size() - 1, -1, -1):
		if is_instance_valid(_states[i].owner):
			return _states[i].state
		_states.remove_at(i)
	var node: Node = hovered
	while node:
		if node.has_meta(META_KEY):
			return node.get_meta(META_KEY)
		node = node.get_parent()
	return "global"


func _live_context() -> String:
	var tree := get_tree()
	if tree == null:
		return "global"
	var main := tree.root
	if not main.has_focus():
		for w in main.get_children():
			if w is FrameWindow and w.has_focus():
				return "device_panel"
	return _resolve_for(main.gui_get_hovered_control(), main.gui_get_focus_owner())


## Recompute the context and emit help_context_changed if it or the modifiers changed.
func resolve_help_context() -> void:
	_motion_dirty = false
	_last_resolve_msec = Time.get_ticks_msec()
	_set_help(_live_context(), _held_mods)


func _set_help(ctx: String, mods: int) -> void:
	if ctx == help_context and mods == help_modifiers:
		return
	help_context = ctx
	help_modifiers = mods
	help_context_changed.emit(ctx, mods)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_motion_dirty = true
	if event is InputEventWithModifiers:
		# A modifier key's own event may report the mask from before it changed, so poll.
		var mods := _poll_modifiers()
		if mods != _held_mods:
			_held_mods = mods
			resolve_help_context()


func _poll_modifiers() -> int:
	return ((KEY_MASK_CTRL if Input.is_key_pressed(KEY_CTRL) else 0)
			| (KEY_MASK_SHIFT if Input.is_key_pressed(KEY_SHIFT) else 0)
			| (KEY_MASK_ALT if Input.is_key_pressed(KEY_ALT) else 0)
			| (KEY_MASK_META if Input.is_key_pressed(KEY_META) else 0))


func _process(_delta: float) -> void:
	if _motion_dirty and Time.get_ticks_msec() - _last_resolve_msec >= RESOLVE_INTERVAL_MSEC:
		resolve_help_context()
