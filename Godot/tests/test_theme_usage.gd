# test_theme_usage.gd
# Scenes and scripts use the semantic theme variations instead of local styleboxes
# (REQ-005, 006, 009): editor sections, device cards and floating surfaces.
# Run: godot --headless --path Godot -s tests/test_theme_usage.gd -- --test
extends TestBase

const EDITOR_SCENE := "res://editor/Editor.tscn"
const CARD_SCENES := [
	"res://devices/device_lane/DevicePanel.tscn",
	"res://devices/compact/CompactDevicePanel.tscn",
]


func suite_name() -> String:
	return "Theme usage tests"


func run_tests() -> void:
	_test_sections()
	await _test_cards()
	await _test_floating()
	await _test_wells()
	await _test_selection()


## Property value `prop` of the node at `path` as stored in the scene file, or null.
func _scene_prop(scene: PackedScene, path: String, prop: StringName) -> Variant:
	var state := scene.get_state()
	for i in state.get_node_count():
		if str(state.get_node_path(i)) == (path if path == "." else "./" + path):
			for j in state.get_node_property_count(i):
				if state.get_node_property_name(i, j) == prop:
					return state.get_node_property_value(i, j)
	return null


func _test_sections() -> void:
	var scene: PackedScene = load(EDITOR_SCENE)
	_assert(_scene_prop(scene, ".", &"theme_type_variation") == &"AppRoot", "the editor root uses AppRoot")
	_assert(_scene_prop(scene, "VBoxContainer", &"theme_type_variation") == &"SectionStack", "the main stack uses SectionStack")
	var base := "VBoxContainer/Middle/LeftRightSplit/"
	var sections := {
		"VBoxContainer/Header": "Header",
		base + "LeftCenterSplit/LeftDock/Inspector": "Inspector",
		base + "LeftCenterSplit/MiddleCenter/Primary": "Primary",
		base + "LeftCenterSplit/MiddleCenter/Secondary": "Secondary",
		base + "RightDock/BrowserPanel": "BrowserPanel",
		"VBoxContainer/Bottom/InfoPanel": "InfoPanel",
	}
	for path in sections:
		_assert(_scene_prop(scene, path, &"theme_type_variation") == &"SectionPanel",
			"%s uses SectionPanel" % sections[path])
		_assert(_scene_prop(scene, path, &"theme_override_styles/panel") == null,
			"%s has no local panel stylebox" % sections[path])
	var assistant: PackedScene = load("res://ai/ui/AssistantPanel.tscn")
	_assert(_scene_prop(assistant, ".", &"theme_type_variation") == &"SectionPanel", "AssistantPanel uses SectionPanel")
	for script_path in ["res://editor/docks/DockPanel.gd", "res://devices/frame/DeviceFrame.gd"]:
		var src := FileAccess.get_file_as_string(script_path)
		_assert(src.contains("\"SectionHeader\"") and not src.contains("Dark" + "Panel"),
			"%s title bars use SectionHeader" % script_path.get_file())



func _test_cards() -> void:
	var theme := ThemeDB.get_project_theme()
	var card := theme.get_stylebox(&"panel", &"DeviceCard") as StyleBoxFlat
	var selected := theme.get_stylebox(&"panel", &"DeviceCardSelected") as StyleBoxFlat
	_assert(card != null and selected != null and card.border_color != selected.border_color,
		"the theme has distinct DeviceCard and DeviceCardSelected borders")
	for path in CARD_SCENES:
		var panel: Control = load(path).instantiate()
		root.add_child(panel)
		await process_frame
		var name: String = path.get_file()
		_assert(panel is PanelContainer and panel.theme_type_variation == &"DeviceCard", "%s resolves DeviceCard" % name)
		_assert((panel.get_theme_stylebox("panel") as StyleBoxFlat).border_color == card.border_color,
			"%s draws the card border" % name)
		panel.is_selected = true
		_assert(panel.theme_type_variation == &"DeviceCardSelected"
				and (panel.get_theme_stylebox("panel") as StyleBoxFlat).border_color == selected.border_color,
			"%s selection swaps to DeviceCardSelected" % name)
		panel.is_selected = false
		_assert(panel.theme_type_variation == &"DeviceCard", "%s deselection restores DeviceCard" % name)
		var header: Control = panel.get("header") if panel.get("header") != null else panel.get_node_or_null("VBox/TopHeader")
		_assert(header != null and header.theme_type_variation == &"DeviceCardHeader", "%s header uses DeviceCardHeader" % name)
		panel.queue_free()
	await process_frame
	for path in ["res://devices/device_lane/DevicePanel.gd", "res://devices/compact/CompactDevicePanel.gd"]:
		_assert(not FileAccess.get_file_as_string(path).contains("BORDER_COLOR"), "%s has no BORDER_COLOR constants" % path.get_file())


