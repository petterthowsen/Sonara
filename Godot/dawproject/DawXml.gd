class_name DawXml extends RefCounted

## Minimal XML DOM and writer for DAWproject files. `parse` wraps `XMLParser` into a tree that
## keeps every element and attribute (unknown ones included); `Writer` builds indented XML with
## attribute escaping and fixed-precision numbers.


class El extends RefCounted:
	var tag: String = ""
	var attrs: Dictionary = {}
	var children: Array[El] = []
	var parent: El = null
	var text: String = ""
	var line: int = 0

	func get_attr(name: String, default: String = "") -> String:
		return str(attrs.get(name, default))

	func has_attr(name: String) -> bool:
		return attrs.has(name)

	func get_float(name: String, default: float = 0.0) -> float:
		if not attrs.has(name):
			return default
		var s: String = str(attrs[name])
		return s.to_float() if s.is_valid_float() else default

	func get_bool(name: String, default: bool = false) -> bool:
		if not attrs.has(name):
			return default
		return str(attrs[name]).to_lower() == "true"

	## First child element named `child_tag`, or null.
	func child(child_tag: String) -> El:
		for c in children:
			if c.tag == child_tag:
				return c
		return null

	func children_named(child_tag: String) -> Array[El]:
		var out: Array[El] = []
		for c in children:
			if c.tag == child_tag:
				out.append(c)
		return out

	## Depth-first search for the first descendant (or self) named `find_tag`.
	func find(find_tag: String) -> El:
		if tag == find_tag:
			return self
		for c in children:
			var hit := c.find(find_tag)
			if hit != null:
				return hit
		return null


## Parse `buffer` into a tree. Returns `{root: El, error: ""}` or `{root: null, error: "..."}`
## where the error names the line.
static func parse(buffer: PackedByteArray) -> Dictionary:
	if buffer.is_empty():
		return {"root": null, "error": "XML error: file is empty"}
	var parser := XMLParser.new()
	var err := parser.open_buffer(buffer)
	if err != OK:
		return {"root": null, "error": "XML: cannot open buffer (%s)" % error_string(err)}
	var root: El = null
	var current: El = null
	while true:
		err = parser.read()
		if err == ERR_FILE_EOF:
			break
		if err != OK:
			return {"root": null, "error": "XML error near line %d" % (parser.get_current_line() + 1)}
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node := El.new()
				node.tag = parser.get_node_name()
				node.line = parser.get_current_line() + 1
				for i in parser.get_attribute_count():
					node.attrs[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				if current != null:
					node.parent = current
					current.children.append(node)
				elif root != null:
					return {"root": null, "error": "XML error at line %d: more than one root element" % node.line}
				else:
					root = node
				if not parser.is_empty():
					current = node
			XMLParser.NODE_ELEMENT_END:
				if current == null or current.tag != parser.get_node_name():
					return {"root": null, "error": "XML error at line %d: unexpected closing tag </%s>" % [parser.get_current_line() + 1, parser.get_node_name()]}
				current = current.parent
			XMLParser.NODE_TEXT:
				if current != null:
					current.text += parser.get_node_data()
	if root == null:
		return {"root": null, "error": "XML error: no root element"}
	if current != null:
		return {"root": null, "error": "XML error: <%s> opened at line %d is never closed" % [current.tag, current.line]}
	_trim_text(root)
	return {"root": root, "error": ""}


static func _trim_text(node: El) -> void:
	node.text = node.text.strip_edges()
	for c in node.children:
		_trim_text(c)


## `%.6f`-style number, trailing zeros kept short: `1.5`, `0.501187`, `3`.
static func num(v: float) -> String:
	var s := "%.6f" % v
	if s == "-0.000000":
		s = "0.000000"
	return s


static func escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


class Writer extends RefCounted:
	var _out: String = ""
	var _stack: Array[String] = []
	var _open_pending: bool = false  # last `open` tag hasn't been terminated with `>` yet

	func _init() -> void:
		_out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

	func _attrs(attrs: Dictionary) -> String:
		var s := ""
		for key in attrs:
			var v: Variant = attrs[key]
			var text: String
			if v is float:
				text = DawXml.num(v)
			elif v is bool:
				text = "true" if v else "false"
			else:
				text = str(v)
			s += " %s=\"%s\"" % [key, DawXml.escape(text)]
		return s

	func _flush_pending() -> void:
		if _open_pending:
			_out += ">\n"
			_open_pending = false

	func _indent() -> String:
		return "    ".repeat(_stack.size())

	## Start `<tag attrs>`; children follow until `close()`.
	func open(tag: String, attrs: Dictionary = {}) -> void:
		_flush_pending()
		_out += "%s<%s%s" % [_indent(), tag, _attrs(attrs)]
		_stack.append(tag)
		_open_pending = true

	## `<tag attrs/>`, or `<tag attrs>text</tag>` when `text` is not empty.
	func leaf(tag: String, attrs: Dictionary = {}, text: String = "") -> void:
		_flush_pending()
		if text == "":
			_out += "%s<%s%s/>\n" % [_indent(), tag, _attrs(attrs)]
		else:
			_out += "%s<%s%s>%s</%s>\n" % [_indent(), tag, _attrs(attrs), DawXml.escape(text), tag]

	func close() -> void:
		var tag: String = _stack.pop_back()
		if _open_pending:
			_out += "/>\n"
			_open_pending = false
		else:
			_out += "%s</%s>\n" % [_indent(), tag]

	func to_bytes() -> PackedByteArray:
		assert(_stack.is_empty(), "DawXml.Writer: unclosed elements")
		return _out.to_utf8_buffer()

	func to_text() -> String:
		return _out
