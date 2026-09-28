# test_sends_panel_pre_fader.gd
# Right-clicking a send knob offers a Pre-Fader toggle: disabled until the send exists,
# checked to match the send, and toggling it updates the channel's send and the knob arc.
# Run: godot --headless --path Godot -s tests/test_sends_panel_pre_fader.gd -- --test
extends TestBase

const PANEL_SCENE := "res://mixer/sends_panel/SendsPanel.tscn"


func suite_name() -> String:
	return "Sends panel pre-fader tests"


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var channel: Object = project.create_instrument_track("Drums").channel
	var bus: Object = project.create_bus_channel("Reverb")

	var panel: Control = load(PANEL_SCENE).instantiate()
	var pre_fader_id: int = panel.SendMenuItem.PRE_FADER
	root.add_child(panel)
	panel.bind_to_channel(channel, project)
	await process_frame

	var control: Object = panel._find_send_control(bus.id)
	_assert(control != null, "a send knob exists for the bus")
	var post_color: Color = control.knob.value_arc_color

	panel._show_send_menu(bus.id)
	var menu: PopupMenu = panel._send_menu
	var index := menu.get_item_index(pre_fader_id)
	_assert(menu.is_item_disabled(index), "Pre-Fader is disabled while there is no send")
	menu.hide()

	channel.add_send(bus.id, -12.0, false)
	panel._show_send_menu(bus.id)
	_assert(not menu.is_item_disabled(index), "Pre-Fader is enabled once the send exists")
	_assert(not menu.is_item_checked(index), "Pre-Fader is unchecked for a post-fader send")
	menu.hide()

	panel._on_send_menu_id_pressed(pre_fader_id)
	_assert(channel.get_send(bus.id).pre_fader, "toggling makes the send pre-fader")
	_assert(control.knob.value_arc_color == control.PRE_FADER_ARC_COLOR,
		"a pre-fader send colors the knob arc")

	panel._show_send_menu(bus.id)
	_assert(menu.is_item_checked(index), "Pre-Fader is checked for a pre-fader send")
	menu.hide()

	panel._on_send_menu_id_pressed(pre_fader_id)
	_assert(not channel.get_send(bus.id).pre_fader, "toggling again makes it post-fader")
	_assert(control.knob.value_arc_color == post_color, "a post-fader send restores the arc color")

	channel.remove_send(bus.id)
	panel.queue_free()
