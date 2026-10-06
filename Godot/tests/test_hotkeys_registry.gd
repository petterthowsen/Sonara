# Hotkey registry (Phase 1a): table consistency, chord strings, InputMap application,
# exact matching, coercion and double taps.
extends TestBase

# Autoloads don't resolve as bare identifiers when this script is the main loop script.
var Hotkeys
var Settings


func suite_name() -> String:
	return "Hotkeys registry"


func run_tests() -> void:
	Hotkeys = root.get_node("Hotkeys")
	Settings = root.get_node("Settings")
	_test_table()
	_test_chords()
	_test_no_default_conflicts()
	_test_input_map()
	_test_coerce()
	_test_double_tap()
	_test_no_project_input_duplicates()


func _key(keycode: Key, mods := {}, physical := false) -> InputEventKey:
	var ev := InputEventKey.new()
	if physical:
		ev.physical_keycode = keycode
	else:
		ev.keycode = keycode
	ev.pressed = true
	ev.ctrl_pressed = mods.get("ctrl", false)
	ev.shift_pressed = mods.get("shift", false)
	ev.alt_pressed = mods.get("alt", false)
	return ev


func _test_table() -> void:
	var seen := {}
	var ok_unique := true
	var ok_ctx := true
	for a in HotkeyActions.ACTIONS:
		if seen.has(a.id):
			ok_unique = false
		seen[a.id] = true
		if not HotkeyActions.CONTEXTS.has(a.context):
			ok_ctx = false
	_assert(ok_unique, "every action id is unique")
	_assert(ok_ctx, "every action context is in CONTEXTS")
	var ok_chain := true
	for ctx in HotkeyActions.CONTEXTS:
		var chain := HotkeyActions.context_chain(ctx)
		if chain.is_empty() or chain[-1] != "global":
			ok_chain = false
	_assert(ok_chain, "every context's parent chain ends at global")
	_assert(HotkeyActions.contexts_overlap("arranger", "global"), "arranger overlaps global")
	_assert(not HotkeyActions.contexts_overlap("arranger", "mixer"), "arranger and mixer don't overlap")


func _test_chords() -> void:
	for pair in [["Space", false], ["Shift+Space", false], ["Ctrl+Shift+Z", false], ["Ctrl+Plus", false],
			["Ctrl+Shift+A", false], ["Q", true], ["CapsLock", true], ["Kp Enter", false], ["Backspace", false]]:
		var ev := KeyChord.parse(pair[0], pair[1])
		_assert(ev != null and KeyChord.to_text(ev, pair[1]) == pair[0], "chord '%s' round-trips" % pair[0])
	var all_ok := true
	for a in HotkeyActions.ACTIONS:
		for c in a.get("defaults", []):
			var ev := KeyChord.parse(c, a.get("physical", false))
			if ev == null or KeyChord.to_text(ev, a.get("physical", false)) != c:
				all_ok = false
				print("bad default chord: ", a.id, " ", c)
	_assert(all_ok, "every default chord parses and round-trips")
	var plus := KeyChord.parse("Ctrl++", false)
	_assert(plus != null and plus.keycode == KEY_PLUS and plus.ctrl_pressed, "'Ctrl++' parses as Ctrl and the plus key")
	_assert(KeyChord.parse("Ctrl", false) == null, "modifier-only chord is invalid")
	_assert(KeyChord.parse("Bogus+A", false) == null, "unknown modifier is invalid")
	_assert(KeyChord.parse("", false) == null, "empty chord is invalid")
	_assert(KeyChord.parse("Ctrl+NoSuchKey", false) == null, "unknown key is invalid")
	_assert(KeyChord.from_event(_key(KEY_CTRL), false) == "", "modifier-only press yields no chord")
	_assert(KeyChord.from_event(_key(KEY_D, {"ctrl": true}), false) == "Ctrl+D", "from_event builds Ctrl+D")


func _test_no_default_conflicts() -> void:
	var conflicts: Array[String] = []
	for a in HotkeyActions.ACTIONS:
		if a.has("double_tap_of"):
			continue
		for chord in a.defaults:
			for other in Hotkeys.find_conflicts(a.id, chord):
				conflicts.append("%s vs %s (%s)" % [a.id, other, chord])
	_assert(conflicts.is_empty(), "no default chord conflicts: %s" % str(conflicts))


