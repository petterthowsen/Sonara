#!/usr/bin/env bash
# Print the body of the `## [<version>]` section of CHANGELOG.md (up to the next `## [` heading).
#
#   scripts/changelog_section.sh <version> [changelog-file]
#
# Exits 1 when the section is missing or has no text, so a release without notes fails fast.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
FILE="${2:-$ROOT/CHANGELOG.md}"
[ -n "$VERSION" ] || { echo "usage: $0 <version> [changelog-file]" >&2; exit 2; }
[ -f "$FILE" ] || { echo "$FILE not found" >&2; exit 1; }

BODY="$(awk -v head="## [$VERSION]" '
    index($0, "## [") == 1 { if (on) exit; on = (index($0, head) == 1) ; next }
    on { print }
' "$FILE")"

# Trim leading and trailing blank lines.
BODY="$(printf '%s\n' "$BODY" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
if [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no entry for $VERSION (add a '## [$VERSION] - <date>' section)" >&2
    exit 1
fi
printf '%s\n' "$BODY"
