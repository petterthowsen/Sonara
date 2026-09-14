# test_command_history.gd
# Headless unit tests for CommandHistory, MacroCommand, and PropertyCommand.
# Run: godot --headless --path Godot -s history/test_command_history.gd
extends SceneTree


var _failures: int = 0


func _init() -> void:
	print("=== CommandHistory tests ===")
	_test_execute_undo_redo()
	_test_record()
	_test_macro()
	_test_property_merge()
	_test_clear_and_save_point()
	_test_save_point_after_undo_and_new_edits()
	_test_save_point_not_falsely_clean_on_merge()
	_test_property_on_stub_object()
	if _failures == 0:
		print("=== ALL PASSED ===")
	else:
		print("=== FAILED: %d ===" % _failures)
	quit(_failures)


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)


func _test_execute_undo_redo() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 0}
	var cmd := PropertyCommand.new("Set", null, "", 0, 5)
	cmd.set_callable(func(v): target["value"] = v)
	hist.execute(cmd)
	_assert(target["value"] == 5, "execute applies new value")
	_assert(hist.can_undo(), "can undo after execute")
	hist.undo()
	_assert(target["value"] == 0, "undo restores old value")
	_assert(hist.can_redo(), "can redo after undo")
	hist.redo()
	_assert(target["value"] == 5, "redo reapplies new value")


func _test_record() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 10}
	target["value"] = 20
	var cmd := PropertyCommand.new("Set", null, "", 10, 20)
	cmd.set_callable(func(v): target["value"] = v)
	hist.record(cmd)
	_assert(target["value"] == 20, "record does not re-apply do()")
	hist.undo()
	_assert(target["value"] == 10, "undo after record works")


func _test_macro() -> void:
	var hist := CommandHistory.new()
	var target := {"a": 0, "b": 0}
	var c1 := PropertyCommand.new("A", null, "", 0, 1)
	c1.set_callable(func(v): target["a"] = v)
	var c2 := PropertyCommand.new("B", null, "", 0, 2)
	c2.set_callable(func(v): target["b"] = v)
	hist.execute(MacroCommand.new("Macro", [c1, c2]))
	_assert(target["a"] == 1 and target["b"] == 2, "macro do runs children")
	hist.undo()
	_assert(target["a"] == 0 and target["b"] == 0, "macro undo reverses children")


func _test_property_merge() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 0.0}
	var apply := func(v): target["value"] = v
	var c1 := PropertyCommand.new("Vol", null, "", 0.0, 1.0)
	c1.set_callable(apply).set_mergeable(true)
	hist.record(c1)
	target["value"] = 2.0
	var c2 := PropertyCommand.new("Vol", null, "", 1.0, 2.0)
	c2.set_callable(apply).set_mergeable(true)
	hist.record(c2)
	_assert(hist.undo_count() == 1, "mergeable properties coalesce")
	hist.undo()
	_assert(is_equal_approx(float(target["value"]), 0.0), "merged undo restores first old value")


func _test_clear_and_save_point() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 0}
	var cmd := PropertyCommand.new("Set", null, "", 0, 1)
	cmd.set_callable(func(v): target["value"] = v)
	hist.execute(cmd)
	hist.mark_save_point()
	_assert(hist.is_at_save_point(), "at save point after mark")
	var cmd2 := PropertyCommand.new("Set2", null, "", 1, 2)
	cmd2.set_callable(func(v): target["value"] = v)
	hist.execute(cmd2)
	_assert(not hist.is_at_save_point(), "dirty after new edit")
	hist.undo()
	_assert(hist.is_at_save_point(), "clean after undo to save point")
	hist.clear()
	_assert(not hist.can_undo() and not hist.can_redo(), "clear empties stacks")


## B3: save at depth 3, undo to depth 1, then two new (non-mergeable) edits
## bring the stack back to depth 3. Without invalidating save_point_index on
## the undo-then-branch, is_at_save_point() would falsely report clean.
func _test_save_point_after_undo_and_new_edits() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 0}
	var make_cmd := func(name: String, old_v: int, new_v: int) -> PropertyCommand:
		var c := PropertyCommand.new(name, null, "", old_v, new_v)
		c.set_callable(func(v): target["value"] = v)
		return c
	hist.execute(make_cmd.call("C1", 0, 1))
	hist.execute(make_cmd.call("C2", 1, 2))
	hist.execute(make_cmd.call("C3", 2, 3))
	hist.mark_save_point()
	_assert(hist.undo_count() == 3 and hist.is_at_save_point(), "saved at depth 3")
	hist.undo()
	hist.undo()
	_assert(hist.undo_count() == 1, "undone back to depth 1")
	hist.execute(make_cmd.call("C4", 1, 10))
	hist.execute(make_cmd.call("C5", 10, 20))
	_assert(hist.undo_count() == 3, "two new edits return stack to depth 3")
	_assert(not hist.is_at_save_point(), "depth matches save point but content diverged: must report dirty")


## B3: merging a new edit into the entry sitting exactly at the save point
## must not silently rewrite the saved entry while keeping depth unchanged.
func _test_save_point_not_falsely_clean_on_merge() -> void:
	var hist := CommandHistory.new()
	var target := {"value": 0.0}
	var apply := func(v): target["value"] = v
	var c1 := PropertyCommand.new("Vol", null, "", 0.0, 1.0)
	c1.set_callable(apply).set_mergeable(true)
	hist.record(c1)
	hist.mark_save_point()
	_assert(hist.is_at_save_point(), "clean right after save")
	target["value"] = 2.0
	var c2 := PropertyCommand.new("Vol", null, "", 1.0, 2.0)
	c2.set_callable(apply).set_mergeable(true)
	hist.record(c2)
	_assert(not hist.is_at_save_point(), "merging into the save-point entry must mark dirty")


## Stub object with a setter — avoids loading Channel (engine OSC dependency).
class VolumeStub extends RefCounted:
	var volume: float = 0.0


	func set_volume(v: float) -> void:
		volume = clampf(v, -60.0, 12.0)


func _test_property_on_stub_object() -> void:
	var stub := VolumeStub.new()
	var old_vol := stub.volume
	var cmd := PropertyCommand.new("Volume", stub, "set_volume", old_vol, -6.0)
	var hist := CommandHistory.new()
	hist.execute(cmd)
	_assert(is_equal_approx(stub.volume, -6.0), "named setter applies on stub object")
	hist.undo()
	_assert(is_equal_approx(stub.volume, old_vol), "undo restores stub volume")
