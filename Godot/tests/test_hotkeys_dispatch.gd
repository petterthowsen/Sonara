# Hotkey dispatch (Phase 1b): the chords that the migrated handlers rely on pick the right action.
# Building a full Editor headless is too heavy, so this checks the matching at the Hotkeys.pressed
# level, the same calls Editor, Mixer, NoteEditor and LayerMappingWindow make.
extends TestBase

# Autoloads don't resolve as bare identifiers when this script is the main loop script.
var Hotkeys


func suite_name() -> String:
	return "Hotkeys dispatch"


func run_tests() -> void:
	Hotkeys = root.get_node("Hotkeys")
	_test_transport()
	_test_modifier_variants()
	_test_delete_bindings()
	_test_double_tap_before_single()


func _key(keycode: Key, mods := {}) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ev.ctrl_pressed = mods.get("ctrl", false)
	ev.shift_pressed = mods.get("shift", false)
	return ev


## The first of `ids` that `ev` presses, or "" (handlers check them in this order).
func _dispatch(ev: InputEvent, ids: Array) -> String:
	for id in ids:
		if Hotkeys.pressed(ev, id):
			return id
	return ""


func _test_transport() -> void:
	var ids := ["transport_pause_to_start", "transport_play"]
	_assert(_dispatch(_key(KEY_SPACE, {"shift": true}), ids) == "transport_pause_to_start", "Shift+Space pauses here")
	_assert(_dispatch(_key(KEY_SPACE), ids) == "transport_play", "Space toggles play")
	var view := ["switch_extra_view", "switch_view"]
	_assert(_dispatch(_key(KEY_TAB, {"shift": true}), view) == "switch_extra_view", "Shift+Tab is the previous view")
	_assert(_dispatch(_key(KEY_TAB), view) == "switch_view", "Tab is the next view")
	_assert(not Hotkeys.pressed(_key(KEY_D, {"ctrl": true}), "toggle_device_lane"), "Ctrl+D doesn't toggle the device lane")


func _test_modifier_variants() -> void:
	var notes := ["notes_octave_up", "notes_transpose_up"]
	_assert(_dispatch(_key(KEY_UP, {"ctrl": true}), notes) == "notes_octave_up", "Ctrl+Up transposes an octave")
	_assert(_dispatch(_key(KEY_UP), notes) == "notes_transpose_up", "Up transposes a semitone")
	var fader := ["mixer_volume_up_fine", "mixer_volume_up"]
	_assert(_dispatch(_key(KEY_UP, {"shift": true}), fader) == "mixer_volume_up_fine", "Shift+Up nudges the fader finely")
	_assert(_dispatch(_key(KEY_UP), fader) == "mixer_volume_up", "Up nudges the fader")
	var layers := ["layers_shift_octave_down", "layers_shift_down"]
	_assert(_dispatch(_key(KEY_DOWN, {"shift": true}), layers) == "layers_shift_octave_down", "Shift+Down shifts an octave")
	_assert(_dispatch(_key(KEY_DOWN), layers) == "layers_shift_down", "Down shifts a semitone")


func _test_delete_bindings() -> void:
	_assert(Hotkeys.pressed(_key(KEY_DELETE), "edit_delete"), "Delete deletes")
	_assert(Hotkeys.pressed(_key(KEY_BACKSPACE), "edit_delete"), "Backspace deletes")
	_assert(not Hotkeys.pressed(_key(KEY_BACKSPACE), "zones_delete"), "the sampler zone map only deletes on Delete")
	_assert(Hotkeys.pressed(_key(KEY_BACKSPACE), "layers_delete"), "the layer mapping deletes on Backspace")


## Arranger._handle_input asks double_tapped before pressed: the first tap is a plain select-all.
func _test_double_tap_before_single() -> void:
	var now := [0]
	Hotkeys._now_msec = func(): return now[0]
	Hotkeys._last_press.clear()
	var tap := func() -> String:
		var ev := _key(KEY_A, {"ctrl": true})
		if Hotkeys.double_tapped(ev, "edit_select_all_tracks"):
			return "all_tracks"
		return "select_all" if Hotkeys.pressed(ev, "edit_select_all") else ""
	_assert(tap.call() == "select_all", "first Ctrl+A selects the active track")
	now[0] = 100
	_assert(tap.call() == "all_tracks", "a quick second Ctrl+A selects every track")
	now[0] = 200
	_assert(tap.call() == "select_all", "a third quick tap starts over")
	Hotkeys._now_msec = Time.get_ticks_msec
