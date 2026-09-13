# PromptTemplate.gd
# Load ~/.config/sonara/aichat/system_prompt.md and expand {variables}.
class_name PromptTemplate extends RefCounted


const USER_RELATIVE := "aichat/system_prompt.md"
const SHIPPED_PATH := "res://ai/prompt/system_prompt.md"


## User-editable prompt path under the Sonara config dir.
static func user_path() -> String:
	var sonara := _sonara()
	if sonara:
		return str(sonara.call("get_config_dir")).path_join(USER_RELATIVE)
	return OS.get_environment("HOME").path_join(".config/sonara").path_join(USER_RELATIVE)


## Autoload if the tree is up; null in isolated script tests.
static func _sonara() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("Sonara")


## Copy the shipped default once, then return the current prompt text.
static func load_text() -> String:
	var path := user_path()
	if not FileAccess.file_exists(path):
		_copy_shipped(path)
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			return text
	if FileAccess.file_exists(SHIPPED_PATH):
		return FileAccess.get_file_as_string(SHIPPED_PATH)
	return "You are Sonara’s in-project assistant."


## Expand `{name}` from `values`. Unknown tokens stay as-is. `{{` / `}}` → `{` / `}`.
static func expand(template: String, values: Dictionary) -> String:
	var out := ""
	var i := 0
	var n := template.length()
	while i < n:
		var ch := template.unicode_at(i)
		if ch == 123: # {
			if i + 1 < n and template.unicode_at(i + 1) == 123:
				out += "{"
				i += 2
				continue
			var close := template.find("}", i + 1)
			if close < 0:
				out += template.substr(i)
				break
			var inner := template.substr(i + 1, close - i - 1)
			if inner.find("{") >= 0 or inner.find("\n") >= 0 or inner.is_empty():
				out += template.substr(i, close - i + 1)
				i = close + 1
				continue
			if values.has(inner):
				out += str(values[inner])
			else:
				out += "{" + inner + "}"
			i = close + 1
		elif ch == 125: # }
			if i + 1 < n and template.unicode_at(i + 1) == 125:
				out += "}"
				i += 2
			else:
				out += "}"
				i += 1
		else:
			out += char(ch)
			i += 1
	return out


## Names referenced as `{name}` in the template (not escaped braces).
static func referenced_names(template: String) -> PackedStringArray:
	var names: PackedStringArray = []
	var i := 0
	var n := template.length()
	while i < n:
		if template.unicode_at(i) == 123:
			if i + 1 < n and template.unicode_at(i + 1) == 123:
				i += 2
				continue
			var close := template.find("}", i + 1)
			if close < 0:
				break
			var inner := template.substr(i + 1, close - i - 1)
			if not inner.is_empty() and inner.find("{") < 0 and inner.find("\n") < 0:
				if not names.has(inner):
					names.append(inner)
			i = close + 1
		else:
			i += 1
	return names


## Render the user (or shipped) system prompt with the given context.
static func render(context: PromptContext) -> String:
	var template := load_text()
	var values := {}
	for name in referenced_names(template):
		if context.has_variable(name):
			values[name] = context.get_value(name)
	return expand(template, values)


## Write the shipped default only if the user file is missing.
static func _copy_shipped(dest: String) -> void:
	if not FileAccess.file_exists(SHIPPED_PATH):
		return
	var dir := dest.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var src := FileAccess.get_file_as_string(SHIPPED_PATH)
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		push_warning("[PromptTemplate] Could not create %s" % dest)
		return
	file.store_string(src)
	file.close()
	print("[PromptTemplate] Copied default system prompt to %s" % dest)
