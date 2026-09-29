# AI pan support: channel summaries per pan mode and set_mixer pan_mode/values (pan-modes spec).
# Run: godot --headless --path Godot -s ai/tests/test_set_mixer_pan.gd -- --test
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _ai_tool: GDScript
var _set_mixer_tool: GDScript
var _channel: GDScript


func suite_name() -> String:
	return "AI set_mixer pan tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_ai_tool = load("res://ai/tools/AiTool.gd")
	_set_mixer_tool = load("res://ai/tools/SetMixerTool.gd")
	_channel = load("res://data/Channel.gd")
	_test_describe_pan()
	_test_set_each_mode_and_undo()
	_test_refusals()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	project.create_instrument_track("Lead")
	return {"project": project, "channel": _ai_tool.resolve_channel(project, {"channel": "Lead"})}


func _test_describe_pan() -> void:
	var s := _setup()
	var c = s.channel
	c.pan = 0.3
	_assert(_ai_tool.describe_pan(c) == "balance 0.30", "balance: %s" % _ai_tool.describe_pan(c))
	c.pan_mode = _channel.PanMode.STEREO_COMBINED
	c.pan = 0.0
	_assert(_ai_tool.describe_pan(c) == "combined 0.00 w1.00", "combined: %s" % _ai_tool.describe_pan(c))
	c.pan_mode = _channel.PanMode.STEREO_DUAL
	c.pan_left = -1.0
	c.pan_right = 0.2
	_assert(_ai_tool.describe_pan(c) == "dual L-1.00 R0.20", "dual: %s" % _ai_tool.describe_pan(c))
	c.pan_mode = _channel.PanMode.MONO
	c.pan = -0.5
	_assert(_ai_tool.describe_pan(c) == "mono -0.50", "mono: %s" % _ai_tool.describe_pan(c))
	var compact: Dictionary = _ai_tool.compact_channel(s.project, c)
	_assert(compact.pan_mode == "mono" and compact.pan == "mono -0.50", "compact_channel reports mode and values")


func _test_set_each_mode_and_undo() -> void:
	var s := _setup()
	var c = s.channel
	var tool: Object = _set_mixer_tool.new()
	var out: Dictionary = tool.execute({"channel": "Lead", "pan": 0.4})
	_assert(out.get("ok", false) and is_equal_approx(c.pan, 0.4), "balance pan set: %s" % out.get("error", ""))
	out = tool.execute({"channel": "Lead", "pan_mode": "combined", "pan_width": 0.5})
	_assert(out.get("ok", false) and c.pan_mode == _channel.PanMode.STEREO_COMBINED, "switch to combined")
	_assert(is_equal_approx(c.pan, 0.4) and is_equal_approx(c.pan_width, 0.5), "combined keeps position, sets width")
	out = tool.execute({"channel": "Lead", "pan_mode": "dual", "pan_left": -1.0, "pan_right": 0.2})
	_assert(out.get("ok", false) and c.pan_mode == _channel.PanMode.STEREO_DUAL, "switch to dual")
	_assert(is_equal_approx(c.pan_left, -1.0) and is_equal_approx(c.pan_right, 0.2), "dual handles set")
	out = tool.execute({"channel": "Lead", "pan_mode": "mono", "pan": 0.1})
	_assert(out.get("ok", false) and c.pan_mode == _channel.PanMode.MONO and is_equal_approx(c.pan, 0.1), "mono set")
	_sonara.editor.undo()
	_assert(c.pan_mode == _channel.PanMode.STEREO_DUAL and is_equal_approx(c.pan_right, 0.2), "undo restores dual exactly")


func _test_refusals() -> void:
	var s := _setup()
	var c = s.channel
	var tool: Object = _set_mixer_tool.new()
	var before: Dictionary = c.get_pan_state()
	var out: Dictionary = tool.execute({"channel": "Lead", "pan_width": 0.5, "volume_db": -12.0})
	_assert(out.get("ok") == false, "pan_width on balance refused")
	_assert(c.get_pan_state() == before and c.volume != -12.0, "refusal changes nothing")
	out = tool.execute({"channel": "Lead", "pan_left": 0.0})
	_assert(out.get("ok") == false, "pan_left on balance refused")
	out = tool.execute({"channel": "Lead", "pan_mode": "wide"})
	_assert(out.get("ok") == false, "unknown mode refused")
	c.set_pan_mode(_channel.PanMode.STEREO_DUAL)
	out = tool.execute({"channel": "Lead", "pan": 0.5})
	_assert(out.get("ok") == false, "pan on dual refused")
