#!/usr/bin/env bash
# Runs the headless GDScript test scripts and reports a summary.
# Usage: tests/run_all.sh [-j N] [name_substring ...]   (run from anywhere - it cds itself)
#   -j N              scripts to run in parallel (default 3, or $TEST_JOBS). Each script costs
#                     ~2.7 s of Godot startup, so this is what makes the full run fast.
#   name_substring    only run scripts whose path contains one of these (e.g. clip_drag)
# The output of the last run, in script order, is also written to logs/tests_last.log
# (relative to Godot/).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$GODOT_DIR"

JOBS="${TEST_JOBS:-3}"
FILTERS=()
while [ $# -gt 0 ]; do
	case "$1" in
		-j) JOBS="$2"; shift 2 ;;
		-j*) JOBS="${1#-j}"; shift ;;
		*) FILTERS+=("$1"); shift ;;
	esac
done

LOG_FILE="logs/tests_last.log"
mkdir -p logs
exec > >(tee "$LOG_FILE") 2>&1
echo "Test run started $(date '+%Y-%m-%d %H:%M:%S') (jobs: $JOBS)"

mapfile -t TEST_SCRIPTS < <(find . -name 'test_*.gd' -not -path './addons/*' | sort)
if [ "${#FILTERS[@]}" -gt 0 ]; then
	selected=()
	for script in "${TEST_SCRIPTS[@]}"; do
		for f in "${FILTERS[@]}"; do
			if [[ "$script" == *"$f"* ]]; then selected+=("$script"); break; fi
		done
	done
	TEST_SCRIPTS=("${selected[@]}")
fi

if [ "${#TEST_SCRIPTS[@]}" -eq 0 ]; then
	echo "No test scripts found."
	exit 1
fi

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

# Runs one script; writes its output to $RESULT_DIR/<index>.out and a "pass"/"fail" status file.
run_one() {
	local idx="$1" rel="$2"
	local output status
	output="$(godot --headless --path . -s "$rel" -- --test 2>&1)"
	status=$?
	printf '%s\n' "$output" >"$RESULT_DIR/$idx.out"
	# Compile errors don't fail _assert(), so a broken script can still exit 0; catch them here.
	if [ "$status" -eq 0 ] && ! grep -qE 'SCRIPT ERROR|Failed to load script' <<<"$output"; then
		echo pass >"$RESULT_DIR/$idx.status"
	else
		echo fail >"$RESULT_DIR/$idx.status"
	fi
}

# Wait on the test PIDs only: a bare `wait` would also wait for the tee behind `exec >`.
pids=()
for i in "${!TEST_SCRIPTS[@]}"; do
	run_one "$i" "${TEST_SCRIPTS[$i]#./}" &
	pids+=($!)
	if [ "${#pids[@]}" -ge "$JOBS" ]; then
		wait "${pids[0]}"
		pids=("${pids[@]:1}")
	fi
done
for pid in "${pids[@]}"; do wait "$pid"; done

failures=0
failed_scripts=()
for i in "${!TEST_SCRIPTS[@]}"; do
	rel="${TEST_SCRIPTS[$i]#./}"
	echo "--- $rel ---"
	cat "$RESULT_DIR/$i.out"
	if [ "$(cat "$RESULT_DIR/$i.status")" != "pass" ]; then
		failures=$((failures + 1))
		failed_scripts+=("$rel")
		echo "*** $rel FAILED ***"
	fi
	echo
done

if [ "$failures" -eq 0 ]; then
	echo "=== All ${#TEST_SCRIPTS[@]} test scripts passed ==="
	exit 0
else
	echo "=== $failures of ${#TEST_SCRIPTS[@]} test script(s) failed ==="
	printf '  %s\n' "${failed_scripts[@]}"
	exit 1
fi
