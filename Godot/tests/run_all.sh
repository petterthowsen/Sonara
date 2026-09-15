#!/usr/bin/env bash
# Runs every headless GDScript test script and reports a summary.
# Usage: tests/run_all.sh (run from Godot/, or from anywhere - it cds itself)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$GODOT_DIR"

mapfile -t TEST_SCRIPTS < <(find . -name 'test_*.gd' -not -path './addons/*' | sort)

if [ "${#TEST_SCRIPTS[@]}" -eq 0 ]; then
	echo "No test scripts found."
	exit 1
fi

failures=0
for script in "${TEST_SCRIPTS[@]}"; do
	rel="${script#./}"
	echo "--- $rel ---"
	if godot --headless --path . -s "$rel" -- --test; then
		:
	else
		failures=$((failures + 1))
		echo "*** $rel FAILED ***"
	fi
	echo
done

if [ "$failures" -eq 0 ]; then
	echo "=== All test scripts passed ==="
	exit 0
else
	echo "=== $failures test script(s) failed ==="
	exit 1
fi
