# test_track_io_button.gd
# The TrackItem IO button shows the track channel's route, lists Master plus buses, routes the
# channel on selection, and follows the target's renames.
# Run: godot --headless --path Godot -s tests/test_track_io_button.gd -- --test
extends TestBase

const TRACK_ITEM_SCENE := "res://arranger/tracklist/TrackItem.tscn"


func suite_name() -> String:
	return "Track IO button tests"


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var pair: Dictionary = project.create_instrument_track("Lead")
	var channel: Object = pair.channel
	var bus: Object = project.create_bus_channel("Reverb")

	var item: Control = (load(TRACK_ITEM_SCENE) as PackedScene).instantiate()
	root.add_child(item)
	item.bind_to_track(pair.track, 0, project)
	await process_frame

	var button: MenuButton = item.io_button
	_assert(not button.disabled, "the IO button is enabled for a track with a channel")
	_assert(button.text == "Master", "it shows the default route (got '%s')" % button.text)

	item._rebuild_io_menu()
	var popup := button.get_popup()
	_assert(popup.get_item_index(1) >= 0, "Master is listed")
	_assert(popup.is_item_checked(popup.get_item_index(1)), "Master is checked")
	_assert(popup.get_item_index(bus.id) >= 0, "the bus is listed")
	_assert(popup.get_item_index(channel.id) < 0, "the track's own channel is not listed")

	item._on_io_menu_selected(bus.id)
	_assert(channel.output_channel_id == bus.id, "selecting the bus routes the channel to it")
	_assert(button.text == "Reverb", "the button shows the new route (got '%s')" % button.text)

	bus.set_name("Hall")
	_assert(button.text == "Hall", "the button follows the target's rename (got '%s')" % button.text)

	channel.set_route(1)
	_assert(button.text == "Master", "a route change elsewhere updates the button")

	item.queue_free()
	await process_frame
