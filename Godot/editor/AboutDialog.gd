# AboutDialog.gd
# Help > About Sonara: icon, UI and engine versions, links and the license texts (spec 046
# REQ-012), plus the changelog. Built in code, like QuitPromptDialog.
class_name AboutDialog extends AcceptDialog

const GITHUB_URL := "https://github.com/petterthowsen/Sonara"
const ITCH_URL := "https://thowsenmedia.itch.io/sonara"
const ISSUES_URL := GITHUB_URL + "/issues/"
const LICENSE_FILES := ["LICENSE", "THIRD_PARTY_LICENSES"]
const CHANGELOG_FILE := "CHANGELOG.md"

var ui_label: Label
var engine_label: Label
var _licenses_window: Window
var _changelog_window: Window


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
	var whats_new := Button.new()
	whats_new.name = "WhatsNewButton"
	whats_new.text = "What's New"
	whats_new.pressed.connect(show_changelog)
	links.add_child(whats_new)

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


## The CHANGELOG.md in the install folder (repo root in dev runs), or a note pointing at itch.io.
static func changelog_text() -> String:
	var path: String = BuildInfo.install_dir().path_join(CHANGELOG_FILE)
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_string(path)
	return "The changelog was not found in %s.\n\nSee %s for release notes." % [BuildInfo.install_dir(), ITCH_URL]


## Light Markdown to BBCode for a RichTextLabel: #/##/### headings, "- " bullets, **bold**,
## `code`, [text](url) links and #123 issue references (linked to GitHub). Literal brackets are
## escaped, so other text shows as written.
static func markdown_to_bbcode(markdown: String) -> String:
	var bold := RegEx.create_from_string("\\*\\*(.+?)\\*\\*")
	var code := RegEx.create_from_string("`([^`]+)`")
	var link := RegEx.create_from_string("\uE000(.+?)\uE001\\((https?://[^)\\s]+)\\)")
	var issue := RegEx.create_from_string("(?<![\\w&/])#(\\d+)\\b")
	var heading_sizes := {1: 22, 2: 18, 3: 15}
	var lines: PackedStringArray = []
	for raw in markdown.replace("\r\n", "\n").split("\n"):
		var line: String = raw.replace("[", "\uE000").replace("]", "\uE001")
		line = bold.sub(line, "[b]$1[/b]", true)
		line = code.sub(line, "[code]$1[/code]", true)
		line = link.sub(line, "[url=$2]$1[/url]", true)
		line = issue.sub(line, "[url=%s$1]#$1[/url]" % ISSUES_URL, true)
		var level := 0
		while level < line.length() and line[level] == "#":
			level += 1
		if level >= 1 and level <= 3 and line.substr(level).begins_with(" "):
			line = "[font_size=%d][b]%s[/b][/font_size]" % [heading_sizes[level], line.substr(level + 1).strip_edges()]
		elif line.begins_with("- "):
			line = "  \u2022 " + line.substr(2)
		lines.append(line.replace("\uE000", "[lb]").replace("\uE001", "[rb]"))
	return "\n".join(lines)


func show_changelog() -> void:
	if _changelog_window == null:
		_changelog_window = Window.new()
		_changelog_window.title = "What's New in Sonara"
		_changelog_window.size = Vector2i(640, 560)
		_changelog_window.exclusive = false
		_changelog_window.close_requested.connect(_changelog_window.hide)
		var text := RichTextLabel.new()
		text.name = "ChangelogText"
		text.bbcode_enabled = true
		text.selection_enabled = true
		text.text = markdown_to_bbcode(changelog_text())
		text.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(str(meta)))
		text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_changelog_window.add_child(text)
		add_child(_changelog_window)
	_changelog_window.popup_centered()
