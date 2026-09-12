# CollapsibleBlock.gd
# Header + body row, collapsed by default (thinking / tool call / tool result).
class_name CollapsibleBlock extends VBoxContainer


var _toggle: Button
var _body: RichTextLabel
var _kind: String = "block"
var _title: String = ""
var _preview: String = ""
var _collapsed: bool = true


## Build a collapsed block. `kind` is thinking, tool, or result.
func _init(kind: String = "block", title: String = "", body_text: String = "") -> void:
	_kind = kind
	_title = title
	add_theme_constant_override("separation", 2)
	_toggle = Button.new()
	_toggle.flat = true
	_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_on_toggle)
	add_child(_toggle)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = false
	_body.fit_content = true
	_body.scroll_active = false
	_body.selection_enabled = true
	_body.add_theme_font_size_override("normal_font_size", 12)
	_body.add_theme_color_override("default_color", Color(0.75, 0.75, 0.78, 0.9))
	_body.visible = false
	add_child(_body)
	if not body_text.is_empty():
		set_body(body_text)
	else:
		_refresh_header()


func set_title(title: String) -> void:
	_title = title
	_refresh_header()


func set_preview(preview: String) -> void:
	_preview = preview
	_refresh_header()


func set_body(text: String) -> void:
	_body.text = text
	if _preview.is_empty():
		_preview = _short(text)
	_refresh_header()


func append_body(text: String) -> void:
	_body.text += text
	if _preview.is_empty():
		_preview = _short(_body.text)
	_refresh_header()


func get_body() -> String:
	return _body.text


func _on_toggle() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_refresh_header()


func _refresh_header() -> void:
	var chevron := "▸" if _collapsed else "▾"
	var label := _title
	if _collapsed and not _preview.is_empty():
		label = "%s — %s" % [_title, _preview]
	_toggle.text = "%s %s" % [chevron, label]


func _short(text: String) -> String:
	var line := text.strip_edges().replace("\n", " ")
	if line.length() > 48:
		return line.substr(0, 48) + "…"
	return line
