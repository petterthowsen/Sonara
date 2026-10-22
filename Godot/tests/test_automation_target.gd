# Stage automation target (spec 051 T-018): the `channel/stage/{param}` spelling, the room
# normalization and the value readouts.
extends TestBase

var _stage: GDScript
var _ch: GDScript


func suite_name() -> String:
	return "Automation target (stage)"


func run_tests() -> void:
	_stage = load("res://data/Stage.gd")
	_ch = load("res://data/Channel.gd")
	_test_spelling()
	_test_normalization()
	_test_channel_values()
	_test_readouts()


func _test_spelling() -> void:
	_assert(AutomationTarget.Kind.STAGE_PARAM == 6, "STAGE_PARAM is appended as kind 6")
	for param in ["x", "y", "z", "size", "rotation"]:
		var t := AutomationTarget.stage(param)
		_assert(str(t) == "channel/stage/" + param, "%s spells channel/stage/%s" % [param, param])
		var parsed := AutomationTarget.parse("channel/stage/" + param)
		_assert(parsed != null and parsed.kind == AutomationTarget.Kind.STAGE_PARAM and parsed.stage_param == param,
				"%s parses back" % param)
	for bad in ["channel/stage", "channel/stage/w", "channel/stage/x/y", "stage/x"]:
		_assert(AutomationTarget.parse(bad) == null, "%s does not parse" % bad)
	_assert(AutomationTarget.stage("nope") == null, "unknown param gives null")
	_assert(AutomationTarget.channel_pan().kind == AutomationTarget.Kind.CHANNEL_PAN, "existing targets unchanged")


func _room():
	var room = _stage.new()
	room.set_room_size(20.0, 30.0, 10.0)
	return room


func _test_normalization() -> void:
	var room = _room()
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("x", 0.5, room), 10.0), "x = v * width")
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("y", 0.5, room), 15.0), "y = v * depth")
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("z", 0.5, room), 5.0), "z = v * height")
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("size", 0.5, room), 15.0), "size = v * max(width, depth)")
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("rotation", 0.0, room), -180.0), "rotation 0 = -180")
	_assert(is_equal_approx(AutomationTarget.stage_denormalize("rotation", 0.75, room), 90.0), "rotation = v * 360 - 180")
	for param in AutomationTarget.STAGE_PARAMS:
		var v := 0.3
		var back := AutomationTarget.stage_normalize(param, AutomationTarget.stage_denormalize(param, v, room), room)
		_assert(is_equal_approx(back, v), "%s normalize inverts denormalize" % param)


func _test_channel_values() -> void:
	var ch = _ch.new(2)
	ch.set_stage_state({"x": 11.0, "y": 3.0, "z": 1.0, "size": 6.0, "rotation": 90.0})
	# No project: the default room, 22 x 28 x 11.
	var room = _stage.new()
	_assert(is_equal_approx(AutomationTarget.stage("x").current_normalized_value(ch), 11.0 / room.width), "x seed from base")
	_assert(is_equal_approx(AutomationTarget.stage("rotation").current_normalized_value(ch), 0.75), "rotation seed from base")
	_assert(AutomationTarget.stage("size").is_resolvable(ch), "stage target resolves")
	_assert(AutomationTarget.stage("size").display_name(ch) == "Stage Size", "display name")
	_assert(ch.stage_x == 11.0, "reading a base value never writes it")


func _test_readouts() -> void:
	var ch = _ch.new(2)
	var x := AutomationTarget.stage("x")
	var rot := AutomationTarget.stage("rotation")
	_assert(x.format_value(ch, 0.5) == "11.0 m", "x readout in meters: %s" % x.format_value(ch, 0.5))
	_assert(rot.format_value(ch, 0.75) == "90°", "rotation readout in degrees: %s" % rot.format_value(ch, 0.75))
	_assert(x.edit_text(ch, 0.5) == "11.0", "edit text without unit")
	_assert(is_equal_approx(x.parse_edit_text(ch, "5.5 m"), 0.25), "typed meters parse")
	_assert(is_equal_approx(rot.parse_edit_text(ch, "90"), 0.75), "typed degrees parse")
	_assert(is_nan(x.parse_edit_text(ch, "abc")), "garbage is NaN")
