# KeyChord.gd
# Chord strings ("Ctrl+Shift+A", "Space", "Ctrl++") <-> InputEventKey, plus display labels.
# Modifiers are always written in the order Ctrl, Shift, Alt, Meta.
# `physical` chords name a physical key position (QWERTY names), the others the logical key.
class_name KeyChord

const _MOD_ORDER := ["Ctrl", "Shift", "Alt", "Meta"]
const _MOD_ALIASES := { "ctrl": "Ctrl", "control": "Ctrl", "shift": "Shift", "alt": "Alt",
		"meta": "Meta", "cmd": "Meta", "super": "Meta" }
const _SYMBOLS := { "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "CapsLock": "Caps Lock",
		"Kp Enter": "Num Enter" }


## Chord string for *ev*, or "" when it is only a modifier press (or has no key).
static func from_event(ev: InputEventKey, physical: bool) -> String:
	var key: Key = ev.physical_keycode if physical else ev.keycode
	if key == KEY_NONE:
		key = ev.keycode if physical else ev.physical_keycode
	if key == KEY_NONE or _is_modifier_key(key):
		return ""
	return _build(ev.ctrl_pressed, ev.shift_pressed, ev.alt_pressed, ev.meta_pressed, key)


## Same as from_event, for a parsed event: the stored chord string for *ev*.
static func to_text(ev: InputEventKey, physical: bool) -> String:
	return from_event(ev, physical)


## InputEventKey for chord string *s*, or null when it is invalid.
static func parse(s: String, physical: bool) -> InputEventKey:
	if s.is_empty():
		return null
	var key_name: String
	var mod_part: String
	if s.ends_with("+"):
		# The key itself is "+" (stored as "Plus"): "+" or "Ctrl++".
		key_name = "Plus"
		mod_part = s.substr(0, s.length() - 1)
		if mod_part.ends_with("+"):
			mod_part = mod_part.substr(0, mod_part.length() - 1)
		elif not mod_part.is_empty():
			return null
	else:
		var cut := s.rfind("+")
		key_name = s if cut < 0 else s.substr(cut + 1)
		mod_part = "" if cut < 0 else s.substr(0, cut)
	var ev := InputEventKey.new()
	if not mod_part.is_empty():
		for m in mod_part.split("+"):
			match _MOD_ALIASES.get(m.to_lower(), ""):
				"Ctrl": ev.ctrl_pressed = true
				"Shift": ev.shift_pressed = true
				"Alt": ev.alt_pressed = true
				"Meta": ev.meta_pressed = true
				_: return null
	var key: Key = OS.find_keycode_from_string(key_name)
	if key == KEY_NONE or _is_modifier_key(key):
		return null
	if physical:
		ev.physical_keycode = key
	else:
		ev.keycode = key
	return ev


## Human label for the UI: like the stored form, with arrows as symbols. For physical
## chords the key shows the label it has on the user's keyboard layout.
static func display(s: String, physical: bool = false) -> String:
	if s.is_empty():
		return ""
	var ev := parse(s, physical)
	if ev == null:
		return s
	var key: Key = ev.physical_keycode if physical else ev.keycode
	var key_name := OS.get_keycode_string(key)
	if physical and DisplayServer.get_name() != "headless":
		var label := DisplayServer.keyboard_get_label_from_physical(key)
		if label != KEY_NONE:
			key_name = OS.get_keycode_string(label)
	key_name = _SYMBOLS.get(key_name, key_name)
	var parts: Array[String] = []
	if ev.ctrl_pressed: parts.append("Ctrl")
	if ev.shift_pressed: parts.append("Shift")
	if ev.alt_pressed: parts.append("Alt")
	if ev.meta_pressed: parts.append("Meta")
	parts.append(key_name)
	return "+".join(parts)


static func _build(ctrl: bool, shift: bool, alt: bool, meta: bool, key: Key) -> String:
	var parts: Array[String] = []
	if ctrl: parts.append("Ctrl")
	if shift: parts.append("Shift")
	if alt: parts.append("Alt")
	if meta: parts.append("Meta")
	parts.append(OS.get_keycode_string(key))
	return "+".join(parts)


static func _is_modifier_key(key: Key) -> bool:
	return key == KEY_CTRL or key == KEY_SHIFT or key == KEY_ALT or key == KEY_META