func _test_input_map() -> void:
	var ok := true
	for a in HotkeyActions.ACTIONS:
		if a.has("double_tap_of"):
			continue
		if not InputMap.has_action(a.id) or InputMap.action_get_events(a.id).size() != a.defaults.size():
			ok = false
			print("InputMap mismatch: ", a.id)
	_assert(ok, "InputMap holds the default events of every action")
	var shift_space := _key(KEY_SPACE, {"shift": true})
	var space := _key(KEY_SPACE)
	_assert(Hotkeys.pressed(shift_space, "transport_pause_here"), "Shift+Space presses pause_here")
	_assert(not Hotkeys.pressed(shift_space, "transport_play_toggle"), "Shift+Space doesn't press play")
	_assert(Hotkeys.pressed(space, "transport_play_toggle"), "Space presses play")
	_assert(not Hotkeys.pressed(space, "transport_pause_here"), "Space doesn't press pause_here")
	var ctrl_d := _key(KEY_D, {"ctrl": true})
	_assert(Hotkeys.pressed(ctrl_d, "edit_duplicate"), "Ctrl+D presses duplicate")
	_assert(not Hotkeys.pressed(ctrl_d, "toggle_device_lane"), "Ctrl+D doesn't press toggle_device_lane")
	_assert(Hotkeys.pressed(_key(KEY_D), "toggle_device_lane"), "D presses toggle_device_lane")
	_assert(Hotkeys.pressed(_key(KEY_Q, {}, true), "keyboard_c3"), "physical Q presses keyboard_c3")
	Hotkeys.capturing = true
	_assert(not Hotkeys.pressed(space, "transport_play_toggle"), "nothing is pressed while capturing")
	Hotkeys.capturing = false
	var echo := _key(KEY_SPACE)
	echo.echo = true
	_assert(not Hotkeys.pressed(echo, "transport_play_toggle"), "key repeat doesn't press a normal action")
	var left_echo := _key(KEY_LEFT)
	left_echo.echo = true
	_assert(Hotkeys.pressed(left_echo, "arranger_move_left"), "key repeat presses an allow_echo action")
	# Rebinding goes through Settings and reaches InputMap.
	var changed: Array = []
	Hotkeys.bindings_changed.connect(func(id): changed.append(id))
	Settings.set_value("shortcuts/transport_play_toggle", ["P"])
	_assert(changed == ["transport_play_toggle"], "bindings_changed fires for the rebound action")
	_assert(Hotkeys.pressed(_key(KEY_P), "transport_play_toggle"), "rebound play answers to P")
	_assert(not Hotkeys.pressed(space, "transport_play_toggle"), "rebound play no longer answers to Space")
	_assert(Hotkeys.get_display("transport_play_toggle") == "P", "get_display reflects the rebinding")
	Settings.set_value("shortcuts/transport_play_toggle", [])
	_assert(Hotkeys.get_display("transport_play_toggle") == "", "unbound action has an empty display")
	Settings.set_value("shortcuts/transport_play_toggle", ["Space"])


func _test_coerce() -> void:
	var s = Settings.get_setting("shortcuts/edit_copy")
	_assert(s != null and s.type == Settings.Type.SHORTCUT, "shortcut settings are registered")
	_assert(Settings.get_setting("shortcuts/edit_select_all_tracks") == null, "no setting for a double-tap action")
	_assert(Settings._coerce(s, ["Ctrl+C", "garbage+", "Ctrl+C", "Ctrl+Insert", "Alt+C"]) == ["Ctrl+C", "Ctrl+Insert"],
			"coerce drops garbage and duplicates and caps at two")
	_assert(Settings._coerce(s, []) == [], "coerce keeps an empty (unbound) array")
	_assert(Settings._coerce(s, "Ctrl+C") == s.default, "coerce falls back to the default for a non-array")
	_assert(Settings.get_categories().has(Settings.CATEGORY_SHORTCUTS), "Shortcuts category is listed")


func _test_double_tap() -> void:
	var table_ok := true
	for a in HotkeyActions.ACTIONS:
		if not a.has("double_tap_of"):
			continue
		var parent := HotkeyActions.get_action(a.double_tap_of)
		if parent.is_empty() or parent.has("double_tap_of") or parent.get("allow_echo", false) \
				or a.has("defaults") or not HotkeyActions.contexts_overlap(a.context, parent.context) \
				or a.context not in _descendants_or_self(parent.context):
			table_ok = false
	_assert(table_ok, "double-tap actions are well formed")
	var now := [1000]
	Hotkeys._now_msec = func(): return now[0]
	Hotkeys._last_press.clear()
	var ctrl_a := func(): return _key(KEY_A, {"ctrl": true})
	# The handler calls double_tapped() first, then pressed().
	var first: InputEventKey = ctrl_a.call()
	_assert(not Hotkeys.double_tapped(first, "edit_select_all_tracks"), "first tap is not a double tap")
	_assert(Hotkeys.pressed(first, "edit_select_all"), "first tap presses select_all")
	now[0] += 100
	var second: InputEventKey = ctrl_a.call()
	_assert(Hotkeys.double_tapped(second, "edit_select_all_tracks"), "second tap 100 ms later is a double tap")
	_assert(Hotkeys.pressed(second, "edit_select_all"), "the double-tap event still presses the parent")
	now[0] += 100
	var third: InputEventKey = ctrl_a.call()
	_assert(not Hotkeys.double_tapped(third, "edit_select_all_tracks"), "third quick tap is a new first tap")
	Hotkeys.pressed(third, "edit_select_all")
	now[0] += 500
	_assert(not Hotkeys.double_tapped(ctrl_a.call(), "edit_select_all_tracks"), "tap 500 ms later is not a double tap")
	_assert(Hotkeys.get_display("edit_select_all_tracks") == "Ctrl+A ×2", "double tap displays the parent's chord with ×2")
	# Rebinding the parent moves the double tap with it.
	Settings.set_value("shortcuts/edit_select_all", ["Ctrl+L"])
	Hotkeys._last_press.clear()
	var l1 := _key(KEY_L, {"ctrl": true})
	Hotkeys.double_tapped(l1, "edit_select_all_tracks")
	Hotkeys.pressed(l1, "edit_select_all")
	now[0] += 100
	_assert(Hotkeys.double_tapped(_key(KEY_L, {"ctrl": true}), "edit_select_all_tracks"), "double tap follows a rebound parent")
	_assert(Hotkeys.get_double_taps("edit_select_all") == ["edit_select_all_tracks"], "get_double_taps lists the follower")
	Settings.set_value("shortcuts/edit_select_all", ["Ctrl+A"])
	Hotkeys._now_msec = Time.get_ticks_msec


func _descendants_or_self(ctx: String) -> Array:
	var result := []
	for c in HotkeyActions.CONTEXTS:
		if ctx in HotkeyActions.context_chain(c):
			result.append(c)
	return result


func _test_no_project_input_duplicates() -> void:
	var dup: Array[String] = []
	for a in HotkeyActions.ACTIONS:
		if ProjectSettings.has_setting("input/" + a.id):
			dup.append(a.id)
	_assert(dup.is_empty(), "no registry id is defined in project.godot: %s" % str(dup))
