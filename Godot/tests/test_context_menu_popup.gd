# test_context_menu_popup.gd
# Headless test for ContextMenuPopup (anchoring math, auto-close timer, shared open path) and the
# shared add-track list used by the arranger's + button and the tracklist's right-click menu.
#
# Run: godot --headless --path Godot -s tests/test_context_menu_popup.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"

## Loaded lazily: it reaches the Sonara autoload, which is not resolvable at parse time.
const TRACK_CREATE_MENU := "res://arranger/tracklist/TrackCreateMenu.gd"

const BOUNDS := Rect2(0, 0, 800, 600)
const MENU := Vector2(150, 100)


func suite_name() -> String:
	return "ContextMenuPopup"


func run_tests() -> void:
	_test_place_below_and_flip()
	_test_place_prefer_up()
	_test_place_horizontal()
	_test_place_overlap_and_clamp()
	_test_auto_close_timer()
	_test_track_create_items()
	await _test_popup_opens_in_test_mode()
	await _test_animated_paths()
	await _test_arranger_add_menu()
	await _test_clip_menu_icons()


func _test_place_below_and_flip() -> void:
	var anchor := Rect2(100, 200, 40, 20)
	var p := ContextMenuPopup.place(MENU, anchor, BOUNDS)
	_assert(not p.up, "opens below when there is room")
	_assert(p.position == Vector2(100, 220 + ContextMenuPopup.ANCHOR_GAP), "below the anchor with the gap: %s" % p.position)
	var low := Rect2(100, 560, 40, 20)
	p = ContextMenuPopup.place(MENU, low, BOUNDS)
	_assert(p.up, "flips above when below does not fit")
	_assert(p.position.y == 560 - ContextMenuPopup.ANCHOR_GAP - MENU.y, "above the anchor: %s" % p.position)


func _test_place_prefer_up() -> void:
	var anchor := Rect2(100, 400, 40, 20)
	var p := ContextMenuPopup.place(MENU, anchor, BOUNDS, true)
	_assert(p.up, "prefer_up opens above when it fits")
	var top := Rect2(100, 20, 40, 20)
	p = ContextMenuPopup.place(MENU, top, BOUNDS, true)
	_assert(not p.up, "prefer_up flips below when above does not fit")
	var tiny := Rect2(0, 0, 800, 120)
	p = ContextMenuPopup.place(Vector2(100, 400), Rect2(10, 60, 20, 20), tiny, false)
	_assert(p.position.y >= tiny.position.y and p.position.y + 400 <= tiny.end.y + 400, "never above the bounds when neither side fits")


func _test_place_horizontal() -> void:
	var p := ContextMenuPopup.place(MENU, Rect2(760, 100, 30, 20), BOUNDS)
	_assert(p.position.x == 790 - MENU.x, "right-aligns with the anchor when it overflows the right edge: %s" % p.position)
	p = ContextMenuPopup.place(MENU, Rect2(20, 100, 30, 20), BOUNDS)
	_assert(p.position.x == 20, "left-aligns with the anchor otherwise")
	p = ContextMenuPopup.place(Vector2(900, 50), Rect2(100, 100, 30, 20), BOUNDS)
	_assert(p.position.x == 0, "a menu wider than the bounds clamps to the left edge: %s" % p.position)


func _test_place_overlap_and_clamp() -> void:
	var m := Vector2(300, 200)
	var anchor := Rect2(Vector2(400, 300) - Vector2.ONE * 10, Vector2.ONE * 20)
	var p := ContextMenuPopup.place(m, anchor, BOUNDS, false, true)
	_assert(p.position == Vector2(390, 290), "overlap: top-left sits at the pointer square: %s" % p.position)
	p = ContextMenuPopup.place(m, Rect2(Vector2(400, 590) - Vector2.ONE * 10, Vector2.ONE * 20), BOUNDS, false, true)
	_assert(p.up and p.position.y == 600 - m.y, "overlap flips up with its bottom edge at the pointer square: %s" % p.position)
	_assert(BOUNDS.encloses(Rect2(p.position, m)), "result is inside the bounds")
	p = ContextMenuPopup.place(m, Rect2(795, 595, 20, 20), BOUNDS, false, true)
	_assert(BOUNDS.encloses(Rect2(p.position, m)), "a corner pointer still gives an on-screen menu: %s" % p.position)


