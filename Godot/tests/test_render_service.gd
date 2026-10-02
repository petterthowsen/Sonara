# Drives RenderService and ExportAudioDialog against a mocked transport (no engine needed).
extends TestBase

# Scripts are load()ed after the first frame: they reference autoloads, which a -s script can't
# resolve at compile time.
var RS: GDScript
var EAD: GDScript


class MockTransport extends RefCounted:
	var sent: Array = []
	var listeners: Dictionary = {}

	func send(address: String, args: Array = []) -> void:
		sent.append({"address": address, "args": args})

	func listen(address: String, callback: Callable) -> void:
		listeners[address] = callback

	func deliver(address: String, args: Array) -> void:
		listeners[address].call(args)


func suite_name() -> String:
	return "RenderService"


func run_tests() -> void:
	RS = load("res://core/RenderService.gd")
	EAD = load("res://export/ExportAudioDialog.gd")
	_test_start_message()
	_test_validation()
	_test_progress_done()
	_test_failed_and_cancel()
	_test_ignores_other_jobs()
	await _test_dialog_options()


func _make() -> Array:
	var mock := MockTransport.new()
	var service = RS.new()
	service.transport = mock
	root.add_child(service)
	return [service, mock]


func _opts() -> Dictionary:
	return {"start_tick": 0, "end_tick": 3840, "tail_seconds": 2.5, "until_silent": true,
			"master_path": "/tmp/mix.wav", "bit_depth": 24,
			"stems": [{"channel_id": 2, "path": "/tmp/mix - Bass.wav"}]}


func _test_start_message() -> void:
	var made = _make()
	var service = made[0]
	var mock = made[1]
	var job_id = service.start(_opts())
	_assert(job_id != "", "start returns a job id")
	_assert(service.is_running, "running after start")
	var msg = mock.sent[0]
	_assert(msg.address == "/render/start", "sends /render/start")
	var a: Array = msg.args
	_assert(a[0] == job_id and a[1] == 0 and a[2] == 3840, "job id and range")
	_assert(is_equal_approx(a[3], 2.5) and a[4] == 1, "tail and until_silent")
	_assert(a[5] == "/tmp/mix.wav" and a[6] == 24 and a[7] == 0 and a[8] == 0, "master, depth, rate, block")
	_assert(a[9] == 2 and a[10] == "/tmp/mix - Bass.wav", "stem pair appended")
	_assert(service.start(_opts()) == "", "second start while running is rejected")
	service.queue_free()


func _test_validation() -> void:
	_assert(RS.validate(_opts()) == "", "valid options pass")
	var o = _opts()
	o.end_tick = 0
	_assert(RS.validate(o) != "", "empty range rejected")
	o = _opts()
	o.master_path = ""
	o.stems = []
	_assert(RS.validate(o) != "", "no outputs rejected")
	o = _opts()
	o.bit_depth = 20
	_assert(RS.validate(o) != "", "bad bit depth rejected")
	o = _opts()
	o.stems = [{"channel_id": 2, "path": ""}]
	_assert(RS.validate(o) != "", "stem without path rejected")
	var made = _make()
	var service = made[0]
	var failures: Array = []
	service.job_failed.connect(func(id, err): failures.append([id, err]))
	_assert(service.start({}) == "" and not service.is_running, "invalid start does not run")
	_assert(failures.size() == 1 and failures[0][0] == "", "invalid start emits job_failed")
	_assert(made[1].sent.is_empty(), "invalid start sends nothing")
	service.queue_free()


func _test_progress_done() -> void:
	var made = _make()
	var service = made[0]
	var mock = made[1]
	var seen := {"progress": -1.0, "paths": PackedStringArray(), "running": []}
	service.progress_changed.connect(func(_id, f): seen.progress = f)
	service.job_finished.connect(func(_id, p): seen.paths = p)
	service.running_changed.connect(func(r): seen.running.append(r))
	var job_id = service.start(_opts())
	mock.deliver("/render/progress", [job_id, 0.4])
	_assert(is_equal_approx(seen.progress, 0.4), "progress forwarded")
	mock.deliver("/render/done", [job_id, "/tmp/mix.wav", "/tmp/mix - Bass.wav"])
	_assert(not service.is_running, "not running after done")
	_assert(seen.paths.size() == 2 and seen.paths[0] == "/tmp/mix.wav", "done paths forwarded in order")
	_assert(seen.running == [true, false], "running_changed true then false")
	_assert(service.start(_opts()) != "", "a new job can start after done")
	service.queue_free()


func _test_failed_and_cancel() -> void:
	var made = _make()
	var service = made[0]
	var mock = made[1]
	var errors: Array = []
	service.job_failed.connect(func(_id, err): errors.append(err))
	var job_id = service.start(_opts())
	service.cancel()
	_assert(mock.sent.back().address == "/render/cancel" and mock.sent.back().args == [job_id], "cancel message sent")
	_assert(service.is_running, "still running until the engine confirms")
	mock.deliver("/render/failed", [job_id, "cancelled"])
	_assert(errors == [RS.CANCELLED] and not service.is_running, "cancelled ends the job")
	var sent_before = mock.sent.size()
	service.cancel()
	_assert(mock.sent.size() == sent_before, "cancel when idle sends nothing")
	job_id = service.start(_opts())
	mock.deliver("/render/failed", [job_id, "plugin crashed"])
	_assert(errors.back() == "plugin crashed", "failure message forwarded")
	service.queue_free()


func _test_ignores_other_jobs() -> void:
	var made = _make()
	var service = made[0]
	var mock = made[1]
	var job_id = service.start(_opts())
	mock.deliver("/render/done", ["someone_else", "/x.wav"])
	mock.deliver("/render/failed", ["someone_else", "boom"])
	mock.deliver("/render/progress", ["someone_else", 0.9])
	_assert(service.is_running and service.current_job_id == job_id and service.progress == 0.0, "other job ids ignored")
	service.queue_free()


func _test_dialog_options() -> void:
	var project = load("res://data/Project.gd").new()
	var made = project.create_instrument_track("Bass")
	var channel = made["channel"]
	var dialog = load("res://export/ExportAudioDialog.tscn").instantiate()
	root.add_child(dialog)
	await process_frame
	var svc_made = _make()
	var service = svc_made[0]
	dialog.open_for(project, service, {"has": true, "start": 960, "has_end": true, "end": 1920})
	dialog._path_edit.text = "/tmp/out/My Mix.wav"
	var o = dialog.build_options()
	_assert(o.start_tick == 960 and o.end_tick == 1920, "selection range used by default when present")
	_assert(o.master_path == "/tmp/out/My Mix.wav" and o.bit_depth == 24, "master path and default bit depth")
	_assert(o.stems.is_empty(), "no stems until channels are checked")
	dialog._stem_tree.get_root().get_child(0).set_checked(0, true)
	o = dialog.build_options()
	_assert(o.stems.size() == 1 and o.stems[0].channel_id == channel.id, "checked channel becomes a stem")
	_assert(o.stems[0].path == "/tmp/out/My Mix - Bass.wav", "stem path sits next to the master")
	dialog._master_check.button_pressed = false
	_assert(dialog.build_options().master_path == "", "master unchecked drops the master path")
	dialog._range_option.select(EAD.RangeMode.PROJECT)
	_assert(dialog.selected_range().start == 0, "project range starts at 0")
	_assert(EAD.project_end_ticks(load("res://data/Project.gd").new()) == 0, "empty project has no end")
	service.queue_free()
	dialog.queue_free()
