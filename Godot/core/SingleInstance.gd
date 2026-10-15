## The one-UI-at-a-time check (spec 046 REQ-018). A PID file in the runtime folder names the
## running instance; it counts only while that process is alive and runs the same executable
## (a recycled pid belonging to something else is stale). Static and autoload-free for tests.
class_name SingleInstance extends RefCounted

const PID_FILE_NAME := "ui.pid"


static func pid_file_path() -> String:
	return AppPaths.runtime_dir().path_join(PID_FILE_NAME)


## The executable behind `pid`, or "" when the process doesn't exist or can't be inspected.
static func exe_of(pid: int) -> String:
	if pid <= 0:
		return ""
	# A binary replaced by an upgrade while running reads "<path> (deleted)".
	return DirAccess.read_link("/proc/%d/exe" % pid).trim_suffix(" (deleted)")


## True when `pid_file` names a live process running `exe`.
static func is_running_instance(pid_file: String, exe: String, exe_lookup: Callable = exe_of) -> bool:
	if not FileAccess.file_exists(pid_file):
		return false
	var pid := FileAccess.get_file_as_string(pid_file).strip_edges().to_int()
	if pid <= 0:
		return false
	var other_exe: String = exe_lookup.call(pid)
	return not other_exe.is_empty() and other_exe == exe


## Claim the PID file for `pid`. Returns false (and leaves the file alone) when another live
## instance already holds it.
static func claim(pid_file: String, pid: int, exe: String, exe_lookup: Callable = exe_of) -> bool:
	if is_running_instance(pid_file, exe, exe_lookup):
		var holder := FileAccess.get_file_as_string(pid_file).strip_edges().to_int()
		if holder != pid:
			return false
	DirAccess.make_dir_recursive_absolute(pid_file.get_base_dir())
	var file := FileAccess.open(pid_file, FileAccess.WRITE)
	if file == null:
		# Can't write the file: don't lock the user out over it.
		push_warning("SingleInstance: can't write %s" % pid_file)
		return true
	file.store_string(str(pid))
	file.close()
	return true


## Remove the PID file if it still names `pid`.
static func release(pid_file: String, pid: int) -> void:
	if FileAccess.file_exists(pid_file) and FileAccess.get_file_as_string(pid_file).strip_edges().to_int() == pid:
		DirAccess.remove_absolute(pid_file)
