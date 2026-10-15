# test_about_dialog.gd
# The About dialog builds and shows the version strings, links and licenses (spec 046 REQ-012).
# Run: godot --headless --path Godot -s tests/test_about_dialog.gd -- --test
extends TestBase


func suite_name() -> String:
	return "AboutDialog tests"


func run_tests() -> void:
	var dialog := AboutDialog.new()
	root.add_child(dialog)
	await process_frame
	_assert(dialog.ui_label.text == "Version %s (%s)" % [BuildInfo.version(), BuildInfo.commit()], "UI version and commit shown")
	_assert(BuildInfo.version() in dialog.ui_label.text, "the version string is in the label")
	_assert(dialog.engine_label.text == "Engine: not connected", "no engine shows not connected")
	_assert(AboutDialog.engine_text("0.1.0-beta.1", "abc", true) == "Engine 0.1.0-beta.1 (abc)", "engine version and commit")
	_assert(AboutDialog.engine_text("", "", true) == "Engine: unknown version", "a pre-beta engine reads as unknown version")
	_assert(dialog.find_child("GitHubButton", true, false) != null, "GitHub button exists")
	_assert(dialog.find_child("itchioButton", true, false) != null, "itch.io button exists")
	_assert(dialog.find_child("LicensesButton", true, false) != null, "Licenses button exists")
	_assert(AboutDialog.GITHUB_URL.begins_with("https://github.com/") and AboutDialog.ITCH_URL == "https://thowsenmedia.itch.io/sonara", "link targets")
	var text := AboutDialog.license_text()
	_assert("==== LICENSE ====" in text and "==== THIRD_PARTY_LICENSES ====" in text, "both license files are read from the install folder")
	dialog.show_licenses()
	var edit: TextEdit = dialog.find_child("LicenseText", true, false)
	_assert(edit != null and not edit.editable and edit.text == text, "licenses window is a read-only text view")
	dialog.queue_free()
