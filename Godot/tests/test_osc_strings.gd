# Round-trips OSC messages through godOSC's encoder and parser to check that
# non-ASCII strings survive as UTF-8 and don't misalign the arguments after them.
extends TestBase


func suite_name() -> String:
	return "OSC string encoding"


func run_tests() -> void:
	_test_ascii_roundtrip()
	_test_utf8_roundtrip_keeps_following_args()
	_test_utf8_address()


func _roundtrip(address: String, args: Array) -> Array:
	var client := OSCClient.new()
	var server := OSCServer.new()
	var packet: PackedByteArray = client.prepare_message(address, args)
	var got := []
	server.message_received.connect(func(addr, vals, _time): got.append([addr, vals]))
	server.parse_message(packet)
	client.free()
	server.free()
	return got[0] if got.size() > 0 else []


func _test_ascii_roundtrip() -> void:
	var got := _roundtrip("/track/1/name", ["Kick", 7])
	_assert(got[0] == "/track/1/name", "ascii address survives")
	_assert(got[1] == ["Kick", 7], "ascii string and int survive: %s" % [got[1]])


func _test_utf8_roundtrip_keeps_following_args() -> void:
	# "Jyn Ersø – Suite ♪" is longer in bytes than characters; padding by character
	# count used to shift the int that follows it.
	var name := "Jyn Ersø – Suite ♪"
	var got := _roundtrip("/track/2/name", [name, 42, 0.5])
	_assert(got[1][0] == name, "utf8 string survives: %s" % got[1][0])
	_assert(got[1][1] == 42, "int after utf8 string is aligned: %s" % [got[1][1]])
	_assert(is_equal_approx(got[1][2], 0.5), "float after utf8 string is aligned")


func _test_utf8_address() -> void:
	var got := _roundtrip("/preset/Café", [])
	_assert(got[0] == "/preset/Café", "utf8 address survives: %s" % got[0])
