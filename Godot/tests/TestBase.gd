# TestBase.gd
# Shared runner for headless GDScript test scripts. A test script extends
# this instead of SceneTree directly, overrides suite_name() and run_tests(),
# and gets _assert()/pass-fail bookkeeping/exit code for free.
#
# Run one test: godot --headless --path Godot -s tests/test_foo.gd -- --test
# Run all:      tests/run_all.sh
class_name TestBase extends SceneTree


var _failures: int = 0


func _init() -> void:
	# Autoload singletons (Sonara, etc.) aren't resolvable as bare identifiers
	# until the tree has processed at least one frame. Wait one out so suites
	# that touch autoload-referencing scripts (e.g. AiTool) compile cleanly.
	await process_frame
	print("=== %s ===" % suite_name())
	run_tests()
	if _failures == 0:
		print("=== ALL PASSED ===")
	else:
		print("=== FAILED: %d ===" % _failures)
	quit(_failures)


## Override: short name printed as the suite header.
func suite_name() -> String:
	return "Tests"


## Override: call each _test_* method here.
func run_tests() -> void:
	pass


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)
