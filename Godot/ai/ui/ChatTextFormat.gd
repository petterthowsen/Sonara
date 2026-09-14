## BBCode helpers for chat transcript bodies (JSON tools, markdown messages).
class_name ChatTextFormat extends RefCounted


const _C_KEY := "#9ecfff"
const _C_STRING := "#a8e6a1"
const _C_NUMBER := "#e8b080"
const _C_LITERAL := "#c9a0e8"
const _C_CODE_BG := "#1a1b1f"
const _C_QUOTE := "#9a9aa3"


## Escape user/model text so RichTextLabel BBCode stays safe.
static func escape_bbcode(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch: int = text.unicode_at(i)
		if ch == 91:
			out += "[lb]"
		elif ch == 93:
			out += "[rb]"
		else:
			out += text.substr(i, 1)
	return out


## Re-indent JSON when the whole body parses; otherwise return as-is.
static func pretty_json(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return text
	var parsed: Variant = JSON.parse_string(trimmed)
	if parsed == null:
		return text
	return JSON.stringify(parsed, "\t")


## Monospace JSON with light syntax coloring for tool call / result blocks.
static func json_to_bbcode(text: String) -> String:
	var pretty := pretty_json(text)
	return "[code][bgcolor=%s]%s[/bgcolor][/code]" % [_C_CODE_BG, _highlight_json(pretty)]


## User/assistant markdown → BBCode (code spans are left untouched).
static func message_to_bbcode(text: String) -> String:
	if text.is_empty():
		return ""
	var out := ""
	for part in _split_code_tokens(text):
		match part["kind"]:
			"fence":
				out += _code_block(part["value"])
			"inline":
				out += (
					"[code][bgcolor=%s]%s[/bgcolor][/code]"
					% [_C_CODE_BG, escape_bbcode(part["value"])]
				)
			"text":
				out += _markdown_text(part["value"])
	return out


static func _split_code_tokens(text: String) -> Array:
	var parts: Array = []
	var i := 0
	var n := text.length()
	while i < n:
		if _match_at(text, i, "```"):
			var close := text.find("```", i + 3)
			if close == -1:
				parts.append({"kind": "text", "value": text.substr(i)})
				break
			var inner := text.substr(i + 3, close - i - 3)
			var lang_len := 0
			var nl := inner.find("\n")
			if nl != -1:
				var maybe_lang := inner.substr(0, nl).strip_edges()
				if maybe_lang.is_valid_identifier() and not maybe_lang.contains(" "):
					lang_len = nl + 1
			parts.append({"kind": "fence", "value": inner.substr(lang_len)})
			i = close + 3
			continue
		var tick := text.find("`", i)
		if tick == -1:
			parts.append({"kind": "text", "value": text.substr(i)})
			break
		if tick > i:
			parts.append({"kind": "text", "value": text.substr(i, tick - i)})
		var tick_end := text.find("`", tick + 1)
		if tick_end == -1:
			parts.append({"kind": "text", "value": text.substr(tick)})
			break
		parts.append({"kind": "inline", "value": text.substr(tick + 1, tick_end - tick - 1)})
		i = tick_end + 1
	return parts


static func _markdown_text(text: String) -> String:
	if text.is_empty():
		return ""
	var lines := text.split("\n", false)
	var out: PackedStringArray = []
	var i := 0
	while i < lines.size():
		var line: String = lines[i]
		if line.is_empty():
			out.append("")
			i += 1
			continue
		if _is_hr_line(line):
			out.append("[hr]")
			i += 1
			continue
		var heading := _parse_heading(line)
		if not heading.is_empty():
			out.append(_heading_bbcode(int(heading["level"]), str(heading["text"])))
			i += 1
			continue
		if _is_ul_line(line):
			var items: PackedStringArray = []
			while i < lines.size() and _is_ul_line(lines[i]):
				items.append(_markdown_inline(_ul_body(lines[i])))
				i += 1
			out.append("[ul]\n%s\n[/ul]" % "\n".join(items))
			continue
		if _is_ol_line(line):
			var items: PackedStringArray = []
			while i < lines.size() and _is_ol_line(lines[i]):
				items.append(_markdown_inline(_ol_body(lines[i])))
				i += 1
			out.append("[ol]\n%s\n[/ol]" % "\n".join(items))
			continue
		if _is_quote_line(line):
			var quotes: PackedStringArray = []
			while i < lines.size() and _is_quote_line(lines[i]):
				quotes.append(_markdown_inline(_quote_body(lines[i])))
				i += 1
			out.append("[color=%s][i]%s[/i][/color]" % [_C_QUOTE, "\n".join(quotes)])
			continue
		out.append(_markdown_inline(line))
		i += 1
	return "\n".join(out)


static func _markdown_inline(text: String) -> String:
	if text.is_empty():
		return ""
	var out := ""
	var i := 0
	var n := text.length()
	while i < n:
		if _match_at(text, i, "**"):
			var close := text.find("**", i + 2)
			if close != -1:
				var inner := text.substr(i + 2, close - i - 2)
				out += "[b]%s[/b]" % _markdown_inline(inner)
				i = close + 2
				continue
		if _match_at(text, i, "__"):
			var close := text.find("__", i + 2)
			if close != -1:
				var inner := text.substr(i + 2, close - i - 2)
				out += "[b]%s[/b]" % _markdown_inline(inner)
				i = close + 2
				continue
		if _match_at(text, i, "~~"):
			var close := text.find("~~", i + 2)
			if close != -1:
				var inner := text.substr(i + 2, close - i - 2)
				out += "[s]%s[/s]" % _markdown_inline(inner)
				i = close + 2
				continue
		if text.unicode_at(i) == 91:
			var link := _try_markdown_link(text, i)
			if not link.is_empty():
				out += link["bbcode"]
				i = int(link["end"])
				continue
		if text.unicode_at(i) == 42 and not _match_at(text, i, "**"):
			var close := text.find("*", i + 1)
			if close != -1 and close > i + 1:
				var inner := text.substr(i + 1, close - i - 1)
				out += "[i]%s[/i]" % _markdown_inline(inner)
				i = close + 1
				continue
		if text.unicode_at(i) == 95:
			var close := text.find("_", i + 1)
			if close != -1 and close > i + 1:
				var inner := text.substr(i + 1, close - i - 1)
				if not inner.contains(" "):
					out += "[i]%s[/i]" % _markdown_inline(inner)
					i = close + 1
					continue
		out += escape_bbcode(text.substr(i, 1))
		i += 1
	return out


static func _try_markdown_link(text: String, start: int) -> Dictionary:
	var label_end := text.find("](", start + 1)
	if label_end == -1:
		return {}
	var url_start: int = label_end + 2
	var url_end := text.find(")", url_start)
	if url_end == -1:
		return {}
	var label := text.substr(start + 1, label_end - start - 1)
	var url := text.substr(url_start, url_end - url_start).strip_edges()
	if url.is_empty():
		return {}
	var bb := "[url=%s]%s[/url]" % [escape_bbcode(url), _markdown_inline(label)]
	return {"bbcode": bb, "end": url_end + 1}


static func _parse_heading(line: String) -> Dictionary:
	var trimmed := line.strip_edges()
	if trimmed.is_empty() or trimmed.unicode_at(0) != 35:
		return {}
	var level := 0
	while level < trimmed.length() and trimmed.unicode_at(level) == 35:
		level += 1
	if level > 6 or level >= trimmed.length() or trimmed.unicode_at(level) != 32:
		return {}
	var title := trimmed.substr(level + 1).strip_edges()
	if title.is_empty():
		return {}
	return {"level": level, "text": title}


static func _heading_bbcode(level: int, title: String) -> String:
	var sizes := {1: 16, 2: 15, 3: 14, 4: 13, 5: 13, 6: 13}
	var size: int = sizes.get(level, 13)
	return "[font_size=%d][b]%s[/b][/font_size]" % [size, _markdown_inline(title)]


static func _is_hr_line(line: String) -> bool:
	var t := line.strip_edges()
	if t.length() < 3:
		return false
	var ch: int = t.unicode_at(0)
	if ch != 45 and ch != 42 and ch != 95:
		return false
	for i in t.length():
		if t.unicode_at(i) != ch:
			return false
	return true


static func _is_ul_line(line: String) -> bool:
	return _ul_body(line) != ""


static func _ul_body(line: String) -> String:
	var t := line.strip_edges()
	if t.length() < 3:
		return ""
	var ch: int = t.unicode_at(0)
	if ch != 45 and ch != 42 and ch != 43:
		return ""
	if t.unicode_at(1) != 32:
		return ""
	return t.substr(2).strip_edges()


static func _is_ol_line(line: String) -> bool:
	return _ol_body(line) != ""


static func _ol_body(line: String) -> String:
	var t := line.strip_edges()
	var dot := t.find(". ")
	if dot <= 0:
		return ""
	var num := t.substr(0, dot)
	if not num.is_valid_int():
		return ""
	return t.substr(dot + 2).strip_edges()


static func _is_quote_line(line: String) -> bool:
	return _quote_body(line) != "" or line.strip_edges().begins_with(">")


static func _quote_body(line: String) -> String:
	var t := line.strip_edges()
	if not t.begins_with(">"):
		return ""
	if t.length() == 1:
		return ""
	if t.length() > 1 and t.unicode_at(1) == 32:
		return t.substr(2)
	return t.substr(1)


static func _code_block(code: String) -> String:
	var trimmed := code.strip_edges()
	if _looks_like_json(trimmed):
		var pretty := pretty_json(trimmed)
		return "[code][bgcolor=%s]%s[/bgcolor][/code]" % [_C_CODE_BG, _highlight_json(pretty)]
	return "[code][bgcolor=%s]%s[/bgcolor][/code]" % [_C_CODE_BG, escape_bbcode(trimmed)]


static func _looks_like_json(text: String) -> bool:
	var t := text.strip_edges()
	if t.is_empty():
		return false
	var first: int = t.unicode_at(0)
	return first == 123 or first == 91


static func _highlight_json(source: String) -> String:
	var out := ""
	var i := 0
	var n := source.length()
	while i < n:
		var ch: int = source.unicode_at(i)
		if ch == 34:
			var j := i + 1
			while j < n:
				var cj: int = source.unicode_at(j)
				if cj == 92 and j + 1 < n:
					j += 2
					continue
				if cj == 34:
					j += 1
					break
				j += 1
			var segment := source.substr(i, j - i)
			var k := j
			while k < n and _is_ws(source.unicode_at(k)):
				k += 1
			var color := _C_STRING
			if k < n and source.unicode_at(k) == 58:
				color = _C_KEY
			out += "[color=%s]%s[/color]" % [color, escape_bbcode(segment)]
			i = j
			continue
		if ch == 45 or (ch >= 48 and ch <= 57):
			var j := i + 1
			while j < n:
				var cj: int = source.unicode_at(j)
				if (cj >= 48 and cj <= 57) or cj == 46 or cj == 101 or cj == 69 or cj == 43 or cj == 45:
					j += 1
					continue
				break
			out += "[color=%s]%s[/color]" % [_C_NUMBER, escape_bbcode(source.substr(i, j - i))]
			i = j
			continue
		var matched_literal := false
		for lit in ["true", "false", "null"]:
			if i + lit.length() > n:
				continue
			if source.substr(i, lit.length()) != lit:
				continue
			var next: int = i + lit.length()
			if next < n and _is_ident_cont(source.unicode_at(next)):
				continue
			out += "[color=%s]%s[/color]" % [_C_LITERAL, lit]
			i = next
			matched_literal = true
			break
		if matched_literal:
			continue
		out += escape_bbcode(source.substr(i, 1))
		i += 1
	return out


static func _match_at(text: String, index: int, needle: String) -> bool:
	if index + needle.length() > text.length():
		return false
	return text.substr(index, needle.length()) == needle


static func _is_ws(ch: int) -> bool:
	return ch == 32 or ch == 9 or ch == 10 or ch == 13


static func _is_ident_cont(ch: int) -> bool:
	return (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 122) or (ch >= 65 and ch <= 90) or ch == 95
