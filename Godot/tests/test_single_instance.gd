# test_single_instance.gd
# The PID-file check for a second launch (REQ-018) and finding a .sonara argument (REQ-017).
# Run: godot --headless --path Godot -s tests/test_single_instance.gd -- --test
extends TestBase


func suite_name() -> String:
	return "SingleInstance and CLI project path tests"


func run_tests() -> void:
	var dir := OS.get_cache_dir().path_join("sonara_test_single_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var pid_file := dir.path_join("run/ui.pid")
	var exe := "/opt/sonara/Sonara.x86_64"
	var live := func(pid: int) -> String: return exe if pid == 111 else ("/usr/bin/other" if pid == 222 else "")

	_assert(SingleInstance.claim(pid_file, 100, exe, live), "first instance claims the file")
	_assert(FileAccess.get_file_as_string(pid_file) == "100", "file holds our pid")
	# A running instance (pid 111, same exe) blocks a second one.
	FileAccess.open(pid_file, FileAccess.WRITE).store_string("111")
	_assert(not SingleInstance.claim(pid_file, 100, exe, live), "second instance is refused while the first runs")
	_assert(FileAccess.get_file_as_string(pid_file) == "111", "the refused instance leaves the file alone")
	# Stale: dead pid, pid reused by another program, garbage.
	for stale in ["333", "222", "junk", ""]:
		FileAccess.open(pid_file, FileAccess.WRITE).store_string(stale)
		_assert(SingleInstance.claim(pid_file, 100, exe, live), "stale file '%s' does not block" % stale)
	SingleInstance.release(pid_file, 999)
	_assert(FileAccess.file_exists(pid_file), "release leaves another instance's file")
	SingleInstance.release(pid_file, 100)
	_assert(not FileAccess.file_exists(pid_file), "release removes our own file")

	# The real /proc lookup: our own process runs our own executable.
	_assert(SingleInstance.exe_of(OS.get_process_id()) != "", "exe_of reads /proc for this process")
	_assert(SingleInstance.exe_of(0) == "", "no pid, no exe")

	# .sonara arguments, in both forms the desktop can hand us.
	var project := dir.path_join("demo.sonara")
	FileAccess.open(project, FileAccess.WRITE).store_string("{}")
	var find := func(args: Array) -> String: return Sonara.project_path_from_args(PackedStringArray(args))
	_assert(find.call([project]) == project, "positional path (sonara demo.sonara)")
	_assert(find.call(["--fullscreen", project]) == project, "after other arguments")
	_assert(find.call(["file://" + project.uri_encode().replace("%2F", "/")]) == project, "file:// URI")
	_assert(find.call([dir.path_join("missing.sonara")]) == "", "a missing file is ignored")
	_assert(find.call(["--test", "notes.txt"]) == "", "no .sonara argument")
	_assert(find.call([]) == "", "no arguments")
	DirAccess.remove_absolute(project)
	DirAccess.remove_absolute(dir.path_join("run"))
	DirAccess.remove_absolute(dir)
