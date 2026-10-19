# A burst of OSC messages larger than the kernel's UDP buffer (a plugin advertising 900+
# parameters) must reach OSCServer whole while the main thread is busy. Polling only once per
# frame dropped everything past roughly 275 small datagrams.
extends TestBase

const PORT := 47391
const COUNT := 3000


func suite_name() -> String:
	return "OSC burst"


func run_tests() -> void:
	var server := OSCServer.new()
	server.port = PORT
	var got: Array[int] = []
	server.message_received.connect(func(_addr, vals, _time): got.append(vals[0]))
	root.add_child(server)
	await process_frame

	var client := OSCClient.new()
	var peer := PacketPeerUDP.new()
	peer.set_dest_address("127.0.0.1", PORT)
	# Simulate a main-thread stall while the engine sends: nothing parses during the burst.
	for i in COUNT:
		peer.put_packet(client.prepare_message("/channel/2/device/0/param/info", [i, "Param %d padded to a realistic size" % i, 0.0, 1.0, 0.5]))
		if i % 64 == 63:
			OS.delay_msec(2)
	OS.delay_msec(200)

	var deadline := Time.get_ticks_msec() + 3000
	while got.size() < COUNT and Time.get_ticks_msec() < deadline:
		await process_frame
	_assert(got.size() == COUNT, "all %d messages arrive (got %d)" % [COUNT, got.size()])
	var in_order := true
	for i in got.size():
		if got[i] != i:
			in_order = false
			break
	_assert(in_order, "messages arrive in order")

	peer.close()
	client.free()
	server.queue_free()
	await process_frame