func _test_auto_close_timer() -> void:
	var auto := ContextMenuPopup.AutoClose.new()
	_assert(ContextMenuPopup.AUTO_CLOSE_SECONDS == 2.0, "auto-close is 2 seconds")
	_assert(not auto.tick(1.0, false), "1 s outside does not close")
	_assert(not auto.tick(0.9, false), "1.9 s outside does not close")
	_assert(auto.tick(0.2, false), "2.1 s outside closes")
	auto.reset()
	auto.tick(1.5, false)
	_assert(not auto.tick(0.1, true), "re-entering the popup does not close")
	_assert(auto.outside_seconds == 0.0, "re-entering resets the timer")
	_assert(not auto.tick(1.9, false), "the full timeout applies again after re-entering")
	_assert(not auto.tick(5.0, false, true), "a busy popup (child popup, text edit) never closes")
	_assert(auto.outside_seconds == 0.0, "busy resets the timer")


func _test_track_create_items() -> void:
	var create_menu: GDScript = load(TRACK_CREATE_MENU)
	var menu := PopupMenu.new()
	create_menu.populate(menu)
	var kinds: Array[String] = []
	for item in create_menu.ITEMS:
		kinds.append(item["kind"])
	_assert(menu.item_count == 5, "five track kinds: %d" % menu.item_count)
	_assert(kinds == ["instrument", "audio", "track", "folder", "group"] , "kinds in order: %s" % [kinds])
	_assert(menu.get_item_text(2) == "Empty Track", "third entry is Empty Track")
	_assert(create_menu.create(null, 0) == null, "no project, no track")
	menu.free()
	# Loaded lazily: it names the Sonara autoload, which is not resolvable at parse time.
	var list_menu: PopupMenu = load("res://arranger/tracklist/TrackListContextMenu.gd").new()
	_assert(list_menu.item_count == 5, "tracklist right-click menu offers the same five: %d" % list_menu.item_count)
	for i in list_menu.item_count:
		_assert(list_menu.get_item_text(i) == create_menu.ITEMS[i]["label"], "tracklist entry %d matches the shared list" % i)
	list_menu.free()


func _test_popup_opens_in_test_mode() -> void:
	# The headless root window is tiny (64x64); the popups clamp to it, so give it room.
	get_root().size = Vector2i(800, 600)
	var root := Control.new()
	root.size = Vector2(800, 600)
	get_root().add_child(root)
	var button := Button.new()
	button.text = "Menu"
	button.position = Vector2(300, 560)
	button.size = Vector2(60, 30)
	root.add_child(button)
	var menu := PopupMenu.new()
	menu.add_item("One", 0)
	menu.add_item("Two", 1)
	root.add_child(menu)
	await process_frame
	ContextMenuPopup.popup_below_control(menu, button, true)
	await process_frame
	_assert(menu.is_embedded(), "headless popups are embedded")
	_assert(menu.position.x == 300, "left-aligned with the button: %s" % menu.position)
	_assert(menu.visible, "popup is visible straight after opening (no animation in tests)")
	_assert(menu.position.y + menu.size.y <= int(button.global_position.y), "opens above the button: pos %s size %s" % [menu.position, menu.size])
	_assert(menu.get_node_or_null(NodePath(ContextMenuPopup.CONTROLLER_NAME)) == null, "no animation controller in test mode")
	ContextMenuPopup.close(menu)
	_assert(not menu.visible, "close() hides immediately in test mode")
	ContextMenuPopup.popup_at_point(menu, Vector2(790, 590))
	_assert(menu.visible and menu.position.x + menu.size.x <= 800 and menu.position.y + menu.size.y <= 600,
			"a menu opened in the corner stays inside the window: %s %s" % [menu.position, menu.size])
	menu.hide()
	root.queue_free()


