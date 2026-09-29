# Mixer multi-edit: one volume, pan or send edit applied to every selected channel as one undo step.
extends TestBase

var _ch: GDScript
var _edit: GDScript
var _kind: GDScript


func suite_name() -> String:
	return "Channel multi-edit"


func run_tests() -> void:
	_ch = load("res://data/Channel.gd")
	_edit = load("res://mixer/ChannelMultiEdit.gd")
	_kind = load("res://components/ValueEditKind.gd")
	_test_volume_relative()
	_test_volume_clamps()
	_test_volume_typed()
	_test_volume_reset()
	_test_pan_relative_and_reset()
	_test_pan_other_mode()
	_test_send()
	_test_command_merge_and_undo()


## A typed Array[Channel]; Channel is not named here because it needs the autoloads (see test_channel_pan.gd).
func _peers(list: Array) -> Array:
	var out := Array([], TYPE_OBJECT, &"RefCounted", _ch)
	out.assign(list)
	return out


func _pair(vol_a: float, vol_b: float) -> Array:
	var a = _ch.new(2)
	var b = _ch.new(3)
	a.volume = vol_a
	b.volume = vol_b
	return [a, b]


## Mimics MixerChannel: the primary takes its new value first, then the peers follow.
func _volume(p: Array, new_db: float, kind: int) -> void:
	var old: float = p[0].volume
	p[0].set_volume(new_db)
	_edit.apply_volume(p[0], old, _peers([p[1]]), kind)


func _test_volume_relative() -> void:
	var p := _pair(-10.0, -20.0)
	_volume(p, -7.0, _kind.Kind.DRAG)
	_assert(p[0].volume == -7.0 and p[1].volume == -17.0, "drag moves peers by the same dB")


func _test_volume_clamps() -> void:
	var p := _pair(-10.0, 10.0)
	_volume(p, -5.0, _kind.Kind.DRAG)
	_assert(p[1].volume == 12.0, "peer volume clamps at +12 dB")


func _test_volume_typed() -> void:
	var p := _pair(-10.0, -20.0)
	_volume(p, -3.0, _kind.Kind.TYPED)
	_assert(p[0].volume == -3.0 and p[1].volume == -3.0, "typed volume assigns to all")


func _test_volume_reset() -> void:
	var a = _ch.new(2)
	var master = _ch.new(1)
	a.volume = -20.0
	master.volume = -20.0
	var old: float = a.volume
	a.set_volume(a.get_default_volume())
	_edit.apply_volume(a, old, _peers([master]), _kind.Kind.RESET)
	_assert(a.volume == -6.0 and master.volume == 0.0, "reset returns each channel to its own default")


func _test_pan_relative_and_reset() -> void:
	var a = _ch.new(2)
	var b = _ch.new(3)
	b.set_pan(-0.5)
	var old: Dictionary = a.get_pan_state()
	a.set_pan(0.25)
	_edit.apply_pan(a, old, a.get_pan_state(), _peers([b]), _kind.Kind.DRAG)
	_assert(is_equal_approx(b.pan, -0.25), "pan drag shifts peers by the same amount")
	old = a.get_pan_state()
	a.set_pan(0.0)
	_edit.apply_pan(a, old, a.get_pan_state(), _peers([b]), _kind.Kind.RESET)
	_assert(b.pan == 0.0, "pan reset centers peers")


func _test_pan_other_mode() -> void:
	var a = _ch.new(2)
	var b = _ch.new(3)
	b.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	b.set_pan_dual(-0.5, 0.5)
	var old: Dictionary = a.get_pan_state()
	a.set_pan(0.25)
	_edit.apply_pan(a, old, a.get_pan_state(), _peers([b]), _kind.Kind.DRAG)
	_assert(is_equal_approx(b.pan_left, -0.25) and is_equal_approx(b.pan_right, 0.75), "position shift moves both dual handles")
	old = a.get_pan_state()
	a.set_pan(0.0)
	_edit.apply_pan(a, old, a.get_pan_state(), _peers([b]), _kind.Kind.RESET)
	_assert(is_equal_approx(b.pan_left, -0.5) and is_equal_approx(b.pan_right, 0.5), "reset centers a dual peer, keeping its width")


func _test_send() -> void:
	var a = _ch.new(2)
	var b = _ch.new(3)
	a.add_send(10, -20.0)
	a.set_send_amount(10, -15.0)
	_edit.apply_send(a, 10, -20.0, -15.0, _peers([b]), _kind.Kind.DRAG)
	_assert(b.get_send(10) != null and b.get_send(10).amount == -55.0, "send drag creates and shifts the peer's send")
	_edit.apply_send(a, 10, -15.0, -6.0, _peers([b]), _kind.Kind.TYPED)
	a.set_send_amount(10, -6.0)
	_assert(b.get_send(10).amount == -6.0, "typed send assigns to all")
	_edit.apply_send(a, 10, -6.0, -60.0, _peers([b]), _kind.Kind.RESET)
	_assert(b.get_send(10).amount == -60.0, "send reset silences peers")
	var bus = _ch.new(10)
	_edit.apply_send(a, 10, -60.0, -30.0, _peers([bus]), _kind.Kind.TYPED)
	_assert(bus.get_send(10) == null, "the target bus itself is skipped")


func _test_command_merge_and_undo() -> void:
	var p := _pair(-10.0, -20.0)
	var apply := func(ch, v): ch.set_volume(v)
	var c1 := ChannelsPropertyCommand.new("v", {p[0]: -10.0, p[1]: -20.0}, {p[0]: -9.0, p[1]: -19.0}, apply, "volume")
	var c2 := ChannelsPropertyCommand.new("v", {p[0]: -9.0, p[1]: -19.0}, {p[0]: -8.0, p[1]: -18.0}, apply, "volume")
	_assert(c1.can_merge(c2), "consecutive drags merge")
	c1.merge_with(c2)
	c1.do()
	_assert(p[0].volume == -8.0 and p[1].volume == -18.0, "merged do applies the last values")
	c1.undo()
	_assert(p[0].volume == -10.0 and p[1].volume == -20.0, "undo restores each channel's own starting value")
	var c3 := ChannelsPropertyCommand.new("v", {p[0]: -10.0}, {p[0]: -9.0}, apply, "volume")
	_assert(not c1.can_merge(c3), "different channel sets do not merge")
