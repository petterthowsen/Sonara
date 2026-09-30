#!/usr/bin/env bash
# Schema check for DAWproject export (REQ-003): runs the export test, then validates every
# exported project.xml / metadata.xml against the XSDs in tests/fixtures/dawproject/.
# Needs xmllint (package libxml2-utils). Usage: tests/validate_dawproject.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES="$SCRIPT_DIR/fixtures/dawproject"
cd "$GODOT_DIR"

if ! command -v xmllint >/dev/null; then
	echo "xmllint not found - install libxml2-utils" >&2
	exit 1
fi

APP_NAME="$(sed -n 's/^config\/name="\(.*\)"/\1/p' project.godot)"
OUT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/$APP_NAME/dawproject_export"
rm -f "$OUT_DIR"/*.dawproject

output="$(godot --headless --path . -s tests/test_dawproject_export.gd -- --test 2>&1)"
status=$?
if [ "$status" -ne 0 ] || grep -qE 'SCRIPT ERROR|Failed to load script' <<<"$output"; then
	echo "$output"
	echo "*** export test failed ***"
	exit 1
fi

shopt -s nullglob
files=("$OUT_DIR"/*.dawproject)
if [ "${#files[@]}" -eq 0 ]; then
	echo "*** no exported files found in $OUT_DIR ***"
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
for f in "${files[@]}"; do
	name="$(basename "$f")"
	mkdir -p "$tmp/$name"
	unzip -q -o "$f" project.xml metadata.xml -d "$tmp/$name"
	for pair in "project.xml:Project.xsd" "metadata.xml:MetaData.xsd"; do
		xml="${pair%%:*}"
		xsd="${pair##*:}"
		if ! result="$(xmllint --noout --schema "$FIXTURES/$xsd" "$tmp/$name/$xml" 2>&1)"; then
			printf '%s: %s\n%s\n' "$name" "$xml" "$result"
			failures=$((failures + 1))
		fi
	done
done

if [ "$failures" -eq 0 ]; then
	echo "=== ${#files[@]} exported file(s) validate ==="
	exit 0
fi
echo "=== $failures schema failure(s) ==="
exit 1
