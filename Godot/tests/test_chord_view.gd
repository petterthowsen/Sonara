# test_chord_view.gd
# The Chord panel view: a keyboard of intervals around middle C that toggles the voice parameters,
# zooms up to three octaves, pages, and lights the enabled keys while notes are held.
# Run: godot --headless --path Godot -s tests/test_chord_view.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript


func suite_name() -> String:
	return "Chord view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	var instance := _make_instance()
	_test_registered(instance)
	_test_toggle(instance)
	_test_window()
	_test_live(instance)
	await _test_bind_before_tree(instance)
	# The views generated a Simple View layout for the Chord; don't leave it in the user's config.
	var store: GDScript = load("res://devices/simple_view/SimpleLayoutStore.gd")
	DirAccess.remove_absolute(store.path_for(instance.device.device_id))
	store.clear_cache()


func _param(id: int, name: String, type := "float", lo := 0.0, hi := 1.0, default_v := 0.0) -> Object:
	var p: Object = _param_script.new(id, name)
	p.param_type = type
	p.min_value = lo
	p.max_value = hi
	p.default_value = default_v
	return p


func _make_instance() -> Object:
	var device: Object = _device_script.new("sonara.builtin.chord", "Chord",
		_device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	device.add_parameter(_param(0, "Play Original", "bool", 0, 1, 1))
	device.add_parameter(_param(1, "Strum", "float", 0, 500, 0))
	for k in range(1, 7):
		device.add_parameter(_param(10 * k, "Voice %d" % k, "bool", 0, 1, 1 if k <= 2 else 0))
		device.add_parameter(_param(10 * k + 1, "Interval %d" % k, "float", -24, 24, 4 if k == 1 else (7 if k == 2 else 0)))
		device.add_parameter(_param(10 * k + 2, "Velocity %d" % k, "float", 0, 100, 100))
	load("res://devices/DeviceViewFactory.gd").register_builtin_views(device)
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	var project: Object = _project_script.new()
	var channel: Object = project.create_instrument_track("Chord").channel
	return _instance_script.new(device, channel.id, 0)


func _view(instance: Object) -> Control:
	var view: Control = load("res://devices/builtin/chord/ChordDefaultView.tscn").instantiate()
	root.add_child(view)
	view.bind_to_device(instance)
	return view


func _test_registered(instance: Object) -> void:
	_assert(instance.device.has_panel_view(), "the Chord has its own panel view")


func _test_toggle(instance: Object) -> void:
	var view := _view(instance)
	var kb = view.keyboard
	_assert(kb.enabled.has(60) and kb.enabled.has(64) and kb.enabled.has(67) and kb.enabled.size() == 3,
		"the default chord shows root, +4 and +7 as enabled keys")
	kb.key_toggled.emit(64)
	_assert(instance.get_parameter_real(10) < 0.5 and not kb.enabled.has(64), "clicking an enabled key switches its voice off")
	kb.key_toggled.emit(64)
	_assert(instance.get_parameter_real(10) >= 0.5 and kb.enabled.has(64), "clicking it again switches it back on")
	kb.key_toggled.emit(71)
	_assert(kb.enabled.has(71) and is_equal_approx(instance.get_parameter_real(31), 11.0) and instance.get_parameter_real(30) >= 0.5,
		"a new key takes the first free voice (3) with its interval")
	kb.key_toggled.emit(60)
	_assert(instance.get_parameter_real(0) < 0.5 and not kb.enabled.has(60), "the root key toggles Play Original")
	for key in [48, 50, 52, 53]:
		kb.key_toggled.emit(key)
	_assert(not kb.enabled.has(53) or kb.enabled.size() <= 6, "no more than six voices are used")
	var voices_on := 0
	for k in range(1, 7):
		voices_on += 1 if instance.get_parameter_real(10 * k) >= 0.5 else 0
	_assert(voices_on <= 6, "voice count stays within six")
	view.queue_free()


func _test_window() -> void:
	var kb = load("res://devices/builtin/chord/ChordKeyboard.gd").new()
	kb.set_visible_octaves(3)
	_assert(kb.visible_octaves == 3, "three octaves can be shown")
	kb.set_visible_octaves(4)
	_assert(kb.visible_octaves == 3, "no more than three octaves")
	kb.set_page(9)
	_assert(kb.page == 1 and kb.key_range() == Vector2i(48, 84), "paging stops at the top (%s)" % kb.key_range())
	kb.set_page(-3)
	_assert(kb.page == 0 and kb.key_range() == Vector2i(36, 72), "paging stops at the bottom")
	kb.set_visible_octaves(1)
	_assert(kb.key_range() == Vector2i(36, 48), "one octave plus the closing C")
	kb.set_page(3)
	_assert(kb.key_range() == Vector2i(72, 84), "the top octave is reachable")
	kb.size = Vector2(130, 44)
	_assert(kb.key_at(1.0) == 72 and kb.key_at(129.0) == 84 and kb.key_at(-1.0) == -1, "x maps to keys")
	kb.free()


func _test_live(instance: Object) -> void:
	var view := _view(instance)
	view.show_view()
	var path: String = instance.osc_path()
	_assert(view._subscribed_path == path, "a shown view subscribes")
	view._on_data(path, "note_state", PackedByteArray([0xFF, 0xFF, 0xFF, 1, 72]))
	_assert(view.keyboard.live.has(64) and view.keyboard.is_key_sounding(64), "held notes light the enabled keys")
	_assert(not view.keyboard.live.has(62), "other keys stay unlit")
	view._on_data("/channel/999/device/9", "note_state", PackedByteArray([0xFF, 0xFF, 0xFF, 0]))
	_assert(view.keyboard.live.has(64), "a blob for another device is ignored")
	view._on_data(path, "note_state", PackedByteArray([0xFF, 0xFF, 0xFF, 0]))
	_assert(view.keyboard.live.is_empty(), "releasing every note clears the highlight")
	view.hide_view()
	_assert(view._subscribed_path == "", "hiding unsubscribes")
	view.queue_free()


## Bound before it enters the tree (as the device lane does): the scene's keyboard and buttons
## pick the device up on ready, and the header-tab getters are safe before then.
func _test_bind_before_tree(instance: Object) -> void:
	var view: Control = load("res://devices/builtin/chord/ChordDefaultView.tscn").instantiate()
	view.bind_to_device(instance)
	_assert(view.get_header_tabs().is_empty() and view.get_header_tab() == 0, "header tabs are safe before ready")
	root.add_child(view)
	await process_frame
	var kb = view.keyboard
	_assert(kb != null and not kb.enabled.is_empty() and kb.enabled.size() == view.enabled_intervals().size(), "bound before tree: the keyboard shows the enabled keys")
	_assert(view.page_left_button.text == "‹" and view.zoom_in_button.tooltip_text == "Show more octaves", "buttons come from the scene")
	view.zoom_in_button.pressed.emit()
	_assert(kb.visible_octaves == 3 and view.zoom_in_button.disabled, "+ shows another octave and disables itself at the limit")
	view.queue_free()
	await process_frame
