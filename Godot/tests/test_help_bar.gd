# HelpBar (Phase 2b): pure bbcode build for a context + modifier mask, rebinding, the
# double-tap entry, width truncation, and that every declared gesture points at a real context.
extends TestBase

var Hotkeys
var Settings


func suite_name() -> String:
	return "Help bar"


func run_tests() -> void:
	Hotkeys = root.get_node("Hotkeys")
	Settings = root.get_node("Settings")
	_test_gestures_valid()
	_test_no_modifiers()
	_test_shift_held()
	_test_double_tap_entry()
	_test_rebind()
	_test_truncation()
	_test_text_context()
	_test_hint()
	_test_conditions()
	_test_knob_context()
	_test_extra_contexts()


func _bar(ctx: String, mods: int, width := 4000.0) -> String:
	return HelpBar.build(ctx, mods, width)


func _plain(bb: String) -> String:
	var re := RegEx.new()
	re.compile("\\[/?color[^\\]]*\\]")
	return re.sub(bb, "", true).replace("[lb]", "[")


func _test_gestures_valid() -> void:
	for g in HotkeyActions.GESTURES:
		var ok: bool = HotkeyActions.CONTEXTS.has(g.context) or HotkeyActions.STATES.has(g.context)
		_assert(ok, "gesture context exists: %s" % g.context)
		_assert(g.input in HotkeyActions.GESTURE_INPUTS, "gesture input valid: %s" % g.input)
		_assert(g.input != "" or g.mods != "", "gesture has a modifier or an input: %s" % g.label)
		for m in g.mods.split("+", false):
			_assert(m in ["Ctrl", "Shift", "Alt", "Meta"], "gesture modifier valid: %s" % m)


func _test_no_modifiers() -> void:
	var text := _plain(_bar("arranger", 0))
	_assert("Wheel scroll" in text, "arranger lists the wheel gesture: " + text)
	_assert(not "Space" in text, "fundamental hotkeys (Play) are tagged help:false")
	_assert("Shift …" in text, "arranger hints at Shift")
	_assert("Ctrl …" in text, "arranger hints at Ctrl")
	_assert(not "zoom horizontally" in text, "Shift entries stay hidden without Shift")
	_assert("[color=%s]Wheel[/color]" % HelpBar._chip_color() in _bar("arranger", 0), "chips use the chip colour")


func _test_shift_held() -> void:
	var text := _plain(_bar("arranger", KEY_MASK_SHIFT))
	_assert("zoom horizontally" in text, "Shift lists zoom horizontally: " + text)
	_assert(not "track height" in text, "Shift hides the Ctrl entry")
	_assert("Shift+Space" in text, "Shift lists Shift+Space")
	_assert(not "Shift …" in text, "no unlock hints while a modifier is held")


func _test_double_tap_entry() -> void:
	var text := _plain(_bar("arranger", KEY_MASK_CTRL))
	_assert("Ctrl+A ×2" in text, "Ctrl in the arranger lists Ctrl+A ×2: " + text)
	var other := _plain(_bar("mixer", KEY_MASK_CTRL))
	_assert(not "×2" in other, "double tap is arranger-only")


func _test_rebind() -> void:
	Settings.set_value("shortcuts/transport_pause_to_start", ["Ctrl+P"])
	_assert("Ctrl+P pause" in _plain(_bar("arranger", KEY_MASK_CTRL)), "rebound Pause shows Ctrl+P")
	Settings.set_value("shortcuts/transport_pause_to_start", [])
	_assert(not "ause" in _plain(_bar("arranger", KEY_MASK_SHIFT)), "unbound Pause disappears")
	Settings.set_value("shortcuts/transport_pause_to_start", ["Shift+Space"])
	Settings.set_value("shortcuts/edit_select_all", ["Ctrl+L"])
	_assert("Ctrl+L ×2" in _plain(_bar("arranger", KEY_MASK_CTRL)), "double tap follows the new chord")
	Settings.set_value("shortcuts/edit_select_all", ["Ctrl+A"])


func _test_truncation() -> void:
	var full := _bar("arranger", 0)
	var cut := _bar("arranger", 0, 200.0)
	_assert("…" in cut and cut.length() < full.length(), "narrow width truncates with …")
	var entries := HelpBar.collect("arranger")
	var font := ThemeDB.fallback_font
	var fitted := true
	for part in _plain(cut).split("  ", false):
		if part == "…" or part.ends_with(" …"):
			continue
		var found := false
		for e in entries:
			if e.plain == part:
				found = true
		fitted = fitted and found
	_assert(fitted, "only whole entries remain: " + _plain(cut))
	_assert(font.get_string_size(_plain(cut)).x <= 200.0 + 40.0, "truncated text roughly fits")


func _test_text_context() -> void:
	_assert(_bar("text", 0) == "", "text focus shows nothing")


func _test_hint() -> void:
	var owner := Node.new()
	Hotkeys.show_hint("Drop to add zone", owner)
	_assert(Hotkeys.current_hint() == "Drop to add zone", "hint is current")
	Hotkeys.clear_hint(owner)
	_assert(Hotkeys.current_hint() == "", "hint cleared")
	Hotkeys.show_hint("x", owner)
	owner.free()
	_assert(Hotkeys.current_hint() == "", "freed owner's hint is dropped")


func _test_knob_context() -> void:
	var text := _plain(_bar("control_knob", 0))
	_assert("Drag change value" in text, "knob lists drag: " + text)
	_assert("Double-click type value" in text, "knob lists double-click")
	_assert("Shift …" in text and "Ctrl …" in text, "knob hints at Shift and Ctrl")
	_assert("Shift+Drag fine adjust" in _plain(_bar("control_knob", KEY_MASK_SHIFT)), "Shift+drag fine adjust")
	_assert("Ctrl+Click reset to default" in _plain(_bar("control_knob", KEY_MASK_CTRL)), "Ctrl+click reset")


func _test_extra_contexts() -> void:
	var extras: Array[String] = ["computer_keyboard"]
	var without := _plain(_bar("arranger", 0))
	var with_kb := _plain(HelpBar.build("arranger", 0, 4000.0, null, 14, extras))
	_assert(not "octave" in without, "no keyboard hints while the computer keyboard is off")
	_assert("octave down" in with_kb and "velocity up" in with_kb, "keyboard hints appear as an extra context: " + with_kb)
	_assert(not "Note C3" in with_kb, "note keys stay out of the bar")


func _test_conditions() -> void:
	Hotkeys.set_condition("clip_selection", false)
	_assert(not "Move clips" in _plain(_bar("arranger", 0)), "move keys hidden without a clip selection")
	Hotkeys.set_condition("clip_selection", true)
	_assert("← move clips left" in _plain(_bar("arranger", 0)), "move keys shown with a clip selection: " + _plain(_bar("arranger", 0)))
	Hotkeys.set_condition("clip_selection", false)
