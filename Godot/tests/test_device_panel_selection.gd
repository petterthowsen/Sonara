# test_device_panel_selection.gd
# Headless tests for the DevicePanel selection work: panels are selectable with the white
# border of MixerChannel/TrackItem, the DeviceLane owns the selection (plain, ctrl/cmd
# additive, shift range, collapse on release), a drag carries the whole selection and a
# drop moves the block in one undo step. Also covers the left header as a drag handle,
# the modulators toggle below the View toggle, the chevron scroll behind the modulators
# pane and the pane fade animations.
# Run: godot --headless --path Godot -s tests/test_device_panel_selection.gd -- --test
#
# The lane, project and drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _device_drag: GDScript
var _drop_util: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "DevicePanel selection"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_device_drag = load("res://devices/DeviceDrag.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	await _test_selects_additive_and_range()
	await _test_release_collapses_multi_selection()
	await _test_drag_carries_the_selection()
	await _test_left_header_is_a_drag_handle()
	await _test_drop_selection_moves_the_block()
	await _test_drop_selection_across_channels()
	await _test_copy_paste_duplicate()
	await _test_nested_context_menu()
	await _test_selection_border()
	await _test_modulators_toggle_and_scroll()
	await _test_chevron_scroll()
	await _test_panes_slide_and_fade()
	await _test_note_fx_stripe()


## Registered fake effect `n`.
func _fx(ch: Object, n: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var id := "test.fx." + n
	var device: Object = registry._devices.get(id)
	if device == null:
		device = _device_script.new(id, id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		registry._devices[id] = device
	var inst: Object = _device_instance_script.new(device, ch.id, -1)
	ch.add_device(inst)
	return inst


func _fresh_project() -> Object:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_project = _project_script.new()
	return _project.create_instrument_track("Inst").channel


## Device lane bound to `ch` (headless there is no editor to bind it on channel focus).
func _lane(ch: Object) -> Control:
	var lane: Control = (load("res://devices/device_lane/DeviceLane.tscn") as PackedScene).instantiate()
	lane.size = Vector2(1600, 400)
	root.add_child(lane)
	_nodes.append(lane)
	lane.bind_to_channel(ch)
	await _settle()
	return lane


func _settle() -> void:
	await process_frame
	await process_frame


func _names(list: Array) -> Array:
	var out: Array = []
	for d in list:
		out.append(d.device.device_id.get_extension())
	return out


func _ids(list: Array) -> Array:
	var out: Array = []
	for d in list:
		out.append(d)
	return out


func _test_selects_additive_and_range() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var c := _fx(ch, "c")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	_assert(pa != null, "the lane shows a panel per device")
	if pa == null:
		return
	pa.select_requested.emit(pa, false, false)
	_assert(_ids(lane.selected_devices) == [a], "a plain click selects one device: %s" % str(_names(lane.selected_devices)))
	_assert(pa.is_selected, "the selected panel shows the selection")

	# Additive on b's panel through the row wiring (DevicePanel -> item -> row -> lane).
	var pb: Control = lane.find_device_panel(b)
	pb.select_requested.emit(pb, true, false)
	_assert(_ids(lane.selected_devices) == [a, b], "ctrl-click adds: %s" % str(_names(lane.selected_devices)))
	_assert(pb.is_selected and pa.is_selected, "both panels show the selection")

	# Shift-click takes the visual range from the anchor (a) to c.
	var pc: Control = lane.find_device_panel(c)
	pa.select_requested.emit(pa, false, false)
	pa.select_released.emit(pa)
	pc.select_requested.emit(pc, false, true)
	_assert(_ids(lane.selected_devices) == [a, b, c], "shift-click takes the range from the anchor: %s" % str(_names(lane.selected_devices)))
	_assert(pc.is_selected, "the range's end is selected")

	# A plain press on part of the block keeps it (drag support); release collapses to it.
	pc.select_requested.emit(pc, false, false)
	_assert(_ids(lane.selected_devices) == [a, b, c], "pressing part of the block keeps it")
	pc.select_released.emit(pc)
	_assert(_ids(lane.selected_devices) == [c], "release replaces the selection with the clicked device")
	_assert(not pa.is_selected and not pb.is_selected, "the other panels lose the border")


func _test_release_collapses_multi_selection() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var c := _fx(ch, "c")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	var pb: Control = lane.find_device_panel(b)
	pa.select_requested.emit(pa, true, false)
	pb.select_requested.emit(pb, true, false)
	_assert(lane.selected_devices.size() == 2, "two devices selected")

	# Plain press on part of the block keeps it (so a drag moves it all)...
	pb.select_requested.emit(pb, false, false)
	_assert(_ids(lane.selected_devices) == [a, b], "pressing a multi-selected panel keeps the block")
	# ...and releasing without a drag collapses to it.
	pb.select_released.emit(pb)
	_assert(_ids(lane.selected_devices) == [b], "release collapses the block to the clicked device: %s" % str(_names(lane.selected_devices)))
	_assert(pa.is_selected == false and pb.is_selected, "only the clicked panel stays selected")


func _test_drag_carries_the_selection() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	pa.select_requested.emit(pa, false, false)
	lane.find_device_panel(b).select_requested.emit(lane.find_device_panel(b), true, false)
	_assert(lane.selection_containing(a) == [a, b], "the lane hands the selection for the dragged device")
	_assert(lane.selection_containing(_fx(ch, "c")).is_empty(), "a device outside the selection drags alone")

	var drag: Object = _device_drag.start(pa, a, lane.selection_containing(a))
	_assert(drag.devices.size() == 2 and drag.device == a, "the drag carries both devices")
	_assert(_device_drag.unwrap_all(drag) == [a, b], "unwrap_all exposes the block")
	var single: Object = _device_drag.start(pa, a, [])
	_assert(single.devices == [a], "without a selection the drag carries one device")
	_assert(_device_drag.unwrap_all(_device_drag.unwrap(drag)) == [a], "unwrap still gives the primary device")


func _test_left_header_is_a_drag_handle() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	var pb: Control = lane.find_device_panel(b)
	_assert(pa.left_header != null and pa.left_header.mouse_filter == Control.MOUSE_FILTER_PASS,
		"the left header lets selection clicks pass to the panel")
	pa.select_requested.emit(pa, false, false)
	pb.select_requested.emit(pb, true, false)
	var drag: Variant = pa._get_drag_data(Vector2.ZERO)
	_assert(drag != null and drag.devices.size() == 2,
		"drag data from the panel carries the lane's selection: %s" % str(drag))


func _test_drop_selection_moves_the_block() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var c := _fx(ch, "c")
	var d := _fx(ch, "d")
	var lane := await _lane(ch)

	# Move A and B (visual order) to after C: a, b, c, d -> c, a, b, d.
	var moved: bool = _drop_util.drop_selection(ch, [a, b], null, 3)
	_assert(moved and _names(ch.devices) == ["c", "a", "b", "d"],
		"a selection drop moves the block in order: %s" % str(_names(ch.devices)))

	# Dropping the block where it already is changes nothing.
	_assert(not _drop_util.drop_selection(ch, [a, b], null, 2), "a no-op selection drop returns false")

	# Mixed parents (one device inside a container) reduce to moving the primary device alone.
	var layer: Object = _device_instance_script.new(_fresh_device("test.layer", true), ch.id, -1)
	ch.add_device(layer)
	var inside: Object = _device_instance_script.new(_fresh_device("test.fx.inside"), ch.id, -1)
	ch.add_device(inside, -1, layer)
	_drop_util.drop_selection(ch, [a, inside], null, -1)
	_assert(_names(ch.devices) == ["c", "b", "d", "layer", "a"],
		"a mixed selection moves only the primary device: %s" % str(_names(ch.devices)))
	_assert(_names(layer.children) == ["inside"], "the container keeps its child")


func _test_drop_selection_across_channels() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var other: Object = _project.create_instrument_track("Other").channel
	var x := _fx(other, "x")
	_drop_util.drop_selection(other, [a, b], null, 0)
	_assert(_names(other.devices) == ["a", "b", "x"] and ch.devices.is_empty(),
		"a selection from another channel transfers as a block: %s / %s" % [str(_names(other.devices)), str(_names(ch.devices))])


func _fresh_device(id: String, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(id)
	if device == null:
		device = _device_script.new(id, id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[id] = device
	return device


func _test_copy_paste_duplicate() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var c := _fx(ch, "c")
	var actions: GDScript = load("res://history/DeviceActions.gd")
	actions.duplicate_devices([b, a])
	_assert(_names(ch.devices) == ["a", "b", "a", "b", "c"], "duplicate puts copies after the block in order: %s" % str(_names(ch.devices)))
	_assert(ch.devices[2] != a and ch.devices[2].id != a.id, "the copy is a new instance")
	_assert(actions.copy([c]) == 1, "copy reports one device")
	actions.paste(ch, null, 0)
	_assert(_names(ch.devices) == ["c", "a", "b", "a", "b", "c"], "paste inserts at the position: %s" % str(_names(ch.devices)))


## A context menu request from a slot's row reaches the lane.
func _test_nested_context_menu() -> void:
	var ch: Object = _fresh_project()
	var chain: Object = _device_instance_script.new(_fresh_device("sonara.builtin.chain", true), ch.id, -1)
	ch.add_device(chain)
	var inside: Object = _device_instance_script.new(_fresh_device("test.fx.inside"), ch.id, -1)
	ch.add_device(inside, -1, chain)
	chain.set_slot_open(_device_instance_script.CHAIN_SLOT, true)
	var lane := await _lane(ch)
	var got := []
	lane.devices.context_menu_requested.connect(func(d, in_slot): got.append([d, in_slot]))
	var panel: Control = lane.find_device_panel(inside)
	if panel == null:
		_assert(false, "the nested device has a panel")
		return
	panel.request_context_menu.emit()
	_assert(got.size() == 1 and got[0][0] == inside and got[0][1], "a nested device's menu request reaches the lane")


func _test_selection_border() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	var pb: Control = lane.find_device_panel(b)
	pa.is_selected = true
	_assert(pa.theme_type_variation == &"DeviceCardSelected", "selecting swaps to DeviceCardSelected")
	var theme_sel := ThemeDB.get_project_theme()
	_assert(pa.get_theme_stylebox("panel") is StyleBoxFlat
			and (pa.get_theme_stylebox("panel") as StyleBoxFlat).border_color == theme_sel.get_color(&"border_selected", &"Sonara"),
		"selecting shows the neutral selection border")
	_assert(pb.theme_type_variation == &"DeviceCard", "the untouched panel keeps DeviceCard")
	pa.is_selected = false
	_assert(pa.theme_type_variation == &"DeviceCard", "deselecting restores DeviceCard")


func _test_modulators_toggle_and_scroll() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	var mod_button: Control = pa.modulators_button
	_assert(mod_button != null, "every panel gets a modulators toggle")
	_assert(mod_button.get_parent() == pa.view_button.get_parent(),
		"the modulators toggle lives in the left header column")
	_assert(mod_button.get_index() == pa.view_button.get_index() + 1,
		"the modulators toggle sits right below the View toggle")
	var mod: Control = pa.modulators
	_assert(mod != null and mod.get_parent() == pa.modulators_pane,
		"the modulators pane hosts the ModulatorsPane directly")
	_assert(mod._grid_scroll.get_script() == load("res://components/ChevronScrollContainer.gd"),
		"the modulator list scrolls with chevrons: %s" % mod._grid_scroll.get_class())
	_assert(mod._grid_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"the list pages vertically only")
	_assert(mod._detail_scroll != null and mod._detail_scroll.get_parent() == mod,
		"the options panel sits beside the list, not inside its scroll")


func _test_panes_slide_and_fade() -> void:
	var ch: Object = _fresh_project()
	var a := _fx(ch, "a")
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	_assert(not pa.view_pane.visible, "a device with no view keeps its View pane closed")
	_assert(pa.name_label.text == a.get_display_name(), "the header shows the name as a plain label")
	_assert(pa.name_label.mouse_filter == Control.MOUSE_FILTER_PASS, "the name label lets clicks pass")
	_assert(pa.vertical_name_label.mouse_filter == Control.MOUSE_FILTER_PASS, "the vertical name lets clicks pass")

	# The modulators tab opens through a reveal wrapper: the pane fades while the wrapper's
	# reveal (and so the whole panel layout) grows.
	var wrap: Control = pa.modulators_pane.get_parent()
	_assert(wrap != pa.content_hbox and wrap.clip_contents, "panes sit in clipping reveal wrappers")
	pa.modulators_button.button_pressed = true
	_assert(pa.modulators_pane.visible and wrap.visible, "an opening pane is visible immediately")
	await process_frame
	_assert(0.0 < wrap.reveal and wrap.reveal < 1.0 and pa.modulators_pane.modulate.a < 1.0,
		"an opening pane slides the layout and fades")
	await root.get_tree().create_timer(pa.PANE_ANIM_DURATION + 0.05).timeout
	_assert(is_equal_approx(wrap.reveal, 1.0) and is_equal_approx(pa.modulators_pane.modulate.a, 1.0),
		"a shown pane settles revealed at full opacity")

	# Toggle off: the wrapper's reveal animates to zero, then the pane leaves the layout.
	pa.modulators_button.button_pressed = false
	await process_frame
	_assert(pa.modulators_pane.visible and 0.0 < wrap.reveal and wrap.reveal < 1.0,
		"a closing pane shrinks the layout before disappearing")
	await root.get_tree().create_timer(pa.PANE_ANIM_DURATION + 0.05).timeout
	_assert(not pa.modulators_pane.visible and not wrap.visible, "a closed pane ends hidden")
	_assert(is_equal_approx(pa.modulators_pane.modulate.a, 1.0), "its alpha is restored for the next show")

	# Reopening animates again and ends revealed.
	pa.modulators_button.button_pressed = true
	_assert(pa.modulators_pane.visible, "reopening shows the pane immediately")
	await root.get_tree().create_timer(pa.PANE_ANIM_DURATION + 0.05).timeout
	_assert(wrap.visible and is_equal_approx(wrap.reveal, 1.0), "a shown pane ends revealed")


## ChevronScrollContainer regression: paging with `snap_to_items` must not hit a typed-array
## error, and an item too wide for the view must stay visible instead of fading to nothing.
func _test_chevron_scroll() -> void:
	var scroll: Control = load("res://components/ChevronScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(200, 80)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.snap_to_items = true
	scroll.fade_hidden_items = true
	var flow := HBoxContainer.new()
	scroll.add_child(flow)
	var items: Array[Control] = []
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(250, 40)  # wider than the 200px view
	flow.add_child(wide)
	items.append(wide)
	root.add_child(scroll)
	await process_frame
	await process_frame
	scroll.scroll_step(false, 1)
	await root.get_tree().create_timer(0.25).timeout
	_assert(scroll.scroll_horizontal > 0.0, "paging with items to snap to scrolls: %f" % scroll.scroll_horizontal)
	_assert(items[0].modulate.a > 0.99, "an item too wide for the view stays visible")
	scroll.free()


## Spec 027 REQ-036: only a note-effect device shows the accent_secondary stripe.
func _test_note_fx_stripe() -> void:
	var ch: Object = _fresh_project()
	var fx := _fx(ch, "stripe_audio")
	var registry: Object = root.get_node("AssetService").device_registry
	var note_device: Object = _device_script.new("test.note.stripe", "Stripe", _device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	registry._devices[note_device.device_id] = note_device
	var note_fx: Object = _device_instance_script.new(note_device, ch.id, -1)
	ch.add_device(note_fx)
	var lane := await _lane(ch)
	var audio_panel: Control = lane.find_device_panel(fx)
	var note_panel: Control = lane.find_device_panel(note_fx)
	_assert(audio_panel != null and note_panel != null, "the lane shows both panels")
	if audio_panel == null or note_panel == null:
		return
	_assert(not audio_panel.note_fx_stripe.visible, "an audio device has no note-effect stripe")
	_assert(note_panel.note_fx_stripe.visible, "a note effect shows the stripe")
	_assert(note_panel.note_fx_stripe.color == UiColors.role(&"accent_secondary"), "the stripe uses accent_secondary")
