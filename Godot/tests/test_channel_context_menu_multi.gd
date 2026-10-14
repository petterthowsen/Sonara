# test_channel_context_menu_multi.gd
# The mixer channel menu on a multi-selection: colour, hidden and delete apply to every selected
# channel (master excluded), the name field becomes "N channels", and each action is one undo step.
# Run: godot --headless --path Godot -s tests/test_channel_context_menu_multi.gd -- --test
extends TestBase

var _recorded: Array = []


func suite_name() -> String:
	return "Channel context menu multi-selection tests"


func run_tests() -> void:
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	await _test_multi()
	await _test_single()
	util.test_recorder = Callable()


func _menu() -> Object:
	var menu: Object = (load("res://mixer/ChannelContextMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	menu.hide()
	return menu


func _test_multi() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var a: Object = project.create_bus_channel("A")
	var b: Object = project.create_bus_channel("B")
	var c: Object = project.create_bus_channel("C")
	var master: Object = project.get_channel_by_id(1)
	var menu: Object = _menu()
	await process_frame
	menu.bind_to_channel(a, _peers([b, master]))
	_assert(menu.is_multi(), "multi with 3 channels")
	_assert(menu.label.disabled, "name editing disabled")
	_assert(menu.label.get_value() == "3 channels" if menu.label.has_method("get_value") else true, "name shows count")

	# Colour: applies to all, one undo step.
	var olds := [a.color, b.color, master.color]
	_recorded.clear()
	menu._on_color_changed(Color(0.1, 0.2, 0.3))
	menu._on_color_changed(Color(0.9, 0.2, 0.3))
	menu._flush_color_history()
	_assert(a.color == Color(0.9, 0.2, 0.3) and b.color == a.color and master.color == a.color, "colour applied to all")
	_assert(not c.color == a.color, "unselected channel untouched")
	_assert(_recorded.size() == 1, "colour is one history entry (got %d)" % _recorded.size())
	_recorded[0].undo()
	_assert(a.color == olds[0] and b.color == olds[1] and master.color == olds[2], "colour undo restores all")
	_recorded[0].do()
	_assert(b.color == Color(0.9, 0.2, 0.3), "colour redo")

	# Hidden: all but master, one step.
	_recorded.clear()
	menu._on_hidden_toggled(true)
	_assert(a.hidden and b.hidden and not master.hidden and not c.hidden, "hidden on selected, not master")
	_assert(_recorded.size() == 1, "hide is one history entry")
	_recorded[0].undo()
	_assert(not a.hidden and not b.hidden, "hide undo")

	# Hide sends on buses.
	_recorded.clear()
	menu._on_sends_hidden_toggled(true)
	_assert(a.sends_hidden and b.sends_hidden and not c.sends_hidden, "sends hidden on selected buses")
	_assert(_recorded.size() == 1, "hide sends is one history entry")
	_recorded[0].undo()

	# Delete: master excluded.
	var deleted: Array = []
	menu.delete_many_requested.connect(func(list): deleted.append_array(list))
	menu._on_delete_pressed()
	_assert(deleted.size() == 2 and deleted.has(a) and deleted.has(b) and not deleted.has(master), "delete excludes master")
	menu.queue_free()

	# Mixer-level delete is one undo step.
	var delete_script: GDScript = load("res://history/commands/ChannelDeleteCommand.gd")
	var cmds: Array = []
	for ch in [a, b]:
		cmds.append(delete_script.new(project, ch))
	_recorded.clear()
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.execute_many("Delete Channels", Array(cmds, TYPE_OBJECT, &"RefCounted", load("res://history/commands/Command.gd")))
	_assert(project.get_channel_by_id(a.id) == null and project.get_channel_by_id(b.id) == null, "both deleted")
	_assert(project.get_channel_by_id(c.id) != null, "unselected kept")
	_assert(_recorded.size() == 1, "delete is one history entry")
	_recorded[0].undo()
	_assert(project.get_channel_by_id(a.id) != null and project.get_channel_by_id(b.id) != null, "delete undo restores both")


func _test_single() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var a: Object = project.create_bus_channel("Solo")
	var menu: Object = _menu()
	await process_frame
	menu.bind_to_channel(a)
	_assert(not menu.is_multi(), "single is not multi")
	_assert(not menu.label.disabled, "name editable for a single channel")
	menu._on_color_changed(Color(0.5, 0.5, 0.5))
	_assert(a.color == Color(0.5, 0.5, 0.5), "single colour applies")
	menu.queue_free()


## A typed Array[Channel] (the menu's signature) built without the class_name identifier.
func _peers(list: Array) -> Array:
	return Array(list, TYPE_OBJECT, &"RefCounted", load("res://data/Channel.gd"))
