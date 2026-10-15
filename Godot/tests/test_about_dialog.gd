# test_about_dialog.gd
# The About dialog builds and shows the version strings, links and licenses (spec 046 REQ-012).
# Run: godot --headless --path Godot -s tests/test_about_dialog.gd -- --test
extends TestBase

## Loaded at runtime: the script names autoloads, which don't exist yet when this file compiles.
var _ad: GDScript


func suite_name() -> String:
	return "AboutDialog tests"


func run_tests() -> void:
	_ad = load("res://editor/AboutDialog.gd")
	var dialog = _ad.new()
	root.add_child(dialog)
	await process_frame
	_assert(dialog.ui_label.text == "Version %s (%s)" % [BuildInfo.version(), BuildInfo.commit()], "UI version and commit shown")
	_assert(BuildInfo.version() in dialog.ui_label.text, "the version string is in the label")
	_assert(dialog.engine_label.text == "Engine: not connected", "no engine shows not connected")
	_assert(_ad.engine_text("0.1.0-beta.1", "abc", true) == "Engine 0.1.0-beta.1 (abc)", "engine version and commit")
	_assert(_ad.engine_text("", "", true) == "Engine: unknown version", "a pre-beta engine reads as unknown version")
	_assert(dialog.find_child("GitHubButton", true, false) != null, "GitHub button exists")
	_assert(dialog.find_child("itchioButton", true, false) != null, "itch.io button exists")
	_assert(dialog.find_child("LicensesButton", true, false) != null, "Licenses button exists")
	_assert(_ad.GITHUB_URL.begins_with("https://github.com/") and _ad.ITCH_URL == "https://thowsenmedia.itch.io/sonara", "link targets")
	var text: String = _ad.license_text()
	_assert("==== LICENSE ====" in text and "==== THIRD_PARTY_LICENSES ====" in text, "both license files are read from the install folder")
	dialog.show_licenses()
	var edit: TextEdit = dialog.find_child("LicenseText", true, false)
	_assert(edit != null and not edit.editable and edit.text.length() > 100 and text.begins_with(edit.text.substr(0, 100)), "licenses window is a read-only text view")
	_assert(dialog.find_child("WhatsNewButton", true, false) != null, "What's New button exists")
	_assert("## [" in _ad.changelog_text(), "the changelog is read from the install folder")
	dialog.show_changelog()
	var changelog: RichTextLabel = dialog.find_child("ChangelogText", true, false)
	_assert(changelog != null and changelog.bbcode_enabled and changelog.get_parsed_text().length() > 100, "changelog window is a rich text view")
	_assert(not changelog.get_parsed_text().contains("[lb]"), "escaped brackets render as brackets")
	_test_markdown()
	dialog.queue_free()


func _test_markdown() -> void:
	var md = _ad.markdown_to_bbcode
	_assert(md.call("# Title") == "[font_size=22][b]Title[/b][/font_size]", "h1")
	_assert(md.call("## [Unreleased]") == "[font_size=18][b][lb]Unreleased[rb][/b][/font_size]", "h2 with escaped brackets")
	_assert(md.call("### Added") == "[font_size=15][b]Added[/b][/font_size]", "h3")
	_assert(md.call("#123 is not a heading") == "[url=%s123]#123[/url] is not a heading" % _ad.ISSUES_URL, "an issue ref at line start is a link, not a heading")
	_assert(md.call("- A **bold** move") == "  \u2022 A [b]bold[/b] move", "bullet and bold")
	_assert(md.call("- Fixed the crash (#42)") == "  \u2022 Fixed the crash ([url=%s42]#42[/url])" % _ad.ISSUES_URL, "issue ref in a bullet")
	_assert(md.call("Run `x [1]`") == "Run [code]x [lb]1[rb][/code]", "inline code and escaped brackets")
	_assert(md.call("[site](https://example.com/a)") == "[url=https://example.com/a]site[/url]", "markdown link")
	_assert(md.call("a\r\nb") == "a\nb", "CRLF line endings")
	_assert(md.call("plain") == "plain", "plain text is unchanged")
