# Help context resolution (Phase 2a): nearest declared context, text-focus override,
# interaction-state stack with freed-owner cleanup, and the emitted signal.
extends TestBase

var Hotkeys


func suite_name() -> String:
	return "Help context"


func run_tests() -> void:
	Hotkeys = root.get_node("Hotkeys")
	_test_nearest_ancestor()
	_test_text_focus()
	_test_states()
	_test_chain_and_signal()


func _test_nearest_ancestor() -> void:
	var top := Control.new()
	var inner := Control.new()
	var leaf := Control.new()
	var other := Control.new()
	top.add_child(inner)
	inner.add_child(leaf)
	top.add_child(other)
	Hotkeys.set_context(top, "arranger")
	Hotkeys.set_context(inner, "mixer")
	_assert(Hotkeys._resolve_for(leaf) == "mixer", "leaf resolves to nearest declared ancestor")
	_assert(Hotkeys._resolve_for(other) == "arranger", "sibling resolves to the outer context")
	_assert(Hotkeys._resolve_for(null) == "global", "no hover resolves to global")
	_assert(Hotkeys._resolve_for(Control.new()) == "global", "undeclared tree resolves to global")
	top.free()


func _test_text_focus() -> void:
	var c := Control.new()
	Hotkeys.set_context(c, "arranger")
	var le := LineEdit.new()
	var te := TextEdit.new()
	_assert(Hotkeys._resolve_for(c, le) == "text", "LineEdit focus overrides hover")
	_assert(Hotkeys._resolve_for(c, te) == "text", "TextEdit focus overrides hover")
	_assert(Hotkeys._resolve_for(c, c) == "arranger", "non-text focus doesn't override")
	var owner := Node.new()
	Hotkeys._states.append({"owner": owner, "state": "clip_drag"})
	_assert(Hotkeys._resolve_for(c, le) == "text", "text focus beats a state")
	Hotkeys._states.clear()
	owner.free()
	c.free()
	le.free()
	te.free()


func _test_states() -> void:
	var c := Control.new()
	Hotkeys.set_context(c, "mixer")
	var a := Node.new()
	var b := Node.new()
	Hotkeys.begin_state(a, "clip_drag")
	Hotkeys.begin_state(b, "box_select")
	_assert(Hotkeys._resolve_for(c) == "box_select", "newest state wins over hover")
	Hotkeys.end_state(b)
	_assert(Hotkeys._resolve_for(c) == "clip_drag", "ending the top state reveals the one below")
	Hotkeys.begin_state(a, "clip_resize")
	_assert(Hotkeys._states.size() == 1, "one entry per owner")
	_assert(Hotkeys._resolve_for(c) == "clip_resize", "re-beginning replaces the state")
	Hotkeys.end_state(Node.new())
	_assert(Hotkeys._states.size() == 1, "end_state tolerates unknown owners")
	a.free()
	_assert(Hotkeys._resolve_for(c) == "mixer", "freed owner's state is dropped")
	_assert(Hotkeys._states.is_empty(), "freed owner removed from the stack")
	b.free()
	c.free()


func _test_chain_and_signal() -> void:
	var chain: Array = HotkeyActions.context_chain("clip_drag")
	_assert(chain == ["clip_drag", "arranger", "workspace", "global"], "state chain: %s" % [chain])
	for s in HotkeyActions.STATES:
		_assert(HotkeyActions.CONTEXTS.has(HotkeyActions.STATES[s]), "state %s has a real parent" % s)
	var got := []
	var cb := func(ctx: String, mods: int): got.append([ctx, mods])
	Hotkeys.help_context_changed.connect(cb)
	Hotkeys._set_help("arranger", 0)
	Hotkeys._set_help("arranger", 0)
	Hotkeys._set_help("arranger", KEY_MASK_SHIFT)
	_assert(got == [["arranger", 0], ["arranger", KEY_MASK_SHIFT]], "emits only on change: %s" % [got])
	Hotkeys.help_context_changed.disconnect(cb)