func _test_floating() -> void:
	var theme := ThemeDB.get_project_theme()
	var floating := theme.get_stylebox(&"panel", &"Floating") as StyleBoxFlat
	for node in [ValueTooltip.new(), LabelOverlay.new()]:
		root.add_child(node)
		await process_frame
		_assert(node.theme_type_variation == &"Floating", "%s uses Floating" % node.get_class())
		_assert((node.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == floating.bg_color,
			"%s draws the floating background" % node.get_class())
		node.queue_free()
	var plain := ValueTooltip.new()
	root.add_child(plain)
	plain.set_plain(true)
	_assert(plain.get_theme_stylebox("panel") is StyleBoxEmpty, "a plain ValueTooltip keeps an empty style")
	plain.set_plain(false)
	_assert(plain.get_theme_stylebox("panel") is StyleBoxFlat, "leaving plain mode restores the floating style")
	plain.queue_free()
	for variation in [&"ContextMenu", &"ContextMenuList"]:
		_assert((theme.get_stylebox(&"panel", variation) as StyleBoxFlat).bg_color == floating.bg_color,
			"%s has the floating look" % variation)


func _test_wells() -> void:
	var list: PackedScene = load("res://mixer/device_list/ChannelDeviceList.tscn")
	_assert(_scene_prop(list, ".", &"theme_type_variation") == &"Well", "the channel device list uses Well")
	_assert(_scene_prop(list, ".", &"theme_override_styles/panel") == null, "the device list has no local panel stylebox")
	var well := UiColors.role(&"well")
	for control in [XYSlider.new(), EnvelopeControl.new()]:
		root.add_child(control)
		await process_frame
		_assert(control.bg_color == well, "%s draws the well colour" % control.get_script().get_global_name())
		control.queue_free()


## Every selectable item draws the same neutral border when selected (REQ-012).
func _test_selection() -> void:
	var want := UiColors.role(&"border_selected")
	var track_script: GDScript = load("res://data/Track.gd")
	var track = track_script.new(2)
	for path in CARD_SCENES:
		var panel: Control = load(path).instantiate()
		root.add_child(panel)
		await process_frame
		panel.is_selected = true
		_assert((panel.get_theme_stylebox("panel") as StyleBoxFlat).border_color == want,
			"%s selected border is border_selected" % path.get_file())
		panel.queue_free()

	var strip = load("res://mixer/MixerChannel.tscn").instantiate()
	root.add_child(strip)
	await process_frame
	strip.is_selected = true
	_assert((strip.get_theme_stylebox("panel") as StyleBoxFlat).border_color == want, "MixerChannel selected border is border_selected")
	strip.is_selected = false
	_assert((strip.get_theme_stylebox("panel") as StyleBoxFlat).border_color == UiColors.role(&"border"), "MixerChannel unselected border is the card border")
	strip.queue_free()

	var item = load("res://clip_editor/tracklist/ClipEditorTrackListItem.tscn").instantiate()
	root.add_child(item)
	item.track = track
	item.set_selected(true)
	await process_frame
	_assert((item.get_theme_stylebox("panel") as StyleBoxFlat).border_color == want, "ClipEditorTrackListItem selected border is border_selected")
	item.queue_free()

	var row = load("res://arranger/tracklist/TrackItem.tscn").instantiate()
	root.add_child(row)
	await process_frame
	_assert(row.selected_outline_color == want, "TrackItem selection outline is border_selected")
	row.queue_free()
