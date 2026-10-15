# AboutDialog.gd
# Help > About Sonara: icon, UI and engine versions, links and the license texts (spec 046
# REQ-012). Built in code, like QuitPromptDialog.
class_name AboutDialog extends AcceptDialog

const GITHUB_URL := "https://github.com/petterthowsen/Sonara"
const ITCH_URL := "https://thowsenmedia.itch.io/sonara"
const LICENSE_FILES := ["LICENSE", "THIRD_PARTY_LICENSES"]

var ui_label: Label
var engine_label: Label
var _licenses_window: Window


func _init() -> void:
	title = "About Sonara"
	ok_button_text = "Close"
	min_size = Vector2i(420, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var icon_path = ProjectSettings.get_setting("application/config/icon", "")
	if icon_path is String and not (icon_path as String).is_empty() and ResourceLoader.exists(icon_path):
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = load(icon_path)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(72, 72)
		box.add_child(icon)

	var name_label := Label.new()
	name_label.name = "AppName"
	name_label.text = "Sonara"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 24)
	box.add_child(name_label)

	ui_label = Label.new()
	ui_label.name = "UiVersion"
	ui_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(ui_label)

	engine_label = Label.new()
	engine_label.name = "EngineVersion"
	engine_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(engine_label)

	var links := HBoxContainer.new()
	links.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(links)
	links.add_child(_link_button("GitHub", GITHUB_URL))
	links.add_child(_link_button("itch.io", ITCH_URL))
	var licenses := Button.new()
	licenses.name = "LicensesButton"
	licenses.text = "Licenses"
	licenses.pressed.connect(show_licenses)
	links.add_child(licenses)

	about_to_popup.connect(refresh)
	refresh()


func _ready() -> void:
	if AudioEngineOSC != null:
		AudioEngineOSC.engine_info_received.connect(func(_v, _c, _p) -> void: refresh())
		AudioEngineOSC.engine_disconnected.connect(refresh)


func _link_button(label: String, url: String) -> Button:
	var button := Button.new()
	button.name = label.replace(".", "") + "Button"
	button.text = label
	button.tooltip_text = url
	button.pressed.connect(func() -> void: OS.shell_open(url))
	return button


## "Version 0.1.0-beta.1 (380d9b0)" for the UI.
static func ui_text() -> String:
	return "Version %s (%s)" % [BuildInfo.version(), BuildInfo.commit()]


## The engine line: its version and commit, "unknown version" for an engine that predates
## /status/engine_info, or "not connected".
static func engine_text(version: String, commit: String, connected: bool) -> String:
	if not version.is_empty():
		return "Engine %s (%s)" % [version, commit]
	if connected:
		return "Engine: unknown version"
	return "Engine: not connected"


func refresh() -> void:
	ui_label.text = ui_text()
	engine_label.text = engine_text(AudioEngineOSC.engine_version, AudioEngineOSC.engine_commit,
			AudioEngineOSC._is_engine_connected)


## The text of the license files found in the install folder, with a heading per file.
static func license_text() -> String:
	var parts: PackedStringArray = []
	for file_name in LICENSE_FILES:
		var path: String = BuildInfo.install_dir().path_join(file_name)
		if FileAccess.file_exists(path):
			parts.append("==== %s ====\n\n%s" % [file_name, FileAccess.get_file_as_string(path)])
	if parts.is_empty():
		return "License files were not found in %s." % BuildInfo.install_dir()
	return "\n\n".join(parts)


func show_licenses() -> void:
	if _licenses_window == null:
		_licenses_window = Window.new()
		_licenses_window.title = "Sonara licenses"
		_licenses_window.size = Vector2i(760, 560)
		_licenses_window.exclusive = false
		_licenses_window.close_requested.connect(_licenses_window.hide)
		var edit := TextEdit.new()
		edit.name = "LicenseText"
		edit.editable = false
		edit.text = license_text()
		edit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_licenses_window.add_child(edit)
		add_child(_licenses_window)
	_licenses_window.popup_centered()
