# Headless test for PerfRecorder: scopes, frame sampling and report sections.
extends TestBase

const PerfScript := preload("res://components/PerfRecorder.gd")


func suite_name() -> String:
	return "PerfRecorder"


func run_tests() -> void:
	var rec: Node = PerfScript.new()
	root.add_child(rec)
	await process_frame

	# Scopes are ignored while not recording.
	rec.begin(&"idle")
	rec.end(&"idle")
	_assert(not rec.is_recording(), "not recording initially")

	rec.start()
	_assert(rec.is_recording(), "recording after start")
	for i in 6:
		rec.begin(&"outer")
		rec.begin(&"inner")
		OS.delay_usec(1000)
		rec.end(&"inner")
		rec.begin(&"inner")
		rec.end(&"inner")
		rec.end(&"outer")
		await process_frame
	var report: String = rec.stop()
	_assert(not rec.is_recording(), "stopped")
	for section in ["Duration:", "Frames:", "FPS (mean)", "--- Frame timings (ms) ---", "p99",
			"render GPU", "Draw calls:", "--- Scopes ---", "--- Worst 10 frames ---"]:
		_assert(report.contains(section), "report has '%s'" % section)
	_assert(report.contains("outer"), "report lists outer scope")
	_assert(not report.contains("idle"), "idle scope not recorded")
	var inner_line := ""
	for line in report.split("\n"):
		if line.begins_with("inner"):
			inner_line = line
	_assert(inner_line != "", "inner scope row present")
	_assert(inner_line.contains("2.00"), "inner has 2 calls per frame: " + inner_line)
	_assert(report.contains("Frames: 5") or report.contains("Frames: 6"), "frame count plausible")
	rec.queue_free()
