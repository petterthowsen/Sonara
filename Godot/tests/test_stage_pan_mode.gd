# Stage pan mode on channels (spec 051 T-016, T-017): which channels accept it, placement from the
# pan, restoring the pan on leaving, the Stage return and its deletion rule.
#
# Headless the OSC client never becomes ready, so sends queue in AudioEngineOSC._pending_sends.
extends TestBase

var _stage: GDScript
var _ch: GDScript

var _osc: Node
var _project_script: GDScript


func suite_name() -> String:
	return "Stage pan mode"


func run_tests() -> void:
	_stage = load("res://data/Stage.gd")
	_ch = load("res://data/Channel.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_project_script = load("res://data/Project.gd")
	_test_pan_mode_value()
	_test_channel_types()
	_test_placement_from_pan()
	_test_leaving_restores_pan()
	_test_dual_restores_handles()
	_test_stage_values()
	_test_json_round_trip()
	_test_osc()
	_test_stage_return()


## Channels hold their project weakly: keep every project alive for the whole run.
var _keep: Array = []


func _project_with(channel_type: int) -> Array:
	var project: Object = _project_script.new()
	_keep.append(project)
	return [project, project.create_channel("Ch", channel_type)]


func _test_pan_mode_value() -> void:
	_assert(_ch.PanMode.STAGE == 4, "Stage is OSC pan mode 4")
	_assert(_ch.PanMode.keys()[4] == "STAGE", "saved as STAGE")


func _test_channel_types() -> void:
	for t in [_ch.ChannelType.INSTRUMENT, _ch.ChannelType.AUDIO, _ch.ChannelType.GROUP]:
		var ch = _project_with(t)[1]
		_assert(ch.can_use_stage(), "type %d can use stage" % t)
		ch.set_pan_mode(_ch.PanMode.STAGE)
		_assert(ch.pan_mode == _ch.PanMode.STAGE and ch.is_stage_source(), "type %d accepts Stage" % t)
	for t in [_ch.ChannelType.BUS]:
		var ch = _project_with(t)[1]
		ch.set_pan(0.3)
		ch.set_pan_mode(_ch.PanMode.STAGE)
		_assert(not ch.can_use_stage() and ch.pan_mode == _ch.PanMode.STEREO_BALANCE and ch.pan == 0.3,
				"type %d refuses Stage and keeps its pan mode" % t)
	var project: Object = _project_script.new()
	var master = project.get_master_channel()
	master.set_pan_mode(_ch.PanMode.STAGE)
	_assert(master.pan_mode != _ch.PanMode.STAGE, "master refuses Stage")
	var ch = project.create_channel("I", _ch.ChannelType.INSTRUMENT)
	ch.set_pan_state({"mode": _ch.PanMode.STAGE})
	ch.is_stage_return = true
	_assert(not ch.can_use_stage(), "the Stage return can't be a source")


func _test_placement_from_pan() -> void:
	var pair := _project_with(_ch.ChannelType.INSTRUMENT)
	var project: Object = pair[0]
	var ch = pair[1]
	project.stage.set_room_size(20.0, 30.0, 10.0)
	project.stage.set_listener(Vector3(10, 18, 1.8))
	ch.set_pan(-0.5)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	_assert(is_equal_approx(ch.stage_x - 10.0, -5.0), "pan -0.5 in a 20 m room gives X = -5 m from center: %s" % ch.stage_x)
	_assert(is_equal_approx(ch.stage_y, 13.0), "default depth is 5 m in front of the listener: %s" % ch.stage_y)
	_assert(is_equal_approx(ch.stage_z, 1.2), "default height 1.2 m")
	_assert(ch.stage_size == 3.0 and ch.stage_placed, "stereo source defaults to 3 m wide")
	var mono = project.create_channel("M", _ch.ChannelType.AUDIO)
	mono.place_in_stage_from_pan(false)
	_assert(mono.stage_size == 0.0, "mono source defaults to size 0")


func _test_leaving_restores_pan() -> void:
	var ch = _project_with(_ch.ChannelType.INSTRUMENT)[1]
	ch.set_pan(0.3)
	ch.set_pan_mode(_ch.PanMode.STEREO_BALANCE)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	ch.set_stage_position(Vector3(3, 4, 2))
	ch.set_pan_mode(_ch.PanMode.STEREO_BALANCE)
	_assert(ch.pan_mode == _ch.PanMode.STEREO_BALANCE and is_equal_approx(ch.pan, 0.3), "Balance restored with pan 0.3")
	ch.set_pan_mode(_ch.PanMode.STAGE)
	_assert(ch.stage_x == 3.0 and ch.stage_y == 4.0 and ch.stage_z == 2.0, "Stage restores the moved position")


func _test_dual_restores_handles() -> void:
	var ch = _project_with(_ch.ChannelType.INSTRUMENT)[1]
	ch.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	ch.set_pan_dual(-0.25, 0.75)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	ch.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	_assert(is_equal_approx(ch.pan_left, -0.25) and is_equal_approx(ch.pan_right, 0.75), "Dual handles survive Stage")
	ch.set_pan_mode(_ch.PanMode.STAGE)
	ch.set_pan_mode(_ch.PanMode.STEREO_COMBINED)
	_assert(ch.pan_mode == _ch.PanMode.STEREO_COMBINED, "leaving Stage to another mode")


func _test_stage_values() -> void:
	var ch = _project_with(_ch.ChannelType.INSTRUMENT)[1]
	var emitted := [0]
	ch.stage_changed.connect(func(): emitted[0] += 1)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	var base: int = emitted[0]
	ch.set_stage_position(Vector3(999, -3, 999))
	var room = ch.get_project().stage
	_assert(ch.stage_x == room.width and ch.stage_y == 0.0 and ch.stage_z == room.height, "position clamped into the room")
	ch.set_stage_size(999.0)
	_assert(ch.stage_size == maxf(room.width, room.depth), "size clamped to the room")
	ch.set_stage_rotation(270.0)
	_assert(is_equal_approx(ch.stage_rotation, -90.0), "rotation wraps into -180..180: %s" % ch.stage_rotation)
	ch.set_stage_sum_mode(_ch.StageSumMode.MID)
	ch.set_stage_has_room(true)
	_assert(ch.stage_sum_mode == _ch.StageSumMode.MID and ch.stage_has_room, "sum mode and has room set")
	_assert(emitted[0] - base == 5, "each setter emits stage_changed: %d" % (emitted[0] - base))
	var snapshot: Dictionary = ch.get_stage_state()
	ch.set_stage_position(Vector3(1, 1, 1))
	ch.set_stage_state(snapshot)
	_assert(ch.get_stage_state() == snapshot, "get/set_stage_state round trip")


func _test_json_round_trip() -> void:
	var ch = _project_with(_ch.ChannelType.INSTRUMENT)[1]
	_assert(not ch.to_json().has("stage"), "an unplaced channel saves no stage block")
	ch.set_pan_mode(_ch.PanMode.STAGE)
	ch.set_stage_position(Vector3(3, 4, 2))
	ch.set_stage_size(2.0)
	ch.set_stage_rotation(45.0)
	ch.set_stage_sum_mode(_ch.StageSumMode.MID)
	ch.set_stage_has_room(true)
	var again = _ch.from_json(JSON.parse_string(JSON.stringify(ch.to_json())))
	_assert(again.pan_mode == _ch.PanMode.STAGE, "pan mode round-trips")
	_assert(again.get_stage_state() == ch.get_stage_state(), "stage values round-trip")
	# Leaving Stage after a reload still restores the mode before it.
	ch.set_pan_mode(_ch.PanMode.STEREO_COMBINED)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	var reloaded = _ch.from_json(JSON.parse_string(JSON.stringify(ch.to_json())))
	_assert(reloaded.stage_prev_pan_mode == _ch.PanMode.STEREO_COMBINED, "previous pan mode round-trips")


func _test_osc() -> void:
	var ch = _project_with(_ch.ChannelType.INSTRUMENT)[1]
	_osc._pending_sends.clear()
	ch.set_stage_position(Vector3(1, 2, 3))
	_assert(_osc._pending_sends.is_empty(), "no send while not connected")
	ch._is_connected = true
	ch.set_pan_mode(_ch.PanMode.STAGE)
	var modes: Array = _osc._pending_sends.filter(func(m): return m.address == "/channel/%d/pan_mode" % ch.id)
	_assert(modes.size() == 1 and modes[0].args == [4], "pan_mode 4 sent")
	_osc._pending_sends.clear()
	ch.set_stage_size(2.0)
	ch.set_stage_rotation(30.0)
	ch.set_stage_sum_mode(_ch.StageSumMode.MID)
	ch.set_stage_has_room(true)
	var stage_msgs: Array = _osc._pending_sends.filter(func(m): return m.address == "/channel/%d/stage" % ch.id)
	_assert(stage_msgs.size() == 4, "each setter sends /channel/{id}/stage")
	var last: Array = stage_msgs[3].args
	_assert(last.size() == 7 and last[3] == 2.0 and last[4] == 30.0 and last[5] == 1 and last[6] == 1,
			"stage args: x y z size rotation sum_mode has_room: %s" % [last])
	_osc._pending_sends.clear()
	ch.sync_to_engine()
	var addresses: Array = _osc._pending_sends.map(func(m): return m.address)
	_assert(addresses.has("/channel/%d/stage" % ch.id), "sync_to_engine sends the placement")
	_assert(addresses.find("/channel/%d/pan_mode" % ch.id) < addresses.find("/channel/%d/stage" % ch.id),
			"pan mode goes before the placement")
	ch._is_connected = false


func _test_stage_return() -> void:
	var project: Object = _project_script.new()
	var a = project.create_channel("A", _ch.ChannelType.INSTRUMENT)
	var b = project.create_channel("B", _ch.ChannelType.AUDIO)
	_assert(project.get_stage_return() == null, "no Stage return before any source")
	a.set_pan_mode(_ch.PanMode.STAGE)
	b.set_pan_mode(_ch.PanMode.STAGE)
	var returns: Array = project.channels.filter(func(c): return c.is_stage_return)
	_assert(returns.size() == 1, "two sources, one Stage return")
	var r = returns[0]
	_assert(r.channel_type == _ch.ChannelType.BUS and r.output_channel_id == 1, "return is a bus routed to master")
	_assert(project.ensure_stage_return() == r, "ensure_stage_return is idempotent")
	_assert(project.stage_sources().size() == 2, "stage_sources lists both")
	_assert(not project.can_remove_channel(r.id) and not project.remove_channel(r.id), "delete refused while sources exist")
	_assert(project.stage_return_removal_blocker(r.id) != "", "a reason is given")
	_assert(project.get_channel_by_id(r.id) != null, "return still there")
	a.set_pan_mode(_ch.PanMode.STEREO_BALANCE)
	_assert(not project.remove_channel(r.id), "still refused with one source")
	b.set_pan_mode(_ch.PanMode.STEREO_BALANCE)
	_assert(project.get_stage_return() == r, "return stays when no sources remain")
	_assert(project.can_remove_channel(r.id) and project.remove_channel(r.id), "delete allowed with no sources")
	_assert(project.get_stage_return() == null, "return removed")
	_assert(project.remove_channel(a.id), "other channels delete normally")
