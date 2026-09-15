# ExchangeViewer.gd
# Popup for one stored OpenRouter request/response record (ExchangeLog): summary, request, response.
class_name ExchangeViewer extends Window


const C_STRING := Color("#a8e6a1")
const C_NUMBER := Color("#e8b080")
const C_LITERAL := Color("#c9a0e8")
const C_SYMBOL := Color("#9a9aa3")

var _tabs: TabContainer
var _summary: CodeEdit
var _request: CodeEdit
var _response: CodeEdit
var _wrap: CheckBox
var _file_path: String = ""


func _init() -> void:
	title = "Request / Response"
	initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	size = Vector2i(900, 680)
	min_size = Vector2i(420, 300)
	wrap_controls = true
	close_requested.connect(hide)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tabs)
	_summary = _make_editor("Summary", false)
	_request = _make_editor("Request", true)
	_response = _make_editor("Response", true)
	vbox.add_child(_make_buttons())


## Show `record` (ExchangeLog.read) stored at `file_path`.
func show_exchange(record: Dictionary, file_path: String) -> void:
	_file_path = file_path
	var status := str(record.get("status", "?"))
	title = "Request / Response · %s · %s" % [str(record.get("model", "")), status]
	_summary.text = summary_text(record, file_path)
	_request.text = JSON.stringify(record.get("request", {}), "\t")
	_response.text = JSON.stringify(record.get("response", {}), "\t")
	for edit in [_summary, _request, _response]:
		edit.set_caret_line(0)
		edit.scroll_vertical = 0
	_tabs.current_tab = 0
	popup_centered()


## Human-readable key facts for the Summary tab.
static func summary_text(record: Dictionary, file_path: String = "") -> String:
	var response: Dictionary = record.get("response", {}) if record.get("response", {}) is Dictionary else {}
	var request: Dictionary = record.get("request", {}) if record.get("request", {}) is Dictionary else {}
	var usage: Dictionary = response.get("usage", {}) if response.get("usage", {}) is Dictionary else {}
	var rows: Array = []
	rows.append(["Status", str(record.get("status", ""))])
	rows.append(["Model", str(record.get("model", ""))])
	rows.append(["HTTP", str(response.get("http_status", ""))])
	var started := float(record.get("started_unix", 0.0))
	if started > 0.0:
		var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		rows.append(["Started", Time.get_datetime_string_from_unix_time(int(started) + bias, true)])
	rows.append(["Duration", "%.2f s" % (float(record.get("duration_ms", 0)) / 1000.0)])
	rows.append(["Finish reason", str(response.get("finish_reason", ""))])
	rows.append(["Generation id", str(response.get("generation_id", ""))])
	rows.append(["SSE events", str(response.get("sse_events", 0))])
	if not usage.is_empty():
		var prompt := str(int(usage.get("prompt_tokens", 0)))
		var details = usage.get("prompt_tokens_details", null)
		if details is Dictionary and int(details.get("cached_tokens", 0)) > 0:
			prompt += "  (cached %d)" % int(details.cached_tokens)
		rows.append(["Prompt tokens", prompt])
		var completion := str(int(usage.get("completion_tokens", 0)))
		var cdetails = usage.get("completion_tokens_details", null)
		if cdetails is Dictionary and int(cdetails.get("reasoning_tokens", 0)) > 0:
			completion += "  (reasoning %d)" % int(cdetails.reasoning_tokens)
		rows.append(["Completion tokens", completion])
		if usage.get("cost", null) != null:
			rows.append(["Cost", "$%.6f" % float(usage.cost)])
	else:
		rows.append(["Usage", "not reported"])
	var msgs = request.get("messages", [])
	var tools = request.get("tools", [])
	rows.append(["Messages sent", str(msgs.size() if msgs is Array else 0)])
	rows.append(["Tools sent", str(tools.size() if tools is Array else 0)])
	rows.append(["Request size", "%s chars (~%s tokens)" % [
		str(JSON.stringify(request).length()), TokenEstimate.format_count(TokenEstimate.text(JSON.stringify(request)))
	]])
	var err = response.get("error", null)
	if err is Dictionary:
		rows.append(["Error", "%s  [%s]" % [str(err.get("message", "")), str(err.get("code", ""))]])
	if not file_path.is_empty():
		rows.append(["File", file_path])
	var lines: PackedStringArray = []
	for row in rows:
		lines.append("%-18s %s" % [row[0], row[1]])
	return "\n".join(lines)


func _make_editor(tab_name: String, json: bool) -> CodeEdit:
	var edit := CodeEdit.new()
	edit.name = tab_name
	edit.editable = false
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.highlight_current_line = true
	edit.add_theme_font_size_override("font_size", 12)
	if json:
		edit.gutters_draw_line_numbers = true
		edit.line_folding = true
		edit.gutters_draw_fold_gutter = true
		edit.indent_use_spaces = false
		edit.syntax_highlighter = _json_highlighter()
	_tabs.add_child(edit)
	return edit


func _make_buttons() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var copy := Button.new()
	copy.text = "Copy Tab"
	copy.tooltip_text = "Copy the visible tab's text to the clipboard"
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(_current_editor().text))
	row.add_child(copy)
	var fold := Button.new()
	fold.text = "Fold All"
	fold.pressed.connect(func() -> void: _current_editor().fold_all_lines())
	row.add_child(fold)
	var unfold := Button.new()
	unfold.text = "Unfold All"
	unfold.pressed.connect(func() -> void: _current_editor().unfold_all_lines())
	row.add_child(unfold)
	_wrap = CheckBox.new()
	_wrap.text = "Wrap"
	_wrap.button_pressed = true
	_wrap.toggled.connect(_on_wrap_toggled)
	row.add_child(_wrap)
	var reveal := Button.new()
	reveal.text = "Show File"
	reveal.tooltip_text = "Reveal the JSON record in the file manager"
	reveal.pressed.connect(func() -> void:
		if not _file_path.is_empty():
			OS.shell_show_in_file_manager(_file_path)
	)
	row.add_child(reveal)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(hide)
	row.add_child(close)
	return row


func _current_editor() -> CodeEdit:
	return _tabs.get_current_tab_control() as CodeEdit


func _on_wrap_toggled(on: bool) -> void:
	var mode := TextEdit.LINE_WRAPPING_BOUNDARY if on else TextEdit.LINE_WRAPPING_NONE
	for edit in [_summary, _request, _response]:
		edit.wrap_mode = mode


static func _json_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = C_NUMBER
	h.symbol_color = C_SYMBOL
	h.function_color = C_SYMBOL
	h.member_variable_color = C_SYMBOL
	h.add_color_region("\"", "\"", C_STRING)
	for literal in ["true", "false", "null"]:
		h.add_keyword_color(literal, C_LITERAL)
	return h
