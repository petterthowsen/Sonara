class_name SfzFiles extends RefCounted

## Finds every file an SFZ instrument needs: the SFZ itself, its `#include`s and each `sample=`
## (resolved against `default_path`, then the SFZ's folder), so export can embed them.

static var _opcode_re: RegEx


## `{files: PackedStringArray, missing: PackedStringArray}` - absolute paths, deduplicated.
## `files` holds only files that exist; `sfz_path` is first when it exists.
static func collect(sfz_path: String) -> Dictionary:
	var files := PackedStringArray()
	var missing := PackedStringArray()
	var root_dir := sfz_path.get_base_dir()
	_collect_file(sfz_path, root_dir, files, missing, [""], 0)
	return {"files": files, "missing": missing}


static func _add_unique(list: PackedStringArray, path: String) -> void:
	if not list.has(path):
		list.append(path)


## `default_path` is boxed in a one-element array so an included file can change it for the rest
## of the root file, as SFZ specifies.
static func _collect_file(path: String, root_dir: String, files: PackedStringArray, missing: PackedStringArray, default_path: Array, depth: int) -> void:
	if depth > 8:
		return
	if not FileAccess.file_exists(path):
		_add_unique(missing, path)
		return
	if files.has(path):
		return
	_add_unique(files, path)
	var text := FileAccess.get_file_as_string(path)
	text = _strip_comments(text)
	for raw_line in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("#include"):
			var quoted := line.get_slice("\"", 1)
			if quoted != "":
				_collect_file(_join(path.get_base_dir(), quoted), root_dir, files, missing, default_path, depth + 1)
			continue
		if line.begins_with("#"):
			continue
		for opcode in _opcodes(line):
			if opcode.name == "default_path":
				default_path[0] = opcode.value
			elif opcode.name == "sample":
				if opcode.value == "" or opcode.value.begins_with("*"):
					continue  # built-in oscillator, no file
				var sample := _join(root_dir, str(default_path[0]) + opcode.value)
				if FileAccess.file_exists(sample):
					_add_unique(files, sample)
				else:
					_add_unique(missing, sample)


static func _join(base_dir: String, relative: String) -> String:
	var rel := relative.replace("\\", "/")
	if rel.is_absolute_path():
		return rel.simplify_path()
	return base_dir.path_join(rel).simplify_path()


static func _strip_comments(text: String) -> String:
	var out := ""
	var i := 0
	var n := text.length()
	while i < n:
		if text.substr(i, 2) == "/*":
			var end := text.find("*/", i + 2)
			i = n if end == -1 else end + 2
		elif text.substr(i, 2) == "//":
			var nl := text.find("\n", i)
			i = n if nl == -1 else nl
		else:
			out += text[i]
			i += 1
	return out


## `name=value` pairs on one line; a value runs until the next `name=` (so sample names may
## contain spaces).
static func _opcodes(line: String) -> Array:
	if _opcode_re == null:
		_opcode_re = RegEx.create_from_string("(?:^|\\s)([A-Za-z_][A-Za-z0-9_]*)=")
	var matches := _opcode_re.search_all(line)
	var out: Array = []
	for i in matches.size():
		var m: RegExMatch = matches[i]
		var value_end: int = line.length() if i == matches.size() - 1 else matches[i + 1].get_start()
		out.append({"name": m.get_string(1), "value": line.substr(m.get_end(), value_end - m.get_end()).strip_edges()})
	return out
