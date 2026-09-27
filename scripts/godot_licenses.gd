# Writes the Godot engine's license and third-party notices to a file (stdout also carries
# autoload output). Used by gen_third_party_licenses.sh:
#   godot --headless --path Godot -s ../scripts/godot_licenses.gd -- --test --out=/abs/path.txt
extends SceneTree


func _init() -> void:
	var out := PackedStringArray()
	out.append("Godot Engine %s" % Engine.get_version_info().string)
	out.append("")
	out.append(Engine.get_license_text())
	out.append("")
	out.append("Third-party components bundled with Godot:")
	out.append("")
	for info in Engine.get_copyright_info():
		out.append("- %s" % info["name"])
		for part in info["parts"]:
			var files: PackedStringArray = part["files"]
			out.append("  Files: %s" % ", ".join(files))
			for c in part["copyright"]:
				out.append("  Copyright: %s" % c)
			out.append("  License: %s" % part["license"])
	out.append("")
	var licenses: Dictionary = Engine.get_license_info()
	for name in licenses:
		out.append("-".repeat(80))
		out.append("License: %s" % name)
		out.append("")
		out.append(licenses[name])
		out.append("")
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			path = arg.trim_prefix("--out=")
	var file := FileAccess.open(path, FileAccess.WRITE) if path != "" else null
	if file == null:
		push_error("godot_licenses.gd: pass a writable --out=<path>")
		quit(1)
		return
	file.store_string("\n".join(out) + "\n")
	file.close()
	quit()
