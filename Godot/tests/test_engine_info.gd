# test_engine_info.gd
# AudioEngineOSC stores the engine's /status/engine_info; a protocol mismatch is detected and
# worded (spec 046 REQ-006). Also checks the engine quit message encoding.
# Run: godot --headless --path Godot -s tests/test_engine_info.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Engine info tests"


func run_tests() -> void:
	var osc = root.get_node("AudioEngineOSC")
	_assert(osc.engine_protocol == -1 and osc.engine_version == "", "unknown before the engine reports")
	_assert(not osc.is_protocol_mismatch(), "unknown protocol is not a mismatch (pre-beta engine)")

	var seen := []
	osc.engine_info_received.connect(func(v, c, p): seen.append([v, c, p]))
	osc._on_osc_message_received("/status/engine_info", ["0.1.0-beta.1", "abc1234", BuildInfo.PROTOCOL], 0)
	_assert(osc.engine_version == "0.1.0-beta.1" and osc.engine_commit == "abc1234", "version and commit stored")
	_assert(osc.engine_protocol == BuildInfo.PROTOCOL and not osc.is_protocol_mismatch(), "matching protocol is fine")
	_assert(seen == [["0.1.0-beta.1", "abc1234", BuildInfo.PROTOCOL]], "engine_info_received emitted once")
	_assert(Editor.protocol_mismatch_text("0.1.0-beta.1", BuildInfo.PROTOCOL) == "", "no warning when matching")

	osc._on_osc_message_received("/status/engine_info", ["0.2.0", "def", BuildInfo.PROTOCOL + 1], 0)
	_assert(osc.is_protocol_mismatch(), "a different protocol is a mismatch")
	var text: String = Editor.protocol_mismatch_text(osc.engine_version, osc.engine_protocol)
	_assert("0.2.0" in text and BuildInfo.version() in text, "the warning names both versions")

	osc._on_osc_message_received("/status/engine_info", ["only one"], 0)
	_assert(osc.engine_version == "0.2.0", "a malformed message is ignored")

	osc.engine_connected.emit()
	osc._is_engine_connected = true
	osc.reset_connection()
	_assert(osc.engine_version == "" and osc.engine_protocol == -1, "disconnect forgets the engine info")

	var quit: PackedByteArray = root.get_node("EngineProcess").osc_message("/engine/quit")
	_assert(quit.size() % 4 == 0, "OSC message is 4-byte aligned")
	_assert(quit.slice(0, 12).get_string_from_ascii() == "/engine/quit", "address first")
	_assert(quit.slice(16, 18) == PackedByteArray([0x2c, 0]), "then the empty type tag")
	_assert(quit.size() == 20, "address padded to 16 bytes plus 4 for the type tag")
