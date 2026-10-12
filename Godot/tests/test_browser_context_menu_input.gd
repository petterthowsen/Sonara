# Regression: the browser "Open in Containing Folder" context menu must
# survive the real input pipeline, not just direct handler calls. Godot 4.7's
# Tree.item_mouse_selected carries (local mouse position, button index) — a
# handler with the pre-4.4 (item, column, button) signature silently never
# runs (arity mismatch at emit), which is exactly what this suite guards
# against. Routes InputEventMouseButton RMB presses through the viewport into
# the full Editor scene's Browser.
#
# Run: godot --headless --path . -s tests/test_browser_context_menu_input.gd -- --test
extends TestBase

var _asset_script: Object
var _rmb_reached := false

func suite_name() -> String:
	return "Browser context menu input pipeline"

func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	var editor: Control = load("res://editor/Editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	var browser: Node = editor.find_child("Browser", true, false)
	_assert(browser != null, "Browser node found in the Editor scene")

	await _test_tree_right_click(browser)
	await _test_content_tree_right_click(browser)

	editor.queue_free()
	await process_frame


func _make_file_asset() -> Object:
	var asset: Object = _asset_script.new()
	asset.type = 0 # Asset.TYPE.Audio
	asset.path = "/abs/samples/kick.wav"
	asset.name = "kick"
	return asset


## Right-click a tree row through real event routing -> popup visible.
func _test_tree_right_click(browser: Node) -> void:
	var tree: Tree = browser._trees[0]
	tree.show()
	var ti: TreeItem = tree.create_item()
	ti.set_metadata(0, _make_file_asset())
	ti.select(0)
	await process_frame
	var reached: bool = await _rmb_click(tree, Vector2(20, 10))
	_assert(reached, "RMB reaches the tree row")
	var menu: PopupMenu = browser._context_menu
	_assert(menu != null and menu.visible, "tree right-click pops the context menu")
	if menu:
		menu.hide()
	tree.queue_free()
	await process_frame


## Right-click a content-tree row (list mode) through real event routing -> popup visible.
func _test_content_tree_right_click(browser: Node) -> void:
	var tree: Tree = browser._content_trees[0]
	tree.show()
	tree.clear()
	var ti: TreeItem = tree.create_item()
	var row: TreeItem = tree.create_item(ti)
	row.set_text(0, "kick.wav")
	row.set_metadata(0, _make_file_asset())
	await process_frame
	var reached: bool = await _rmb_click(tree, Vector2(20, 10))
	_assert(reached, "RMB reaches the content row")
	var menu: PopupMenu = browser._context_menu
	_assert(menu != null and menu.visible, "content tree right-click pops the context menu")
	if menu:
		menu.hide()


## Send a RMB press at an offset inside `control` and report whether its
## gui_input saw the event (the mouse button never reaches _gui_input when a
## parent swallows it first, so this also guards the routing chain).
func _rmb_click(control: Control, offset: Vector2) -> bool:
	_rmb_reached = false
	var cb := func(_ev):
		if _ev is InputEventMouseButton and _ev.button_index == MOUSE_BUTTON_RIGHT and _ev.pressed:
			_rmb_reached = true
	control.gui_input.connect(cb)
	var pos: Vector2 = control.get_global_rect().position + offset
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_RIGHT
	mb.pressed = true
	mb.position = pos
	mb.global_position = pos
	Input.parse_input_event(mb)
	await process_frame
	await process_frame
	control.gui_input.disconnect(cb)
	return _rmb_reached