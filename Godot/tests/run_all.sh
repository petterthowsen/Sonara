#!/usr/bin/env bash
# Runs every headless GDScript test script and reports a summary.
# Usage: tests/run_all.sh (run from Godot/, or from anywhere - it cds itself)
# The full output of the last run is also written to logs/tests_last.log (relative to Godot/).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$GODOT_DIR"

LOG_FILE="logs/tests_last.log"
mkdir -p logs
exec > >(tee "$LOG_FILE") 2>&1
echo "Test run started $(date '+%Y-%m-%d %H:%M:%S')"

mapfile -t TEST_SCRIPTS < <(find . -name 'test_*.gd' -not -path './addons/*' | sort)

if [ "${#TEST_SCRIPTS[@]}" -eq 0 ]; then
	echo "No test scripts found."
	exit 1
fi

failures=0
failed_scripts=()
for script in "${TEST_SCRIPTS[@]}"; do
	rel="${script#./}"
	echo "--- $rel ---"
	# Compile errors don't fail _assert(), so a broken script can still exit 0; catch them here.
	output="$(godot --headless --path . -s "$rel" -- --test 2>&1)"
	status=$?
	echo "$output"
	if [ "$status" -eq 0 ] && ! grep -qE 'SCRIPT ERROR|Failed to load script' <<<"$output"; then
		:
	else
		failures=$((failures + 1))
		failed_scripts+=("$rel")
		echo "*** $rel FAILED ***"
	fi
	echo
done

if [ "$failures" -eq 0 ]; then
	echo "=== All test scripts passed ==="
	exit 0
else
	echo "=== $failures test script(s) failed ==="
	printf '  %s\n' "${failed_scripts[@]}"
	exit 1
fi