## Exercise the animated open / close / auto-close paths, which are off in test mode by default.
func _test_animated_paths() -> void:
	ContextMenuPopup.animate_in_tests = true
	get_root().size = Vector2i(800, 600)
	var root := Control.new()
	root.size = Vector2(800, 600)
	get_root().add_child(root)
	var menu := PopupMenu.new()
	menu.add_item("One", 0)
	menu.add_item("Two", 1)
	root.add_child(menu)
	var panel := PopupPanel.new()
	var label := Label.new()
	label.text = "Panel"
	panel.add_child(label)
	root.add_child(panel)
	await process_frame

	ContextMenuPopup.popup_at_point(menu, Vector2(600, 100))
	var controller := menu.get_node_or_null(NodePath(ContextMenuPopup.CONTROLLER_NAME))
	_assert(controller != null, "an animated popup gets a controller")
	_assert(not menu.hide_on_item_selection, "a PopupMenu hands item-selection closing to the controller")
	var start_y := menu.position.y
	await create_timer(0.5).timeout
	_assert(menu.visible, "visible after the open animation")
	_assert(menu.position.y != start_y, "it slid from its start offset: %d -> %d" % [start_y, menu.position.y])
	var settled := menu.position
	menu.index_pressed.emit(0)
	await create_timer(0.05).timeout
	_assert(menu.visible, "choosing an item keeps the menu up while it animates out")
	await create_timer(0.4).timeout
	_assert(not menu.visible, "choosing an item closes the menu after the close animation")

	# Reopening after a close lands where it did the first time.
	ContextMenuPopup.popup_at_point(menu, Vector2(600, 100))
	await create_timer(0.5).timeout
	_assert(menu.position == settled, "reopened at the same spot: %s vs %s" % [menu.position, settled])
	ContextMenuPopup.close(menu)
	await create_timer(0.4).timeout
	_assert(not menu.visible, "close() hides after the animation")

	# A PopupPanel fades its content in and out.
	ContextMenuPopup.popup_at_point(panel, Vector2(300, 300))
	await create_timer(0.5).timeout
	_assert(is_equal_approx(label.modulate.a, 1.0), "content fully visible once open")
	# Auto-close with the pointer never over the popup (a short timeout stands in for 2 s).
	(panel.get_node(NodePath(ContextMenuPopup.CONTROLLER_NAME)) as ContextMenuPopup.Controller)._auto.timeout = 0.3
	(panel.get_node(NodePath(ContextMenuPopup.CONTROLLER_NAME)) as ContextMenuPopup.Controller)._pointer_inside = false
	await create_timer(0.9).timeout
	_assert(not panel.visible, "the popup closes by itself once the pointer stays outside")
	_assert(is_equal_approx(label.modulate.a, 1.0), "content alpha is restored after closing")

	# A popup the pointer is inside does not auto-close.
	ContextMenuPopup.popup_at_point(panel, Vector2(300, 300))
	var inside_controller := panel.get_node(NodePath(ContextMenuPopup.CONTROLLER_NAME)) as ContextMenuPopup.Controller
	inside_controller._auto.timeout = 0.3
	inside_controller._set_inside(true)
	await create_timer(0.8).timeout
	_assert(panel.visible, "stays open while the pointer is inside")
	panel.hide()
	ContextMenuPopup.animate_in_tests = false
	root.queue_free()


func _test_arranger_add_menu() -> void:
	get_root().size = Vector2i(1200, 800)
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await process_frame

	var menu: PopupMenu = arranger.add_track_menu
	_assert(menu.item_count == 5, "+ menu lists five track kinds: %d" % menu.item_count)
	var texts: Array[String] = []
	for i in menu.item_count:
		texts.append(menu.get_item_text(i))
	_assert(texts == ["Instrument Track", "Audio Track", "Empty Track", "Folder Track", "Group Track"],
			"+ menu entries: %s" % [texts])
	_assert(arranger.find_child("AddFolderButton", true, false) == null, "the separate folder button is gone")
	arranger.add_track_button.pressed.emit()
	await process_frame
	_assert(menu.visible, "pressing + opens the menu")
	var button_top: int = int(arranger.add_track_button.get_global_rect().position.y)
	_assert(menu.position.y + menu.size.y <= button_top, "the + menu opens upwards: menu %s %s, button top %d" % [menu.position, menu.size, button_top])
	_assert(menu.position.x == int(arranger.add_track_button.get_global_rect().position.x), "the + menu is left-aligned with the button")
	menu.hide()
	root.queue_free()


## Every action button of the clip context menu has an icon (spec 054 REQ-031). The Reverse
## check button is a toggle row with its own check mark, not an action.
func _test_clip_menu_icons() -> void:
	var menu: Node = (load("res://arranger/timeline/ClipContextMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await process_frame
	var buttons := menu.find_children("*", "Button", true, false)
	var missing: Array[String] = []
	var checked := 0
	for b in buttons:
		if b is CheckButton or b is LineEdit:
			continue
		checked += 1
		if (b as Button).icon == null:
			missing.append(str(menu.get_path_to(b)))
	_assert(checked >= 14, "the clip menu has its action buttons (%d)" % checked)
	_assert(missing.is_empty(), "every action button has an icon (missing: %s)" % str(missing))
	menu.queue_free()
	await process_frame
